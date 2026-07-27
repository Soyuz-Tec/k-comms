import type { Conversation, RetainedSenderLabel } from "../types";
import { conversationTitle } from "./format";

export interface ParticipantIdentity {
  id: string;
  display_name: string;
}

const participantCodes = Symbol("k-comms-participant-codes");

type IndexedDuplicateNames = Set<string> & {
  [participantCodes]: ReadonlyMap<string, string>;
};

export function participantNameKey(displayName: string): string {
  return displayName.trim().normalize("NFKC").toLowerCase();
}

export function participantDisambiguator(userId: string): string {
  let hash = 2_166_136_261;
  for (let index = 0; index < userId.length; index += 1) {
    hash ^= userId.charCodeAt(index);
    hash = Math.imul(hash, 16_777_619);
  }
  return (hash >>> 0).toString(36).toUpperCase().padStart(5, "0").slice(-5);
}

export function duplicateParticipantNames(
  participants: Iterable<ParticipantIdentity>
): ReadonlySet<string> {
  const identitiesById = new Map<string, ParticipantIdentity>();
  for (const participant of participants) {
    identitiesById.set(participant.id, participant);
  }

  const participantsByName = new Map<string, ParticipantIdentity[]>();
  for (const participant of identitiesById.values()) {
    const key = participantNameKey(participant.display_name);
    const group = participantsByName.get(key) || [];
    group.push(participant);
    participantsByName.set(key, group);
  }

  const duplicates = new Set(
    [...participantsByName.entries()]
      .filter(([, group]) => group.length > 1)
      .map(([name]) => name)
  ) as IndexedDuplicateNames;
  const codes = new Map<string, string>();
  for (const [name, group] of participantsByName) {
    if (!duplicates.has(name)) continue;
    allocateUniqueParticipantCodes(group, codes);
  }
  Object.defineProperty(duplicates, participantCodes, {
    configurable: false,
    enumerable: false,
    value: codes,
    writable: false
  });
  return duplicates;
}

function allocateUniqueParticipantCodes(
  participants: ParticipantIdentity[],
  target: Map<string, string>
): void {
  const candidates = participants.map((participant) => ({
    id: participant.id,
    code: `${participantDisambiguator(participant.id)}${participantExtendedCode(participant.id)}`
  }));
  let length = 5;
  while (
    length < candidates[0]!.code.length &&
    new Set(candidates.map(({ code }) => code.slice(0, length))).size !==
      candidates.length
  ) {
    length += 1;
  }
  const collisions = new Map<string, string[]>();
  for (const candidate of candidates) {
    const code = candidate.code.slice(0, length);
    const ids = collisions.get(code) || [];
    ids.push(candidate.id);
    collisions.set(code, ids);
  }
  for (const [code, ids] of collisions) {
    ids.sort();
    ids.forEach((id, index) => {
      target.set(id, ids.length === 1 ? code : `${code}-${index + 1}`);
    });
  }
}

function participantExtendedCode(userId: string): string {
  let hash = 14_695_981_039_346_656_037n;
  for (let index = 0; index < userId.length; index += 1) {
    hash ^= BigInt(userId.charCodeAt(index));
    hash = BigInt.asUintN(64, hash * 1_099_511_628_211n);
  }
  return hash.toString(36).toUpperCase().padStart(13, "0");
}

export function duplicateDirectConversationNames(
  conversations: Iterable<Conversation>
): ReadonlySet<string> {
  return duplicateParticipantNames(
    [...conversations]
      .filter(
        (conversation) =>
          conversation.kind === "direct" &&
          Boolean(conversation.counterpart_display_name?.trim())
      )
      .map((conversation) => ({
        id: conversation.counterpart_user_id || conversation.id,
        display_name: conversation.counterpart_display_name!.trim()
      }))
  );
}

export function conversationParticipantIdentifier(
  conversation: Conversation,
  duplicateDisplayNames: ReadonlySet<string>
): string {
  if (
    conversation.kind !== "direct" ||
    !conversation.counterpart_display_name?.trim()
  ) {
    return conversationTitle(conversation);
  }
  return participantIdentifier(
    {
      id: conversation.counterpart_user_id || conversation.id,
      display_name: conversation.counterpart_display_name.trim()
    },
    duplicateDisplayNames
  );
}

export function participantIdentifier(
  participant: ParticipantIdentity,
  duplicateDisplayNames: ReadonlySet<string>
): string {
  const indexed = duplicateDisplayNames as Partial<IndexedDuplicateNames>;
  const allocatedCode = indexed[participantCodes]?.get(participant.id);
  return duplicateDisplayNames.has(participantNameKey(participant.display_name))
    ? `${participant.display_name} · #${allocatedCode || participantDisambiguator(participant.id)}`
    : participant.display_name;
}

export function retainedSenderLabelMap(
  labels: RetainedSenderLabel[] | undefined
): Map<string, RetainedSenderLabel> {
  return mergeRetainedSenderLabelMaps(new Map(), labels);
}

export function mergeRetainedSenderLabelMaps(
  current: Map<string, RetainedSenderLabel>,
  incoming: RetainedSenderLabel[] | undefined
): Map<string, RetainedSenderLabel> {
  if (!incoming || incoming.length === 0) return current;
  const next = new Map(current);
  for (const label of incoming) {
    const existing = next.get(label.id);
    if (
      existing?.redacted === true &&
      label.redacted !== true
    ) {
      continue;
    }
    next.set(label.id, label);
  }
  return next;
}

export function resolveVisibleSenderIdentity(
  userId: string,
  activeIdentities: ReadonlyMap<string, ParticipantIdentity>,
  retainedLabels: ReadonlyMap<string, RetainedSenderLabel>,
  fallbackIdentities: ReadonlyMap<string, ParticipantIdentity>[]
): ParticipantIdentity | undefined {
  const retained = retainedLabels.get(userId);
  if (retained?.redacted === true) return retained;
  return (
    activeIdentities.get(userId) ||
    retained ||
    fallbackIdentities
      .map((identities) => identities.get(userId))
      .find((identity) => identity !== undefined)
  );
}
