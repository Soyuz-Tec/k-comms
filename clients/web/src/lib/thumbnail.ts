/**
 * Client-side thumbnail generation for image attachments.
 *
 * A thumbnail is an enhancement, never a precondition: every failure path here
 * resolves to null so the attachment uploads exactly as it does today. Nothing
 * in this module may throw into the upload flow.
 */

/** Mirrors the server allowlist. SVG is absent because it is scriptable. */
const permittedTypes = ["image/webp", "image/jpeg", "image/png"] as const;

/** Mirrors the server's byte bound for a variant. */
const maxThumbnailBytes = 512 * 1024;

/** Longest edge of the generated image, in CSS pixels. */
const maxEdge = 512;

/**
 * Source formats worth previewing. SVG is excluded: it is a document rather
 * than a raster, drawing it can pull external references, and the server would
 * refuse the result anyway.
 */
const permittedSources = ["image/webp", "image/jpeg", "image/png", "image/gif", "image/avif"];

/** Quality ladder, tried in order until the output fits the byte bound. */
const qualityLadder = [0.82, 0.7, 0.55];

export interface GeneratedThumbnail {
  blob: Blob;
  contentType: string;
  byteSize: number;
}

export function canGenerateThumbnail(file: File): boolean {
  return permittedSources.includes(normalizedType(file));
}

/**
 * Produces a bounded preview, or null when one cannot be made.
 *
 * Returning null is an ordinary outcome: an unsupported source, a browser
 * without the required canvas APIs, a decode failure on a malformed image, or
 * an output that will not fit the byte bound all mean "no preview", not
 * "upload failed".
 */
export async function generateThumbnail(file: File): Promise<GeneratedThumbnail | null> {
  if (!canGenerateThumbnail(file)) return null;

  try {
    const bitmap = await decode(file);
    if (!bitmap) return null;

    try {
      return await encodeBounded(bitmap);
    } finally {
      bitmap.close?.();
    }
  } catch {
    // A corrupt or hostile image must not surface as an upload error.
    return null;
  }
}

async function decode(file: File): Promise<ImageBitmap | null> {
  if (typeof createImageBitmap !== "function") return null;

  // createImageBitmap decodes off the main thread and, unlike an <img> element,
  // never executes anything the source file contains.
  const bitmap = await createImageBitmap(file);
  return bitmap.width > 0 && bitmap.height > 0 ? bitmap : null;
}

async function encodeBounded(bitmap: ImageBitmap): Promise<GeneratedThumbnail | null> {
  const { width, height } = scaleToFit(bitmap.width, bitmap.height);
  const canvas = createCanvas(width, height);
  if (!canvas) return null;

  const context = drawingContext(canvas);
  if (!context) return null;
  context.drawImage(bitmap, 0, 0, width, height);

  for (const quality of qualityLadder) {
    const blob = await toBlob(canvas, quality);
    if (!blob) continue;

    // The browser may ignore the requested type and encode something else, so
    // the produced type is read back rather than assumed. Declaring a type the
    // bytes do not match would fail the signed upload.
    const contentType = normalizeBlobType(blob);
    if (!contentType) return null;
    if (blob.size > 0 && blob.size <= maxThumbnailBytes) {
      return { blob, contentType, byteSize: blob.size };
    }
  }

  return null;
}

function scaleToFit(width: number, height: number): { width: number; height: number } {
  const longest = Math.max(width, height);
  if (longest <= maxEdge) return { width, height };

  const scale = maxEdge / longest;
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale))
  };
}

type ThumbnailCanvas = OffscreenCanvas | HTMLCanvasElement;

/**
 * `getContext("2d")` is typed as a union across canvas kinds, so the drawing
 * context is narrowed explicitly rather than asserted.
 */
function drawingContext(
  canvas: ThumbnailCanvas
): CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D | null {
  return canvas instanceof OffscreenCanvas
    ? canvas.getContext("2d")
    : canvas.getContext("2d");
}

function createCanvas(width: number, height: number): ThumbnailCanvas | null {
  // OffscreenCanvas keeps the resize off the document entirely. A browser
  // without it falls back to a detached element, which is still never attached
  // to the DOM.
  if (typeof OffscreenCanvas === "function") return new OffscreenCanvas(width, height);
  if (typeof document === "undefined") return null;

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  return canvas;
}

async function toBlob(canvas: ThumbnailCanvas, quality: number): Promise<Blob | null> {
  if ("convertToBlob" in canvas) {
    try {
      return await canvas.convertToBlob({ type: "image/webp", quality });
    } catch {
      return null;
    }
  }

  return new Promise<Blob | null>((resolve) => {
    try {
      canvas.toBlob((blob) => resolve(blob), "image/webp", quality);
    } catch {
      resolve(null);
    }
  });
}

function normalizeBlobType(blob: Blob): string | null {
  const type = (blob.type || "").split(";")[0]?.trim().toLowerCase() || "";
  return (permittedTypes as readonly string[]).includes(type) ? type : null;
}

function normalizedType(file: File): string {
  return (file.type || "").split(";")[0]?.trim().toLowerCase() || "";
}
