import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";
import { useExperienceModeController } from "./ExperienceModeProvider";
import { getExperienceModeSnapshot } from "./experience-mode-store";
import { selectImmersiveEligibility } from "./immersive-eligibility";
import type { GuestCapabilities, ServiceStatus, UserCapabilities } from "../../types";

function status(immersive?: boolean): ServiceStatus {
  return {
    service: "k-comms",
    version: "test",
    status: "operational",
    capabilities: {
      administration: true,
      attachment_scanning: true,
      bootstrap: false,
      guest_links: true,
      immersive_mode: immersive,
      instant_rooms: true,
      notifications: true,
      realtime: true,
      secure_account_actions: true,
      secure_media_actions: true,
      webhooks: true
    }
  };
}

function guestCapabilities(immersive?: boolean): GuestCapabilities {
  return {
    allow_audio_calls: true,
    allow_video_calls: true,
    allow_immersive_mode: immersive,
    conversion_enabled: false
  };
}

function Surface({
  serviceStatus,
  capabilities,
  phase
}: {
  serviceStatus: ServiceStatus | null;
  capabilities: GuestCapabilities | null;
  phase?: string;
}) {
  const { mode } = useExperienceModeController({
    sessionState: phase ? { conversationId: "room-1", phase } : null,
    status: serviceStatus,
    capabilities,
    loading: serviceStatus === null
  });
  return <span data-testid="mode">{mode}</span>;
}

describe("guest and instant-room immersive entry", () => {
  beforeEach(() => {
    delete document.documentElement.dataset.experienceMode;
  });

  it("uses the same selector for guest capabilities as for member ones", () => {
    // The contract asks for one client selector combining the applicable
    // capability inputs, not one per surface. Guests and members carry the
    // field on different responses; the question is identical.
    const member: UserCapabilities = {
      allow_audio_calls: true,
      allow_video_calls: true,
      allow_immersive_mode: true,
      allow_public_channels: true,
      message_edit_window_seconds: 900,
      max_attachment_bytes: 1024
    };
    expect(selectImmersiveEligibility(status(true), member)).toBe(true);
    expect(selectImmersiveEligibility(status(true), guestCapabilities(true))).toBe(true);
  });

  it("enters immersive when a guest joins an eligible call", async () => {
    render(
      <Surface serviceStatus={status(true)} capabilities={guestCapabilities(true)} phase="joining" />
    );
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("immersive"));
  });

  it("stays in workspace when the guest link does not permit immersive", async () => {
    render(
      <Surface
        serviceStatus={status(true)}
        capabilities={guestCapabilities(false)}
        phase="joining"
      />
    );
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("workspace"));
  });

  it("stays in workspace when the deployment switch is off, whatever the link says", async () => {
    render(
      <Surface
        serviceStatus={status(false)}
        capabilities={guestCapabilities(true)}
        phase="joining"
      />
    );
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("workspace"));
  });

  it("treats a server that omits the guest field as ineligible", async () => {
    render(
      <Surface
        serviceStatus={status(true)}
        capabilities={guestCapabilities(undefined)}
        phase="joining"
      />
    );
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("workspace"));
  });

  it("publishes the mode without mounting any authenticated provider", async () => {
    // Nothing here is wrapped in CallSessionProvider, WorkspaceDataProvider or
    // ExperienceModeProvider -- a guest route mounting authenticated
    // navigation is grounds for rejecting the implementation outright. The
    // controller still reaches the call surface, because the mode travels
    // through the store and the document root rather than a context tree.
    render(
      <Surface serviceStatus={status(true)} capabilities={guestCapabilities(true)} phase="joining" />
    );
    await waitFor(() => expect(getExperienceModeSnapshot()).toBe("immersive"));
    expect(document.documentElement.dataset.experienceMode).toBe("immersive");
  });

  it("returns to workspace when the guest leaves the call", async () => {
    const view = render(
      <Surface serviceStatus={status(true)} capabilities={guestCapabilities(true)} phase="joining" />
    );
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("immersive"));

    view.rerender(
      <Surface serviceStatus={status(true)} capabilities={guestCapabilities(true)} />
    );
    await waitFor(() => expect(screen.getByTestId("mode")).toHaveTextContent("workspace"));
  });
});
