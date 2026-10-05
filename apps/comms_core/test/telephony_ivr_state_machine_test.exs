defmodule CommsCore.TelephonyIvrStateMachineTest do
  use ExUnit.Case, async: true
  alias CommsCore.Telephony.{IvrRun, IvrStateMachine}
  @id "4acf5490-60ba-439d-8a74-84960a9a1e4d"
  @now ~U[2026-10-05 01:00:00.000000Z]

  test "single-level choices reject recursion, unknown attributes and more than nine digits" do
    assert IvrStateMachine.valid_choices?(%{"1" => %{"kind" => "hangup"}})
    assert IvrStateMachine.valid_target?(%{"kind" => "route", "route_id" => @id})

    assert IvrStateMachine.valid_target?(%{
             "kind" => "destination",
             "destination" => "+14155550123"
           })

    refute IvrStateMachine.valid_choices?(%{})
    refute IvrStateMachine.valid_choices?(%{"0" => %{"kind" => "hangup"}})

    refute IvrStateMachine.valid_choices?(
             Map.new(1..10, &{Integer.to_string(&1), %{"kind" => "hangup"}})
           )

    refute IvrStateMachine.valid_target?(%{"kind" => "menu", "menu_id" => @id})
    refute IvrStateMachine.valid_target?(%{"kind" => "hangup", "user_id" => @id})

    refute IvrStateMachine.valid_target?(%{
             "kind" => "destination",
             "destination" => "sip:foreign.test"
           })
  end

  test "no caller digit selects a branch before actual prompt completion" do
    run = run(:playing)

    assert {:ignored, %{}} =
             IvrStateMachine.transition(run, %{type: :digit, step: 1, digit: "1"}, @now)
  end

  test "completion requires the exact run-step playback and approved frozen prompt" do
    run = run(:playing)

    event = %{
      type: :playback_finished,
      step: 1,
      playback_id: IvrStateMachine.playback_id(@id, 1),
      media_uri: "sound:custom/menu"
    }

    assert {:applied, changes} = IvrStateMachine.transition(run, event, @now)
    assert changes.phase == :awaiting_digit
    assert changes.prompt_completed_at == @now

    assert {:ignored, %{}} =
             IvrStateMachine.transition(
               run,
               %{event | playback_id: IvrStateMachine.playback_id(@id, 2)},
               @now
             )

    assert {:ignored, %{}} =
             IvrStateMachine.transition(run, %{event | media_uri: "sound:custom/other"}, @now)
  end

  test "digit deadline is clamped to the unchanged caller lifetime" do
    run = %{
      run(:playing)
      | expires_at: DateTime.add(@now, 7, :second),
        snapshot: Map.put(run(:playing).snapshot, "digit_timeout_seconds", 30)
    }

    assert {:applied, changes} =
             IvrStateMachine.playback_completed(
               run,
               IvrStateMachine.playback_id(@id, 1),
               "sound:custom/menu",
               @now
             )

    assert changes.digit_deadline == run.expires_at
  end

  test "valid digit selects one frozen target and repeated digits cannot select another" do
    run = %{run(:awaiting_digit) | digit_deadline: DateTime.add(@now, 10, :second)}

    assert {:applied, changes} =
             IvrStateMachine.transition(run, %{type: :digit, step: 1, digit: "1"}, @now)

    assert changes == %{
             phase: :selected,
             selected_target: %{"kind" => "route", "route_id" => @id}
           }

    selected = struct!(run, changes)

    assert {:ignored, %{}} =
             IvrStateMachine.transition(selected, %{type: :digit, step: 1, digit: "2"}, @now)
  end

  test "invalid digits have at most two retries and each retry changes the playback step" do
    first = %{run(:awaiting_digit) | digit_deadline: DateTime.add(@now, 10, :second)}

    assert {:applied, change1} =
             IvrStateMachine.transition(first, %{type: :digit, step: 1, digit: "#"}, @now)

    assert change1.phase == :pending and change1.retries == 1 and change1.step == 2

    second =
      struct!(
        first,
        Map.merge(change1, %{phase: :awaiting_digit, digit_deadline: first.digit_deadline})
      )

    assert {:applied, change2} =
             IvrStateMachine.transition(second, %{type: :digit, step: 2, digit: "0"}, @now)

    assert change2.retries == 2 and change2.step == 3

    third =
      struct!(
        second,
        Map.merge(change2, %{phase: :awaiting_digit, digit_deadline: first.digit_deadline})
      )

    assert {:applied, %{phase: :selected, selected_target: %{"kind" => "hangup"}}} =
             IvrStateMachine.transition(third, %{type: :digit, step: 3, digit: "0"}, @now)
  end

  test "prior-step late input cannot consume a newer retry" do
    run = %{
      run(:awaiting_digit)
      | step: 2,
        retries: 1,
        digit_deadline: DateTime.add(@now, 10, :second)
    }

    assert {:ignored, %{}} =
             IvrStateMachine.transition(run, %{type: :digit, step: 1, digit: "1"}, @now)
  end

  test "delayed input from before actual playback completion cannot be revived by later delivery" do
    completion_time = DateTime.add(@now, 2, :second)
    playing = run(:playing)

    playback = %{
      type: :playback_finished,
      step: 1,
      occurred_at: completion_time,
      playback_id: IvrStateMachine.playback_id(@id, 1),
      media_uri: "sound:custom/menu"
    }

    assert {:applied, completion} =
             IvrStateMachine.transition(playing, playback, DateTime.add(@now, 4, :second))

    awaiting = struct!(playing, completion)
    assert awaiting.prompt_completed_at == completion_time
    assert awaiting.digit_deadline == DateTime.add(completion_time, 10, :second)

    before_prompt = %{
      type: :digit,
      step: 1,
      digit: "1",
      occurred_at: DateTime.add(@now, 1, :second)
    }

    assert {:ignored, %{}} =
             IvrStateMachine.transition(awaiting, before_prompt, DateTime.add(@now, 5, :second))

    after_prompt = %{before_prompt | occurred_at: DateTime.add(@now, 3, :second)}

    assert {:applied,
            %{phase: :selected, selected_target: %{"kind" => "route", "route_id" => @id}}} =
             IvrStateMachine.transition(awaiting, after_prompt, DateTime.add(@now, 5, :second))
  end

  test "delivery delay does not extend a provider-completed prompt's digit window" do
    playing = run(:playing)

    playback = %{
      type: :playback_finished,
      step: 1,
      occurred_at: @now,
      playback_id: IvrStateMachine.playback_id(@id, 1),
      media_uri: "sound:custom/menu"
    }

    assert {:applied, completion} =
             IvrStateMachine.transition(playing, playback, DateTime.add(@now, 8, :second))

    assert completion.digit_deadline == DateTime.add(@now, 10, :second)
    awaiting = struct!(playing, completion)

    assert {:applied, %{phase: :pending, retries: 1}} =
             IvrStateMachine.timeout(awaiting, DateTime.add(@now, 10, :second))
  end

  test "total lifetime expiry fails instead of originating an expensive fallback" do
    run = %{
      run(:awaiting_digit)
      | expires_at: @now,
        snapshot:
          Map.put(run(:awaiting_digit).snapshot, "fallback", %{
            "kind" => "destination",
            "destination" => "+14155550123"
          })
    }

    assert {:applied, %{phase: :failed, failure_reason: "ivr_deadline"}} =
             IvrStateMachine.timeout(run, @now)

    assert {:applied, %{phase: :failed, failure_reason: "ivr_deadline"}} =
             IvrStateMachine.transition(run, %{type: :digit, step: 1, digit: "1"}, @now)
  end

  test "terminal runs cannot reopen on current valid playback or digit evidence" do
    for phase <- [:completed, :failed, :cancelled] do
      run = run(phase)

      assert {:ignored, %{}} =
               IvrStateMachine.transition(run, %{type: :digit, step: 1, digit: "1"}, @now)

      assert {:ignored, %{}} = IvrStateMachine.timeout(run, DateTime.add(@now, 60, :second))
    end
  end

  defp run(phase) do
    %IvrRun{
      id: @id,
      phase: phase,
      step: 1,
      retries: 0,
      expires_at: DateTime.add(@now, 45, :second),
      prompt_completed_at: if(phase == :awaiting_digit, do: @now, else: nil),
      snapshot: %{
        "prompt_media" => "sound:custom/menu",
        "choices" => %{"1" => %{"kind" => "route", "route_id" => @id}},
        "fallback" => %{"kind" => "hangup"},
        "digit_timeout_seconds" => 10,
        "max_retries" => 2
      }
    }
  end
end
