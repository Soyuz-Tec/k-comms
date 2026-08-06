import type { convertToExcalidrawElements as convertElements } from "@excalidraw/excalidraw";
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types";

type TemplateSkeletons = NonNullable<
  Parameters<typeof convertElements>[0]
>;

export type CanvasTemplateCategory =
  | "recommended"
  | "brainstorming"
  | "planning"
  | "reflection";

export type CanvasTemplatePreview =
  | "affinity"
  | "brainstorm"
  | "kanban"
  | "meeting"
  | "retrospective"
  | "swot";

export interface CanvasTemplate {
  id: string;
  name: string;
  description: string;
  category: Exclude<CanvasTemplateCategory, "recommended">;
  tags: readonly string[];
  preview: CanvasTemplatePreview;
  build: () => TemplateSkeletons;
}

export const canvasTemplateCategories: ReadonlyArray<{
  id: CanvasTemplateCategory;
  label: string;
}> = [
  { id: "recommended", label: "Recommended" },
  { id: "brainstorming", label: "Brainstorming" },
  { id: "planning", label: "Planning" },
  { id: "reflection", label: "Reflection" }
];

const palette = {
  ink: "#243b3a",
  muted: "#5d7472",
  teal: "#0f766e",
  tealSoft: "#ccfbf1",
  blue: "#2563eb",
  blueSoft: "#dbeafe",
  amber: "#d97706",
  amberSoft: "#fef3c7",
  rose: "#e11d48",
  roseSoft: "#ffe4e6",
  violet: "#7c3aed",
  violetSoft: "#ede9fe",
  canvas: "#ffffff"
} as const;

function card(
  id: string,
  x: number,
  y: number,
  width: number,
  height: number,
  label: string,
  backgroundColor: string,
  strokeColor: string = palette.ink
): TemplateSkeletons[number] {
  return {
    id,
    type: "rectangle",
    x,
    y,
    width,
    height,
    backgroundColor,
    strokeColor,
    fillStyle: "solid",
    roundness: { type: 3 },
    roughness: 0,
    strokeWidth: 2,
    label: {
      text: label,
      fontSize: 20,
      textAlign: "center",
      verticalAlign: "middle"
    }
  };
}

function heading(
  id: string,
  x: number,
  y: number,
  text: string,
  width = 720,
  fontSize = 32
): TemplateSkeletons[number] {
  return {
    id,
    type: "text",
    x,
    y,
    width,
    height: fontSize * 1.4,
    text,
    fontSize,
    strokeColor: palette.ink,
    textAlign: "left"
  };
}

function note(
  id: string,
  x: number,
  y: number,
  text: string,
  backgroundColor: string
): TemplateSkeletons[number] {
  return card(id, x, y, 176, 116, text, backgroundColor, palette.muted);
}

function buildAffinityMap(): TemplateSkeletons {
  const columns = [
    { id: "people", title: "People", color: palette.amberSoft },
    { id: "process", title: "Process", color: palette.blueSoft },
    { id: "ideas", title: "Ideas", color: palette.violetSoft }
  ] as const;
  const elements: TemplateSkeletons = [
    heading("affinity-title", 0, 0, "Affinity map")
  ];

  columns.forEach((column, columnIndex) => {
    const x = columnIndex * 236;
    elements.push(
      card(
        `affinity-${column.id}-header`,
        x,
        78,
        212,
        64,
        column.title,
        column.color
      )
    );
    for (let row = 0; row < 3; row += 1) {
      elements.push(
        note(
          `affinity-${column.id}-${row + 1}`,
          x + 18,
          166 + row * 138,
          row === 0 ? "Add an observation" : "Add a note",
          column.color
        )
      );
    }
  });
  return elements;
}

