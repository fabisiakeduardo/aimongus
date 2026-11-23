defmodule Aimongus.Game.MeetingTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.Server
  alias Aimongus.Game.Map, as: GameMap

  # Same layout as server_test: Cafeteria (C) / MedBay (M) joined by a
  # one-tile corridor at (6, 2). Tasks: T1 at {2, 2}, T2 at {2, 3};
  # emergency button at {2, 4}.
  @ascii """
  ############
  #CCCCC#MMMM#
  #CT1CC.MMMM#
  #CT2CC#MMMM#
  #CBCCC#MMMM#
  ############

  C: Cafeteria
  M: MedBay
  """

  defp test_map, do: GameMap.parse(@ascii)

  # roles zip onto sorted ids with shuffle_roles: false — "p1" is the impostor.
  defp default_players do
    [
      %{id: "p1", pos: {4, 2}},
      %{id: "p2", pos: {5, 2}},
      %{id: "p3", pos: {4, 3}},
      %{id: "p4", pos: {8, 3}}
    ]
  end

  defp start_server(config \\ %{}) do
    match_id = "meeting-test-#{System.unique_integer([:positive])}"

    config =
      %{
        map: test_map(),
        players: default_players(),
        roles: [:impostor, :crewmate, :crewmate, :crewmate],
        shuffle_roles: false,
        tasks_per_player: 2,
        auto_tick: false,
        speech_rounds: 1
      }
      |> Map.merge(config)

    {:ok, _pid} = Server.start_link(match_id, config)
    Phoenix.PubSub.subscribe(Aimongus.PubSub, "match:#{match_id}")
    match_id
  end

  defp step_until(match_id, fun, max \\ 60) do
    Enum.reduce_while(1..max, Server.state(match_id), fn _, _acc ->
      state = Server.step(match_id)
      if fun.(state), do: {:halt, state}, else: {:cont, state}
    end)
  end

  # Boots a match and drives it into a meeting: p1 (impostor) kills p2 in
  # Cafeteria, p3 (same room) reports the body. Alive voters/speakers are
  # p1, p3, p4.
  defp start_meeting(config \\ %{}) do
    match_id = start_server(config)
    :ok = Server.start_match(match_id)

    :ok = Server.submit_intent(match_id, "p1", {:kill, "p2"})
    assert_received {:killed, "p2", "p1", {5, 2}}

    :ok = Server.submit_intent(match_id, "p3", :report)
    assert_received {:body_reported, "p3", {5, 2}}
    assert_received :meeting_called
    assert_received {:meeting_started, {:report, "p3"}}

    match_id
  end

  # Answers each {:speak_request, id} in `speakers` order with a canned
  # line and asserts the matching {:spoke, ...} broadcast.
  defp drain_speeches(match_id, speakers) do
    Enum.each(speakers, fn id ->
      text = "#{id} speaks"

      assert_received {:speak_request, ^id}
      assert :ok = Server.submit_intent(match_id, id, {:speak, text})
      assert_received {:spoke, ^id, ^text}
    end)
  end

  describe "meeting start" do
    test "a body report opens discussion: meeting_started + first speak_request" do
      id = start_meeting()

      assert Server.state(id).phase == :meeting
      # p2 is dead; alive speakers run in sorted-id order
      assert_received {:speak_request, "p1"}
    end

    test "a button press opens a meeting with a button reason" do
      id = start_server()
      :ok = Server.start_match(id)

      :ok = Server.submit_intent(id, "p2", {:move_to, {2, 3}})
      step_until(id, fn st -> st.players["p2"].pos == {2, 3} end)

      assert :ok = Server.submit_intent(id, "p2", :press_button)
      assert_received {:button_pressed, "p2"}
      assert_received {:meeting_started, {:button, "p2"}}

      # everyone alive — all four get a slot, starting at p1
      assert_received {:speak_request, "p1"}
    end
  end

  describe "discussion" do
    test "speak slots run every alive player each round, in sorted-id order" do
      id = start_meeting(%{speech_rounds: 2})

      drain_speeches(id, ["p1", "p3", "p4", "p1", "p3", "p4"])

      assert_received :voting_started
      assert Server.state(id).phase == :voting
    end

    test "only the floor holder may speak" do
      id = start_meeting()
      assert_received {:speak_request, "p1"}

      assert {:rejected, :not_your_turn} = Server.submit_intent(id, "p3", {:speak, "me?"})
      assert {:rejected, :dead} = Server.submit_intent(id, "p2", {:speak, "boo"})
      assert {:rejected, :unknown_player} = Server.submit_intent(id, "ghost", {:speak, "hi"})
      assert {:rejected, :invalid_text} = Server.submit_intent(id, "p1", {:speak, ""})

      assert :ok = Server.submit_intent(id, "p1", {:speak, "where was the body?"})
      assert_received {:spoke, "p1", "where was the body?"}
      assert_received {:speak_request, "p3"}
    end

    test ":nothing passes the current speaker's slot" do
      id = start_meeting()
      assert_received {:speak_request, "p1"}

      assert :ok = Server.submit_intent(id, "p1", :nothing)
      assert_received {:spoke, "p1", nil}
      assert_received {:speak_request, "p3"}
    end

    test "the meeting_seconds deadline skips unspoken slots into voting" do
      id = start_meeting(%{meeting_seconds: 0})
      assert_received {:speak_request, "p1"}

      state = Server.step(id)
      assert state.phase == :voting
      assert_received :voting_started
    end
  end

  describe "voting" do
    test "votes validate voter and target" do
      id = start_meeting()
      drain_speeches(id, ["p1", "p3", "p4"])
      assert_received :voting_started

      assert {:rejected, :unknown_player} = Server.submit_intent(id, "ghost", {:vote, "p1"})
      assert {:rejected, :dead} = Server.submit_intent(id, "p2", {:vote, "p1"})
      assert {:rejected, :unknown_target} = Server.submit_intent(id, "p3", {:vote, "nobody"})
      assert {:rejected, :target_dead} = Server.submit_intent(id, "p3", {:vote, "p2"})

      assert :ok = Server.submit_intent(id, "p3", {:vote, :skip})
      assert_received {:voted, "p3", :skip}
    end

    test "a voter may change their vote before the tally" do
      id = start_meeting()
      drain_speeches(id, ["p1", "p3", "p4"])
      assert_received :voting_started

      :ok = Server.submit_intent(id, "p3", {:vote, "p4"})
      :ok = Server.submit_intent(id, "p3", {:vote, "p1"})
      :ok = Server.submit_intent(id, "p4", {:vote, "p1"})
      :ok = Server.submit_intent(id, "p1", {:vote, :skip})

      # p3's switch leaves p1 with two votes, skip with one — p1 ejected
      assert_received {:ejected, "p1", :impostor}
    end

    test "the vote_seconds deadline counts missing votes as :skip" do
      id = start_meeting(%{vote_seconds: 0})
      drain_speeches(id, ["p1", "p3", "p4"])
      assert_received :voting_started

      # one real vote for p1; p1 and p4 never vote — implicit skips win 2-1
      :ok = Server.submit_intent(id, "p3", {:vote, "p1"})

      state = Server.step(id)
      assert state.phase == :eject
      assert_received :no_ejection
      assert Enum.all?(state.players, fn {_id, p} -> p.alive? or p.id == "p2" end)

      assert Server.step(id).phase == :free_roam
    end
  end

  describe "eject" do
    test "a plurality ejects, reveals the role, then game_over when killers are gone" do
      id = start_meeting()
      drain_speeches(id, ["p1", "p3", "p4"])
      assert_received :voting_started

      :ok = Server.submit_intent(id, "p1", {:vote, "p3"})
      :ok = Server.submit_intent(id, "p3", {:vote, "p1"})
      :ok = Server.submit_intent(id, "p4", {:vote, "p1"})

      assert_received {:voted, "p4", "p1"}
      assert_received {:ejected, "p1", :impostor}

      state = Server.state(id)
      assert state.phase == :eject
      refute state.players["p1"].alive?

      # p1 was the only impostor — resolving the eject ends the match
      state = Server.step(id)
      assert state.phase == :game_over
      assert state.winner == :crew
      assert_received {:game_over, :crew}
    end

    test "a tie ejects nobody and the match returns to free_roam" do
      id = start_meeting()
      drain_speeches(id, ["p1", "p3", "p4"])
      assert_received :voting_started

      :ok = Server.submit_intent(id, "p1", {:vote, :skip})
      :ok = Server.submit_intent(id, "p3", {:vote, "p1"})
      :ok = Server.submit_intent(id, "p4", {:vote, "p3"})

      # p1: 1, p3: 1, skip: 1 — tied at the top, nobody ejected
      assert_received :no_ejection
      assert Server.state(id).phase == :eject

      state = Server.step(id)
      assert state.phase == :free_roam
      assert_received :meeting_ended

      # meeting cleanup: bodies gone, positions and cooldowns preserved
      assert state.bodies == []
      assert state.players["p1"].pos == {4, 2}
      assert state.players["p1"].kill_ready_at > state.tick

      # free-roam intents are accepted again
      assert :ok = Server.submit_intent(id, "p3", :nothing)
    end

    test "ejecting a crewmate with the match still live returns to free_roam" do
      id =
        start_meeting(%{
          players: default_players() ++ [%{id: "p5", pos: {9, 3}}],
          roles: [:impostor, :crewmate, :crewmate, :crewmate, :crewmate]
        })

      drain_speeches(id, ["p1", "p3", "p4", "p5"])
      assert_received :voting_started

      :ok = Server.submit_intent(id, "p1", {:vote, "p3"})
      :ok = Server.submit_intent(id, "p3", {:vote, "p1"})
      :ok = Server.submit_intent(id, "p4", {:vote, "p3"})
      :ok = Server.submit_intent(id, "p5", {:vote, "p3"})

      assert_received {:ejected, "p3", :crewmate}
      refute Server.state(id).players["p3"].alive?

      # impostor p1 vs crew p4+p5 — no winner yet, play resumes
      state = Server.step(id)
      assert state.phase == :free_roam
      assert_received :meeting_ended
      refute_received {:game_over, _}
    end

    test "reveal_role_on_eject: false hides the ejected role" do
      id =
        start_meeting(%{
          reveal_role_on_eject: false,
          players: default_players() ++ [%{id: "p5", pos: {9, 3}}],
          roles: [:impostor, :crewmate, :crewmate, :crewmate, :crewmate]
        })

      drain_speeches(id, ["p1", "p3", "p4", "p5"])

      :ok = Server.submit_intent(id, "p1", {:vote, "p3"})
      :ok = Server.submit_intent(id, "p3", {:vote, "p1"})
      :ok = Server.submit_intent(id, "p4", {:vote, "p3"})
      :ok = Server.submit_intent(id, "p5", {:vote, "p3"})

      assert_received {:ejected, "p3", nil}
    end
  end

  describe "phase gating" do
    test "meeting intents are rejected in free_roam and vice versa" do
      id = start_server()
      :ok = Server.start_match(id)

      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p3", {:speak, "hi"})
      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p3", {:vote, "p1"})

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", _}
      :ok = Server.submit_intent(id, "p3", :report)
      assert_received {:meeting_started, _}

      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p3", {:move_to, {1, 1}})
      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p3", {:vote, "p1"})
      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p3", :report)

      drain_speeches(id, ["p1", "p3", "p4"])
      assert_received :voting_started

      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p3", {:speak, "hi"})
      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p3", {:kill, "p1"})
    end
  end
end
