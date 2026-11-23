defmodule Aimongus.Game.StallTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.Server
  alias Aimongus.Game.Map, as: GameMap

  # Same layout as server_test/meeting_test: Cafeteria (C) / MedBay (M)
  # joined by a one-tile corridor at (6, 2). Tasks: T1 at {2, 2}, T2 at
  # {2, 3}; emergency button at {2, 4}.
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

  defp start_server(config) do
    match_id = "stall-test-#{System.unique_integer([:positive])}"

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

  defp start_running(config) do
    match_id = start_server(config)
    :ok = Server.start_match(match_id)
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

  describe "match deadline" do
    test "expiry with fewer kills than the threshold ends the match — crew wins by survival" do
      id = start_running(%{match_max_seconds: 0})

      state = Server.step(id)
      assert state.phase == :game_over
      assert state.winner == :crew
      assert_received {:match_timeout, :crew}
      assert_received {:game_over, :crew}
    end

    test "expiry with kills >= kill_threshold declares impostors the winner" do
      id = start_running(%{match_max_seconds: 0, kill_threshold: 1})

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", {5, 2}}

      state = Server.step(id)
      assert state.phase == :game_over
      assert state.winner == :impostors
      assert_received {:match_timeout, :impostors}
      assert_received {:game_over, :impostors}
    end

    test "kills below a raised threshold still go to the crew" do
      id = start_running(%{match_max_seconds: 0, kill_threshold: 3})

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", {5, 2}}

      state = Server.step(id)
      assert state.phase == :game_over
      assert state.winner == :crew
    end

    test "the deadline fires mid-meeting too" do
      id = start_running(%{match_max_seconds: 0})

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", _}
      :ok = Server.submit_intent(id, "p3", :report)
      assert_received {:meeting_started, {:report, "p3"}}
      assert Server.state(id).phase == :meeting

      # one kill < default threshold 2 → crew by survival
      state = Server.step(id)
      assert state.phase == :game_over
      assert state.winner == :crew
      assert_received {:match_timeout, :crew}
      assert_received {:game_over, :crew}
    end

    test "a pending real winner beats the heuristic at timeout" do
      # p1 (impostor) kills p2 and gets ejected; the eject transient is
      # holding a real :crew win (no impostors left) when the cap fires.
      # One kill >= kill_threshold 1 would read :impostors — the real
      # winner must win instead.
      id = start_running(%{match_max_seconds: 0, kill_threshold: 1})

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", _}
      :ok = Server.submit_intent(id, "p3", :report)
      assert_received {:meeting_started, {:report, "p3"}}

      drain_speeches(id, ["p1", "p3", "p4"])
      assert_received :voting_started

      :ok = Server.submit_intent(id, "p1", {:vote, "p3"})
      :ok = Server.submit_intent(id, "p3", {:vote, "p1"})
      :ok = Server.submit_intent(id, "p4", {:vote, "p1"})

      assert_received {:ejected, "p1", :impostor}
      assert Server.state(id).phase == :eject

      state = Server.step(id)
      assert state.phase == :game_over
      assert state.winner == :crew
      assert_received {:match_timeout, :crew}
      assert_received {:game_over, :crew}
    end

    test "ejections do not count as kills for the heuristic" do
      # Five players so ejecting a crewmate leaves the match live. One
      # real kill (p2) plus one ejection (p4) makes two dead players —
      # counting dead bodies instead of murders would reach the
      # threshold of 2 and read :impostors; only the kill may count.
      id =
        start_running(%{
          match_max_seconds: 0,
          kill_threshold: 2,
          players: default_players() ++ [%{id: "p5", pos: {9, 3}}],
          roles: [:impostor, :crewmate, :crewmate, :crewmate, :crewmate]
        })

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", _}
      :ok = Server.submit_intent(id, "p3", :report)
      assert_received {:meeting_started, {:report, "p3"}}

      drain_speeches(id, ["p1", "p3", "p4", "p5"])
      assert_received :voting_started

      :ok = Server.submit_intent(id, "p1", {:vote, "p4"})
      :ok = Server.submit_intent(id, "p3", {:vote, "p4"})
      :ok = Server.submit_intent(id, "p4", {:vote, "p1"})
      :ok = Server.submit_intent(id, "p5", {:vote, "p4"})

      assert_received {:ejected, "p4", :crewmate}
      assert Server.state(id).phase == :eject

      state = Server.step(id)
      assert state.phase == :game_over
      assert state.winner == :crew
    end

    test "a match under the cap keeps running" do
      id = start_running(%{match_max_seconds: 60})

      state = Server.step(id)
      assert state.phase == :free_roam
      refute_received {:game_over, _}
      refute_received {:match_timeout, _}
    end

    test "match_max_seconds: nil disables the cap" do
      id = start_running(%{match_max_seconds: nil})

      Enum.each(1..5, fn _ -> Server.step(id) end)
      assert Server.state(id).phase == :free_roam
      refute_received {:game_over, _}
    end
  end
end
