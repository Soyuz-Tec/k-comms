export type FormattingKind = "bold" | "italic" | "code" | "quote" | "bullet";
export function formatSelection(body: string, start: number, end: number, kind: FormattingKind) {
  const selected = body.slice(start, end) || (kind === "code" ? "code" : "text");
  const delimiters = { bold: ["**", "**"], italic: ["_", "_"], code: ["`", "`"], quote: ["> ", ""], bullet: ["- ", ""] } as const;
  const [before, after] = delimiters[kind]; const insertion = before + selected + after;
  return { body: body.slice(0, start) + insertion + body.slice(end), start: start + before.length, end: start + before.length + selected.length };
}
export function CompositionToolbar({ value, textareaId, disabled, onChange }: { value: string; textareaId: string; disabled: boolean; onChange: (value: string) => void }) {
  function apply(kind: FormattingKind) {
    const textarea = document.getElementById(textareaId);
    if (!(textarea instanceof HTMLTextAreaElement)) return;
    const result = formatSelection(value, textarea.selectionStart, textarea.selectionEnd, kind);
    if (result.body.length > 65_535) return;
    onChange(result.body);
    window.requestAnimationFrame(() => { textarea.focus(); textarea.setSelectionRange(result.start, result.end); });
  }
  return <div className="composition-formatting" role="group" aria-label="Message formatting">{([ ["bold", "Bold"], ["italic", "Italic"], ["code", "Code"], ["quote", "Quote"], ["bullet", "Bullet"] ] as const).map(([kind, label]) => <button key={kind} type="button" disabled={disabled} onClick={() => apply(kind)}>{label}</button>)}</div>;
}
