# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.Plugs.UserEnabledPlug do
  alias Pleroma.Helpers.AuthHelper
  alias Pleroma.User

  def init(options) do
    options
  end

  def call(%{assigns: %{user: %User{} = user}} = conn, _) do
    case User.account_status(user) do
      :active ->
        conn

      _ ->
        AuthHelper.drop_auth_info(conn)
    end
  end

  def call(conn, _) do
    conn
  end
end
