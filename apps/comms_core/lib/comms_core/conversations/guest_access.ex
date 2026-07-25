defmodule CommsCore.Conversations.GuestAccess do
  @moduledoc false

  import Bitwise
  import Ecto.Query

  alias CommsCore.{
    Accounts,
    Administration,
    AdmissionQuotas,
    Audit,
    Repo,
    RuntimePorts
  }

  alias CommsCore.Conversations.{
    Conversation,
    GuestAdmission,
    GuestAdmissionView,
    GuestLink,
    GuestLinkPreviewView,
    GuestLinkView,
    Membership,
    Projector
  }

  @default_expiry_seconds 24 * 60 * 60
  @min_expiry_seconds 15 * 60
  @max_expiry_seconds 24 * 60 * 60
  @default_max_uses 10
  @verification_secret_bytes 32

  @spec create_link(Ecto.UUID.t(), map(), map()) ::
          {:ok,
           %{
             guest_link: GuestLinkView.t(),
             token: String.t(),
             conversion_verification_code: String.t() | nil
           }}
          | {:error,
             :forbidden
             | :guest_account_conversion_forbidden
             | :guest_account_conversion_requires_single_use
             | :guest_links_not_supported
             | :invalid_guest_conversion_email
             | :invalid_guest_link_expiry
             | :invalid_guest_link_max_uses
             | :step_up_required}
  def create_link(conversation_id, attrs, subject)
      when is_binary(conversation_id) and is_map(attrs) and is_map(subject) do
    with {:ok, grant, conversation} <- manager_scope(conversation_id, subject),
         :ok <- ensure_guest_capable(conversation),
         {:ok, expiry_seconds} <- expiry_seconds(attrs),
         {:ok, max_uses} <- max_uses(attrs),
         {:ok, conversion_email} <- conversion_email(attrs, grant),
         :ok <- validate_conversion_use_limit(conversion_email, max_uses) do
      link_id = Ecto.UUID.generate()
      secret = :crypto.strong_rand_bytes(32)
      token = link_id <> "." <> Base.url_encode64(secret, padding: false)
      token_digest = :crypto.hash(:sha256, secret)

      {conversion_verification_code, conversion_verification_digest} =
        conversion_verification_credentials(
          conversion_email,
          secret,
          grant.tenant_id,
          conversation.id,
          link_id
        )

      Repo.transaction(fn ->
        conversation = lock_managed_conversation!(conversation.id, grant, subject)
        ensure_guest_capable!(conversation)
        authorize_conversion_email!(conversion_email, subject)
        timestamp = now()
        expires_at = DateTime.add(timestamp, expiry_seconds, :second)

        link =
          %GuestLink{id: link_id}
          |> GuestLink.changeset(%{
            tenant_id: conversation.tenant_id,
            conversation_id: conversation.id,
            created_by_user_id: grant.user_id,
            token_digest: token_digest,
            conversion_email: conversion_email,
            conversion_verification_digest: conversion_verification_digest,
            expires_at: expires_at,
            max_uses: max_uses,
            use_count: 0
          })
          |> insert_or_rollback()

        audit!(
          conversation.tenant_id,
          grant.user_id,
          "conversation.guest_link.created",
          "conversation_guest_link",
          link.id,
          %{
            conversation_id: conversation.id,
            expires_at: DateTime.to_iso8601(expires_at),
            max_uses: max_uses,
            conversion_enabled: not is_nil(conversion_email)
          },
          value(subject, :request_id)
        )

        %{
          guest_link: project_link(link, timestamp),
          token: token,
          conversion_verification_code: conversion_verification_code
        }
      end)
      |> transaction_result()
    end
  end

  def create_link(_conversation_id, _attrs, _subject), do: {:error, :forbidden}

  @spec list_links(Ecto.UUID.t(), map()) ::
          {:ok, [GuestLinkView.t()]}
          | {:error, :forbidden | :guest_links_not_supported}
  def list_links(conversation_id, subject)
      when is_binary(conversation_id) and is_map(subject) do
    with {:ok, grant, conversation} <- manager_scope(conversation_id, subject),
         :ok <- ensure_guest_capable(conversation) do
      timestamp = now()

      links =
        GuestLink
        |> where(
          [link],
          link.tenant_id == ^grant.tenant_id and
            link.conversation_id == ^conversation.id
        )
        |> order_by([link], desc: link.inserted_at, desc: link.id)
        |> Repo.all()
        |> Enum.map(&project_link(&1, timestamp))

      {:ok, links}
    end
  end

  def list_links(_conversation_id, _subject), do: {:error, :forbidden}

  @spec revoke_link(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          map(),
          (Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t() ->
             :ok | {:error, term()})
        ) ::
          {:ok, %{guest_link: GuestLinkView.t(), revoked_session_ids: [Ecto.UUID.t()]}}
          | {:error, :forbidden | :guest_link_not_found | :guest_links_not_supported | term()}
  def revoke_link(conversation_id, link_id, subject, call_access_revoker)
      when is_binary(conversation_id) and is_binary(link_id) and is_map(subject) and
             is_function(call_access_revoker, 4) do
    with {:ok, grant, conversation} <- manager_scope(conversation_id, subject),
         :ok <- ensure_guest_capable(conversation),
         {:ok, link_id} <- cast_uuid(link_id) do
      Repo.transaction(fn ->
        _policy = admission_policy!(grant.tenant_id)
        conversation = lock_managed_conversation!(conversation.id, grant, subject)
        ensure_guest_capable!(conversation)

        link =
          Repo.one(
            from(link in GuestLink,
              where:
                link.id == ^link_id and
                  link.tenant_id == ^conversation.tenant_id and
                  link.conversation_id == ^conversation.id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:guest_link_not_found)

        admissions =
          Repo.all(
            from(admission in GuestAdmission,
              where:
                admission.tenant_id == ^link.tenant_id and
                  admission.conversation_id == ^link.conversation_id and
                  admission.guest_link_id == ^link.id and is_nil(admission.revoked_at) and
                  is_nil(admission.converted_at),
              order_by: [asc: admission.id],
              lock: "FOR UPDATE"
            )
          )

        timestamp = now()

        revoked_session_ids =
          Enum.map(
            admissions,
            &revoke_admission!(
              &1,
              timestamp,
              "guest_link_revoked",
              call_access_revoker
            )
          )

        revoked_link =
          if link.revoked_at do
            link
          else
            link
            |> GuestLink.changeset(%{revoked_at: timestamp})
            |> Ecto.Changeset.optimistic_lock(:lock_version)
            |> update_or_rollback()
          end

        if is_nil(link.revoked_at) or revoked_session_ids != [] do
          audit!(
            link.tenant_id,
            grant.user_id,
            "conversation.guest_link.revoked",
            "conversation_guest_link",
            link.id,
            %{
              conversation_id: link.conversation_id,
              revoked_admissions: length(revoked_session_ids)
            },
            value(subject, :request_id)
          )
        end

        %{
          guest_link: project_link(revoked_link, timestamp),
          revoked_session_ids: Enum.uniq(revoked_session_ids)
        }
      end)
      |> transaction_result()
    else
      :error -> {:error, :guest_link_not_found}
      {:error, _reason} = error -> error
    end
  end

  def revoke_link(_conversation_id, _link_id, _subject, _call_access_revoker),
    do: {:error, :forbidden}

  @spec preview_link(String.t()) ::
          {:ok, GuestLinkPreviewView.t()}
          | {:error, :guest_link_unavailable}
  def preview_link(token) when is_binary(token) do
    with {:ok, link_id, secret} <- parse_token(token),
         %GuestLink{} = link <- Repo.get(GuestLink, link_id),
         true <- secure_digest_match?(secret, link.token_digest),
         :ok <- available_link(link, now()),
         %Conversation{} = conversation <- available_guest_conversation(link),
         {:ok, _tenant} <- Administration.active_tenant(link.tenant_id) do
      {:ok,
       %GuestLinkPreviewView{
         room_title: guest_room_title(conversation),
         expires_at: link.expires_at,
         conversion_enabled: not is_nil(link.conversion_email),
         email_hint: email_hint(link.conversion_email)
       }}
    else
      _ -> {:error, :guest_link_unavailable}
    end
  end

  def preview_link(_token), do: {:error, :guest_link_unavailable}

  @spec redeem_link(String.t(), map()) ::
          {:ok,
           %{
             authentication: CommsCore.Accounts.AuthenticationResult.t() | struct(),
             conversation: CommsCore.Conversations.ConversationView.t(),
             admission: GuestAdmissionView.t(),
             capabilities: %{allow_audio_calls: boolean(), allow_video_calls: boolean()}
           }}
          | {:error, term()}
  def redeem_link(token, attrs) when is_binary(token) and is_map(attrs) do
    with {:ok, link_id, secret} <- parse_token(token),
         %GuestLink{tenant_id: tenant_id, conversation_id: conversation_id} = link_snapshot <-
           Repo.get(GuestLink, link_id),
         true <- secure_digest_match?(secret, link_snapshot.token_digest),
         {:ok, display_name} <- display_name(attrs),
         {:ok, device} <- device(attrs) do
      Repo.transaction(fn ->
        policy = admission_policy!(tenant_id)
        conversation = lock_available_guest_conversation!(tenant_id, conversation_id)
        link = lock_available_link!(tenant_id, conversation.id, link_id, secret)
        timestamp = now()
        available_link!(link, timestamp)
        quota_ok!(ensure_conversation_member_capacity(policy, conversation))

        authentication =
          provision_guest_identity!(%{
            tenant_id: tenant_id,
            display_name: display_name,
            device: device,
            expires_at: link.expires_at,
            request_id: value(attrs, :request_id)
          })

        guest_user_id = authentication.user.id
        session_id = authentication.session_id
        history_from_sequence = conversation.next_sequence

        membership =
          %Membership{}
          |> Membership.changeset(%{
            tenant_id: tenant_id,
            conversation_id: conversation.id,
            user_id: guest_user_id,
            role: :member,
            joined_at: timestamp,
            left_at: nil,
            last_read_sequence: max(history_from_sequence - 1, 0)
          })
          |> insert_or_rollback()

        admission =
          %GuestAdmission{}
          |> GuestAdmission.changeset(%{
            tenant_id: tenant_id,
            conversation_id: conversation.id,
            guest_link_id: link.id,
            guest_user_id: guest_user_id,
            membership_id: membership.id,
            session_id: session_id,
            admitted_at: timestamp,
            expires_at: link.expires_at,
            history_from_sequence: history_from_sequence
          })
          |> insert_or_rollback()

        link
        |> GuestLink.changeset(%{use_count: link.use_count + 1})
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

        enqueue_expiry!(admission)

        audit!(
          tenant_id,
          guest_user_id,
          "conversation.guest.admitted",
          "conversation_guest_admission",
          admission.id,
          %{
            conversation_id: conversation.id,
            guest_link_id: link.id,
            history_from_sequence: history_from_sequence,
            expires_at: DateTime.to_iso8601(link.expires_at)
          },
          value(attrs, :request_id)
        )

        %{
          authentication: authentication,
          conversation: Projector.conversation(conversation),
          admission: project_admission(admission),
          capabilities: guest_capabilities!(tenant_id, link.conversion_email)
        }
      end)
      |> transaction_result()
    else
      {:error, reason} when reason in [:invalid_guest_display_name, :invalid_guest_device] ->
        {:error, reason}

      _ ->
        {:error, :guest_link_unavailable}
    end
  end

  def redeem_link(_token, _attrs), do: {:error, :guest_link_unavailable}

  @spec resolve_access(map(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :forbidden}
  def resolve_access(subject, conversation_id)
      when is_map(subject) and is_binary(conversation_id) do
    tenant_id = value(subject, :tenant_id)
    user_id = value(subject, :user_id)
    session_id = value(subject, :session_id)
    timestamp = now()

    case Repo.one(
           from(admission in GuestAdmission,
             join: link in GuestLink,
             on:
               link.id == admission.guest_link_id and
                 link.tenant_id == admission.tenant_id and
                 link.conversation_id == admission.conversation_id,
             join: membership in Membership,
             on:
               membership.id == admission.membership_id and
                 membership.tenant_id == admission.tenant_id and
                 membership.conversation_id == admission.conversation_id and
                 membership.user_id == admission.guest_user_id,
             join: conversation in Conversation,
             on:
               conversation.id == admission.conversation_id and
                 conversation.tenant_id == admission.tenant_id,
             where:
               admission.tenant_id == ^tenant_id and
                 admission.conversation_id == ^conversation_id and
                 admission.guest_user_id == ^user_id and admission.session_id == ^session_id and
                 is_nil(admission.revoked_at) and is_nil(admission.converted_at) and
                 admission.expires_at > ^timestamp and
                 is_nil(link.revoked_at) and link.expires_at > ^timestamp and
                 is_nil(membership.left_at) and is_nil(conversation.archived_at),
             order_by: [desc: admission.admitted_at],
             limit: 1,
             select: %{
               admission_id: admission.id,
               guest_link_id: admission.guest_link_id,
               membership_id: admission.membership_id,
               tenant_id: admission.tenant_id,
               conversation_id: admission.conversation_id,
               user_id: admission.guest_user_id,
               session_id: admission.session_id,
               admitted_at: admission.admitted_at,
               expires_at: admission.expires_at,
               converted_at: admission.converted_at,
               history_from_sequence: admission.history_from_sequence,
               conversion_email: link.conversion_email
             }
           )
         ) do
      nil ->
        {:error, :forbidden}

      access ->
        case guest_capabilities(access.tenant_id, access.conversion_email) do
          {:ok, capabilities} ->
            {:ok,
             access
             |> Map.delete(:conversion_email)
             |> Map.put(:capabilities, capabilities)}

          {:error, _reason} ->
            {:error, :forbidden}
        end
    end
  end

  def resolve_access(_subject, _conversation_id), do: {:error, :forbidden}

  @spec scope_for_session(Ecto.UUID.t()) :: {:ok, map()} | {:error, :forbidden}
  def scope_for_session(session_id) when is_binary(session_id) do
    timestamp = now()

    case Repo.one(
           from(admission in GuestAdmission,
             join: link in GuestLink,
             on:
               link.id == admission.guest_link_id and
                 link.tenant_id == admission.tenant_id and
                 link.conversation_id == admission.conversation_id,
             join: membership in Membership,
             on:
               membership.id == admission.membership_id and
                 membership.tenant_id == admission.tenant_id and
                 membership.conversation_id == admission.conversation_id and
                 membership.user_id == admission.guest_user_id,
             join: conversation in Conversation,
             on:
               conversation.id == admission.conversation_id and
                 conversation.tenant_id == admission.tenant_id,
             where:
               admission.session_id == ^session_id and is_nil(admission.revoked_at) and
                 is_nil(admission.converted_at) and admission.expires_at > ^timestamp and
                 is_nil(link.revoked_at) and link.expires_at > ^timestamp and
                 is_nil(membership.left_at) and is_nil(conversation.archived_at),
             limit: 1,
             select: %{
               admission_id: admission.id,
               guest_link_id: admission.guest_link_id,
               membership_id: admission.membership_id,
               tenant_id: admission.tenant_id,
               conversation_id: admission.conversation_id,
               user_id: admission.guest_user_id,
               session_id: admission.session_id,
               admitted_at: admission.admitted_at,
               expires_at: admission.expires_at,
               converted_at: admission.converted_at,
               history_from_sequence: admission.history_from_sequence,
               conversion_email: link.conversion_email,
               conversation: conversation
             }
           )
         ) do
      nil ->
        {:error, :forbidden}

      %{conversation: conversation} = scope ->
        case guest_capabilities(scope.tenant_id, scope.conversion_email) do
          {:ok, capabilities} ->
            {:ok,
             scope
             |> Map.delete(:conversion_email)
             |> Map.put(:conversation, Projector.conversation(conversation))
             |> Map.put(:capabilities, capabilities)}

          {:error, _reason} ->
            {:error, :forbidden}
        end
    end
  end

  def scope_for_session(_session_id), do: {:error, :forbidden}

  @spec convert_account(map(), map()) ::
          {:ok,
           %{
             authentication: CommsCore.Accounts.AuthenticationResult.t() | struct(),
             conversation: CommsCore.Conversations.ConversationView.t()
           }}
          | {:error, term()}
  def convert_account(attrs, guest_subject)
      when is_map(attrs) and is_map(guest_subject) do
    admission_id =
      value(guest_subject, :guest_admission_id) || value(guest_subject, :admission_id)

    conversation_id =
      value(guest_subject, :guest_conversation_id) ||
        value(guest_subject, :conversation_id)

    with {:ok, admission_id} <- cast_uuid(admission_id),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         %GuestAdmission{} = snapshot <-
           admission_snapshot(admission_id, conversation_id, guest_subject) do
      Repo.transaction(fn ->
        _policy = admission_policy!(snapshot.tenant_id)
        conversation = lock_conversion_conversation!(snapshot)
        link = lock_conversion_link!(snapshot)

        admission =
          Repo.one(
            from(admission in GuestAdmission,
              where:
                admission.id == ^admission_id and
                  admission.tenant_id == ^snapshot.tenant_id and
                  admission.conversation_id == ^snapshot.conversation_id and
                  admission.guest_link_id == ^snapshot.guest_link_id and
                  admission.guest_user_id == ^snapshot.guest_user_id and
                  admission.session_id == ^snapshot.session_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:forbidden)

        membership = lock_admission_membership!(admission)
        timestamp = now()
        ensure_convertible!(conversation, link, admission, membership, timestamp)
        expected_email = require_conversion_email!(link, attrs)
        require_conversion_verification!(link, admission, expected_email, attrs)

        authentication =
          case Accounts.convert_guest_account(attrs, guest_subject, expected_email) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end

        admission
        |> GuestAdmission.changeset(%{converted_at: timestamp})
        |> update_or_rollback()

        audit!(
          admission.tenant_id,
          admission.guest_user_id,
          "conversation.guest.converted",
          "conversation_guest_admission",
          admission.id,
          %{conversation_id: admission.conversation_id, guest_link_id: admission.guest_link_id},
          value(guest_subject, :request_id)
        )

        %{
          authentication: authentication,
          conversation: Projector.conversation(conversation)
        }
      end)
      |> transaction_result()
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :forbidden}
    end
  end

  def convert_account(_attrs, _guest_subject), do: {:error, :forbidden}

  @spec expire_admission(
          Ecto.UUID.t(),
          (Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t() ->
             :ok | {:error, term()})
        ) ::
          {:ok, :expired | :already_terminal | {:not_due, pos_integer()}}
          | {:error, :guest_admission_not_found | term()}
  def expire_admission(admission_id, call_access_revoker)
      when is_binary(admission_id) and is_function(call_access_revoker, 4) do
    with {:ok, admission_id} <- cast_uuid(admission_id),
         %GuestAdmission{} = snapshot <- Repo.get(GuestAdmission, admission_id) do
      Repo.transaction(fn ->
        _policy = admission_policy!(snapshot.tenant_id)
        _conversation = lock_expiry_conversation!(snapshot)
        _link = lock_expiry_link!(snapshot)
        admission = lock_expiry_admission!(snapshot)

        cond do
          admission.revoked_at || admission.converted_at ->
            :already_terminal

          true ->
            membership = lock_admission_membership!(admission)
            timestamp = now()

            if DateTime.compare(admission.expires_at, timestamp) == :gt do
              {:not_due, max(DateTime.diff(admission.expires_at, timestamp, :second), 1)}
            else
              revoke_locked_admission!(
                admission,
                membership,
                timestamp,
                "guest_admission_expired",
                call_access_revoker
              )

              audit!(
                admission.tenant_id,
                nil,
                "conversation.guest.expired",
                "conversation_guest_admission",
                admission.id,
                %{
                  conversation_id: admission.conversation_id,
                  guest_link_id: admission.guest_link_id
                },
                "guest-admission-expiry:#{admission.id}"
              )

              :expired
            end
        end
      end)
      |> transaction_result()
    else
      _ -> {:error, :guest_admission_not_found}
    end
  end

  def expire_admission(_admission_id, _call_access_revoker),
    do: {:error, :guest_admission_not_found}

  defp manager_scope(conversation_id, subject) do
    with {:ok, %{account_type: :human} = grant} <- Accounts.access_grant(subject),
         {:ok, conversation_id} <- cast_uuid(conversation_id),
         %{conversation: %Conversation{} = conversation} <-
           manager_membership(grant, conversation_id) do
      {:ok, grant, conversation}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp manager_membership(grant, conversation_id) do
    Repo.one(
      from(membership in Membership,
        join: conversation in Conversation,
        on:
          conversation.id == membership.conversation_id and
            conversation.tenant_id == membership.tenant_id,
        where:
          membership.tenant_id == ^grant.tenant_id and
            membership.conversation_id == ^conversation_id and
            membership.user_id == ^grant.user_id and
            membership.role in [:owner, :moderator] and is_nil(membership.left_at) and
            is_nil(conversation.archived_at),
        select: %{conversation: conversation}
      )
    )
  end

  defp lock_managed_conversation!(conversation_id, expected_grant, subject) do
    conversation =
      Repo.one(
        from(conversation in Conversation,
          where:
            conversation.id == ^conversation_id and
              conversation.tenant_id == ^expected_grant.tenant_id and
              is_nil(conversation.archived_at),
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:forbidden)

    case manager_scope(conversation.id, subject) do
      {:ok, grant, _conversation}
      when grant.tenant_id == expected_grant.tenant_id and
             grant.user_id == expected_grant.user_id ->
        conversation

      _ ->
        Repo.rollback(:forbidden)
    end
  end

  defp ensure_guest_capable(%Conversation{kind: kind}) when kind in [:group, :channel], do: :ok
  defp ensure_guest_capable(_conversation), do: {:error, :guest_links_not_supported}

  defp ensure_guest_capable!(conversation) do
    case ensure_guest_capable(conversation) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp expiry_seconds(attrs) do
    case positive_integer(value(attrs, :expires_in_seconds), @default_expiry_seconds) do
      value when value >= @min_expiry_seconds and value <= @max_expiry_seconds -> {:ok, value}
      _ -> {:error, :invalid_guest_link_expiry}
    end
  end

  defp max_uses(attrs) do
    case positive_integer(value(attrs, :max_uses), @default_max_uses) do
      value when value >= 1 and value <= 25 -> {:ok, value}
      _ -> {:error, :invalid_guest_link_max_uses}
    end
  end

  defp conversion_email(attrs, grant) do
    case value(attrs, :conversion_email) do
      nil ->
        {:ok, nil}

      email when is_binary(email) ->
        email = normalize_email(email)

        cond do
          email == "" ->
            {:ok, nil}

          grant.role not in [:owner, :admin] ->
            {:error, :guest_account_conversion_forbidden}

          not grant.step_up_recent? ->
            {:error, :step_up_required}

          not valid_conversion_email?(email) ->
            {:error, :invalid_guest_conversion_email}

          true ->
            {:ok, email}
        end

      _ ->
        {:error, :invalid_guest_conversion_email}
    end
  end

  defp authorize_conversion_email!(nil, _subject), do: :ok

  defp authorize_conversion_email!(conversion_email, subject) when is_binary(conversion_email) do
    case Accounts.access_grant(subject) do
      {:ok, %{account_type: :human, role: role, step_up_recent?: true}}
      when role in [:owner, :admin] ->
        :ok

      {:ok, %{account_type: :human, role: role}} when role in [:owner, :admin] ->
        Repo.rollback(:step_up_required)

      _ ->
        Repo.rollback(:guest_account_conversion_forbidden)
    end
  end

  defp validate_conversion_use_limit(nil, _max_uses), do: :ok
  defp validate_conversion_use_limit(_conversion_email, 1), do: :ok

  defp validate_conversion_use_limit(_conversion_email, _max_uses),
    do: {:error, :guest_account_conversion_requires_single_use}

  defp conversion_verification_credentials(
         nil,
         _link_secret,
         _tenant_id,
         _conversation_id,
         _link_id
       ),
       do: {nil, nil}

  defp conversion_verification_credentials(
         conversion_email,
         link_secret,
         tenant_id,
         conversation_id,
         link_id
       ) do
    secret = independent_secret(link_secret)

    {
      Base.url_encode64(secret, padding: false),
      conversion_verification_digest(
        secret,
        tenant_id,
        conversation_id,
        link_id,
        conversion_email
      )
    }
  end

  defp independent_secret(excluded_secret) do
    secret = :crypto.strong_rand_bytes(@verification_secret_bytes)

    if secret == excluded_secret,
      do: independent_secret(excluded_secret),
      else: secret
  end

  defp valid_conversion_email?(email) do
    String.length(email) <= 320 and
      Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/, email) and
      not String.ends_with?(email, "@service.invalid")
  end

  defp positive_integer(nil, default), do: default
  defp positive_integer(value, _default) when is_integer(value), do: value

  defp positive_integer(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> :invalid
    end
  end

  defp positive_integer(_value, _default), do: :invalid

  defp display_name(attrs) do
    case value(attrs, :display_name) do
      name when is_binary(name) ->
        name = String.trim(name)

        if String.length(name) in 1..120,
          do: {:ok, name},
          else: {:error, :invalid_guest_display_name}

      _ ->
        {:error, :invalid_guest_display_name}
    end
  end

  defp device(attrs) do
    case value(attrs, :device) do
      device when is_map(device) -> {:ok, device}
      _ -> {:error, :invalid_guest_device}
    end
  end

  defp parse_token(token) do
    with [link_id, encoded_secret] <- String.split(token, ".", parts: 2),
         {:ok, link_id} <- cast_uuid(link_id),
         {:ok, secret} <- Base.url_decode64(encoded_secret, padding: false),
         32 <- byte_size(secret) do
      {:ok, link_id, secret}
    else
      _ -> {:error, :guest_link_unavailable}
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp secure_digest_match?(secret, stored_digest)
       when is_binary(secret) and is_binary(stored_digest) do
    secure_binary_match?(:crypto.hash(:sha256, secret), stored_digest)
  end

  defp secure_digest_match?(_secret, _stored_digest), do: false

  defp secure_binary_match?(candidate, stored)
       when is_binary(candidate) and is_binary(stored) do
    if byte_size(candidate) == byte_size(stored) do
      candidate
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(stored))
      |> Enum.reduce(0, fn {left, right}, difference ->
        bor(difference, bxor(left, right))
      end)
      |> Kernel.==(0)
    else
      false
    end
  end

  defp secure_binary_match?(_candidate, _stored), do: false

  defp available_link(%GuestLink{} = link, timestamp) do
    cond do
      link.revoked_at -> {:error, :guest_link_unavailable}
      DateTime.compare(link.expires_at, timestamp) != :gt -> {:error, :guest_link_unavailable}
      link.use_count >= link.max_uses -> {:error, :guest_link_unavailable}
      true -> :ok
    end
  end

  defp available_guest_conversation(link) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.id == ^link.conversation_id and
            conversation.tenant_id == ^link.tenant_id and
            conversation.kind in [:group, :channel] and is_nil(conversation.archived_at)
      )
    )
  end

  defp available_link!(link, timestamp) do
    case available_link(link, timestamp) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_available_link!(tenant_id, conversation_id, link_id, secret) do
    link =
      Repo.one(
        from(link in GuestLink,
          where:
            link.id == ^link_id and link.tenant_id == ^tenant_id and
              link.conversation_id == ^conversation_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:guest_link_unavailable)

    if secure_digest_match?(secret, link.token_digest) do
      link
    else
      Repo.rollback(:guest_link_unavailable)
    end
  end

  defp lock_available_guest_conversation!(tenant_id, conversation_id) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.id == ^conversation_id and
            conversation.tenant_id == ^tenant_id and
            conversation.kind in [:group, :channel] and is_nil(conversation.archived_at),
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:guest_link_unavailable)
  end

  defp provision_guest_identity!(command) do
    case Accounts.provision_guest_identity(command) do
      {:ok, authentication} -> authentication
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp admission_snapshot(admission_id, conversation_id, guest_subject) do
    Repo.one(
      from(admission in GuestAdmission,
        where:
          admission.id == ^admission_id and
            admission.tenant_id == ^value(guest_subject, :tenant_id) and
            admission.conversation_id == ^conversation_id and
            admission.guest_user_id == ^value(guest_subject, :user_id) and
            admission.session_id == ^value(guest_subject, :session_id)
      )
    )
  end

  defp lock_conversion_conversation!(snapshot) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.id == ^snapshot.conversation_id and
            conversation.tenant_id == ^snapshot.tenant_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:forbidden)
  end

  defp lock_conversion_link!(snapshot) do
    Repo.one(
      from(link in GuestLink,
        where:
          link.id == ^snapshot.guest_link_id and link.tenant_id == ^snapshot.tenant_id and
            link.conversation_id == ^snapshot.conversation_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:forbidden)
  end

  defp lock_admission_membership!(admission) do
    Repo.one(
      from(membership in Membership,
        where:
          membership.id == ^admission.membership_id and
            membership.tenant_id == ^admission.tenant_id and
            membership.conversation_id == ^admission.conversation_id and
            membership.user_id == ^admission.guest_user_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:forbidden)
  end

  defp ensure_convertible!(conversation, link, admission, membership, timestamp) do
    valid? =
      is_nil(conversation.archived_at) and conversation.kind in [:group, :channel] and
        link.conversation_id == conversation.id and is_nil(link.revoked_at) and
        DateTime.compare(link.expires_at, timestamp) == :gt and
        admission.guest_link_id == link.id and
        admission.conversation_id == conversation.id and is_nil(admission.revoked_at) and
        is_nil(admission.converted_at) and
        DateTime.compare(admission.expires_at, timestamp) == :gt and
        membership.id == admission.membership_id and is_nil(membership.left_at)

    if valid?, do: :ok, else: Repo.rollback(:forbidden)
  end

  defp require_conversion_email!(%GuestLink{conversion_email: nil}, _attrs),
    do: Repo.rollback(:guest_account_conversion_not_enabled)

  defp require_conversion_email!(%GuestLink{conversion_email: expected_email}, attrs) do
    if normalize_email(value(attrs, :email)) == expected_email do
      expected_email
    else
      Repo.rollback(:guest_account_conversion_email_mismatch)
    end
  end

  defp require_conversion_verification!(link, admission, expected_email, attrs) do
    {valid_format?, candidate_secret} =
      conversion_verification_secret(value(attrs, :verification_code))

    bound? =
      admission.tenant_id == link.tenant_id and
        admission.conversation_id == link.conversation_id and
        admission.guest_link_id == link.id and expected_email == link.conversion_email

    candidate_digest =
      conversion_verification_digest(
        candidate_secret,
        link.tenant_id,
        link.conversation_id,
        link.id,
        expected_email
      )

    verified? =
      secure_binary_match?(
        candidate_digest,
        link.conversion_verification_digest
      )

    if bound? and valid_format? and verified?,
      do: :ok,
      else: Repo.rollback(:guest_account_conversion_verification_failed)
  end

  defp conversion_verification_secret(code) when is_binary(code) do
    with true <- byte_size(code) == 43,
         {:ok, secret} <- Base.url_decode64(code, padding: false),
         true <- byte_size(secret) == @verification_secret_bytes do
      {true, secret}
    else
      _ -> {false, <<0::size(@verification_secret_bytes * 8)>>}
    end
  end

  defp conversion_verification_secret(_code),
    do: {false, <<0::size(@verification_secret_bytes * 8)>>}

  defp conversion_verification_digest(
         secret,
         tenant_id,
         conversation_id,
         link_id,
         conversion_email
       ) do
    :crypto.hash(:sha256, [
      "k-comms:guest-conversion-verification:v1",
      <<0>>,
      tenant_id,
      <<0>>,
      conversation_id,
      <<0>>,
      link_id,
      <<0>>,
      conversion_email,
      <<0>>,
      secret
    ])
  end

  defp lock_expiry_conversation!(snapshot) do
    Repo.one(
      from(conversation in Conversation,
        where:
          conversation.id == ^snapshot.conversation_id and
            conversation.tenant_id == ^snapshot.tenant_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:guest_admission_not_found)
  end

  defp lock_expiry_link!(snapshot) do
    Repo.one(
      from(link in GuestLink,
        where:
          link.id == ^snapshot.guest_link_id and link.tenant_id == ^snapshot.tenant_id and
            link.conversation_id == ^snapshot.conversation_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:guest_admission_not_found)
  end

  defp lock_expiry_admission!(snapshot) do
    Repo.one(
      from(admission in GuestAdmission,
        where:
          admission.id == ^snapshot.id and admission.tenant_id == ^snapshot.tenant_id and
            admission.conversation_id == ^snapshot.conversation_id and
            admission.guest_link_id == ^snapshot.guest_link_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:guest_admission_not_found)
  end

  defp enqueue_expiry!(admission) do
    %{
      "admission_id" => admission.id,
      "tenant_id" => admission.tenant_id
    }
    |> Oban.Job.new(
      worker: RuntimePorts.job_worker_name!(:guest_admission_expiry),
      queue: :default,
      scheduled_at: admission.expires_at,
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> insert_or_rollback()
  end

  defp revoke_admission!(admission, timestamp, reason, call_access_revoker) do
    membership = lock_admission_membership!(admission)

    revoke_locked_admission!(
      admission,
      membership,
      timestamp,
      reason,
      call_access_revoker
    )
  end

  defp revoke_locked_admission!(
         admission,
         membership,
         timestamp,
         reason,
         call_access_revoker
       ) do
    if is_nil(membership.left_at) do
      membership
      |> Membership.changeset(%{left_at: timestamp})
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> update_or_rollback()
    end

    revoke_guest_session!(admission.session_id, reason)

    call_access_revoker.(
      admission.tenant_id,
      admission.conversation_id,
      admission.guest_user_id,
      reason
    )
    |> transaction_step_ok!()

    admission
    |> GuestAdmission.changeset(%{revoked_at: timestamp})
    |> update_or_rollback()

    admission.session_id
  end

  defp revoke_guest_session!(session_id, reason) do
    case Accounts.revoke_guest_session(session_id, reason) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp project_link(link, timestamp) do
    %GuestLinkView{
      id: link.id,
      tenant_id: link.tenant_id,
      conversation_id: link.conversation_id,
      created_by_user_id: link.created_by_user_id,
      expires_at: link.expires_at,
      max_uses: link.max_uses,
      use_count: link.use_count,
      remaining_uses: max(link.max_uses - link.use_count, 0),
      status: link_status(link, timestamp),
      conversion_enabled: not is_nil(link.conversion_email),
      email_hint: email_hint(link.conversion_email),
      revoked_at: link.revoked_at,
      version: link.lock_version,
      inserted_at: link.inserted_at
    }
  end

  defp project_admission(admission) do
    %GuestAdmissionView{
      id: admission.id,
      conversation_id: admission.conversation_id,
      guest_link_id: admission.guest_link_id,
      guest_user_id: admission.guest_user_id,
      membership_id: admission.membership_id,
      session_id: admission.session_id,
      admitted_at: admission.admitted_at,
      expires_at: admission.expires_at,
      revoked_at: admission.revoked_at,
      converted_at: admission.converted_at,
      history_from_sequence: admission.history_from_sequence
    }
  end

  defp guest_room_title(%Conversation{title: title}) when is_binary(title) do
    case String.trim(title) do
      "" -> "K-Comms room"
      trimmed -> trimmed
    end
  end

  defp guest_room_title(%Conversation{}), do: "K-Comms room"

  defp email_hint(nil), do: nil

  defp email_hint(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        String.first(local) <> "***@" <> domain

      _ ->
        nil
    end
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(_email), do: ""

  defp guest_capabilities(tenant_id, conversion_email) do
    case Administration.call_policy(tenant_id) do
      {:ok, policy} ->
        {:ok,
         %{
           allow_audio_calls: policy.allow_audio_calls,
           allow_video_calls: policy.allow_video_calls,
           conversion_enabled: not is_nil(conversion_email),
           email_hint: email_hint(conversion_email)
         }}

      {:error, _reason} ->
        {:error, :forbidden}
    end
  end

  defp guest_capabilities!(tenant_id, conversion_email) do
    case guest_capabilities(tenant_id, conversion_email) do
      {:ok, capabilities} -> capabilities
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp link_status(%GuestLink{revoked_at: revoked_at}, _timestamp) when not is_nil(revoked_at),
    do: :revoked

  defp link_status(%GuestLink{} = link, timestamp) do
    cond do
      DateTime.compare(link.expires_at, timestamp) != :gt -> :expired
      link.use_count >= link.max_uses -> :exhausted
      true -> :active
    end
  end

  defp audit!(tenant_id, actor_user_id, action, resource_type, resource_id, metadata, request_id) do
    case Audit.record(%{
           tenant_id: tenant_id,
           actor_user_id: actor_user_id,
           action: action,
           resource_type: resource_type,
           resource_id: resource_id,
           metadata: metadata,
           request_id: request_id
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp admission_policy!(tenant_id) do
    case AdmissionQuotas.locked_policy(tenant_id) do
      {:ok, policy} -> policy
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_conversation_member_capacity(policy, conversation) do
    timestamp = now()

    current_active_members =
      Membership
      |> join(
        :left,
        [membership],
        admission in GuestAdmission,
        on:
          admission.tenant_id == membership.tenant_id and
            admission.membership_id == membership.id and is_nil(admission.converted_at)
      )
      |> where(
        [membership, admission],
        membership.tenant_id == ^conversation.tenant_id and
          membership.conversation_id == ^conversation.id and is_nil(membership.left_at) and
          (is_nil(admission.id) or
             (is_nil(admission.revoked_at) and admission.expires_at > ^timestamp))
      )
      |> Repo.aggregate(:count)

    AdmissionQuotas.check_conversation_member_capacity(policy, current_active_members)
  end

  defp quota_ok!(:ok), do: :ok
  defp quota_ok!({:error, reason}), do: Repo.rollback(reason)

  defp transaction_step_ok!(:ok), do: :ok
  defp transaction_step_ok!({:error, reason}), do: Repo.rollback(reason)

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
