export interface WorkspaceDomainClaim {
  id: string;
  domain: string;
  version: number;
  status: "pending" | "verified" | "expired";
  discovery_enabled: boolean;
  challenge_name: string;
  challenge_value: string | null;
  challenge_expires_at: string;
  verified_at: string | null;
  proof_expires_at: string | null;
}

export interface WorkspaceDomainInventory {
  data: WorkspaceDomainClaim[];
  limits: { domains: number };
}

export interface WorkspaceDomainCreateInput {
  domain: string;
  version: 0;
  discovery_enabled?: boolean;
}

export type WorkspaceDiscoveryResult =
  | { available: true; sign_in_path: string }
  | { available: false; sign_in_path: null };
