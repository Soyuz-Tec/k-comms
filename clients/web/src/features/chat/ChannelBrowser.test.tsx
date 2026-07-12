import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { ApiClient } from "../../api";
import type { PublicChannel } from "../../types";
import { ChannelBrowser } from "./ChannelBrowser";

const publicChannel: PublicChannel = {
  id: "channel-1",
  tenant_id: "tenant-1",
  kind: "channel",
  title: "Projects",
  visibility: "tenant",
  latest_sequence: 0,
  archived_at: null,
  version: 1,
  inserted_at: "2026-07-12T10:00:00Z",
  updated_at: "2026-07-12T10:00:00Z",
  joined: false,
  member_count: 2,
  membership: null
};

describe("ChannelBrowser", () => {
  it("shows a policy-disabled state without calling discovery", () => {
    const discoverPublicChannels = vi.fn();
    render(<ChannelBrowser api={{ discoverPublicChannels } as unknown as ApiClient} enabled={false} onClose={vi.fn()} onJoined={vi.fn()} onOpen={vi.fn()} />);
    expect(screen.getByRole("heading", { name: "Channel discovery is disabled" })).toBeVisible();
    expect(discoverPublicChannels).not.toHaveBeenCalled();
  });

  it("filters non-public responses and exposes a no-result state", async () => {
    const api = {
      discoverPublicChannels: vi.fn().mockResolvedValue({ data: [{ ...publicChannel, id: "private-1", title: "Private", visibility: "private" }], page: { limit: 25, has_more: false, next_cursor: null } })
    } as unknown as ApiClient;
    render(<ChannelBrowser api={api} enabled onClose={vi.fn()} onJoined={vi.fn()} onOpen={vi.fn()} />);
    expect(await screen.findByRole("heading", { name: "No public channels found" })).toBeVisible();
    expect(screen.queryByText("#Private")).not.toBeInTheDocument();
  });

  it("joins a public channel and changes the action to Open", async () => {
    const membership = { id: "membership-1", role: "member" as const, joined_at: "2026-07-12T10:00:00Z", left_at: null, last_read_sequence: 0, version: 1 };
    const api = {
      discoverPublicChannels: vi.fn().mockResolvedValue({ data: [publicChannel], page: { limit: 25, has_more: false, next_cursor: null } }),
      joinPublicChannel: vi.fn().mockResolvedValue({ data: { conversation: publicChannel, membership }, replayed: false })
    } as unknown as ApiClient;
    const onJoined = vi.fn();
    const user = userEvent.setup();
    render(<ChannelBrowser api={api} enabled onClose={vi.fn()} onJoined={onJoined} onOpen={vi.fn()} />);
    await user.click(await screen.findByRole("button", { name: "Join" }));
    expect(onJoined).toHaveBeenCalledWith(publicChannel);
    expect(await screen.findByRole("button", { name: "Open" })).toBeVisible();
  });

  it("searches by the submitted query and appends the next page", async () => {
    const secondChannel = { ...publicChannel, id: "channel-2", title: "Operations" };
    const discoverPublicChannels = vi.fn()
      .mockResolvedValueOnce({ data: [], page: { limit: 25, has_more: false, next_cursor: null } })
      .mockResolvedValueOnce({ data: [publicChannel], page: { limit: 25, has_more: true, next_cursor: "page-2" } })
      .mockResolvedValueOnce({ data: [secondChannel], page: { limit: 25, has_more: false, next_cursor: null } });
    const api = { discoverPublicChannels } as unknown as ApiClient;
    const user = userEvent.setup();

    render(<ChannelBrowser api={api} enabled onClose={vi.fn()} onJoined={vi.fn()} onOpen={vi.fn()} />);
    await screen.findByRole("heading", { name: "No public channels found" });
    await user.type(screen.getByRole("searchbox", { name: "Search public channels" }), "projects");
    await user.click(screen.getByRole("button", { name: "Search" }));

    expect(await screen.findByText("#Projects")).toBeVisible();
    expect(discoverPublicChannels).toHaveBeenNthCalledWith(2, "projects", 25, null);

    await user.click(screen.getByRole("button", { name: "Load more channels" }));
    expect(await screen.findByText("#Operations")).toBeVisible();
    expect(screen.getByText("#Projects")).toBeVisible();
    expect(discoverPublicChannels).toHaveBeenNthCalledWith(3, "projects", 25, "page-2");
  });
});
