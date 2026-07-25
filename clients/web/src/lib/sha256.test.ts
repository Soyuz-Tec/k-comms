import { afterEach, describe, expect, it, vi } from "vitest";
import { sha256Base64Url, sha256Hex } from "./sha256";

afterEach(() => vi.unstubAllGlobals());

describe("browser SHA-256", () => {
  it.each([
    [
      "",
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    ],
    [
      "abc",
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    ]
  ])(
    "matches the SHA-256 known vector for %j without SubtleCrypto",
    async (value, expected) => {
      vi.stubGlobal("crypto", {});

      await expect(sha256Hex(new TextEncoder().encode(value))).resolves.toBe(expected);
    }
  );

  it("hashes binary data spanning multiple fallback chunks without blocking one long task", async () => {
    vi.stubGlobal("crypto", {});
    const bytes = new Uint8Array(1024 * 1024 + 17);
    for (let index = 0; index < bytes.length; index += 1) bytes[index] = index & 0xff;

    await expect(sha256Hex(bytes)).resolves.toBe(
      "198fe22858bf90dd34cba065bf3e3d4680918f930e94ce51807b9b3055f2eb1e"
    );
  });

  it("returns the standard unpadded base64url digest without SubtleCrypto", async () => {
    vi.stubGlobal("crypto", {});

    await expect(
      sha256Base64Url(new TextEncoder().encode("abc"))
    ).resolves.toBe("ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0");
  });

  it("prefers SubtleCrypto when the browser provides it", async () => {
    const digest = vi.fn().mockResolvedValue(new Uint8Array(32).fill(0xab).buffer);
    vi.stubGlobal("crypto", { subtle: { digest } });

    await expect(
      sha256Hex(new TextEncoder().encode("uses-web-crypto"))
    ).resolves.toBe("ab".repeat(32));
    expect(digest).toHaveBeenCalledWith("SHA-256", expect.any(Uint8Array));
  });

  it("falls back when an exposed SubtleCrypto implementation rejects the digest", async () => {
    const digest = vi.fn().mockRejectedValue(new Error("secure context required"));
    vi.stubGlobal("crypto", { subtle: { digest } });

    await expect(sha256Hex(new TextEncoder().encode("abc"))).resolves.toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
  });
});
