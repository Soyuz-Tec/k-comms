import { useState, type FormEvent } from "react";
import { useSession } from "../../app/session";
import { errorText } from "../../lib/format";

async function avatarData(file: File): Promise<string> {
  if (!file.type.startsWith("image/") || file.size > 5_000_000) throw new Error("Choose an image smaller than 5 MB.");
  const url = URL.createObjectURL(file);
  try {
    const image = new Image(); image.src = url; await image.decode();
    const canvas = document.createElement("canvas");
    const scale = Math.min(1, 256 / Math.max(image.width, image.height));
    canvas.width = Math.max(1, Math.round(image.width * scale)); canvas.height = Math.max(1, Math.round(image.height * scale));
    const context = canvas.getContext("2d");
    if (!context) throw new Error("Image conversion is unavailable.");
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    const result = canvas.toDataURL("image/png");
    if (result.length > 131_094) throw new Error("Choose a simpler or smaller image.");
    return result;
  } finally { URL.revokeObjectURL(url); }
}
export function EnterpriseProfileSettings() {
  const { api, session, setSession } = useSession();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  if (!session) return null;
  const identity = session;
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const data = new FormData(event.currentTarget);
    setBusy(true); setError(null);
    try {
      const file = data.get("avatar") as File | null;
      const avatar = data.get("remove_avatar") === "on" ? null : file?.size ? await avatarData(file) : identity.user.avatar_url;
      const user = await api.updateProfile({ display_name: identity.user.display_name, timezone: String(data.get("timezone") || "Etc/UTC"), avatar_url: avatar });
      setSession((current) => current?.user.id === user.id && current.tenant.id === user.tenant_id ? { ...current, user } : current);
      setNotice("Avatar and timezone saved.");
    } catch (reason: unknown) { setError(errorText(reason)); }
    finally { setBusy(false); }
  }
  return <section className="settings-card enterprise-settings" aria-labelledby="profile-details-title"><h2 id="profile-details-title">Avatar and timezone</h2>
    {error && <p role="alert">{error}</p>}{notice && <p role="status">{notice}</p>}
    {session.user.avatar_url && <img src={session.user.avatar_url} alt="Your avatar" width="64" height="64" />}
    <form onSubmit={save}><label className="field">Avatar image<input name="avatar" type="file" accept="image/png,image/jpeg,image/webp" /></label>
      <label><input type="checkbox" name="remove_avatar" />Remove avatar</label>
      <label className="field">IANA timezone<input name="timezone" defaultValue={session.user.timezone || "Etc/UTC"} placeholder="Europe/London" required /></label>
      <button className="button primary" disabled={busy}>Save avatar and timezone</button></form></section>;
}
