defmodule CommsWeb.AudioCallPresenterTest do
  use ExUnit.Case, async: true

  alias CommsCore.AudioCalls.CallView
  alias CommsWeb.Presenter

  test "renders the existing HTTP contract from an Ecto-free Calls view" do
    started_at = ~U[2026-07-17 12:00:00.000000Z]
    expires_at = DateTime.add(started_at, 300, :second)

    call = %CallView{
      id: "01903e32-20e9-7000-8000-000000000001",
      tenant_id: "01903e32-20e9-7000-8000-000000000002",
      conversation_id: "01903e32-20e9-7000-8000-000000000003",
      started_by_user_id: "01903e32-20e9-7000-8000-000000000004",
      ended_by_user_id: nil,
      media_kind: :audio,
      status: :active,
      started_at: started_at,
      expires_at: expires_at,
      ended_at: nil,
      end_reason: nil,
      version: 2,
      can_end: true
    }

    assert Presenter.audio_call(call) == %{
             id: call.id,
             tenant_id: call.tenant_id,
             conversation_id: call.conversation_id,
             started_by_user_id: call.started_by_user_id,
             ended_by_user_id: nil,
             media_kind: :audio,
             status: :active,
             started_at: started_at,
             expires_at: expires_at,
             ended_at: nil,
             end_reason: nil,
             version: 2,
             can_end: true
           }
  end
end
