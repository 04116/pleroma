# Pleroma: A lightweight social networking server
# Copyright © 2017-2019 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Delivery do
  use Ecto.Schema

  alias Pleroma.Delivery
  alias Pleroma.FlakeId
  alias Pleroma.User
  alias Pleroma.Repo
  alias Pleroma.Object
  alias Pleroma.User

  import Ecto.Changeset
  import Ecto.Query

  schema "deliveries" do
    belongs_to(:user, User, type: FlakeId)
    belongs_to(:object, Object)
  end

  def changeset(delivery, params \\ %{}) do
    delivery
    |> cast(params, [:user_id, :object_id])
    |> foreign_key_constraint(:object_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id, name: :deliveries_user_id_object_id_index)
  end

  def create(object_id, user_id) do
    %Delivery{}
    |> changeset(%{user_id: user_id, object_id: object_id})
    |> Repo.insert()
  end

  def get(object_id, user_id) do
    from(d in Delivery, where: d.user_id == ^user_id and d.object_id == ^object_id)
    |> Repo.one()
  end

  def get_or_create(object_id, user_id) do
    case get(object_id, user_id) do
      %Delivery{} = delivery -> {:ok, delivery}
      nil -> create(object_id, user_id)
    end
  end

  def delete_all_by_object_id(object_id) do
    from(d in Delivery, where: d.object_id == ^object_id)
    |> Repo.delete_all()
  end

  def get_all_by_object_id(object_id) do
    from(d in Delivery, where: d.object_id == ^object_id)
    |> Repo.all()
  end
end
