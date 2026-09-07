import type { InputHTMLAttributes, ReactNode } from "react";
import { useId } from "react";

export function Field({
  label,
  hint,
  trailingAction,
  id,
  "aria-describedby": describedBy,
  ...props
}: InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: string; trailingAction?: ReactNode }) {
  const generatedId = useId();
  const inputId = id || generatedId;
  const hintId = hint ? `${inputId}-hint` : undefined;
  const descriptions = [describedBy, hintId].filter(Boolean).join(" ") || undefined;
  return (
    <div className="field">
      <label htmlFor={inputId}>{label}</label>
      {trailingAction ? <div className="field-input-row">
        <input {...props} id={inputId} aria-describedby={descriptions} />
        {trailingAction}
      </div> : <input {...props} id={inputId} aria-describedby={descriptions} />}
      {hint && <small id={hintId}>{hint}</small>}
    </div>
  );
}
