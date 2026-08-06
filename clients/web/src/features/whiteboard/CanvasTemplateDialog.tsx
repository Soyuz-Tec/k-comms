import { createPortal } from "react-dom";
import { useMemo, useState } from "react";
import { AppIcon } from "../../components/AppIcon";
import { useModalDialog } from "../../components/useModalDialog";
import {
  canvasTemplateCategories,
  filteredCanvasTemplates,
  type CanvasTemplateCategory,
  type CanvasTemplatePreview
} from "./canvasTemplates";
import "./CanvasTemplateDialog.css";

function TemplatePreview({ variant }: { variant: CanvasTemplatePreview }) {
  return (
    <span className={`canvas-template-preview preview-${variant}`} aria-hidden="true">
      {Array.from({ length: variant === "meeting" ? 8 : 9 }, (_, index) => (
        <i key={index} />
      ))}
    </span>
  );
}

export function CanvasTemplateDialog({
  elementCount,
  onApply,
  onClose
}: {
  elementCount: number;
  onApply: (templateId: string) => Promise<void> | void;
  onClose: () => void;
}) {
  const [category, setCategory] = useState<CanvasTemplateCategory>("recommended");
  const [query, setQuery] = useState("");
  const dialogRef = useModalDialog(onClose);
  const results = useMemo(
    () => filteredCanvasTemplates(category, query),
    [category, query]
  );

  return createPortal(
    <div className="canvas-template-backdrop">
      <section
        ref={dialogRef}
        className="canvas-template-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="canvas-template-title"
        aria-describedby="canvas-template-description"
        tabIndex={-1}
      >
        <header className="canvas-template-header">
          <div>
            <span className="canvas-template-eyebrow">K-Comms canvas</span>
            <h2 id="canvas-template-title">Start with a template</h2>
            <p id="canvas-template-description">
              Choose a layout, then make it yours with everyone in the room.
            </p>
          </div>
          <button type="button" aria-label="Close templates" onClick={onClose}>
            <AppIcon name="x" />
          </button>
        </header>

        <label className="canvas-template-search">
          <AppIcon name="search" />
          <span className="sr-only">Search templates</span>
          <input
            data-initial-focus
            type="search"
            value={query}
            placeholder="Search templates"
            onChange={(event) => setQuery(event.target.value)}
          />
        </label>

        {elementCount > 0 && (
          <div className="canvas-template-safe-add" role="status">
            <AppIcon name="plus" />
            <span><strong>Your work stays in place.</strong> The template will be added beside it.</span>
          </div>
        )}

        <div className="canvas-template-body">
          <nav className="canvas-template-categories" aria-label="Template categories">
            {canvasTemplateCategories.map((item, index) => (
              <button
                key={item.id}
                type="button"
                aria-pressed={category === item.id}
                onClick={() => setCategory(item.id)}
              >
                <AppIcon name={index === 0 ? "sparkles" : "whiteboard"} />
                <span>{item.label}</span>
              </button>
            ))}
          </nav>

          <div className="canvas-template-results" aria-live="polite">
            <div className="canvas-template-results-heading">
              <div>
                <span>{query ? "Search results" : canvasTemplateCategories.find((item) => item.id === category)?.label}</span>
                <strong>{results.length} starter {results.length === 1 ? "layout" : "layouts"}</strong>
              </div>
              <span>Original K-Comms templates</span>
            </div>

            {results.length > 0 ? (
              <div className="canvas-template-grid">
                {results.map((template) => (
                  <button
                    key={template.id}
                    className="canvas-template-card"
                    type="button"
                    aria-label={`Use ${template.name} template`}
                    onClick={() => void onApply(template.id)}
                  >
                    <TemplatePreview variant={template.preview} />
                    <span className="canvas-template-card-copy">
                      <strong>{template.name}</strong>
                      <small>{template.description}</small>
                    </span>
                    <span className="canvas-template-use">Use template <AppIcon name="arrowUpRight" /></span>
                  </button>
                ))}
              </div>
            ) : (
              <div className="canvas-template-empty">
                <AppIcon name="search" />
                <strong>No templates found</strong>
                <span>Try a different word or category.</span>
                <button type="button" onClick={() => {
                  setQuery("");
                  setCategory("recommended");
                }}>
                  Show all templates
                </button>
              </div>
            )}
          </div>
        </div>
      </section>
    </div>,
    document.body
  );
}
