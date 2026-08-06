import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import { describe, expect, it, vi } from "vitest";
import {
  canvasTemplates,
  createCanvasTemplateElements,
  filteredCanvasTemplates
} from "./canvasTemplates";

vi.mock("@excalidraw/excalidraw", () => ({
  convertToExcalidrawElements: (elements: Array<Record<string, unknown>>) =>
    elements.map((element, index) => ({
      width: 100,
      height: 100,
      version: 1,
      versionNonce: index + 1,
      isDeleted: false,
      ...element,
      id: `${String(element.id)}-${index}`
    }))
}));

describe("canvasTemplates", () => {
  it("builds every starter layout from supported, uniquely identified objects", async () => {
    for (const template of canvasTemplates) {
      const elements = await createCanvasTemplateElements(template.id);
      expect(elements.length).toBeGreaterThan(4);
      expect(new Set(elements.map((element) => element.id)).size).toBe(elements.length);
      expect(elements.every((element) =>
        ["rectangle", "ellipse", "text"].includes(element.type)
      )).toBe(true);
    }
  });

  it("places a template beside existing work instead of overwriting it", async () => {
    const existing = [{
      id: "existing",
      type: "rectangle",
      x: 80,
      y: 120,
      width: 200,
      height: 100,
      version: 1,
      versionNonce: 2,
      isDeleted: false
    }] as unknown as ExcalidrawElement[];

    const inserted = await createCanvasTemplateElements("swot-analysis", existing);
    expect(Math.min(...inserted.map((element) => element.x))).toBeGreaterThanOrEqual(440);
    expect(existing).toHaveLength(1);
  });

  it("filters by category, name, description, and tags", () => {
    expect(filteredCanvasTemplates("planning", "").map((item) => item.id))
      .toEqual(["team-board", "meeting-agenda"]);
    expect(filteredCanvasTemplates("recommended", "kanban").map((item) => item.id))
      .toEqual(["team-board"]);
    expect(filteredCanvasTemplates("reflection", "creative")).toEqual([]);
  });
});
