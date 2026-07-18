import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";
import { AdminPage } from "./AdminPage";

const session = {
  access_token: "access-token",
  refresh_token: "refresh-token",
  token_type: "Bearer",
  expires_in: 900,
  tenant: { id: "tenant-1", name: "Example", slug: "example", status: "active" },
  user: {
    id: "owner-1",
    tenant_id: "tenant-1",
    display_name: "Workspace Owner",
    email: "owner@example.test",
    role: "owner" as const,
    status: "active",
    platform_role: null,
    platform_role_expires_at: null
  },
  device: { id: "device-1", user_id: "owner-1", name: "Browser", platform: "web" }
};

vi.mock("../../app/session", () => ({
  useSession: () => ({ api: {}, session, setSession: vi.fn() })
}));

vi.mock("../../app/workspace-data", () => ({
  useWorkspaceData: () => ({
    users: [],
    conversations: [],
    setUsers: vi.fn(),
    setCapabilities: vi.fn(),
    refreshAll: vi.fn()
  })
}));

vi.mock("./TenantSettingsPanel", () => ({ TenantSettingsPanel: () => <h2>Workspace settings</h2> }));
vi.mock("./PeoplePanel", () => ({ PeoplePanel: () => <h2>People directory</h2> }));
vi.mock("./SafetyPanel", () => ({ SafetyPanel: () => <h2>Safety review</h2> }));
vi.mock("./GovernancePanel", () => ({ GovernancePanel: () => <h2>Governance controls</h2> }));
vi.mock("./IntegrationsPanel", () => ({ IntegrationsPanel: () => <h2>Integrations</h2> }));
vi.mock("./AuditPanel", () => ({ AuditPanel: () => <h2>Audit evidence</h2> }));

describe("AdminPage section routing", () => {
  it("opens a section from the URL and preserves other query parameters when navigating", async () => {
    const user = userEvent.setup();
    render(
      <MemoryRouter initialEntries={["/admin?section=audit&source=notification"]}>
        <AdminPage />
        <LocationProbe />
      </MemoryRouter>
    );

    expect(screen.getByRole("heading", { name: "Audit evidence" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Audit" })).toHaveAttribute("aria-current", "page");

    await user.click(screen.getByRole("button", { name: "People" }));

    expect(screen.getByRole("heading", { name: "People directory" })).toBeVisible();
    expect(screen.getByTestId("location-search")).toHaveTextContent("section=people");
    expect(screen.getByTestId("location-search")).toHaveTextContent("source=notification");
  });

  it("replaces an unavailable section with the first authorized section", async () => {
    render(
      <MemoryRouter initialEntries={["/admin?section=unknown"]}>
        <AdminPage />
        <LocationProbe />
      </MemoryRouter>
    );

    expect(screen.getByRole("heading", { name: "Workspace settings" })).toBeVisible();
    await waitFor(() => expect(screen.getByTestId("location-search")).toHaveTextContent("section=workspace"));
  });
});

function LocationProbe() {
  const location = useLocation();
  return <output data-testid="location-search">{location.search}</output>;
}
