import { describe, expect, it } from "vitest";
import {
  isEncryptedUrl,
  isInsecureNonLoopbackOrigin,
  isLoopbackHostname
} from "./transportSecurity";

describe("transport security boundaries", () => {
  it("recognizes browser loopback names without trusting arbitrary LAN hosts", () => {
    expect(isLoopbackHostname("localhost")).toBe(true);
    expect(isLoopbackHostname("app.localhost")).toBe(true);
    expect(isLoopbackHostname("127.0.0.1")).toBe(true);
    expect(isLoopbackHostname("[::1]")).toBe(true);
    expect(isLoopbackHostname("192.168.1.177")).toBe(false);
    expect(isLoopbackHostname("comms.internal.test")).toBe(false);
  });

  it("blocks credential-bearing workflows only on unencrypted non-loopback origins", () => {
    expect(
      isInsecureNonLoopbackOrigin({
        protocol: "http:",
        hostname: "192.168.1.177"
      })
    ).toBe(true);
    expect(
      isInsecureNonLoopbackOrigin({
        protocol: "https:",
        hostname: "comms.internal.test"
      })
    ).toBe(false);
    expect(
      isInsecureNonLoopbackOrigin({
        protocol: "http:",
        hostname: "127.0.0.1"
      })
    ).toBe(false);
  });

  it("derives secure-link copy from the actual shared URL", () => {
    expect(isEncryptedUrl("https://comms.example.test/join#guest=token")).toBe(
      true
    );
    expect(isEncryptedUrl("http://192.168.1.177:4188/join#guest=token")).toBe(
      false
    );
  });
});
