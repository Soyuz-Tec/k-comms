-- Count whiteboards left behind by instant rooms that expired before ADR-0068.
--
-- Expiry archived the conversation and revoked every path to the board, but
-- deleted nothing. Retention only ages messages, and governance erasure waits
-- for a deletion request nobody files for an abandoned public room, so those
-- rows are still there. ADR-0068 fixed the forward path; this measures the
-- backlog so a decision about collecting it is made against a number.
--
-- STRICTLY READ ONLY. Deleting existing tenant content is a separate decision
-- that needs its own ADR, and legal holds are surfaced below precisely because
-- a hold makes some of this backlog uncollectable regardless of the total.
--
--   psql "$DATABASE_URL" -f ops/runtime/count_orphaned_instant_room_boards.sql
--
-- Safe on a replica and safe under load: no locks, no writes.

\pset footer off

-- Boards whose conversation belongs to an expired instant room, split by
-- whether an active legal hold covers them. Tenant-scoped and conversation
-- scoped holds both apply; user-scoped holds do not, because a board is
-- conversation content rather than a per-user record.
WITH expired_room_boards AS (
  SELECT
    w.id            AS whiteboard_id,
    w.tenant_id,
    w.conversation_id,
    r.expired_at,
    EXISTS (
      SELECT 1
      FROM legal_holds h
      WHERE h.tenant_id = w.tenant_id
        AND h.status = 'active'
        AND (
          h.scope_type = 'tenant'
          OR (h.scope_type = 'conversation' AND h.conversation_id = w.conversation_id)
        )
    ) AS held
  FROM whiteboards w
  JOIN conversation_ephemeral_rooms r
    ON r.tenant_id = w.tenant_id
   AND r.conversation_id = w.conversation_id
  WHERE r.status = 'expired'
),
operation_totals AS (
  SELECT
    b.whiteboard_id,
    b.tenant_id,
    b.expired_at,
    b.held,
    COUNT(o.id)                                   AS operations,
    COALESCE(SUM(pg_column_size(o.payload)), 0)   AS payload_bytes
  FROM expired_room_boards b
  LEFT JOIN whiteboard_operations o
    ON o.whiteboard_id = b.whiteboard_id
  GROUP BY b.whiteboard_id, b.tenant_id, b.expired_at, b.held
)
SELECT
  CASE WHEN held THEN 'held by an active legal hold' ELSE 'collectable' END AS disposition,
  COUNT(*)                                        AS boards,
  SUM(operations)                                 AS operations,
  pg_size_pretty(SUM(payload_bytes))              AS payload_size,
  MIN(expired_at)                                 AS oldest_expiry,
  MAX(expired_at)                                 AS newest_expiry
FROM operation_totals
GROUP BY held
ORDER BY held;

-- Concentration check. A backlog spread thinly across many tenants is a
-- different operational problem from one tenant holding most of it, and the
-- totals above hide the difference.
WITH expired_room_boards AS (
  SELECT w.id AS whiteboard_id, w.tenant_id
  FROM whiteboards w
  JOIN conversation_ephemeral_rooms r
    ON r.tenant_id = w.tenant_id
   AND r.conversation_id = w.conversation_id
  WHERE r.status = 'expired'
)
SELECT
  b.tenant_id,
  COUNT(DISTINCT b.whiteboard_id)                              AS boards,
  COUNT(o.id)                                                  AS operations,
  pg_size_pretty(COALESCE(SUM(pg_column_size(o.payload)), 0))  AS payload_size
FROM expired_room_boards b
LEFT JOIN whiteboard_operations o
  ON o.whiteboard_id = b.whiteboard_id
GROUP BY b.tenant_id
ORDER BY operations DESC
LIMIT 20;

-- Growth rate. Whether this backlog is still accumulating is the question that
-- decides urgency: after ADR-0068 ships, recent buckets should trend to zero.
WITH expired_room_boards AS (
  SELECT w.id AS whiteboard_id, r.expired_at
  FROM whiteboards w
  JOIN conversation_ephemeral_rooms r
    ON r.tenant_id = w.tenant_id
   AND r.conversation_id = w.conversation_id
  WHERE r.status = 'expired'
)
SELECT
  date_trunc('day', expired_at)::date AS expired_on,
  COUNT(*)                            AS boards
FROM expired_room_boards
WHERE expired_at IS NOT NULL
GROUP BY 1
ORDER BY 1 DESC
LIMIT 30;

-- Sanity check on the total whiteboard population, so the numbers above can be
-- read as a proportion rather than in isolation.
SELECT
  (SELECT COUNT(*) FROM whiteboards)            AS whiteboards_total,
  (SELECT COUNT(*) FROM whiteboard_operations)  AS operations_total,
  (SELECT COUNT(*) FROM conversation_ephemeral_rooms WHERE status = 'expired')
                                                AS expired_rooms_total;
