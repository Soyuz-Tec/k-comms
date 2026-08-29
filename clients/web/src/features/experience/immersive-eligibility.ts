import type { ServiceStatus } from "../../types";

/**
 * The tenant-, user- or surface-scoped half of eligibility.
 *
 * Members carry it on UserCapabilities and guests on GuestCapabilities, which
 * are different responses issued by different endpoints -- but the question
 * and the field are the same, so one selector answers for both rather than
 * two selectors drifting apart.
 */
export interface ImmersiveSubjectCapabilities {
  allow_immersive_mode?: boolean;
}

/**
 * The single selector §7.2 requires: one place that answers "may this client
 * enter Immersive Mode", reading both capability channels and nothing else.
 *
 * Two independent switches have to agree:
 *
 *   status.capabilities.immersive_mode  -- the deployment kill switch, which
 *     retires the surface for every tenant at once without a client release.
 *   capabilities.allow_immersive_mode   -- the policy for whoever is asking:
 *     the tenant for a member, the link for a guest, the room for an
 *     instant-room participant. Different responses, same question, so one
 *     selector rather than three that can drift.
 *
 * Every ambiguous input resolves to false. A server that predates this
 * increment omits both fields, an unreachable status endpoint leaves the
 * status null, and a malformed payload can produce a non-boolean; all three
 * mean "not eligible", never "assume yes".
 */
export function selectImmersiveEligibility(
  status: ServiceStatus | null | undefined,
  capabilities: ImmersiveSubjectCapabilities | null | undefined
): boolean {
  return (
    status?.capabilities?.immersive_mode === true &&
    capabilities?.allow_immersive_mode === true
  );
}

/**
 * The join deadline from §7.3.
 *
 * Capability retrieval starts when the prejoin surface loads, so by the time
 * Join is pressed the answer is usually already known. When it is not, media
 * connection waits at most this long for it -- and an unresolved decision at
 * the deadline selects the legacy UI. Joining the call is never delayed
 * further than this for a presentation choice.
 */
export const IMMERSIVE_JOIN_DEADLINE_MS = 300;

/**
 * Resolves eligibility under the join deadline, failing closed.
 *
 * Rejection is not propagated: a capability lookup that throws is a denied
 * decision, not a failed join.
 */
export async function resolveImmersiveWithinDeadline(
  pending: Promise<boolean>,
  deadlineMs: number = IMMERSIVE_JOIN_DEADLINE_MS
): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<boolean>((resolve) => {
    timer = setTimeout(() => resolve(false), deadlineMs);
  });
  try {
    return await Promise.race([pending.catch(() => false), deadline]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
