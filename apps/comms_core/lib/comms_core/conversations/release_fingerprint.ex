defmodule CommsCore.Conversations.ReleaseFingerprint do
  @moduledoc false

  import Ecto.Query

  alias CommsCore.Conversations.{
    Conversation,
    EphemeralJoinReceipt,
    EphemeralPresenceLease,
    EphemeralRoom,
    GuestAdmission,
    GuestLink,
    Membership
  }

  def fragment(repo, tenant_id) when is_atom(repo) and is_binary(tenant_id) do
    %{
      conversations:
        repo.all(
          from(conversation in Conversation,
            where: conversation.tenant_id == ^tenant_id,
            select: conversation.id
          )
        ),
      memberships:
        repo.all(
          from(membership in Membership,
            where: membership.tenant_id == ^tenant_id,
            select: membership.id
          )
        ),
      guest_links:
        repo.all(
          from(link in GuestLink,
            where: link.tenant_id == ^tenant_id,
            select: link.id
          )
        ),
      guest_admissions:
        repo.all(
          from(admission in GuestAdmission,
            where: admission.tenant_id == ^tenant_id,
            select: admission.id
          )
        ),
      ephemeral_rooms:
        repo.all(
          from(room in EphemeralRoom,
            where: room.tenant_id == ^tenant_id,
            select: room.id
          )
        ),
      ephemeral_presence_leases:
        repo.all(
          from(lease in EphemeralPresenceLease,
            where: lease.tenant_id == ^tenant_id,
            select: lease.id
          )
        ),
      ephemeral_join_receipts:
        repo.all(
          from(receipt in EphemeralJoinReceipt,
            where: receipt.tenant_id == ^tenant_id,
            select: receipt.id
          )
        )
    }
  end
end
