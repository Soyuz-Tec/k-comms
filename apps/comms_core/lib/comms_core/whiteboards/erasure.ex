defmodule CommsCore.Whiteboards.Erasure do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Repo
  alias CommsCore.Whiteboards.{Operation, Whiteboard}

  @empty_result %{
    whiteboards_deleted: 0,
    whiteboard_operations_deleted: 0,
    whiteboard_operations_neutralized: 0
  }

  @spec erase_for_governance(
          Ecto.UUID.t(),
          :conversation | :user,
          Ecto.UUID.t(),
          DateTime.t()
        ) ::
          {:ok,
           %{
             whiteboards_deleted: non_neg_integer(),
             whiteboard_operations_deleted: non_neg_integer(),
             whiteboard_operations_neutralized: non_neg_integer()
           }}
          | {:error, :invalid_erasure_scope | :transaction_required}
  def erase_for_governance(tenant_id, target_type, target_id, %DateTime{})
      when is_binary(tenant_id) and target_type in [:conversation, :user] and
             is_binary(target_id) do
    if Repo.in_transaction?() do
      with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
           {:ok, target_id} <- Ecto.UUID.cast(target_id) do
        erase(tenant_id, target_type, target_id)
      else
        _ -> {:error, :invalid_erasure_scope}
      end
    else
      {:error, :transaction_required}
    end
  end

  def erase_for_governance(_, _, _, _), do: {:error, :invalid_erasure_scope}

  defp erase(tenant_id, :conversation, conversation_id) do
    {operations_deleted, _} =
      Repo.delete_all(
        from(operation in Operation,
          where:
            operation.tenant_id == ^tenant_id and
              operation.conversation_id == ^conversation_id
        )
      )

    {whiteboards_deleted, _} =
      Repo.delete_all(
        from(whiteboard in Whiteboard,
          where:
            whiteboard.tenant_id == ^tenant_id and
              whiteboard.conversation_id == ^conversation_id
        )
      )

    {:ok,
     %{
       @empty_result
       | whiteboards_deleted: whiteboards_deleted,
         whiteboard_operations_deleted: operations_deleted
     }}
  end

  defp erase(tenant_id, :user, user_id) do
    {operations_neutralized, _} =
      Repo.update_all(
        from(operation in Operation,
          where:
            operation.tenant_id == ^tenant_id and
              operation.actor_user_id == ^user_id and
              operation.kind == "scene.update"
        ),
        set: [payload: %{"elements" => []}]
      )

    {:ok, %{@empty_result | whiteboard_operations_neutralized: operations_neutralized}}
  end
end
