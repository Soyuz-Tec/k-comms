defmodule CommsCore.Telephony.IvrMenu do
  @moduledoc false
  use CommsCore.Schema

  schema "telephony_ivr_menus" do
    field(:tenant_id, :binary_id)
    field(:number_id, :binary_id)
    field(:name, :string)
    field(:prompt_media, :string)
    field(:choices, :map, default: %{})
    field(:fallback, :map, default: %{"kind" => "hangup"})
    field(:digit_timeout_seconds, :integer, default: 10)
    field(:max_retries, :integer, default: 1)
    field(:enabled, :boolean, default: false)
    field(:version, :integer, default: 1)
    timestamps()
  end

  def changeset(menu, attrs) do
    menu
    |> cast(attrs, __schema__(:fields) -- [:inserted_at, :updated_at])
    |> validate_required([
      :tenant_id,
      :number_id,
      :name,
      :prompt_media,
      :choices,
      :fallback,
      :digit_timeout_seconds,
      :max_retries,
      :enabled,
      :version
    ])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_format(:prompt_media, ~r/^sound:[A-Za-z0-9_\/-]{1,150}$/)
    |> validate_number(:digit_timeout_seconds,
      greater_than_or_equal_to: 5,
      less_than_or_equal_to: 30
    )
    |> validate_number(:max_retries, greater_than_or_equal_to: 0, less_than_or_equal_to: 2)
    |> validate_number(:version, greater_than: 0)
    |> validate_change(:choices, fn :choices, choices ->
      if CommsCore.Telephony.IvrStateMachine.valid_choices?(choices),
        do: [],
        else: [choices: "requires one to nine distinct single digits and bounded destinations"]
    end)
    |> validate_change(:fallback, fn :fallback, target ->
      if CommsCore.Telephony.IvrStateMachine.valid_target?(target),
        do: [],
        else: [fallback: "requires a bounded destination"]
    end)
    |> unique_constraint(:number_id)
  end
end
