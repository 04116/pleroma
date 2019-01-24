# Pleroma: A lightweight social networking server
# Copyright © 2017-2019 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Salmon do
  @httpoison Application.get_env(:pleroma, :httpoison)

  use Bitwise
  alias Pleroma.Instances
  alias Pleroma.Web.XML
  alias Pleroma.Web.OStatus.ActivityRepresenter
  alias Pleroma.User
  require Logger

  def decode(salmon) do
    doc = XML.parse_document(salmon)

    {:xmlObj, :string, data} = :xmerl_xpath.string('string(//me:data[1])', doc)
    {:xmlObj, :string, sig} = :xmerl_xpath.string('string(//me:sig[1])', doc)
    {:xmlObj, :string, alg} = :xmerl_xpath.string('string(//me:alg[1])', doc)
    {:xmlObj, :string, encoding} = :xmerl_xpath.string('string(//me:encoding[1])', doc)
    {:xmlObj, :string, type} = :xmerl_xpath.string('string(//me:data[1]/@type)', doc)

    {:ok, data} = Base.url_decode64(to_string(data), ignore: :whitespace)
    {:ok, sig} = Base.url_decode64(to_string(sig), ignore: :whitespace)
    alg = to_string(alg)
    encoding = to_string(encoding)
    type = to_string(type)

    [data, type, encoding, alg, sig]
  end

  def fetch_magic_key(salmon) do
    with [data, _, _, _, _] <- decode(salmon),
         doc <- XML.parse_document(data),
         uri when not is_nil(uri) <- XML.string_from_xpath("/entry/author[1]/uri", doc),
         {:ok, public_key} <- User.get_public_key_for_ap_id(uri),
         magic_key <- encode_key(public_key) do
      {:ok, magic_key}
    end
  end

  def decode_and_validate(magickey, salmon) do
    [data, type, encoding, alg, sig] = decode(salmon)

    signed_text =
      [data, type, encoding, alg]
      |> Enum.map(&Base.url_encode64/1)
      |> Enum.join(".")

    key = decode_key(magickey)

    verify = :public_key.verify(signed_text, :sha256, sig, key)

    if verify do
      {:ok, data}
    else
      :error
    end
  end

  def decode_key("RSA." <> magickey) do
    make_integer = fn bin ->
      list = :erlang.binary_to_list(bin)
      Enum.reduce(list, 0, fn el, acc -> acc <<< 8 ||| el end)
    end

    [modulus, exponent] =
      magickey
      |> String.split(".")
      |> Enum.map(fn n -> Base.url_decode64!(n, padding: false) end)
      |> Enum.map(make_integer)

    {:RSAPublicKey, modulus, exponent}
  end

  def encode_key({:RSAPublicKey, modulus, exponent}) do
    modulus_enc = :binary.encode_unsigned(modulus) |> Base.url_encode64()
    exponent_enc = :binary.encode_unsigned(exponent) |> Base.url_encode64()

    "RSA.#{modulus_enc}.#{exponent_enc}"
  end

  # Native generation of RSA keys is only available since OTP 20+ and in default build conditions
  # We try at compile time to generate natively an RSA key otherwise we fallback on the old way.
  try do
    _ = :public_key.generate_key({:rsa, 2048, 65537})

    def generate_rsa_pem do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
      pem = :public_key.pem_encode([entry]) |> String.trim_trailing()
      {:ok, pem}
    end
  rescue
    _ ->
      def generate_rsa_pem do
        port = Port.open({:spawn, "openssl genrsa"}, [:binary])

        {:ok, pem} =
          receive do
            {^port, {:data, pem}} -> {:ok, pem}
          end

        Port.close(port)

        if Regex.match?(~r/RSA PRIVATE KEY/, pem) do
          {:ok, pem}
        else
          :error
        end
      end
  end

  def keys_from_pem(pem) do
    [private_key_code] = :public_key.pem_decode(pem)
    private_key = :public_key.pem_entry_decode(private_key_code)
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = private_key
    public_key = {:RSAPublicKey, modulus, exponent}
    {:ok, private_key, public_key}
  end

  def encode(private_key, doc) do
    type = "application/atom+xml"
    encoding = "base64url"
    alg = "RSA-SHA256"

    signed_text =
      [doc, type, encoding, alg]
      |> Enum.map(&Base.url_encode64/1)
      |> Enum.join(".")

    signature =
      signed_text
      |> :public_key.sign(:sha256, private_key)
      |> to_string
      |> Base.url_encode64()

    doc_base64 =
      doc
      |> Base.url_encode64()

    # Don't need proper xml building, these strings are safe to leave unescaped
    salmon = """
    <?xml version="1.0" encoding="UTF-8"?>
    <me:env xmlns:me="http://salmon-protocol.org/ns/magic-env">
      <me:data type="application/atom+xml">#{doc_base64}</me:data>
      <me:encoding>#{encoding}</me:encoding>
      <me:alg>#{alg}</me:alg>
      <me:sig>#{signature}</me:sig>
    </me:env>
    """

    {:ok, salmon}
  end

  def remote_users(%{data: %{"to" => to} = data}) do
    to = to ++ (data["cc"] || [])

    to
    |> Enum.map(fn id -> User.get_cached_by_ap_id(id) end)
    |> Enum.filter(fn user -> user && !user.local end)
  end

  # push an activity to remote accounts
  #
  defp send_to_user(%{info: %{salmon: salmon}}, feed, poster),
    do: send_to_user(salmon, feed, poster)

  defp send_to_user(url, feed, poster) when is_binary(url) do
    with {:reachable, true} <- {:reachable, Instances.reachable?(url)},
         {:ok, %{status: code}} when code in 200..299 <-
           poster.(
             url,
             feed,
             [
               {"Content-Type", "application/magic-envelope+xml"},
               {"referer", Pleroma.Web.Endpoint.url()}
             ]
           ) do
      Instances.set_reachable(url)
      Logger.debug(fn -> "Pushed to #{url}, code #{code}" end)
    else
      {:reachable, false} ->
        Logger.debug(fn -> "Pushing Salmon to #{url} skipped as marked unreachable)" end)
        :noop

      e ->
        Instances.set_unreachable(url)
        Logger.debug(fn -> "Pushing Salmon to #{url} failed, #{inspect(e)}" end)
    end
  end

  defp send_to_user(_, _, _), do: nil

  @supported_activities [
    "Create",
    "Follow",
    "Like",
    "Announce",
    "Undo",
    "Delete"
  ]

  @doc """
  Publishes an activity to remote accounts
  """
  @spec publish(User.t(), Pleroma.Activity.t(), Pleroma.HTTP.t()) :: none
  def publish(user, activity, poster \\ &@httpoison.post/3)

  def publish(%{info: %{keys: keys}} = user, %{data: %{"type" => type}} = activity, poster)
      when type in @supported_activities do
    feed = ActivityRepresenter.to_simple_form(activity, user, true)

    if feed do
      feed =
        ActivityRepresenter.wrap_with_entry(feed)
        |> :xmerl.export_simple(:xmerl_xml)
        |> to_string

      {:ok, private, _} = keys_from_pem(keys)
      {:ok, feed} = encode(private, feed)

      remote_users = remote_users(activity)

      salmon_urls = Enum.map(remote_users, & &1.info.salmon)
      reachable_salmon_urls = Instances.filter_reachable(salmon_urls)

      remote_users
      |> Enum.filter(&(&1.info.salmon in reachable_salmon_urls))
      |> Enum.each(fn remote_user ->
        Task.start(fn ->
          Logger.debug(fn -> "Sending Salmon to #{remote_user.ap_id}" end)
          send_to_user(remote_user, feed, poster)
        end)
      end)
    end
  end

  def publish(%{id: id}, _, _), do: Logger.debug(fn -> "Keys missing for user #{id}" end)
end
