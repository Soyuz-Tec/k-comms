import type { InputHTMLAttributes } from "react";
import { useId } from "react";

export function Field({
  label,
  hint,
  id,
  "aria-describedby": describedBy,
  ...props
}: InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: string }) {
  const generatedId = useId();
  const inputId = id || generatedId;
  const hintId = hint ? `${inputId}-hint` : undefined;
  const descriptions = [describedBy, hintId].filter(Boolean).join(" ") || undefined;
  return (
    <div className="field">
      <label htmlFor={inputId}>{label}</label>
      <input {...props} id={inputId} aria-describedby={descriptions} />
      {hint && <small id={hintId}>{hint}</small>}
    </div>
  );
}
