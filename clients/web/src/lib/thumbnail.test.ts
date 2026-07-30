import { afterEach, describe, expect, it, vi } from "vitest";
import { canGenerateThumbnail, generateThumbnail } from "./thumbnail";

afterEach(() => vi.unstubAllGlobals());

function imageFile(type: string, name = "photo.png"): File {
  return new File([new Uint8Array([1, 2, 3])], name, { type });
}

/**
 * jsdom implements neither createImageBitmap nor a drawing canvas, so the
 * pipeline is driven through stubs that let each branch be exercised.
 */
function stubPipeline(options: {
  width?: number;
  height?: number;
  blobs?: (Blob | null)[];
  decodeRejects?: boolean;
}) {
  const drawImage = vi.fn();
  const close = vi.fn();
  const requested: { type: string; quality: number }[] = [];
  const canvases: { width: number; height: number }[] = [];
  const blobs = options.blobs ?? [new Blob(["x"], { type: "image/webp" })];
  let index = 0;

  vi.stubGlobal(
    "createImageBitmap",
    vi.fn(async () => {
      if (options.decodeRejects) throw new Error("decode failed");
      return { width: options.width ?? 2000, height: options.height ?? 1000, close };
    })
  );

  class FakeOffscreenCanvas {
    width: number;
    height: number;
    constructor(width: number, height: number) {
      this.width = width;
      this.height = height;
      canvases.push({ width, height });
    }
    getContext() {
      return { drawImage };
    }
    async convertToBlob({ type, quality }: { type: string; quality: number }) {
      requested.push({ type, quality });
      const blob = blobs[Math.min(index, blobs.length - 1)];
      index += 1;
      if (!blob) throw new Error("encode failed");
      return blob;
    }
  }

  vi.stubGlobal("OffscreenCanvas", FakeOffscreenCanvas);
  return { drawImage, close, requested, canvases };
}

describe("thumbnail source selection", () => {
  it("accepts raster image types", () => {
    for (const type of ["image/png", "image/jpeg", "image/webp", "image/gif", "image/avif"]) {
      expect(canGenerateThumbnail(imageFile(type))).toBe(true);
    }
  });

  it("refuses SVG because it is a scriptable document, not a raster", () => {
    expect(canGenerateThumbnail(imageFile("image/svg+xml", "diagram.svg"))).toBe(false);
  });

  it("refuses non-image types", () => {
    for (const type of ["application/pdf", "text/html", "application/zip", ""]) {
      expect(canGenerateThumbnail(imageFile(type))).toBe(false);
    }
  });

  it("ignores charset parameters and casing on the declared type", () => {
    expect(canGenerateThumbnail(imageFile("IMAGE/PNG"))).toBe(true);
    expect(canGenerateThumbnail(imageFile("image/png; charset=binary"))).toBe(true);
  });
});

describe("thumbnail generation", () => {
  it("bounds the longest edge while preserving aspect ratio", async () => {
    const { canvases, drawImage } = stubPipeline({ width: 2000, height: 1000 });

    await generateThumbnail(imageFile("image/png"));

    expect(canvases).toEqual([{ width: 512, height: 256 }]);
    expect(drawImage).toHaveBeenCalledWith(expect.anything(), 0, 0, 512, 256);
  });

  it("leaves an already-small image at its own size", async () => {
    const { drawImage } = stubPipeline({ width: 120, height: 80 });

    await generateThumbnail(imageFile("image/png"));

    expect(drawImage).toHaveBeenCalledWith(expect.anything(), 0, 0, 120, 80);
  });

  it("reports the produced type rather than the requested one", async () => {
    // A browser may ignore the requested encoding. Declaring a type the bytes
    // do not match would fail the signed upload, so the result is read back.
    stubPipeline({ blobs: [new Blob(["x"], { type: "image/jpeg" })] });

    const result = await generateThumbnail(imageFile("image/png"));

    expect(result?.contentType).toBe("image/jpeg");
  });

  it("refuses a produced type outside the server allowlist", async () => {
    stubPipeline({ blobs: [new Blob(["x"], { type: "image/svg+xml" })] });

    await expect(generateThumbnail(imageFile("image/png"))).resolves.toBeNull();
  });

  it("steps down quality until the output fits the byte bound", async () => {
    const oversized = new Blob([new Uint8Array(600 * 1024)], { type: "image/webp" });
    const fitting = new Blob([new Uint8Array(1024)], { type: "image/webp" });
    const { requested } = stubPipeline({ blobs: [oversized, fitting] });

    const result = await generateThumbnail(imageFile("image/png"));

    expect(result?.byteSize).toBe(1024);
    expect(requested.map((entry) => entry.quality)).toEqual([0.82, 0.7]);
  });

  it("gives up rather than uploading something over the bound", async () => {
    const oversized = new Blob([new Uint8Array(600 * 1024)], { type: "image/webp" });
    stubPipeline({ blobs: [oversized, oversized, oversized] });

    await expect(generateThumbnail(imageFile("image/png"))).resolves.toBeNull();
  });

  it("resolves null when the image cannot be decoded", async () => {
    stubPipeline({ decodeRejects: true });

    // A corrupt or hostile image must never surface as an upload failure.
    await expect(generateThumbnail(imageFile("image/png"))).resolves.toBeNull();
  });

  it("resolves null when the browser has no createImageBitmap", async () => {
    vi.stubGlobal("createImageBitmap", undefined);

    await expect(generateThumbnail(imageFile("image/png"))).resolves.toBeNull();
  });

  it("releases the decoded bitmap even when encoding fails", async () => {
    const { close } = stubPipeline({ blobs: [null] });

    await generateThumbnail(imageFile("image/png"));

    expect(close).toHaveBeenCalledTimes(1);
  });

  it("never generates for a source it refuses", async () => {
    const { drawImage } = stubPipeline({});

    await expect(
      generateThumbnail(imageFile("image/svg+xml", "diagram.svg"))
    ).resolves.toBeNull();
    expect(drawImage).not.toHaveBeenCalled();
  });
});
