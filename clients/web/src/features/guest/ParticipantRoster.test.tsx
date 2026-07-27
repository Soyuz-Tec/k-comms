import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { ConversationMembership, User } from "../../types";
import { ParticipantRoster } from "./ParticipantRoster";

function member(id: string, displayName: string, accountType: User["account_type"] = "human") {
  return {
    id: `membership-${id}`,
    role: "member",
    joined_at: "2026-07-25T10:00:00Z",
    last_read_sequence: 0,
    user: {
      id,
      tenant_id: "tenant-1",
      display_name: displayName,
      account_type: accountType,
      role: "member",
      status: "active"
    }
  } satisfies ConversationMembership;
}

describe("ParticipantRoster", () => {
  it("shows stable display-name identifiers, current identity and presence", () => {
    render(
      <ParticipantRoster
        currentUserId="host"
        members={[
          member("guest", "Jordan Guest", "guest"),
          member("host", "Taylor Host", "guest")
        ]}
        onlineUserIds={new Set(["host", "guest"])}
      />
    );

    const roster = screen.getByRole("list", { name: "Room participants" });
    expect(within(roster).getByText("Taylor Host", { exact: false })).toHaveTextContent(
      "Taylor Host (you)"
    );
    expect(within(roster).getByText("Jordan Guest")).toBeVisible();
    expect(within(roster).getAllByText("Online · Guest")).toHaveLength(2);
    expect(screen.getByText("2 online · 2 total")).toBeVisible();
  });

  it("deduplicates a user with multiple membership entries and sorts online people first", () => {
    const duplicate = member("guest", "Jordan Guest", "guest");
    render(
      <ParticipantRoster
        currentUserId="host"
        members={[
          member("offline", "Alex Offline"),
          duplicate,
          { ...duplicate, id: "membership-guest-replayed" },
          member("host", "Taylor Host")
        ]}
        onlineUserIds={new Set(["host", "guest"])}
      />
    );

    const rows = within(
      screen.getByRole("list", { name: "Room participants" })
    ).getAllByRole("listitem");
    expect(rows).toHaveLength(3);
    expect(rows.map((row) => row.querySelector("strong")?.textContent)).toEqual([
      "Taylor Host (you)",
      "Jordan Guest",
      "Alex Offline"
    ]);
    expect(screen.getByText("2 online · 3 total")).toBeVisible();
  });

  it("marks presence unknown instead of showing stale online state", () => {
    render(
      <ParticipantRoster
        currentUserId="host"
        members={[
          member("guest", "Jordan Guest", "guest"),
          member("host", "Taylor Host")
        ]}
        onlineUserIds={new Set(["host", "guest"])}
        presenceKnown={false}
      />
    );

    const roster = screen.getByRole("list", { name: "Room participants" });
    expect(screen.getByText("Presence unknown · 2 total")).toBeVisible();
    expect(within(roster).queryByText(/^Online/u)).not.toBeInTheDocument();
    expect(within(roster).getAllByText(/^Presence unknown/u)).toHaveLength(2);
  });

  it("adds stable secondary identifiers only when display names collide", () => {
    const { rerender } = render(
      <ParticipantRoster
        currentUserId="user-11111111-1111-4111-8111-111111111111"
        members={[
          member("user-11111111-1111-4111-8111-111111111111", "Alex"),
          member("user-22222222-2222-4222-8222-222222222222", "Alex"),
          member("user-33333333-3333-4333-8333-333333333333", "Jordan")
        ]}
        onlineUserIds={new Set()}
      />
    );

    const roster = screen.getByRole("list", { name: "Room participants" });
    const identifiers = within(roster).getAllByLabelText(
      /^participant identifier /u
    );
    const initialIdentifiers = identifiers.map((identifier) => identifier.textContent);

    expect(identifiers).toHaveLength(2);
    expect(new Set(initialIdentifiers)).toHaveLength(2);
    expect(initialIdentifiers).toEqual([
      expect.stringMatching(/· #[A-Z0-9]{5}$/u),
      expect.stringMatching(/· #[A-Z0-9]{5}$/u)
    ]);
    expect(within(roster).getByText("Jordan").parentElement)
      .not.toHaveTextContent("#");
    expect(roster).not.toHaveTextContent("user-11111111");
    expect(roster).not.toHaveTextContent("user-22222222");

    rerender(
      <ParticipantRoster
        currentUserId="user-11111111-1111-4111-8111-111111111111"
        members={[
          member("user-11111111-1111-4111-8111-111111111111", "Alex"),
          member("user-22222222-2222-4222-8222-222222222222", "Alex"),
          member("user-33333333-3333-4333-8333-333333333333", "Jordan")
        ]}
        onlineUserIds={new Set()}
      />
    );
    expect(
      within(screen.getByRole("list", { name: "Room participants" }))
        .getAllByLabelText(/^participant identifier /u)
        .map((identifier) => identifier.textContent)
    ).toEqual(initialIdentifiers);
  });

  it("lengthens colliding short codes so roster identifiers remain unique", () => {
    render(
      <ParticipantRoster
        currentUserId="00000000-0000-4000-8000-000000005229"
        members={[
          member("00000000-0000-4000-8000-000000005229", "Alex"),
          member("00000000-0000-4000-8000-000000054784", "Alex")
        ]}
        onlineUserIds={new Set()}
      />
    );

    const identifiers = within(
      screen.getByRole("list", { name: "Room participants" })
    ).getAllByLabelText(/^participant identifier /u);
    const codes = identifiers.map((identifier) =>
      identifier.getAttribute("aria-label")?.replace("participant identifier ", "")
    );
    expect(identifiers).toHaveLength(2);
    expect(new Set(codes)).toHaveLength(2);
    expect(codes.every((code) => Boolean(code && code.length > 5))).toBe(true);
  });
});
