defmodule CommsWeb.GuestCommunication.ImmersiveCapabilityTest do
  use ExUnit.Case, async: true

  alias CommsWeb.Presenters.Conversations, as: Presenter

  @moduletag :unit

  describe "guest_capabilities/1 immersive eligibility" do
    test "follows the call kinds the link actually permits" do
      assert %{allow_immersive_mode: true} =
               Presenter.guest_capabilities(%{allow_audio_calls: true, allow_video_calls: false})

      assert %{allow_immersive_mode: true} =
               Presenter.guest_capabilities(%{allow_audio_calls: false, allow_video_calls: true})

      # Immersive Mode is only ever entered after joining a call, so a link
      # that permits neither kind can never reach it.
      assert %{allow_immersive_mode: false} =
               Presenter.guest_capabilities(%{allow_audio_calls: false, allow_video_calls: false})
    end

    test "reads string keys the same as atoms" do
      assert %{allow_immersive_mode: true} =
               Presenter.guest_capabilities(%{"allow_audio_calls" => true})
    end

    test "treats a truthy non-boolean as ineligible rather than as consent" do
      assert %{allow_immersive_mode: false} =
               Presenter.guest_capabilities(%{allow_audio_calls: "yes", allow_video_calls: nil})
    end

    test "is present and false for the list and fallback shapes" do
      # Every shape must carry the key, or a client cannot tell "denied" from
      # "this server predates the field".
      assert %{allow_immersive_mode: true} = Presenter.guest_capabilities([:audio_calls])
      assert %{allow_immersive_mode: false} = Presenter.guest_capabilities([])
      assert %{allow_immersive_mode: false} = Presenter.guest_capabilities(nil)
    end
  end
end
