import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { RichMessageBody } from "./RichMessageBody";
import { formatSelection } from "./CompositionToolbar";

describe("rich composition without HTML execution", () => {
  it("renders formatting as semantic elements and escapes raw markup", () => {
    const { container } = render(<RichMessageBody body={'**Important** _focus_ `a < b`\n<script>alert(1)</script>\n> Remember'} />);
    expect(screen.getByText("Important").tagName).toBe("STRONG");
    expect(screen.getByText("focus").tagName).toBe("EM");
    expect(screen.getByText("a < b").tagName).toBe("CODE");
    expect(container.querySelector("script")).toBeNull();
    expect(container.textContent).toContain("<script>alert(1)</script>");
    expect(container.querySelector("blockquote")).toHaveTextContent("Remember");
  });
  it("formats only the selected text and keeps the text selection", () => {
    expect(formatSelection("hello world", 6, 11, "bold")).toEqual({ body: "hello **world**", start: 8, end: 13 });
  });
});
