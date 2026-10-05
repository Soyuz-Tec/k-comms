import type { ReactNode } from "react";

/** A deliberately small formatting dialect rendered as React text, never HTML. */
export function RichMessageBody({ body }: { body: string }) {
  const lines = body.split("\n"); const output: ReactNode[] = [];
  let code: string[] | null = null;
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] || "";
    if (line.trim().startsWith("```")) {
      if (code) { output.push(<pre key={`code-${index}`}><code>{code.join("\n")}</code></pre>); code = null; }
      else code = [];
      continue;
    }
    if (code) { code.push(line); continue; }
    const text = inline(line);
    if (line.startsWith("> ")) output.push(<blockquote key={index}>{inline(line.slice(2))}</blockquote>);
    else if (line.startsWith("- ")) output.push(<div key={index}><span aria-hidden="true">• </span>{inline(line.slice(2))}</div>);
    else output.push(<span key={index}>{text}{index < lines.length - 1 && <br />}</span>);
  }
  if (code) output.push(<pre key="open-code"><code>{code.join("\n")}</code></pre>);
  return <>{output}</>;
}
function inline(text: string): ReactNode[] {
  return text.split(/(\*\*[^*\n]+\*\*|_[^_\n]+_|`[^`\n]+`)/g).map((part, index) =>
    part.startsWith("**") && part.endsWith("**") ? <strong key={index}>{part.slice(2, -2)}</strong> :
    part.startsWith("_") && part.endsWith("_") ? <em key={index}>{part.slice(1, -1)}</em> :
    part.startsWith("`") && part.endsWith("`") ? <code key={index}>{part.slice(1, -1)}</code> : part);
}
