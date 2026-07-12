import { describe, expect, it } from "vitest";
// @ts-expect-error The static module is shipped verbatim as the browser service worker.
import { safeActionUrl, safeNotificationPayload } from "../../public/k-comms-sw.js";

describe("push service worker safety", () => {
  const origin = "https://comms.example.test";

  it("allows only same-origin application click-through targets", () => {
    expect(safeActionUrl("/app/?conversation=123", origin)).toBe(`${origin}/app/?conversation=123`);
    expect(safeActionUrl("https://evil.example/phish", origin)).toBe(`${origin}/app/`);
    expect(safeActionUrl("/admin", origin)).toBe(`${origin}/app/`);
    expect(safeActionUrl("javascript:alert(1)", origin)).toBe(`${origin}/app/`);
  });

  it("sanitizes provider copy and derives a safe message action", () => {
    const payload = safeNotificationPayload({
      title: " New\u0000mention ",
      body: "Open K-Comms",
      conversation_id: "2d228e4d-b3c7-4ccf-a6bd-cc39c1d44d40",
      message_id: "61087b18-14d3-446a-a208-5912d7ba72f4"
    }, origin);

    expect(payload.title).toBe("New mention");
    expect(payload.actionUrl).toBe(
      `${origin}/app/?conversation=2d228e4d-b3c7-4ccf-a6bd-cc39c1d44d40&message=61087b18-14d3-446a-a208-5912d7ba72f4`
    );
  });
});
