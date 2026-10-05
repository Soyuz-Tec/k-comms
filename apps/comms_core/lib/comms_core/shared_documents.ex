defmodule CommsCore.SharedDocuments do
  @moduledoc "Bounded plaintext collaboration with server-validated RGA operations and original-author erasure."
  alias CommsCore.SharedDocuments.{
    Commands,
    DocumentView,
    ErasureReceipt,
    OperationPage,
    OperationView,
    Queries,
    ReleaseInventory
  }

  @type subject :: %{
          required(:tenant_id) => binary(),
          required(:user_id) => binary(),
          required(:device_id) => binary(),
          required(:session_id) => binary(),
          optional(atom() | binary()) => binary() | atom() | integer() | nil
        }
  @type change :: %{required(binary()) => binary() | nil | [binary()]}
  @type creation :: %{required(:client_document_id) => binary(), required(:title) => binary()}
  @type edit :: %{
          required(:client_operation_id) => binary(),
          required(:generation) => pos_integer(),
          required(:base_version) => non_neg_integer(),
          required(:kind) => binary(),
          optional(:changes) => [change()],
          optional(:title) => binary()
        }
  @spec create(binary(), creation(), subject()) :: {:ok, DocumentView.t()} | {:error, atom()}
  defdelegate create(conversation_id, attrs, subject), to: Commands
  @spec copy(binary(), creation(), subject()) :: {:ok, DocumentView.t()} | {:error, atom()}
  defdelegate copy(id, attrs, subject), to: Commands

  @spec apply_operation(binary(), edit(), subject()) ::
          {:ok, OperationView.t(), :created | :duplicate} | {:error, atom()}
  defdelegate apply_operation(id, attrs, subject), to: Commands
  @spec get(binary(), subject()) :: {:ok, DocumentView.t()} | {:error, atom()}
  defdelegate get(id, subject), to: Queries
  @spec authorize(binary(), subject()) :: {:ok, :ok} | {:error, atom()}
  defdelegate authorize(id, subject), to: Queries

  @spec list(binary(), binary(), subject()) ::
          {:ok, [CommsCore.SharedDocuments.SummaryView.t()]} | {:error, atom()}
  defdelegate list(conversation_id, query, subject), to: Queries

  @spec replay(binary(), pos_integer(), non_neg_integer(), pos_integer(), subject()) ::
          {:ok, OperationPage.t()} | {:error, atom()}
  defdelegate replay(id, generation, after_version, limit, subject), to: Queries
  @spec export(binary(), subject()) :: {:ok, DocumentView.t()} | {:error, atom()}
  defdelegate export(id, subject), to: Queries

  @spec erase_for_governance(binary(), :user | :conversation, binary(), DateTime.t()) ::
          {:ok, ErasureReceipt.t()} | {:error, atom()}
  defdelegate erase_for_governance(tenant_id, type, id, timestamp),
    to: CommsCore.SharedDocuments.Erasure,
    as: :erase

  @spec rollback_hazard_count() :: non_neg_integer()
  def rollback_hazard_count, do: ReleaseInventory.hazard_count(CommsCore.Repo)

  @spec release_tenant_fingerprint_fragment(module(), binary()) :: %{
          shared_documents: [binary()],
          shared_document_operations: [binary()]
        }
  defdelegate release_tenant_fingerprint_fragment(repo, tenant_id),
    to: ReleaseInventory,
    as: :fingerprint
end
