/* global Buffer, console */

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const iconDirectory = join(scriptDirectory, "..", "public", "icons");

const targets = [
  ["pwa-192.png", 192, false],
  ["pwa-512.png", 512, false],
  ["pwa-maskable-512.png", 512, true],
  ["apple-touch-icon.png", 180, false]
];

mkdirSync(iconDirectory, { recursive: true });

for (const [fileName, size, maskable] of targets) {
  writeFileSync(join(iconDirectory, fileName), createLauncherIcon(size, maskable));
}

function createLauncherIcon(size, maskable) {
  const pixels = Buffer.alloc(size * size * 4);
  fill(pixels, size, [16, 42, 42, 255]);

  const width = Math.round(size * (maskable ? 0.4 : 0.46));
  const height = Math.max(8, Math.round(size * 0.065));
  const radius = Math.floor(height / 2);
  const left = Math.floor((size - width) / 2);
  const firstTop = Math.floor(size * 0.35);
  const gap = Math.round(size * 0.13);

  for (let index = 0; index < 3; index += 1) {
    roundedRectangle(
      pixels,
      size,
      left,
      firstTop + gap * index,
      width,
      height,
      radius,
      [232, 246, 239, 255]
    );
  }

  return encodePng(size, size, pixels);
}

function fill(pixels, size, color) {
  for (let offset = 0; offset < size * size * 4; offset += 4) {
    pixels[offset] = color[0];
    pixels[offset + 1] = color[1];
    pixels[offset + 2] = color[2];
    pixels[offset + 3] = color[3];
  }
}

function roundedRectangle(pixels, canvasSize, left, top, width, height, radius, color) {
  const right = left + width - 1;
  const bottom = top + height - 1;

  for (let y = top; y <= bottom; y += 1) {
    for (let x = left; x <= right; x += 1) {
      const nearestX = Math.max(left + radius, Math.min(x, right - radius));
      const nearestY = Math.max(top + radius, Math.min(y, bottom - radius));
      const deltaX = x - nearestX;
      const deltaY = y - nearestY;
      if (deltaX * deltaX + deltaY * deltaY > radius * radius) continue;

      const offset = (y * canvasSize + x) * 4;
      pixels[offset] = color[0];
      pixels[offset + 1] = color[1];
      pixels[offset + 2] = color[2];
      pixels[offset + 3] = color[3];
    }
  }
}

function encodePng(width, height, pixels) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;

  const scanlines = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y += 1) {
    const rowOffset = y * (width * 4 + 1);
    scanlines[rowOffset] = 0;
    pixels.copy(scanlines, rowOffset + 1, y * width * 4, (y + 1) * width * 4);
  }

  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk("IHDR", header),
    pngChunk("IDAT", deflateSync(scanlines, { level: 9 })),
    pngChunk("IEND", Buffer.alloc(0))
  ]);
}

function pngChunk(type, data) {
  const typeBytes = Buffer.from(type, "ascii");
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])));
  return Buffer.concat([length, typeBytes, data, checksum]);
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

console.log(`Generated ${targets.length} neutral PWA launcher assets in ${iconDirectory}`);
