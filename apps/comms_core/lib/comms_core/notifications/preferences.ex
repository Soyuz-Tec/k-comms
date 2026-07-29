defmodule CommsCore.Notifications.Preferences do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Notifications.{Preference, Projector}
  alias CommsCore.Repo

  def get(subject) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    preference =
      Repo.get_by(Preference, tenant_id: tenant_id, user_id: user_id) ||
        %Preference{
          tenant_id: tenant_id,
          user_id: user_id,
          email_enabled: true,
          push_enabled: false,
          in_app_enabled: true,
          muted_event_types: []
        }

    Projector.preference(preference)
  end

  def update(attrs, subject) when is_map(attrs) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)

    changes = %{
      email_enabled: value(attrs, :email_enabled),
      push_enabled: value(attrs, :push_enabled),
      in_app_enabled: value(attrs, :in_app_enabled),
      muted_event_types: normalize_event_types(value(attrs, :muted_event_types))
    }

    existing = Repo.get_by(Preference, tenant_id: tenant_id, user_id: user_id)

    result =
      (existing || %Preference{tenant_id: tenant_id, user_id: user_id})
      |> Preference.changeset(drop_nil(changes))
      |> Repo.insert_or_update()

    project_result(result)
  end

  def by_recipient_id(_tenant_id, []), do: %{}

  def by_recipient_id(tenant_id, recipients) do
    recipient_ids = Enum.map(recipients, & &1.user_id)

    Repo.all(
      from(preference in Preference,
        where: preference.tenant_id == ^tenant_id and preference.user_id in ^recipient_ids
      )
    )
    |> Map.new(&{&1.user_id, &1})
  end

  defp normalize_event_types(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(100)
  end

  defp normalize_event_types(nil), do: nil
  defp normalize_event_types(_), do: []
  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp project_result({:ok, value}), do: {:ok, Projector.preference(value)}
  defp project_result({:error, _reason} = error), do: error
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
