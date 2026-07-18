defmodule CommsCore.Accounts.AccessContext do
  @moduledoc "Authenticated request context returned to the web authentication adapter."
  defstruct [:subject, :session, :tenant, :user, :device]
end
