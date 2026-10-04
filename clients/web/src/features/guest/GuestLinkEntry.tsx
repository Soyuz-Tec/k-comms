import { useId, useState } from "react";
import type { FormEvent } from "react";
import { useNavigate } from "react-router";
import { guestJoinTargetFromInput } from "./guestLink";
import "./GuestLinkEntry.css";

export function GuestLinkEntry({ onJoin }: { onJoin?: (target: string) => void }) {
  const navigate = useNavigate();
  const id = useId();
  const [value, setValue] = useState("");
  const [error, setError] = useState("");
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const target = guestJoinTargetFromInput(value);
    if (!target) {
      setError("Paste the complete room invite link for this K-Comms site.");
      return;
    }
    setValue("");
    setError("");
    if (onJoin) onJoin(target);
    else navigate(target);
  }
  return (
    <form className="guest-link-entry" onSubmit={submit}>
      <div className="field">
        <label htmlFor={id}>Room invite link</label>
        <input id={id} type="text" autoComplete="off" spellCheck={false} value={value} maxLength={4096}
          aria-invalid={Boolean(error)} aria-describedby={error ? `${id}-error` : `${id}-help`}
          onChange={(event) => { setValue(event.target.value); setError(""); }} required />
        <small id={`${id}-help`}>Your host's full invite link opens the room preview.</small>
        {error && <small id={`${id}-error`} className="form-error" role="alert">{error}</small>}
      </div>
      <button className="button ghost full" type="submit">Open room invite</button>
    </form>
  );
}
