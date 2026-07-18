defmodule CommsCore.ValidationError do
  @moduledoc "Stable validation error contract for adapter rendering."

  defstruct [:details]

  @type t :: %__MODULE__{details: map()}

  @spec from(term()) :: {:ok, t()} | :error
  def from(%Ecto.Changeset{} = changeset) do
    details =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, text ->
          String.replace(text, "%{#{key}}", to_string(value))
        end)
      end)

    {:ok, %__MODULE__{details: details}}
  end

  def from(_reason), do: :error
end
