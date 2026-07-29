defmodule CommsCore.Accounts.Directory do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Accounts.{
    AccessGrant,
    Device,
    DirectoryPersonView,
    NotificationRecipient,
    Projector,
    RetainedSenderLabelView,
    User,
    UserView
  }

  alias CommsCore.Administration.AdmissionPolicy
  alias CommsCore.{AdmissionQuotas, Repo}

  @default_directory_limit 25
  @max_directory_limit 100
  @max_retained_sender_label_ids 200

  @spec active_user_count(Ecto.UUID.t()) :: non_neg_integer()
  def active_user_count(tenant_id) when is_binary(tenant_id) do
    timestamp = now()

    User
    |> where(
      [user],
      user.tenant_id == ^tenant_id and user.status == :active and
        (user.account_type != :guest or
           (not is_nil(user.guest_expires_at) and user.guest_expires_at > ^timestamp))
    )
    |> Repo.aggregate(:count)
  end

  @spec persisted_guest_identity_count() :: non_neg_integer()
  def persisted_guest_identity_count do
    User
    |> where([user], user.account_type == :guest)
    |> Repo.aggregate(:count)
  end

  @spec persisted_conversation_only_human_count() :: non_neg_integer()
  def persisted_conversation_only_human_count do
    User
    |> where(
      [user],
      user.account_type == :human and user.access_scope == :conversation_only
    )
    |> Repo.aggregate(:count)
  end

  @spec resolve_active_user_ids(String.t(), [String.t()]) :: [String.t()]
  def resolve_active_user_ids(tenant_id, user_ids)
      when is_binary(tenant_id) and is_list(user_ids) do
    User
    |> where(
      [user],
      user.tenant_id == ^tenant_id and user.id in ^user_ids and user.status == :active and
        user.account_type in [:human, :service] and user.access_scope == :workspace
    )
    |> order_by([user], asc: user.id)
    |> select([user], user.id)
    |> Repo.all()
  end

  def resolve_active_user_ids(_tenant_id, _user_ids), do: []

  @spec resolve_user_views(String.t(), [String.t()]) :: [UserView.t()]
  def resolve_user_views(tenant_id, user_ids)
      when is_binary(tenant_id) and is_list(user_ids) do
    timestamp = now()

    User
    |> where(
      [user],
      user.tenant_id == ^tenant_id and user.id in ^user_ids and
        (user.account_type != :guest or
           (not is_nil(user.guest_expires_at) and user.guest_expires_at > ^timestamp))
    )
    |> order_by([user], asc: user.display_name, asc: user.id)
    |> Repo.all()
    |> Enum.map(&Projector.user/1)
  end

  def resolve_user_views(_tenant_id, _user_ids), do: []

  @spec resolve_retained_sender_labels(String.t(), [String.t()]) ::
          [RetainedSenderLabelView.t()]
  def resolve_retained_sender_labels(tenant_id, user_ids)
      when is_binary(tenant_id) and is_list(user_ids) do
    normalized_ids = user_ids |> Enum.uniq() |> Enum.sort()

    cond do
      not valid_uuid?(tenant_id) ->
        []

      normalized_ids == [] or length(normalized_ids) > @max_retained_sender_label_ids ->
        []

      not Enum.all?(normalized_ids, &valid_uuid?/1) ->
        []

      true ->
        User
        |> where(
          [user],
          user.tenant_id == ^tenant_id and user.id in ^normalized_ids
        )
        |> order_by([user], asc: user.id)
        |> select([user], %{
          id: user.id,
          display_name: user.display_name,
          status: user.status
        })
        |> Repo.all()
        |> Enum.map(fn user ->
          struct!(RetainedSenderLabelView, %{
            id: user.id,
            display_name:
              if(user.status == :deleted, do: "Deleted user", else: user.display_name),
            redacted: user.status == :deleted
          })
        end)
    end
  end

  def resolve_retained_sender_labels(_tenant_id, _user_ids), do: []

  @spec list_directory_views(map(), AccessGrant.t()) ::
          {:ok,
           %{
             people: [DirectoryPersonView.t()],
             next_cursor: String.t() | nil
           }}
          | {:error, :invalid_cursor | :invalid_search_query}
  def list_directory_views(params, %AccessGrant{access_scope: :workspace} = grant)
      when is_map(params) do
    with {:ok, cursor} <- optional_directory_cursor(value(params, :cursor)),
         {:ok, search} <- normalize_directory_search(value(params, :q)) do
      limit = parse_directory_limit(value(params, :limit))

      rows =
        User
        |> where(
          [user],
          user.tenant_id == ^grant.tenant_id and user.status == :active and
            user.account_type == :human and user.access_scope == :workspace and
            user.id != ^grant.user_id
        )
        |> maybe_search_directory(search)
        |> maybe_after_directory_cursor(cursor)
        |> order_by([user], asc: fragment("lower(?)", user.display_name), asc: user.id)
        |> select([user], %{
          user: user,
          sort_name: fragment("lower(?)", user.display_name)
        })
        |> limit(^(limit + 1))
        |> Repo.all()

      {page, remainder} = Enum.split(rows, limit)

      {:ok,
       %{
         people: Enum.map(page, fn row -> Projector.directory_person(row.user) end),
         next_cursor: if(remainder == [], do: nil, else: directory_cursor_for(List.last(page)))
       }}
    end
  end

  @spec lock_active_human_directory_users(Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, [DirectoryPersonView.t()]}
          | {:error, :not_found | :transaction_required}
  def lock_active_human_directory_users(tenant_id, user_ids)
      when is_binary(tenant_id) and is_list(user_ids) do
    normalized_ids = user_ids |> Enum.uniq() |> Enum.sort()

    cond do
      not Repo.in_transaction?() ->
        {:error, :transaction_required}

      not valid_uuid?(tenant_id) or normalized_ids == [] or
          not Enum.all?(normalized_ids, &valid_uuid?/1) ->
        {:error, :not_found}

      true ->
        users =
          Repo.all(
            from(user in User,
              where:
                user.tenant_id == ^tenant_id and user.id in ^normalized_ids and
                  user.status == :active and user.account_type == :human and
                  user.access_scope == :workspace,
              order_by: [asc: user.id],
              lock: "FOR SHARE"
            )
          )

        if Enum.map(users, & &1.id) == normalized_ids do
          {:ok, Enum.map(users, &Projector.directory_person/1)}
        else
          {:error, :not_found}
        end
    end
  end

  def lock_active_human_directory_users(_tenant_id, _user_ids), do: {:error, :not_found}

  @spec validate_governance_user(String.t(), String.t()) :: :ok | {:error, :not_found}
  def validate_governance_user(tenant_id, user_id) do
    if valid_uuid?(tenant_id) and valid_uuid?(user_id) and
         Repo.exists?(
           from(user in User, where: user.tenant_id == ^tenant_id and user.id == ^user_id)
         ) do
      :ok
    else
      {:error, :not_found}
    end
  end

  @spec validate_moderation_assignee(String.t(), String.t()) ::
          :ok | {:error, :invalid_assignee}
  def validate_moderation_assignee(tenant_id, user_id) do
    eligible? =
      valid_uuid?(tenant_id) and valid_uuid?(user_id) and
        Repo.exists?(
          from(user in User,
            where:
              user.tenant_id == ^tenant_id and user.id == ^user_id and
                user.status == :active and user.role in [:owner, :admin, :moderator]
          )
        )

    if eligible?, do: :ok, else: {:error, :invalid_assignee}
  end

  @spec retention_actor_id(String.t()) ::
          {:ok, String.t()} | {:error, :last_owner_required}
  def retention_actor_id(tenant_id) do
    owner_id =
      if valid_uuid?(tenant_id) do
        User
        |> where([user], user.tenant_id == ^tenant_id and user.role == :owner)
        |> where([user], user.status == :active)
        |> order_by([user], asc: user.inserted_at, asc: user.id)
        |> select([user], user.id)
        |> limit(1)
        |> Repo.one()
      end

    if owner_id, do: {:ok, owner_id}, else: {:error, :last_owner_required}
  end

  @spec resolve_notification_recipients(String.t(), [String.t()]) ::
          [NotificationRecipient.t()]
  def resolve_notification_recipients(tenant_id, user_ids)
      when is_binary(tenant_id) and is_list(user_ids) do
    User
    |> where(
      [user],
      user.tenant_id == ^tenant_id and user.id in ^user_ids and user.status == :active and
        user.account_type == :human and user.access_scope == :workspace
    )
    |> order_by([user], asc: user.id)
    |> select([user], %{user_id: user.id, email: user.email})
    |> Repo.all()
    |> Enum.map(&struct!(NotificationRecipient, &1))
  end

  def resolve_notification_recipients(_tenant_id, _user_ids), do: []

  @spec notification_eligible_device_ids(String.t(), String.t(), [String.t()]) :: [String.t()]
  def notification_eligible_device_ids(tenant_id, user_id, device_ids)
      when is_binary(tenant_id) and is_binary(user_id) and is_list(device_ids) do
    Device
    |> join(:inner, [device], user in User,
      on: user.id == device.user_id and user.tenant_id == device.tenant_id
    )
    |> where(
      [device, user],
      device.tenant_id == ^tenant_id and device.user_id == ^user_id and
        device.id in ^device_ids and is_nil(device.revoked_at) and user.id == ^user_id and
        user.status == :active and user.account_type == :human
    )
    |> order_by([device, _user], asc: device.id)
    |> select([device, _user], device.id)
    |> Repo.all()
  end

  def notification_eligible_device_ids(_tenant_id, _user_id, _device_ids), do: []

  @spec lock_push_registration_identity(String.t(), String.t(), String.t()) ::
          :ok | {:error, :forbidden | :transaction_required}
  def lock_push_registration_identity(tenant_id, user_id, device_id)
      when is_binary(tenant_id) and is_binary(user_id) and is_binary(device_id) do
    if Repo.in_transaction?() do
      with %User{} <-
             Repo.one(
               from(user in User,
                 where:
                   user.id == ^user_id and user.tenant_id == ^tenant_id and
                     user.status == :active and user.account_type == :human,
                 lock: "FOR SHARE"
               )
             ),
           %Device{} <-
             Repo.one(
               from(device in Device,
                 where:
                   device.id == ^device_id and device.tenant_id == ^tenant_id and
                     device.user_id == ^user_id and is_nil(device.revoked_at),
                 lock: "FOR SHARE"
               )
             ) do
        :ok
      else
        _ -> {:error, :forbidden}
      end
    else
      {:error, :transaction_required}
    end
  end

  def lock_push_registration_identity(_tenant_id, _user_id, _device_id),
    do: {:error, :forbidden}

  @spec ensure_active_user_capacity(Ecto.UUID.t(), AdmissionPolicy.t(), pos_integer()) ::
          :ok
          | {:error, :active_user_quota_exceeded | :quota_transaction_required}
  def ensure_active_user_capacity(tenant_id, %AdmissionPolicy{} = policy, increment \\ 1)
      when is_binary(tenant_id) and is_integer(increment) and increment > 0 do
    if Repo.in_transaction?() do
      AdmissionQuotas.check_active_user_capacity(
        policy,
        active_user_count(tenant_id),
        increment
      )
    else
      {:error, :quota_transaction_required}
    end
  end

  defp normalize_directory_search(nil), do: {:ok, nil}

  defp normalize_directory_search(value) when is_binary(value) do
    search = String.trim(value)

    cond do
      search == "" -> {:ok, nil}
      String.length(search) <= 120 -> {:ok, search}
      true -> {:error, :invalid_search_query}
    end
  end

  defp normalize_directory_search(_value), do: {:error, :invalid_search_query}

  defp maybe_search_directory(query, nil), do: query

  defp maybe_search_directory(query, search) do
    pattern = "%#{escape_directory_like(search)}%"

    where(
      query,
      [user],
      ilike(user.display_name, ^pattern)
    )
  end

  defp escape_directory_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp optional_directory_cursor(nil), do: {:ok, nil}
  defp optional_directory_cursor(""), do: {:ok, nil}

  defp optional_directory_cursor(value) when is_binary(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"display_name" => display_name, "id" => id}} <- Jason.decode(decoded),
         true <- is_binary(display_name) and String.length(display_name) <= 120,
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {display_name, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp optional_directory_cursor(_value), do: {:error, :invalid_cursor}

  defp maybe_after_directory_cursor(query, nil), do: query

  defp maybe_after_directory_cursor(query, {display_name, id}) do
    where(
      query,
      [user],
      fragment("lower(?)", user.display_name) > ^display_name or
        (fragment("lower(?)", user.display_name) == ^display_name and user.id > ^id)
    )
  end

  defp directory_cursor_for(nil), do: nil

  defp directory_cursor_for(%{sort_name: sort_name, user: %User{id: id}}) do
    %{display_name: sort_name, id: id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp parse_directory_limit(value) when is_integer(value),
    do: value |> max(1) |> min(@max_directory_limit)

  defp parse_directory_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> parse_directory_limit(number)
      _ -> @default_directory_limit
    end
  end

  defp parse_directory_limit(_value), do: @default_directory_limit

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
