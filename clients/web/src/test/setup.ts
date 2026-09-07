import "@testing-library/jest-dom/vitest";
import { afterEach } from "vitest";
import { cleanup, configure } from "@testing-library/react";

// The full browser-like suite runs many jsdom workers in parallel on CI. Keep
// async assertions tolerant of that scheduling pressure while preserving the
// same assertion semantics and failure messages.
configure({ asyncUtilTimeout: 3_000 });

afterEach(() => cleanup());

Object.defineProperty(window, "scrollTo", { value: () => undefined, writable: true });
Element.prototype.scrollIntoView = () => undefined;
