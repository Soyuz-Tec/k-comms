defmodule CommsCore.Administration.WorkspaceDomainErasure do
  @moduledoc "Narrow owner-command boundary for governed personal DNS challenge erasure."

  alias CommsCore.Administration.DomainUserErasureCommand
  alias CommsCore.Administration.DomainUserErasureReceipt
  alias CommsCore.Administration.WorkspaceDomains

  @spec erase_user_challenges(DomainUserErasureCommand.t()) ::
          {:ok, DomainUserErasureReceipt.t()} | {:error, atom()}
  defdelegate erase_user_challenges(command), to: WorkspaceDomains
end
