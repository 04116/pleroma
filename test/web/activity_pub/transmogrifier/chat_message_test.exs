# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.ChatMessageTest do
  use Pleroma.DataCase

  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.Chat
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Transmogrifier

  describe "handle_incoming" do
    test "it rejects messages that don't contain content" do
      data =
        File.read!("test/fixtures/create-chat-message.json")
        |> Poison.decode!()

      object =
        data["object"]
        |> Map.delete("content")

      data =
        data
        |> Map.put("object", object)

      _author =
        insert(:user, ap_id: data["actor"], local: false, last_refreshed_at: DateTime.utc_now())

      _recipient =
        insert(:user,
          ap_id: List.first(data["to"]),
          local: true,
          last_refreshed_at: DateTime.utc_now()
        )

      {:error, _} = Transmogrifier.handle_incoming(data)
    end

    test "it rejects messages that don't concern local users" do
      data =
        File.read!("test/fixtures/create-chat-message.json")
        |> Poison.decode!()

      _author =
        insert(:user, ap_id: data["actor"], local: false, last_refreshed_at: DateTime.utc_now())

      _recipient =
        insert(:user,
          ap_id: List.first(data["to"]),
          local: false,
          last_refreshed_at: DateTime.utc_now()
        )

      {:error, _} = Transmogrifier.handle_incoming(data)
    end

    test "it rejects messages where the `to` field of activity and object don't match" do
      data =
        File.read!("test/fixtures/create-chat-message.json")
        |> Poison.decode!()

      author = insert(:user, ap_id: data["actor"])
      _recipient = insert(:user, ap_id: List.first(data["to"]))

      data =
        data
        |> Map.put("to", author.ap_id)

      assert match?({:error, _}, Transmogrifier.handle_incoming(data))
      refute Object.get_by_ap_id(data["object"]["id"])
    end

    test "it fetches the actor if they aren't in our system" do
      Tesla.Mock.mock(fn env -> apply(HttpRequestMock, :request, [env]) end)

      data =
        File.read!("test/fixtures/create-chat-message.json")
        |> Poison.decode!()
        |> Map.put("actor", "http://mastodon.example.org/users/admin")
        |> put_in(["object", "actor"], "http://mastodon.example.org/users/admin")

      _recipient = insert(:user, ap_id: List.first(data["to"]), local: true)

      {:ok, %Activity{} = _activity} = Transmogrifier.handle_incoming(data)
    end

    test "it inserts it and creates a chat" do
      data =
        File.read!("test/fixtures/create-chat-message.json")
        |> Poison.decode!()

      author =
        insert(:user, ap_id: data["actor"], local: false, last_refreshed_at: DateTime.utc_now())

      recipient = insert(:user, ap_id: List.first(data["to"]), local: true)

      {:ok, %Activity{} = activity} = Transmogrifier.handle_incoming(data)
      assert activity.local == false

      assert activity.actor == author.ap_id
      assert activity.recipients == [recipient.ap_id, author.ap_id]

      %Object{} = object = Object.get_by_ap_id(activity.data["object"])

      assert object
      assert object.data["content"] == "You expected a cute girl? Too bad. alert(&#39;XSS&#39;)"
      assert match?(%{"firefox" => _}, object.data["emoji"])

      refute Chat.get(author.id, recipient.ap_id)
      assert Chat.get(recipient.id, author.ap_id)
    end
  end
end
