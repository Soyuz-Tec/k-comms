import { useEffect, useState } from "react";
import { AppIcon } from "../../components/AppIcon";
import { AvatarBadge } from "../../components/AvatarBadge";
import { duplicateParticipantNames, participantIdentifier } from "../../lib/participantIdentity";
import { formatDateTime } from "../../lib/format";
import type { CallMediaKind, DirectoryPerson, PrivateContactGroup } from "../../types";
import type { useMemberWorkspace } from "./useMemberWorkspace";
import "./memberWorkspace.css";

type Controller = ReturnType<typeof useMemberWorkspace>;
type StartMode = "message" | CallMediaKind;

export function ContactToggle({ person, controller, name = person.display_name }: { person: DirectoryPerson; controller: Controller; name?: string }) {
  const [pending, setPending] = useState<boolean | null>(null);
  const { data, denied, busy, replace } = controller;
  useEffect(() => { if (denied) setPending(null); }, [denied]);
  const saved = data?.contacts.some(({ id }) => id === person.id) === true;
  async function change(adding: boolean) {
    if (!data) return;
    setPending(adding);
    const ids = new Set(data.contacts.map(({ id }) => id));
    if (adding) ids.add(person.id); else ids.delete(person.id);
    const success = await replace({
      contact_ids: [...ids],
      groups: data.groups.map((group) => ({ ...group, member_ids: group.member_ids.filter((id) => ids.has(id)) }))
    });
    if (success) setPending(null);
  }
  const label = pending !== null
    ? `Retry ${pending ? "adding" : "removing"} ${name}`
    : `${saved ? "Remove" : "Add"} ${name} ${saved ? "from" : "to"} contacts`;
  return <button type="button" className="button ghost compact contact-toggle" disabled={!data || denied || busy || (!saved && data.contacts.length >= data.limits.contacts)}
    aria-label={label} title={saved ? "Also removes this person from your private contact groups." : label}
    onClick={() => void change(pending ?? !saved)}><AppIcon name={saved ? "check" : "userPlus"} /><span className="sr-only">{pending !== null ? "Retry contact change" : saved ? "Saved contact" : "Add contact"}</span></button>;
}

