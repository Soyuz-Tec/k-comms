import type { BinaryFileData } from "@excalidraw/excalidraw/types";
import type { ApiClient } from "../../api";
import { downloadUrl } from "../../api";

export function isRasterSignature(bytes: Uint8Array, mime: string): boolean {
  if (mime === "image/png") return [137,80,78,71,13,10,26,10].every((b, i) => bytes[i] === b);
  if (mime === "image/jpeg") return bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
  if (mime === "image/gif") return new TextDecoder().decode(bytes.slice(0, 6)).match(/^GIF8[79]a$/) !== null;
  if (mime === "image/webp") return new TextDecoder().decode(bytes.slice(0, 4)) === "RIFF" && new TextDecoder().decode(bytes.slice(8, 12)) === "WEBP";
  return false;
}

export async function loadBoardAssetFile(api: ApiClient, conversationId: string, assetId: string, signal?: AbortSignal): Promise<BinaryFileData> {
  const authorized = await api.boardAsset(conversationId, assetId);
  const url = downloadUrl(authorized.download);
  if (!url) throw new Error("The board image did not return an approved download URL.");
  const response = await fetch(url, { headers: authorized.download.headers, credentials: "omit", redirect: "error", signal });
  if (!response.ok) throw new Error("The board image could not be downloaded. Retry the board.");
  const body = await response.arrayBuffer();
  if (body.byteLength !== authorized.data.byte_size || body.byteLength > 10_485_760 ||
      !isRasterSignature(new Uint8Array(body), authorized.data.content_type)) throw new Error("The board image did not match its approved raster descriptor.");
  const blob = new Blob([body], { type: authorized.data.content_type });
  const dataURL = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result)); reader.onerror = () => reject(new Error("The image could not be decoded.")); reader.readAsDataURL(blob);
  });
  return { id: assetId as BinaryFileData["id"], mimeType: authorized.data.content_type as BinaryFileData["mimeType"], dataURL: dataURL as BinaryFileData["dataURL"], created: Date.now() };
}
