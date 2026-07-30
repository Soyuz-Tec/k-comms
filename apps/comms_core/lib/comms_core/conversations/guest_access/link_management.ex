defmodule CommsCore.Conversations.GuestAccess.LinkManagement do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.{
    Accounts,
    AdmissionQuotas,
    Audit,
    Repo
  }

  alias CommsCore.Conversations.{
    Conversation,
    GuestAdmission,
    GuestLink,
    Membership
  }

  alias CommsCore.Conversations.GuestAccess.{
    Projection,
    Revocation,
    Token
  }

  @default_expiry_seconds 24 * 60 * 60
  @min_expiry_seconds 15 * 60
  @max_expiry_seconds 24 * 60 * 60
  @default_max_uses 10

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
        Token.conversion_verification_credentials(
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
            purpose: :standard,
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
          guest_link: Projection.link(link, timestamp),
          token: token,
          conversion_verification_code: conversion_verification_code
        }
      end)
      |> transaction_result()
    end
  end

  def create_link(_conversation_id, _attrs, _subject), do: {:error, :forbidden}

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
        |> Enum.map(&Projection.link(&1, timestamp))

      {:ok, links}
    end
  end

  def list_links(_conversation_id, _subject), do: {:error, :forbidden}

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
            &Revocation.revoke_admission!(
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
          guest_link: Projection.link(revoked_link, timestamp),
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
        email = Token.normalize_email(email)

        cond do
          email == "" ->
            {:ok, nil}

          grant.role not in [:owner, :admin] ->
            {:error, :guest_account_conversion_forbidden}

          not grant.step_up_recent? ->
            {:error, :step_up_required}

          not Token.valid_conversion_email?(email) ->
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

  defp positive_integer(nil, default), do: default
  defp positive_integer(value, _default) when is_integer(value), do: value

  defp positive_integer(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> :invalid
    end
  end

  defp positive_integer(_value, _default), do: :invalid

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
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
