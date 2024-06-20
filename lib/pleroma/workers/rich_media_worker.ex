# Pleroma: A lightweight social networking server
# Copyright © 2017-2022 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Workers.RichMediaWorker do
  alias Pleroma.Web.RichMedia.Card

  use Oban.Worker,
    queue: :background

  @impl Oban.Worker
  def perform(%Job{args: %{"op" => "expire", "url" => url} = _args}) do
    Card.delete(url)
  end
end
