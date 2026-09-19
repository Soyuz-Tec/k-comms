defmodule CommsCore.Whiteboards.WriteFence do
  @moduledoc false

  alias CommsCore.Repo

  def lock_author!(tenant_id, user_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))",
      ["whiteboard-author:#{tenant_id}:#{user_id}"]
    )

    :ok
  end
end
