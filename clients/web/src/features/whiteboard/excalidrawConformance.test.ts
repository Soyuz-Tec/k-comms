import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types";
import { describe, expect, it } from "vitest";
import type { WhiteboardElementData } from "../../types";

/**
 * Guards the seam between the Excalidraw SDK and what K-Comms durably persists.
 *
 * ADR-0063 keeps Excalidraw a replaceable editor engine, which only holds while
 * the shape it produces still matches the shape the server stores and every
 * replica merges on. The SDK is pre-1.0 and ships breaking changes in minor
 * versions, so that agreement can lapse silently: a renamed or retyped field
 * would keep compiling, keep serialising, and only surface as boards that
 * merge wrongly.
 *
 * These are deliberately type-level. A runtime test would pass against a
 * fixture while the live SDK had already moved.
 */

/** Fields the merge rule and durable projection actually depend on. */
type MergeCriticalFields = Pick<
  ExcalidrawElement,
  "id" | "type" | "version" | "versionNonce" | "isDeleted"
>;

type Assert<T extends true> = T;
type Extends<A, B> = A extends B ? true : false;

// If any of these stop compiling, the SDK changed the contract underneath the
// adapter. Re-read ADR-0063 before adjusting them: loosening the persisted type
// to make an upgrade compile is how silent divergence starts.
type IdIsString = Assert<Extends<MergeCriticalFields["id"], string>>;
type VersionIsNumber = Assert<Extends<MergeCriticalFields["version"], number>>;
type NonceIsNumber = Assert<Extends<MergeCriticalFields["versionNonce"], number>>;
type TypeIsString = Assert<Extends<MergeCriticalFields["type"], string>>;
type DeletedIsBoolean = Assert<Extends<MergeCriticalFields["isDeleted"], boolean>>;

/**
 * An Excalidraw element must remain assignable to what we persist. The reverse
 * is deliberately not asserted: `WhiteboardElementData` is intentionally wider,
 * because the server accepts elements from clients on other SDK versions.
 */
type ElementIsPersistable = Assert<
  Extends<Pick<ExcalidrawElement, "id" | "type" | "version" | "versionNonce">, WhiteboardElementData>
>;

// Reference the aliases so they are checked rather than elided as unused.
export type WhiteboardSdkConformance = [
  IdIsString,
  VersionIsNumber,
  NonceIsNumber,
  TypeIsString,
  DeletedIsBoolean,
  ElementIsPersistable
];

describe("Excalidraw SDK conformance", () => {
  it("keeps the merge-critical fields the durable projection depends on", () => {
    // The real assertions above are compile-time. This runtime case exists so
    // the file is a first-class test rather than a type-only module a future
    // build config might stop checking.
    const element: WhiteboardElementData = {
      id: "conformance-element",
      type: "rectangle",
      version: 1,
      versionNonce: 2
    };

    expect(Object.keys(element).sort()).toEqual([
      "id",
      "type",
      "version",
      "versionNonce"
    ]);
  });
});
