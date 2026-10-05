import { useMemo } from "react";
import type { Session } from "../../types";

/** Opaque generation: credentials remain dependencies and never become a UI key. */
export function useFederationAuthorityGeneration(session: Session | null) {
  return useMemo(() => crypto.randomUUID(), [
    session?.tenant.id, session?.user.tenant_id, session?.user.id, session?.device.id,
    session?.access_token, session?.refresh_token, session?.user.role,
    session?.user.status, session?.user.version, session?.user.account_type,
    session?.user.access_scope, session?.user.platform_role,
    session?.user.platform_role_expires_at
  ]);
}
