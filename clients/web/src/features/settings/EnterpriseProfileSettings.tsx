export async function avatarData(file: File): Promise<string> {
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
export function EnterpriseProfileSettings({ timezone, onTimezoneChange, hasAvatar, busy }: {
  timezone: string;
  onTimezoneChange: (value: string) => void;
  hasAvatar: boolean;
  busy: boolean;
}) {
  return <div className="profile-preferences">
    <div className="field"><label htmlFor="profile-avatar">Avatar image</label><input id="profile-avatar" name="avatar" type="file" accept="image/png,image/jpeg,image/webp" disabled={busy} aria-describedby="profile-avatar-help" /><small id="profile-avatar-help">Choose a PNG, JPEG or WebP image smaller than 5 MB.</small></div>
    {hasAvatar && <label className="profile-remove-avatar"><input type="checkbox" name="remove_avatar" disabled={busy} />Remove avatar</label>}
    <div className="field"><label htmlFor="profile-timezone">Time zone</label><input id="profile-timezone" name="timezone" value={timezone} onChange={(event) => onTimezoneChange(event.target.value)} placeholder="Europe/London" list="profile-timezones" required aria-describedby="profile-timezone-help" /><small id="profile-timezone-help">Use a location such as Europe/London or Asia/Kolkata.</small></div>
    <datalist id="profile-timezones">{["Etc/UTC", "America/New_York", "America/Chicago", "America/Los_Angeles", "Europe/London", "Europe/Berlin", "Asia/Kolkata", "Asia/Singapore", "Asia/Tokyo", "Australia/Sydney"].map((zone) => <option key={zone} value={zone} />)}</datalist>
  </div>;
}