function buildBrainstorm(): TemplateSkeletons {
  const elements: TemplateSkeletons = [
    heading("brainstorm-title", 0, 0, "Brainstorm"),
    {
      id: "brainstorm-center",
      type: "ellipse",
      x: 270,
      y: 206,
      width: 230,
      height: 150,
      backgroundColor: palette.tealSoft,
      strokeColor: palette.teal,
      fillStyle: "solid",
      roughness: 0,
      strokeWidth: 3,
      label: {
        text: "Core question",
        fontSize: 24,
        textAlign: "center",
        verticalAlign: "middle"
      }
    }
  ];
  const ideas = [
    [0, 116, "Idea 1", palette.amberSoft],
    [20, 378, "Idea 2", palette.roseSoft],
    [296, 430, "Idea 3", palette.blueSoft],
    [570, 378, "Idea 4", palette.violetSoft],
    [590, 116, "Idea 5", palette.amberSoft],
    [296, 80, "Idea 6", palette.blueSoft]
  ] as const;

  ideas.forEach(([x, y, label, color], index) => {
    elements.push(note(`brainstorm-idea-${index + 1}`, x, y, label, color));
  });
  return elements;
}

function buildKanban(): TemplateSkeletons {
  const columns = [
    { id: "backlog", title: "Backlog", color: palette.blueSoft },
    { id: "progress", title: "In progress", color: palette.amberSoft },
    { id: "done", title: "Done", color: palette.tealSoft }
  ] as const;
  const elements: TemplateSkeletons = [
    heading("kanban-title", 0, 0, "Team board")
  ];

  columns.forEach((column, index) => {
    const x = index * 260;
    elements.push(
      card(`kanban-${column.id}`, x, 82, 236, 64, column.title, column.color)
    );
    for (let row = 0; row < 3; row += 1) {
      elements.push(
        card(
          `kanban-${column.id}-${row + 1}`,
          x,
          166 + row * 112,
          236,
          88,
          row === 0 ? "Add a task" : "",
          palette.canvas,
          palette.muted
        )
      );
    }
  });
  return elements;
}

function buildMeetingAgenda(): TemplateSkeletons {
  const elements: TemplateSkeletons = [
    heading("meeting-title", 0, 0, "Meeting agenda"),
    card("meeting-goal", 0, 86, 740, 94, "Goal: What should we decide today?", palette.tealSoft, palette.teal)
  ];
  const rows = [
    ["1", "Welcome and context", "5 min"],
    ["2", "Discussion topic", "20 min"],
    ["3", "Decision", "10 min"],
    ["4", "Owners and next steps", "10 min"]
  ] as const;
  rows.forEach(([number, title, duration], index) => {
    const y = 208 + index * 104;
    elements.push(
      card(`meeting-number-${number}`, 0, y, 82, 78, number, palette.blueSoft, palette.blue),
      card(`meeting-topic-${number}`, 100, y, 470, 78, title, palette.canvas, palette.muted),
      card(`meeting-time-${number}`, 588, y, 152, 78, duration, palette.amberSoft, palette.amber)
    );
  });
  return elements;
}

function buildRetrospective(): TemplateSkeletons {
  const columns = [
    { id: "well", title: "Went well", color: palette.tealSoft },
    { id: "better", title: "Could improve", color: palette.roseSoft },
    { id: "next", title: "Try next", color: palette.violetSoft }
  ] as const;
  const elements: TemplateSkeletons = [
    heading("retro-title", 0, 0, "Team retrospective")
  ];
  columns.forEach((column, index) => {
    const x = index * 250;
    elements.push(
      card(`retro-${column.id}`, x, 86, 226, 68, column.title, column.color)
    );
    for (let row = 0; row < 3; row += 1) {
      elements.push(
        note(
          `retro-${column.id}-${row + 1}`,
          x + 25,
          178 + row * 132,
          row === 0 ? "Add a thought" : "",
          column.color
        )
      );
    }
  });
  return elements;
}

function buildSwot(): TemplateSkeletons {
  const quadrants = [
    { id: "strengths", title: "Strengths", x: 0, y: 86, color: palette.tealSoft },
    { id: "weaknesses", title: "Weaknesses", x: 370, y: 86, color: palette.roseSoft },
    { id: "opportunities", title: "Opportunities", x: 0, y: 340, color: palette.blueSoft },
    { id: "threats", title: "Threats", x: 370, y: 340, color: palette.amberSoft }
  ] as const;
  return [
    heading("swot-title", 0, 0, "SWOT analysis"),
    ...quadrants.map((quadrant) =>
      card(
        `swot-${quadrant.id}`,
        quadrant.x,
        quadrant.y,
        344,
        224,
        `${quadrant.title}\n\nAdd notes here`,
        quadrant.color
      )
    )
  ];
}

