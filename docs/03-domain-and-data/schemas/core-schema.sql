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
