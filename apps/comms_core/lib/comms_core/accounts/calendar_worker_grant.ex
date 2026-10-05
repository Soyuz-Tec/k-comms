defmodule CommsCore.Accounts.CalendarWorkerGrant do
  @moduledoc "Retained offline identity facts. Cleanup never conveys export permission."
  @enforce_keys [:tenant_id, :user_id, :purpose]
  defstruct [:tenant_id, :user_id, :purpose]
  @type t :: %__MODULE__{tenant_id: binary(), user_id: binary(), purpose: :export | :cleanup}
end