export function PrivateContacts({ controller, section, query, onStart, busyAction, audioEnabled, videoEnabled, availabilityDescriptionId }: {
  controller: Controller;
  section: "contacts" | "groups";
  query: string;
  onStart: (ids: string[], title: string | null, mode: StartMode, version: number) => Promise<void>;
  busyAction: boolean;
  audioEnabled: boolean;
  videoEnabled: boolean;
  availabilityDescriptionId?: string;
}) {
  const { data, denied, loading, busy, error, refresh, replace } = controller;
  const [draft, setDraft] = useState<PrivateContactGroup | null>(null);
  const [draftOrigin, setDraftOrigin] = useState<"new" | "existing">("new");
  const [draftError, setDraftError] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);
  const [memberQuery, setMemberQuery] = useState("");
  const [memberLimit, setMemberLimit] = useState(50);
  const [selection, setSelection] = useState<Record<string, string[]>>({});
  useEffect(() => {
    if (denied) { setDraft(null); setDraftError(null); setDeleting(null); setSelection({}); }
  }, [denied]);
  if (denied) return <p role="alert">Private contacts are unavailable. Sign in again to continue.</p>;
  if (!data) return <div role={loading ? "status" : "alert"}>
    {loading ? "Loading private contacts…" : error || "Private contacts could not be loaded."}
    {!loading && <button type="button" onClick={() => void refresh()}>Retry private contacts</button>}
  </div>;
  const duplicateNames = duplicateParticipantNames(data.contacts);
  const names = new Map(data.contacts.map((person) => [person.id, participantIdentifier(person, duplicateNames)]));
  const contactIds = new Set(names.keys());
  const editorContacts = data.contacts.filter((person) => person.display_name.toLocaleLowerCase().includes(memberQuery.trim().toLocaleLowerCase()));
  const filtered = query.trim().toLocaleLowerCase();
  const visibleContacts = data.contacts.filter((person) => person.display_name.toLocaleLowerCase().includes(filtered));
  const visibleGroups = data.groups.filter((group) => group.name.toLocaleLowerCase().includes(filtered));
  const groupLabels = duplicateParticipantNames(data.groups.map((group) => ({ id: group.id, display_name: group.name })));

  async function saveGroup() {
    if (!data || !draft) return;
    if (draftOrigin === "existing" && !data.groups.some((group) => group.id === draft.id)) {
      setDraftError("This group was deleted elsewhere. Create a new group from your draft or cancel.");
      return;
    }
    const name = draft.name.trim();
    if (!name || name.length > 80) { setDraftError("Enter a group name of 1 to 80 characters."); return; }
    if (draft.member_ids.some((id) => !contactIds.has(id))) {
      setDraftError("A selected contact is no longer available. Review and remove unavailable selections before saving.");
      return;
    }
    const groups = data.groups.filter((group) => group.id !== draft.id);
    groups.push({ ...draft, name });
    setDraftError(null);
    if (await replace({ contact_ids: data.contacts.map(({ id }) => id), groups })) setDraft(null);
  }
  async function deleteGroup(id: string) {
    if (!data) return;
    if (await replace({ contact_ids: data.contacts.map(({ id }) => id), groups: data.groups.filter((group) => group.id !== id) })) setDeleting(null);
  }

  return <section className="private-contacts" aria-label={section === "contacts" ? "Private contacts" : "Private contact groups"}>
    <p>Your contacts and groups are private. Conversation membership is assigned when you start a conversation.</p>
    <p className="private-contact-counter">{data.contacts.length} / {data.limits.contacts} contacts · {data.groups.length} / {data.limits.groups} groups. Last synchronized {formatDateTime(data.observed_at)}.</p>
    {error && <div className="inline-notice error" role="alert">{error}<button type="button" disabled={busy} onClick={() => void refresh()}>Refresh private contacts</button></div>}
    {section === "contacts" ? <>
      {visibleContacts.length === 0 && <p>{filtered ? "No matching contacts." : "Add people to contacts from the People section."}</p>}
      <ul className="directory-list" aria-label="Contacts">{visibleContacts.map((person) => <li className="directory-row" key={person.id}>
        <AvatarBadge name={person.display_name} /><div className="directory-row-copy"><strong>{names.get(person.id)}</strong></div>
        <div className="member-workspace-actions">
          <RecipientActions name={names.get(person.id) || "Contact"} disabled={busy || busyAction} audioEnabled={audioEnabled} videoEnabled={videoEnabled} availabilityDescriptionId={availabilityDescriptionId}
            onStart={(mode) => void onStart([person.id], null, mode, data.version)} />
          <ContactToggle person={person} controller={controller} name={names.get(person.id)} />
        </div>
      </li>)}</ul>
    </> : <>
      <button className="button primary" type="button" disabled={busy || data.groups.length >= data.limits.groups} onClick={() => { setDraft({ id: crypto.randomUUID(), name: "", member_ids: [] }); setDraftOrigin("new"); setMemberQuery(""); setMemberLimit(50); setDraftError(null); }}>Create contact group</button>
      {data.contacts.length === 0 && <p>Add contacts from People before choosing group members.</p>}
      {draft && <form className="private-contact-editor" aria-label="Edit private contact group" onSubmit={(event) => { event.preventDefault(); void saveGroup(); }}>
        <label className="field">Group name<input value={draft.name} maxLength={80} required onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label>
        <p>{draft.member_ids.length} / {data.limits.members_per_group} selected contacts</p>
        <label className="field">Find group members<input type="search" value={memberQuery} maxLength={120} onChange={(event) => { setMemberQuery(event.target.value); setMemberLimit(50); }} /></label>
        <ul className="private-contact-selection" aria-label="Group members">{editorContacts.slice(0, memberLimit).map((person) => <li key={person.id}><label><input type="checkbox" checked={draft.member_ids.includes(person.id)} disabled={busy || (!draft.member_ids.includes(person.id) && draft.member_ids.length >= data.limits.members_per_group)}
          onChange={(event) => setDraft({ ...draft, member_ids: event.target.checked ? [...draft.member_ids, person.id] : draft.member_ids.filter((id) => id !== person.id) })} />{names.get(person.id)}</label></li>)}</ul>
        {editorContacts.length > memberLimit && <button type="button" onClick={() => setMemberLimit((limit) => limit + 50)}>Show more group contacts</button>}
        {draft.member_ids.some((id) => !contactIds.has(id)) && <button type="button" onClick={() => setDraft({ ...draft, member_ids: draft.member_ids.filter((id) => contactIds.has(id)) })}>Remove unavailable selections</button>}
        {draftOrigin === "existing" && !data.groups.some((group) => group.id === draft.id) && <div role="alert">
          <p>This group was deleted elsewhere. Your draft is kept.</p><button type="button" disabled={busy || data.groups.length >= data.limits.groups} onClick={() => { setDraft({ ...draft, id: crypto.randomUUID() }); setDraftOrigin("new"); setDraftError(null); }}>Create new group from draft</button>
        </div>}
        {draftError && <p role="alert">{draftError}</p>}
        <div className="member-workspace-actions"><button className="button primary" type="submit" disabled={busy}>{busy ? "Saving…" : "Save contact group"}</button><button type="button" disabled={busy} onClick={() => { setDraft(null); setDraftError(null); }}>Cancel group edit</button></div>
      </form>}
      <ul className="private-contact-group-list" aria-label="Contact groups">{visibleGroups.map((group) => {
        const label = participantIdentifier({ id: group.id, display_name: group.name }, groupLabels);
        const selected = (selection[group.id] ?? group.member_ids).filter((id) => contactIds.has(id) && group.member_ids.includes(id));
        return <li className="private-contact-group" key={group.id}>
          <h2>{label}</h2>
          <ul className="private-contact-selection" aria-label={`Members of ${label}`}>{group.member_ids.map((id) => <li key={id}><label><input type="checkbox" checked={selected.includes(id)} disabled={busy || busyAction}
            onChange={(event) => setSelection({ ...selection, [group.id]: event.target.checked ? [...selected, id] : selected.filter((candidate) => candidate !== id) })} />{names.get(id) || "Unavailable contact"}</label></li>)}</ul>
          <div className="member-workspace-actions"><RecipientActions name={`selected contacts in ${label}`} disabled={busy || busyAction || selected.length === 0} audioEnabled={audioEnabled} videoEnabled={videoEnabled} availabilityDescriptionId={availabilityDescriptionId}
            onStart={(mode) => void onStart(selected, group.name, mode, data.version)} />
            <button type="button" disabled={busy} onClick={() => { setDraft({ ...group, member_ids: [...group.member_ids] }); setDraftOrigin("existing"); setMemberQuery(""); setMemberLimit(50); setDraftError(null); }}>Edit {label}</button>
            <button type="button" disabled={busy} onClick={() => setDeleting(group.id)}>Delete {label}</button>
          </div>
          {deleting === group.id && <div role="group" aria-label={`Confirm deleting ${label}`}><p>Delete this private group? Existing conversations keep their membership.</p><div className="member-workspace-actions"><button type="button" disabled={busy} onClick={() => void deleteGroup(group.id)}>Confirm group deletion</button><button type="button" disabled={busy} onClick={() => setDeleting(null)}>Keep group</button></div></div>}
        </li>;
      })}</ul>
      {!draft && visibleGroups.length === 0 && <p>{filtered ? "No matching groups." : "No contact groups yet."}</p>}
    </>}
  </section>;
}

function RecipientActions({ name, disabled, audioEnabled, videoEnabled, availabilityDescriptionId, onStart }: {
  name: string; disabled: boolean; audioEnabled: boolean; videoEnabled: boolean; availabilityDescriptionId?: string;
  onStart: (mode: StartMode) => void;
}) {
  return <>
    <button type="button" className="button ghost compact" aria-label={`Message ${name}`} disabled={disabled} onClick={() => onStart("message")}><AppIcon name="message" />Message</button>
    <button type="button" className="button ghost compact" aria-label={`Audio call ${name}`} aria-describedby={availabilityDescriptionId} disabled={disabled || !audioEnabled} onClick={() => onStart("audio")}><AppIcon name="phone" />Audio call</button>
    <button type="button" className="button ghost compact" aria-label={`Video call ${name}`} aria-describedby={availabilityDescriptionId} disabled={disabled || !videoEnabled} onClick={() => onStart("video")}><AppIcon name="video" />Video call</button>
  </>;
}
