defmodule CommsCore.Attachments.UsageQuery do
  @moduledoc "Tenant-scoped inclusive UTC date range for retained aggregate usage."
  @enforce_keys [:tenant_id, :from, :through]
  defstruct [:tenant_id, :from, :through]

  @type t :: %__MODULE__{
          tenant_id: Ecto.UUID.t(),
          from: Date.t(),
          through: Date.t()
        }

  @spec range(t()) ::
          {:ok, {DateTime.t(), DateTime.t(), [Date.t()]}} | {:error, :invalid_usage_query}
  def range(%__MODULE__{
        tenant_id: tenant_id,
        from: %Date{calendar: Calendar.ISO} = from,
        through: %Date{calendar: Calendar.ISO} = through
      }) do
    span = Date.diff(through, from)

    if match?({:ok, _}, Ecto.UUID.cast(tenant_id)) and span in 0..30 and
         Date.compare(through, Date.utc_today()) != :gt do
      days = Enum.map(0..span, &Date.add(from, &1))
      start_at = DateTime.new!(from, ~T[00:00:00.000000], "Etc/UTC")
      end_at = DateTime.new!(Date.add(through, 1), ~T[00:00:00.000000], "Etc/UTC")
      {:ok, {start_at, end_at, days}}
    else
      {:error, :invalid_usage_query}
    end
  end

  def range(_), do: {:error, :invalid_usage_query}
end
