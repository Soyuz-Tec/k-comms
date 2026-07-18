defmodule CommsCore.Attachments.RestoreReport do
  @moduledoc """
  Persistence-neutral outcome of a restored-attachment remap.
  """

  @enforce_keys [
    :candidate_count,
    :verified_count,
    :remapped_count,
    :unchanged_count,
    :trustworthy_etag_count,
    :untrusted_etag_count,
    :unversioned_fail_closed_count,
    :tenant_count
  ]
  defstruct [
    :candidate_count,
    :verified_count,
    :remapped_count,
    :unchanged_count,
    :trustworthy_etag_count,
    :untrusted_etag_count,
    :unversioned_fail_closed_count,
    :tenant_count
  ]

  @type t :: %__MODULE__{
          candidate_count: non_neg_integer(),
          verified_count: non_neg_integer(),
          remapped_count: non_neg_integer(),
          unchanged_count: non_neg_integer(),
          trustworthy_etag_count: non_neg_integer(),
          untrusted_etag_count: non_neg_integer(),
          unversioned_fail_closed_count: non_neg_integer(),
          tenant_count: non_neg_integer()
        }
end
