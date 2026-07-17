defmodule CommsCore.Audit.Error do
  @moduledoc "Persistence-neutral audit command error."

  @enforce_keys [:reason, :errors]
  defstruct [:reason, :errors]

  @type t :: %__MODULE__{
          reason: :invalid_audit_event,
          errors: %{optional(atom()) => [String.t()]}
        }

  @doc false
  def from_changeset(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
        Enum.reduce(options, message, fn {key, value}, rendered ->
          String.replace(rendered, "%{#{key}}", to_string(value))
        end)
      end)

    %__MODULE__{reason: :invalid_audit_event, errors: errors}
  end
end
