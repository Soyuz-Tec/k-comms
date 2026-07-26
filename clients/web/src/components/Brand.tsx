export function Brand({ compact = false }: { compact?: boolean }) {
  return (
    <div className={`brand ${compact ? "compact" : ""}`} role="img" aria-label="K-Comms">
      <span className="brand-mark" aria-hidden="true">
        <span className="brand-letter">K</span>
      </span>
      <span>
        K-Comms
      </span>
    </div>
  );
}
