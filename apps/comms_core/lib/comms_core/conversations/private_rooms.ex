defmodule CommsCore.Conversations.PrivateRooms do
  @moduledoc false
  import Ecto.Query
  alias CommsCore.{Accounts, AdmissionQuotas, Repo}

  alias CommsCore.Conversations.{
    PrivateBudget,
    Conversation,
    Membership,
    PrivateRoom,
    PrivateRoomView,
    PrivateRoomGrant,
    PrivateRoomProtectionPort,
    PrivateRoomControlCommand,
    PrivateRoomControlReceipt,
    PrivateRoomControlPort
  }

  def create(attrs, subject) do
    deadline = PrivateBudget.new()

    with :ok <- enabled(),
         {:ok, actor} <- Accounts.access_grant(subject),
         {:ok, id} <- Ecto.UUID.cast(value(attrs, :id)),
         :ok <- title(value(attrs, :title)),
         {:ok, users} <- member_ids(value(attrs, :member_ids), actor.user_id),
         {:ok, room} <-
           PrivateBudget.transaction(deadline, fn ->
             protection!(actor.tenant_id, id, users, :create)

             grant = participants!(actor.tenant_id, users, subject, deadline, true)
             identities = Enum.map(users, &identity!(grant.tenant_id, &1))
             fingerprint = :crypto.hash(:sha256, Jason.encode!([value(attrs, :title), users]))

             existing =
               Repo.one(
                 from(r in PrivateRoom,
                   where: r.tenant_id == ^grant.tenant_id and r.conversation_id == ^id,
                   lock: "FOR UPDATE"
                 )
               )

             if existing do
               if existing.creator_user_id != grant.user_id or
                    existing.input_fingerprint != fingerprint,
                  do: Repo.rollback(:idempotency_conflict)

               if existing.state not in [:provisioning, :active],
                 do: Repo.rollback(:private_room_withdrawn)

               existing
             else
               if Repo.aggregate(
                    from(r in PrivateRoom, where: r.tenant_id == ^grant.tenant_id),
                    :count
                  ) >= 1000, do: Repo.rollback(:private_room_capacity_exhausted)

               policy = CommsCore.Conversations.Commands.admission_policy!(grant.tenant_id)

               case AdmissionQuotas.check_conversation_creation(
                      policy,
                      CommsCore.Conversations.Commands.active_conversation_count(grant.tenant_id),
                      length(users)
                    ) do
                 :ok -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end

               Repo.insert!(%Conversation{
                 id: id,
                 tenant_id: grant.tenant_id,
                 created_by_user_id: grant.user_id,
                 kind: :group,
                 content_mode: :matrix_e2ee,
                 visibility: :private,
                 title: value(attrs, :title)
               })

               Enum.each(users, fn user ->
                 Repo.insert!(%Membership{
                   tenant_id: grant.tenant_id,
                   conversation_id: id,
                   user_id: user,
                   role: if(user == grant.user_id, do: :owner, else: :member),
                   joined_at: now()
                 })
               end)

               provider =
                 Application.get_env(:comms_core, :matrix_identity_provider) ||
                   Repo.rollback(:private_room_provider_unavailable)

               Repo.insert!(%PrivateRoom{
                 tenant_id: grant.tenant_id,
                 conversation_id: id,
                 creator_user_id: grant.user_id,
                 provider_issuer: provider.issuer,
                 provider_server_name: provider.server_name,
                 control_matrix_user_id: provider.control_user_id,
                 room_alias:
                   "#kc_private_" <> String.replace(id, "-", "") <> ":" <> provider.server_name,
                 input_fingerprint: fingerprint,
                 historical_user_ids: users,
                 matrix_members:
                   Map.new(identities, fn i ->
                     {i.user_id, %{"issuer" => i.issuer, "matrix_user_id" => i.matrix_user_id}}
                   end)
               })
             end
           end) do
      if room.state == :provisioning do
        with {:ok, allow_create?} <-
               with_room(id, subject, :control, deadline, fn _g, retained, _c, _m ->
                 if retained.state != :provisioning,
                   do: Repo.rollback(:private_room_generation_stale)

                 if retained.provisioning_attempted_at do
                   false
                 else
                   persist_private_room!(retained, provisioning_attempted_at: now())
                   true
                 end
               end),
             {:ok, _} <-
               with_room(id, subject, :control, deadline, fn grant, retained, _c, _m ->
                 if retained.state != :provisioning or retained.generation != room.generation,
                   do: Repo.rollback(:private_room_generation_stale)

                 control = %{
                   command(retained, PrivateBudget.authority(deadline, grant))
                   | allow_create?: allow_create?
                 }

                 receipt =
                   case PrivateRoomControlPort.execute(:provision, control) do
                     {:ok, %PrivateRoomControlReceipt{} = receipt} -> receipt
                     {:error, reason} -> Repo.rollback(reason)
                   end

                 PrivateBudget.check!(control.deadline)

                 if not is_binary(receipt.matrix_room_id) or
                      byte_size(receipt.matrix_room_id) not in 1..512,
                    do: Repo.rollback(:private_room_provider_receipt_invalid)

                 persist_private_room!(retained,
                   matrix_room_id: receipt.matrix_room_id,
                   state: :active
                 )
               end),
             do: get(id, subject, deadline)
      else
        get(id, subject, deadline)
      end
    else
      :error -> {:error, :invalid_private_room_id}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in Ecto.ConstraintError -> {:error, :private_room_id_conflict}
  end

  def list(subject) do
    deadline = PrivateBudget.new()

    with :ok <- enabled(), {:ok, grant} <- Accounts.access_grant(subject) do
      ids =
        Repo.all(
          from(r in PrivateRoom,
            join: m in Membership,
            on: m.conversation_id == r.conversation_id and m.tenant_id == r.tenant_id,
            where:
              r.tenant_id == ^grant.tenant_id and m.user_id == ^grant.user_id and
                is_nil(m.left_at) and r.state in [:active, :provisioning, :rekey_pending],
            order_by: [desc: r.updated_at],
            limit: 1000,
            select: r.conversation_id
          )
        )

      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, views} ->
        case get(id, subject, deadline) do
          {:ok, view} -> {:cont, {:ok, views ++ [view]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def get(id, subject), do: get(id, subject, PrivateBudget.new())

  defp get(id, subject, deadline),
    do:
      with_room(id, subject, :read, deadline, fn _g, room, convo, member ->
        view(room, convo, member, deadline)
      end)

  def lock_grant(id, subject, epoch, generation),
    do: lock_grant(id, subject, epoch, generation, PrivateBudget.new())

  def lock_grant(id, subject, epoch, generation, deadline) do
    if Repo.in_transaction?() do
      {grant, room, _convo, _member} = retained_room(id, subject, :send, deadline)

      if room.membership_epoch != epoch or room.generation != generation,
        do: Repo.rollback(:private_room_generation_stale)

      mapping = room.matrix_members[grant.user_id] || Repo.rollback(:private_room_lineage_unknown)

      {:ok,
       %PrivateRoomGrant{
         tenant_id: grant.tenant_id,
         conversation_id: id,
         user_id: grant.user_id,
         device_id: grant.device_id,
         session_id: grant.session_id,
         matrix_room_id: room.matrix_room_id,
         matrix_user_id: mapping["matrix_user_id"],
         membership_epoch: epoch,
         generation: generation,
         deadline: PrivateBudget.authority(deadline, grant),
         historical_user_ids: room.historical_user_ids
       }}
    else
      {:error, :transaction_required}
    end
  end

  def remove_member(id, user_id, attrs, subject) do
    deadline = PrivateBudget.new()

    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         epoch when is_integer(epoch) and epoch > 0 <- value(attrs, :membership_epoch),
         {:ok, room} <-
           with_room(id, subject, :control, deadline, fn grant, room, _convo, actor ->
             if actor.role != :owner or user_id == grant.user_id, do: Repo.rollback(:forbidden)
             mapping = room.matrix_members[user_id] || Repo.rollback(:not_found)

             cond do
               room.state == :rekey_pending and room.membership_epoch == epoch + 1 and
                   room.pending_removed_matrix_user_id == mapping["matrix_user_id"] ->
                 room

               room.state == :active and room.membership_epoch == epoch ->
                 target =
                   Repo.one(
                     from(m in Membership,
                       where:
                         m.tenant_id == ^grant.tenant_id and m.conversation_id == ^id and
                           m.user_id == ^user_id and is_nil(m.left_at),
                       lock: "FOR UPDATE"
                     )
                   ) || Repo.rollback(:not_found)

                 persist_membership!(target,
                   left_at: now(),
                   lock_version: target.lock_version + 1
                 )

                 persist_private_room!(room,
                   state: :rekey_pending,
                   membership_epoch: epoch + 1,
                   generation: room.generation + 1,
                   pending_removed_matrix_user_id: mapping["matrix_user_id"],
                   pending_removed_matrix_user_ids: [mapping["matrix_user_id"]]
                 )

               true ->
                 Repo.rollback(:private_room_generation_stale)
             end
           end),
         {:ok, _} <-
           with_room(id, subject, :control, deadline, fn grant, retained, _c, actor ->
             if actor.role != :owner or retained.generation != room.generation or
                  retained.state != :rekey_pending,
                do: Repo.rollback(:private_room_generation_stale)

             control = %{
               command(retained, PrivateBudget.authority(deadline, grant))
               | removed_matrix_user_id: retained.pending_removed_matrix_user_id
             }

             receipt =
               case PrivateRoomControlPort.execute(:remove_member, control) do
                 {:ok, %PrivateRoomControlReceipt{}} = ok -> elem(ok, 1)
                 {:error, reason} -> Repo.rollback(reason)
               end

             if retained.matrix_room_id != receipt.matrix_room_id,
               do: Repo.rollback(:private_room_provider_receipt_invalid)

             PrivateBudget.check!(control.deadline)

             remaining =
               Enum.reject(
                 retained.pending_removed_matrix_user_ids,
                 &(&1 == control.removed_matrix_user_id)
               )

             persist_private_room!(retained,
               state: if(remaining == [], do: :active, else: :rekey_pending),
               pending_removed_matrix_user_id: nil,
               pending_removed_matrix_user_ids: remaining
             )
           end) do
      get(id, subject, deadline)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_membership_epoch}
    end
  end

  defp with_room(id, subject, action, deadline, callback) do
    with :ok <- enabled(), {:ok, id} <- Ecto.UUID.cast(id) do
      PrivateBudget.transaction(deadline, fn ->
        {g, r, c, m} = retained_room(id, subject, action, deadline)
        callback.(g, r, c, m)
      end)
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retained_room(id, subject, action, deadline) do
    PrivateBudget.prepare!(deadline)
    tenant = value(subject, :tenant_id)

    lineage =
      Repo.one(
        from(r in PrivateRoom,
          where: r.tenant_id == ^tenant and r.conversation_id == ^id,
          select: r.historical_user_ids
        )
      ) || []

    protection!(tenant, id, lineage, action)
    grant = participants!(tenant, lineage, subject, deadline, false)

    convo =
      Repo.one(
        from(c in Conversation,
          where:
            c.id == ^id and c.tenant_id == ^grant.tenant_id and c.content_mode == :matrix_e2ee and
              is_nil(c.archived_at),
          lock: "FOR SHARE"
        )
      ) || Repo.rollback(:not_found)

    room =
      Repo.one(
        from(r in PrivateRoom,
          where: r.tenant_id == ^grant.tenant_id and r.conversation_id == ^id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:not_found)

    if room.historical_user_ids != lineage or length(lineage) not in 1..100 or
         map_size(room.matrix_members) != length(lineage),
       do: Repo.rollback(:private_room_lineage_unknown)

    member =
      Repo.one(
        from(m in Membership,
          where:
            m.tenant_id == ^grant.tenant_id and m.conversation_id == ^id and
              m.user_id == ^grant.user_id and is_nil(m.left_at),
          lock: "FOR SHARE"
        )
      ) || Repo.rollback(:forbidden)

    active_ids =
      Repo.all(
        from(m in Membership,
          where: m.tenant_id == ^tenant and m.conversation_id == ^id and is_nil(m.left_at),
          select: m.user_id
        )
      )

    if Enum.any?(active_ids, fn user ->
         match?({:error, _}, Accounts.matrix_identity_view(tenant, user))
       end),
       do: Repo.rollback(:private_room_rekey_pending)

    PrivateBudget.check!(PrivateBudget.authority(deadline, grant))

    if room.state not in [:provisioning, :active, :rekey_pending],
      do: Repo.rollback(:private_room_withdrawn)

    if action == :send and room.state != :active, do: Repo.rollback(:private_room_rekey_pending)
    {grant, room, convo, member}
  end

  defp protection!(tenant, id, users, action) do
    case PrivateRoomProtectionPort.protection(tenant, id, users) do
      {:ok, %{held: held, capture_blocked: blocked}} ->
        if blocked, do: Repo.rollback(:private_room_withdrawn)
        if held and action in [:create, :control], do: Repo.rollback(:legal_hold_active)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp participants!(tenant, users, subject, deadline, require_all?) do
    query = %CommsCore.Accounts.MatrixParticipantsLockQuery{
      tenant_id: tenant,
      user_ids: users,
      deadline: deadline
    }

    case Accounts.lock_matrix_participants(query, subject) do
      {:ok, %{eligible_user_ids: eligible, grant: grant}} ->
        if require_all? and eligible != Enum.sort(users),
          do: Repo.rollback(:private_human_members_required)

        PrivateBudget.check!(PrivateBudget.authority(deadline, grant))
        grant

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp identity!(tenant, user) do
    case Accounts.matrix_identity_view(tenant, user) do
      {:ok, view} -> view
      _ -> Repo.rollback(:matrix_member_enrollment_required)
    end
  end

  defp view(room, convo, member, deadline),
    do: %PrivateRoomView{
      id: room.conversation_id,
      tenant_id: room.tenant_id,
      title: convo.title,
      matrix_room_id: room.matrix_room_id,
      state: room.state,
      membership_epoch: room.membership_epoch,
      generation: room.generation,
      members: command(room, deadline).members,
      role: member.role,
      control_matrix_user_id: room.control_matrix_user_id
    }

  def command(room, deadline) do
    active =
      Repo.all(
        from(m in Membership,
          where:
            m.tenant_id == ^room.tenant_id and m.conversation_id == ^room.conversation_id and
              is_nil(m.left_at),
          order_by: m.user_id,
          select: m.user_id
        )
      )

    members =
      Enum.map(active, fn user ->
        mapping = room.matrix_members[user] || raise "private room immutable lineage missing"

        %CommsCore.Accounts.MatrixIdentityView{
          tenant_id: room.tenant_id,
          user_id: user,
          issuer: mapping["issuer"],
          matrix_user_id: mapping["matrix_user_id"],
          provisioning_state: :ready
        }
      end)

    %PrivateRoomControlCommand{
      tenant_id: room.tenant_id,
      conversation_id: room.conversation_id,
      room_alias: room.room_alias,
      members: members,
      generation: room.generation,
      matrix_room_id: room.matrix_room_id,
      purge_id: room.purge_id,
      provider_issuer: room.provider_issuer,
      provider_server_name: room.provider_server_name,
      control_matrix_user_id: room.control_matrix_user_id,
      historical_matrix_user_ids:
        Enum.map(room.historical_user_ids, fn user ->
          room.matrix_members[user]["matrix_user_id"]
        end),
      deadline: deadline
    }
  end

  defp member_ids(ids, actor) when is_list(ids) and length(ids) in 1..19 do
    result = Enum.map([actor | ids], &Ecto.UUID.cast/1)

    if Enum.all?(result, &match?({:ok, _}, &1)) do
      users = result |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
      if length(users) in 2..20, do: {:ok, users}, else: {:error, :invalid_members}
    else
      {:error, :invalid_members}
    end
  end

  defp member_ids(_, _), do: {:error, :invalid_members}

  defp title(value) when is_binary(value),
    do:
      if(
        String.valid?(value) and length(String.codepoints(value)) in 1..160 and
          byte_size(value) <= 640,
        do: :ok,
        else: {:error, :invalid_private_title}
      )

  defp title(_), do: {:error, :invalid_private_title}

  defp enabled,
    do:
      if(Application.get_env(:comms_core, :private_rooms_enabled, false),
        do: :ok,
        else: {:error, :private_rooms_unavailable}
      )

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp persist_private_room!(%PrivateRoom{} = record, attrs),
    do: Repo.update!(PrivateRoom.retained_changeset(record, attrs))

  defp persist_membership!(%Membership{} = record, attrs),
    do: Repo.update!(Membership.changeset(record, Map.new(attrs)))
end
