import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useModalDialog } from "./useModalDialog";

function AsyncDialog({ ready, onClose }: { ready: boolean; onClose: () => void }) {
  const ref = useModalDialog(onClose);
  return <section ref={ref} role="dialog" aria-modal="true" aria-label="Async form">
    <button type="button" onClick={onClose}>Cancel</button>
    {ready && <label>Reason<textarea data-initial-focus /></label>}
  </section>;
}

describe("modal initial focus", () => {
  afterEach(() => vi.restoreAllMocks());

  it("resolves a late field at frame time and preserves typing already begun in it", async () => {
    const frames: FrameRequestCallback[] = [];
    vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
      frames.push(callback);
      return frames.length;
    });
    vi.spyOn(window, "cancelAnimationFrame").mockImplementation(() => undefined);
    const onClose = vi.fn();
    const view = render(<AsyncDialog ready={false} onClose={onClose} />);
    view.rerender(<AsyncDialog ready onClose={onClose} />);
    const reason = screen.getByLabelText("Reason");
    act(() => frames.shift()?.(0));
    expect(reason).toHaveFocus();
    view.unmount();
    // The restore frame is unrelated to the next dialog's initial frame.
    frames.length = 0;

    const next = render(<AsyncDialog ready={false} onClose={onClose} />);
    next.rerender(<AsyncDialog ready onClose={onClose} />);
    const nextReason = screen.getByLabelText("Reason");
    const user = userEvent.setup();
    await user.click(nextReason);
    await user.keyboard("First");
    act(() => frames.shift()?.(0));
    await user.keyboard(" second");
    expect(nextReason).toHaveFocus();
    expect(nextReason).toHaveValue("First second");
    expect(onClose).not.toHaveBeenCalled();
  });
});
