# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.ActivityPub.Transmogrifier.ChatMessageTest do
  use Pleroma.DataCase

  import Pleroma.Factory

  alias Pleroma.Activity
  alias Pleroma.Object
  alias Pleroma.Web.ActivityPub.Transmogrifier

  describe "handle_incoming" do
    test "it insert it" do
      data =
        File.read!("test/fixtures/create-chat-message.json")
        |> Poison.decode!()

      author = insert(:user, ap_id: data["actor"], local: false)
      recipient = insert(:user, ap_id: List.first(data["to"]), local: false)

      {:ok, %Activity{} = activity} = Transmogrifier.handle_incoming(data)

      assert activity.actor == author.ap_id
      assert activity.recipients == [recipient.ap_id, author.ap_id]

      %Object{} = object = Object.get_by_ap_id(activity.data["object"])
      assert object
    end
  end
end
