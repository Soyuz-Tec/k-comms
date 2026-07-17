-- Conceptual starter only; not production-ready DDL.
CREATE TABLE tenants (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  status text NOT NULL,
  inserted_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE conversations (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenants(id),
  kind text NOT NULL,
  title text,
  inserted_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE TABLE conversation_sequences (
  conversation_id uuid PRIMARY KEY REFERENCES conversations(id),
  next_sequence bigint NOT NULL
);

-- Historical aggregate/table name retained by ADR-0025. This conceptual view
-- omits implementation-specific lock versions, indexes, and worker metadata.
CREATE TABLE audio_calls (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenants(id),
  conversation_id uuid NOT NULL REFERENCES conversations(id),
  media_kind text NOT NULL CHECK (media_kind IN ('audio', 'video')),
  provider_room text NOT NULL,
  status text NOT NULL CHECK (status IN ('active', 'ending', 'ended')),
  started_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  ended_at timestamptz,
  inserted_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (tenant_id, provider_room)
);

CREATE UNIQUE INDEX audio_calls_one_active_per_conversation
  ON audio_calls (tenant_id, conversation_id)
  WHERE status IN ('active', 'ending');

CREATE TABLE audio_call_participants (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenants(id),
  audio_call_id uuid NOT NULL REFERENCES audio_calls(id),
  session_id uuid NOT NULL,
  provider_identity text NOT NULL,
  status text NOT NULL,
  revoked_at timestamptz,
  enforce_until timestamptz,
  inserted_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  UNIQUE (tenant_id, provider_identity)
);

CREATE TABLE messages (
  id uuid PRIMARY KEY,
  tenant_id uuid NOT NULL REFERENCES tenants(id),
  conversation_id uuid NOT NULL REFERENCES conversations(id),
  conversation_sequence bigint NOT NULL,
  sender_user_id uuid NOT NULL,
  sender_device_id uuid NOT NULL,
  client_message_id text NOT NULL,
  body text,
  inserted_at timestamptz NOT NULL,
  UNIQUE (conversation_id, conversation_sequence),
  UNIQUE (tenant_id, sender_device_id, client_message_id)
);
