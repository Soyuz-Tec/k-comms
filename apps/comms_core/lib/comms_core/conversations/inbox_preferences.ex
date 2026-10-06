defmodule CommsCore.Conversations.InboxPreferences do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, Repo}
  alias CommsCore.Conversations.{AccessPolicy, Membership}

  def put_favorite(conversation_id, favorite, subject) when is_boolean(favorite) do
    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id) do
      deadline = System.monotonic_time(:millisecond) + 15_000

      Repo.transaction(
        fn ->
          grant =
            case Accounts.lock_content_write_grant(subject, deadline) do
              {:ok, %{account_type: :human, access_scope: :workspace} = grant} -> grant
              {:ok, _} -> Repo.rollback(:forbidden)
              {:error, reason} -> Repo.rollback(reason)
            end

          authorization = AccessPolicy.active_membership_authorization_query(grant)
          # The update retains the membership row through commit. It cannot set
          # another person's preference or resurrect a departed membership.
          {count, _} =
            Repo.update_all(
              from(m in Membership,
                where:
                  m.tenant_id == ^grant.tenant_id and m.user_id == ^grant.user_id and
                    m.conversation_id == ^conversation_id and is_nil(m.left_at) and
                    m.conversation_id in subquery(
                      from(a in subquery(authorization), select: a.conversation_id)
                    )
              ),
              set: [favorite: favorite]
            )

          if count != 1, do: Repo.rollback(:not_found)
          %{conversation_id: conversation_id, favorite: favorite}
        end,
        timeout: 20_000
      )
    else
      :error -> {:error, :not_found}
    end
  end

  def put_favorite(_, _, _), do: {:error, :invalid_favorite}
end
