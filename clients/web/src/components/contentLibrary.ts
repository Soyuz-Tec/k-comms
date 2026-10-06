import { memberDestinations } from "./MemberAreaLinks";

// Existing library routes remain canonical, including links into a source item.
export const contentLibrary = ["Files", "Shared documents", "Whiteboard", "Recordings", "Saved items"]
  .map((label) => memberDestinations.find((destination) => destination.label === label)!);

export function isContentLibraryPath(pathname: string) {
  const path = pathname.replace(/\/+$/, "");
  return path === "/app/content" || contentLibrary.some((destination) => destination.path === path);
}
