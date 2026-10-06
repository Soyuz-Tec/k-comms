import { Link } from "react-router";
import { AppIcon } from "../../components/AppIcon";
import "./CallTypeNavigation.css";

export function CallTypeNavigation({ active }: { active: "internet" | "phone" }) {
  return <nav className="call-type-navigation" aria-label="Call types">
    <Link to="/app/calls" aria-current={active === "internet" ? "page" : undefined}>
      <AppIcon name="video" />Internet calls
    </Link>
    <Link to="/app/calls/phone" aria-current={active === "phone" ? "page" : undefined}>
      <AppIcon name="phone" />Phone
    </Link>
  </nav>;
}
