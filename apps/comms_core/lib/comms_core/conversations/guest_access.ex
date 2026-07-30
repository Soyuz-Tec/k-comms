defmodule CommsCore.Conversations.GuestAccess do
  @moduledoc false

  alias CommsCore.Conversations.{
    GuestAdmissionView,
    GuestLinkPreviewView,
    GuestLinkView
  }

  alias CommsCore.Conversations.GuestAccess.{
    AdmissionLifecycle,
    Conversion,
    LinkManagement,
    Redemption
  }

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
  def create_link(conversation_id, attrs, subject),
    do: LinkManagement.create_link(conversation_id, attrs, subject)

  @spec list_links(Ecto.UUID.t(), map()) ::
          {:ok, [GuestLinkView.t()]}
          | {:error, :forbidden | :guest_links_not_supported}
  def list_links(conversation_id, subject),
    do: LinkManagement.list_links(conversation_id, subject)

  @spec revoke_link(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          map(),
          (Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t() ->
             :ok | {:error, term()})
        ) ::
          {:ok, %{guest_link: GuestLinkView.t(), revoked_session_ids: [Ecto.UUID.t()]}}
          | {:error, :forbidden | :guest_link_not_found | :guest_links_not_supported | term()}
  def revoke_link(conversation_id, link_id, subject, call_access_revoker),
    do: LinkManagement.revoke_link(conversation_id, link_id, subject, call_access_revoker)

  @spec preview_link(String.t()) ::
          {:ok, GuestLinkPreviewView.t()}
          | {:error, :guest_link_unavailable}
  def preview_link(token), do: Redemption.preview_link(token)

  @spec redeem_link(String.t(), map()) ::
          {:ok,
           %{
             authentication: CommsCore.Accounts.AuthenticationResult.t() | struct(),
             conversation: CommsCore.Conversations.ConversationView.t(),
             admission: GuestAdmissionView.t(),
             capabilities: %{allow_audio_calls: boolean(), allow_video_calls: boolean()}
           }}
          | {:error, term()}
  def redeem_link(token, attrs), do: Redemption.redeem_link(token, attrs)

  @spec resolve_access(map(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :forbidden}
  def resolve_access(subject, conversation_id),
    do: Redemption.resolve_access(subject, conversation_id)

  @spec scope_for_session(Ecto.UUID.t()) :: {:ok, map()} | {:error, :forbidden}
  def scope_for_session(session_id), do: Redemption.scope_for_session(session_id)

  @spec convert_account(map(), map()) ::
          {:ok,
           %{
             authentication: CommsCore.Accounts.AuthenticationResult.t() | struct(),
             conversation: CommsCore.Conversations.ConversationView.t()
           }}
          | {:error, term()}
  def convert_account(attrs, guest_subject),
    do: Conversion.convert_account(attrs, guest_subject)

  @spec logout_session(
          map(),
          (Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t() ->
             :ok | {:error, term()})
        ) :: :ok | {:error, term()}
  def logout_session(guest_subject, call_access_revoker),
    do: AdmissionLifecycle.logout_session(guest_subject, call_access_revoker)

  @spec expire_admission(
          Ecto.UUID.t(),
          (Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t() ->
             :ok | {:error, term()})
        ) ::
          {:ok, :expired | :already_terminal | {:not_due, pos_integer()}}
          | {:error, :guest_admission_not_found | term()}
  def expire_admission(admission_id, call_access_revoker),
    do: AdmissionLifecycle.expire_admission(admission_id, call_access_revoker)
end