export const canvasTemplates: readonly CanvasTemplate[] = [
  {
    id: "brainstorm",
    name: "Brainstorm",
    description: "Explore one question from six directions.",
    category: "brainstorming",
    tags: ["ideas", "mind map", "creative"],
    preview: "brainstorm",
    build: buildBrainstorm
  },
  {
    id: "affinity-map",
    name: "Affinity map",
    description: "Cluster observations into clear themes.",
    category: "brainstorming",
    tags: ["research", "notes", "themes"],
    preview: "affinity",
    build: buildAffinityMap
  },
  {
    id: "team-board",
    name: "Team board",
    description: "Move work from backlog to done.",
    category: "planning",
    tags: ["kanban", "tasks", "project"],
    preview: "kanban",
    build: buildKanban
  },
  {
    id: "meeting-agenda",
    name: "Meeting agenda",
    description: "Keep the conversation timed and outcome-led.",
    category: "planning",
    tags: ["meeting", "agenda", "decision"],
    preview: "meeting",
    build: buildMeetingAgenda
  },
  {
    id: "retrospective",
    name: "Retrospective",
    description: "Reflect, improve, and choose the next experiment.",
    category: "reflection",
    tags: ["retro", "feedback", "team"],
    preview: "retrospective",
    build: buildRetrospective
  },
  {
    id: "swot-analysis",
    name: "SWOT analysis",
    description: "Compare internal strengths with external risks.",
    category: "reflection",
    tags: ["strategy", "quadrants", "analysis"],
    preview: "swot",
    build: buildSwot
  }
];

export function filteredCanvasTemplates(
  category: CanvasTemplateCategory,
  query: string
): readonly CanvasTemplate[] {
  const normalizedQuery = query.trim().toLowerCase();
  return canvasTemplates.filter((template) => {
    const inCategory = category === "recommended" || template.category === category;
    const searchable = [
      template.name,
      template.description,
      template.category,
      ...template.tags
    ].join(" ").toLowerCase();
    return inCategory && (!normalizedQuery || searchable.includes(normalizedQuery));
  });
}

function elementBounds(elements: readonly ExcalidrawElement[]) {
  return elements.reduce(
    (bounds, element) => ({
      minX: Math.min(bounds.minX, element.x),
      minY: Math.min(bounds.minY, element.y),
      maxX: Math.max(bounds.maxX, element.x + element.width),
      maxY: Math.max(bounds.maxY, element.y + element.height)
    }),
    {
      minX: Number.POSITIVE_INFINITY,
      minY: Number.POSITIVE_INFINITY,
      maxX: Number.NEGATIVE_INFINITY,
      maxY: Number.NEGATIVE_INFINITY
    }
  );
}

export async function createCanvasTemplateElements(
  templateId: string,
  existingElements: readonly ExcalidrawElement[] = []
): Promise<ExcalidrawElement[]> {
  const template = canvasTemplates.find((candidate) => candidate.id === templateId);
  if (!template) return [];

  const { convertToExcalidrawElements } = await import("@excalidraw/excalidraw");
  const generated = convertToExcalidrawElements(template.build(), {
    regenerateIds: true
  }) as ExcalidrawElement[];
  if (generated.length === 0) return [];

  const visibleExisting = existingElements.filter((element) => !element.isDeleted);
  const templateBounds = elementBounds(generated);
  const existingBounds = elementBounds(visibleExisting);
  const targetX = visibleExisting.length > 0 ? existingBounds.maxX + 160 : 40;
  const targetY = visibleExisting.length > 0 ? existingBounds.minY : 40;
  const offsetX = targetX - templateBounds.minX;
  const offsetY = targetY - templateBounds.minY;

  return generated.map((element) => ({
    ...element,
    x: element.x + offsetX,
    y: element.y + offsetY
  }));
}
