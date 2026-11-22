defmodule Aimongus.Game.ServerTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.Server
  alias Aimongus.Game.Map, as: GameMap

  # Cafeteria (C) / MedBay (M) joined by a one-tile corridor at (6, 2).
  # Tasks: T1 at {2, 2}, T2 at {2, 3}; emergency button at {2, 4}.
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
    match_id = "test-#{System.unique_integer([:positive])}"

    config =
      %{
        map: test_map(),
        players: default_players(),
        roles: [:impostor, :crewmate, :crewmate, :crewmate],
        shuffle_roles: false,
        tasks_per_player: 2,
        auto_tick: false
      }
      |> Map.merge(config)

    {:ok, _pid} = Server.start_link(match_id, config)
    Phoenix.PubSub.subscribe(Aimongus.PubSub, "match:#{match_id}")
    match_id
  end

  defp start_running(config \\ %{}) do
    match_id = start_server(config)
    :ok = Server.start_match(match_id)
    match_id
  end

  # Drives synchronous world ticks until `fun` holds (or `max` ticks pass).
  defp step_until(match_id, fun, max \\ 60) do
    Enum.reduce_while(1..max, Server.state(match_id), fn _, _acc ->
      state = Server.step(match_id)
      if fun.(state), do: {:halt, state}, else: {:cont, state}
    end)
  end

  defp manhattan({x1, y1}, {x2, y2}), do: abs(x1 - x2) + abs(y1 - y2)

  describe "lifecycle" do
    test "starts in :lobby with config players added" do
      id = start_server()
      state = Server.state(id)

      assert state.phase == :lobby
      assert map_size(state.players) == 4
      assert state.players["p1"].pos == {4, 2}
      assert state.players["p1"].personality != nil
    end

    test "add_player joins the lobby and broadcasts the join" do
      id = start_server(%{players: []})
      assert {:ok, "newbie"} = Server.add_player(id, %{id: "newbie", name: "Newbie", pos: {1, 1}})
      assert_receive {:player_joined, "newbie", "Newbie", {1, 1}}
      assert Server.state(id).players["newbie"].pos == {1, 1}
    end

    test "add_player rejects duplicates and non-lobby joins" do
      id = start_server()
      assert {:error, :duplicate_player} = Server.add_player(id, %{id: "p1"})
      :ok = Server.start_match(id)
      assert {:error, :not_lobby} = Server.add_player(id, %{id: "late"})
    end

    test "intents submitted in the lobby are rejected as wrong phase" do
      id = start_server()
      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p1", :nothing)
    end

    test "start_match assigns roles + tasks, enters free_roam, broadcasts" do
      id = start_server()
      :ok = Server.start_match(id)

      assert_receive :match_started
      assert_receive {:role_assigned, "p1", :impostor}
      assert_receive {:role_assigned, "p2", :crewmate}

      state = Server.state(id)
      assert state.phase == :free_roam
      assert state.players["p1"].role == :impostor
      assert map_size(state.players["p2"].tasks) == 2
      assert state.tasks |> Map.keys() |> Enum.sort() == ["T1", "T2"]

      assert {:error, :already_started} = Server.start_match(id)
    end
  end

  describe "movement" do
    test "move_to pos paths and the pawn advances one waypoint per tick" do
      id = start_running()
      assert :ok = Server.submit_intent(id, "p3", {:move_to, {1, 1}})
      assert Server.state(id).players["p3"].path != []

      state = Server.step(id)
      new_pos = state.players["p3"].pos
      assert new_pos != {4, 3}
      assert manhattan(new_pos, {4, 3}) == 1
      assert_receive {:moved, "p3", ^new_pos}

      state = step_until(id, fn st -> st.players["p3"].path == [] end)
      assert state.players["p3"].pos == {1, 1}
    end

    test "move_to room name routes into the room through the door" do
      id = start_running()
      assert :ok = Server.submit_intent(id, "p3", {:move_to, "MedBay"})

      state =
        step_until(id, fn st -> GameMap.room_at(st.map, st.players["p3"].pos) == "MedBay" end)

      assert GameMap.room_at(state.map, state.players["p3"].pos) == "MedBay"
    end

    test "move_to rejects walls, unknown rooms and unknown players" do
      id = start_running()
      assert {:rejected, :unreachable} = Server.submit_intent(id, "p3", {:move_to, {0, 0}})
      assert {:rejected, :unknown_room} = Server.submit_intent(id, "p3", {:move_to, "Atlantis"})
      assert {:rejected, :unknown_player} = Server.submit_intent(id, "ghost", :nothing)
    end

    test "move_speed config advances multiple tiles per tick" do
      id = start_running(%{move_speed: 3})
      assert :ok = Server.submit_intent(id, "p3", {:move_to, {1, 1}})

      state = Server.step(id)
      assert manhattan(state.players["p3"].pos, {4, 3}) == 3
    end

    test ":nothing cancels the current path" do
      id = start_running()
      :ok = Server.submit_intent(id, "p3", {:move_to, {1, 1}})
      assert Server.state(id).players["p3"].path != []

      :ok = Server.submit_intent(id, "p3", :nothing)
      assert Server.state(id).players["p3"].path == []
    end
  end

  describe "tasks" do
    test "do_task paths to the spot, ticks progress, completes and updates the pool" do
      id = start_running(%{task_ticks: 3})

      assert :ok = Server.submit_intent(id, "p2", {:do_task, "T1"})

      # {5,2} -> {2,2} is three steps; arrival tick counts as work tick 1.
      step_until(id, fn st -> st.players["p2"].pos == {2, 2} end)
      assert_receive {:task_progress, "p2", "T1", 33}

      Server.step(id)
      assert_receive {:task_progress, "p2", "T1", 67}

      Server.step(id)
      assert_receive {:task_done, "p2", "T1"}

      state = Server.state(id)
      assert state.players["p2"].tasks["T1"] == true
      assert state.tasks["T1"] == true
    end

    test "do_task rejects unknown and unassigned tasks" do
      id = start_running(%{tasks_per_player: 1})

      assert {:rejected, :unknown_task} = Server.submit_intent(id, "p2", {:do_task, "T99"})

      assigned = Server.state(id).players["p2"].tasks |> Map.keys() |> hd()
      other = Enum.find(["T1", "T2"], &(&1 != assigned))
      assert {:rejected, :not_assigned} = Server.submit_intent(id, "p2", {:do_task, other})
    end

    test "moving mid-task abandons progress; redoing restarts it" do
      id = start_running(%{task_ticks: 5})

      :ok = Server.submit_intent(id, "p2", {:do_task, "T1"})
      step_until(id, fn st -> st.players["p2"].pos == {2, 2} end)
      assert_receive {:task_progress, "p2", "T1", 20}

      :ok = Server.submit_intent(id, "p2", {:move_to, {5, 4}})
      step_until(id, fn st -> st.players["p2"].pos == {5, 4} end)

      :ok = Server.submit_intent(id, "p2", {:do_task, "T1"})
      step_until(id, fn st -> st.players["p2"].pos == {2, 2} end)

      # restarted from zero — a continued task would read 40 at work tick 2
      assert_receive {:task_progress, "p2", "T1", 20}
    end

    test "completing the whole task pool wins the game for crew" do
      id = start_running(%{task_ticks: 2})

      :ok = Server.submit_intent(id, "p2", {:do_task, "T1"})
      step_until(id, fn st -> st.players["p2"].tasks["T1"] end)

      :ok = Server.submit_intent(id, "p2", {:do_task, "T2"})
      step_until(id, fn st -> st.phase == :game_over end)

      assert_receive {:game_over, :crew}
      assert Server.state(id).winner == :crew
    end
  end

  describe "kills" do
    test "an in-range kill produces a body and a :killed event" do
      id = start_running()

      assert :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_receive {:killed, "p2", "p1", {5, 2}}

      state = Server.state(id)
      refute state.players["p2"].alive?
      assert [%{player_id: "p2", pos: {5, 2}, by: "p1"} | _] = state.bodies
      assert state.players["p1"].kill_ready_at > state.tick
    end

    test "kill rejects with precise reasons" do
      id = start_running(%{kill_cooldown_ticks: 0})

      # crewmates cannot kill
      assert {:rejected, :cannot_kill} = Server.submit_intent(id, "p3", {:kill, "p2"})
      # unknown / dead targets
      assert {:rejected, :unknown_target} = Server.submit_intent(id, "p1", {:kill, "nobody"})
      # p1 at {4,2} vs p4 at {8,3}: ~4.1 tiles > kill_range
      assert {:rejected, :out_of_range} = Server.submit_intent(id, "p1", {:kill, "p4"})
      # self-kill is not legal
      assert {:rejected, :cannot_kill} = Server.submit_intent(id, "p1", {:kill, "p1"})

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert {:rejected, :target_dead} = Server.submit_intent(id, "p1", {:kill, "p2"})
    end

    test "kill on cooldown reports remaining ticks" do
      id = start_running(%{kill_cooldown_ticks: 10})

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert {:rejected, {:cooldown, 10}} = Server.submit_intent(id, "p1", {:kill, "p3"})

      # after the cooldown expires, range — not cooldown — is the blocker
      Enum.each(1..10, fn _ -> Server.step(id) end)
      assert {:rejected, :out_of_range} = Server.submit_intent(id, "p1", {:kill, "p4"})
    end

    test "a kill that flips the majority ends the game" do
      id =
        start_running(%{
          players: [%{id: "p1", pos: {4, 2}}, %{id: "p2", pos: {5, 2}}, %{id: "p3", pos: {4, 3}}],
          roles: [:impostor, :crewmate, :crewmate]
        })

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})

      assert_receive {:killed, "p2", "p1", {5, 2}}
      assert_receive {:game_over, :impostors}

      state = Server.state(id)
      assert state.phase == :game_over
      assert state.winner == :impostors
      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p1", {:kill, "p3"})
    end
  end

  describe "reports and the button" do
    test "report marks the body, broadcasts and freezes the world into :meeting" do
      id = start_running()

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_receive {:killed, "p2", "p1", _pos}

      # p3 at {4,3} shares Cafeteria with the body at {5,2} — visible.
      assert :ok = Server.submit_intent(id, "p3", :report)
      assert_receive {:body_reported, "p3", {5, 2}}
      assert_receive :meeting_called

      state = Server.state(id)
      assert state.phase == :meeting
      assert [%{reported?: true} | _] = state.bodies
      # world frozen: everyone stopped, free-roam intents rejected —
      # :nothing is now a meeting intent (pass), and p3 doesn't hold
      # the floor (p1 does), so the precise rejection is :not_your_turn
      assert Enum.all?(state.players, fn {_id, p} -> p.path == [] end)
      assert {:rejected, :not_your_turn} = Server.submit_intent(id, "p3", :nothing)
      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p3", {:move_to, {1, 1}})
    end

    test "report requires a visible unreported body" do
      id = start_running()
      assert {:rejected, :no_body} = Server.submit_intent(id, "p3", :report)

      # body in Cafeteria; p4 at {8,3} sits in MedBay — too far / other room
      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert {:rejected, :no_body} = Server.submit_intent(id, "p4", :report)
    end

    test "press_button works only next to the button spot" do
      id = start_running()

      # p3 at {4,3}: distance to button {2,4} is ~2.24 > button_range
      assert {:rejected, :not_at_button} = Server.submit_intent(id, "p3", :press_button)

      :ok = Server.submit_intent(id, "p2", {:move_to, {2, 3}})
      step_until(id, fn st -> st.players["p2"].pos == {2, 3} end)

      assert :ok = Server.submit_intent(id, "p2", :press_button)
      assert_receive {:button_pressed, "p2"}
      assert_receive :meeting_called
      assert Server.state(id).phase == :meeting
    end
  end

  describe "whispers" do
    test "whisper reaches exactly the radius audience" do
      id = start_running()

      assert :ok = Server.submit_intent(id, "p2", {:whisper, "psst", nil})
      assert_receive {:whisper, "p2", audience, "psst"}
      # p1 ~1 tile, p3 ~1.4 tiles away; p4 sits in MedBay >3 tiles out
      assert audience == ["p1", "p3"]
    end

    test "a whisper with nobody in range still goes out with an empty audience" do
      id = start_running()

      assert :ok = Server.submit_intent(id, "p4", {:whisper, "anyone?", "p1"})
      assert_receive {:whisper, "p4", [], "anyone?"}
    end
  end

  describe "ghosts" do
    test "dead players may roam but cannot act on the living" do
      id = start_running()

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_receive {:killed, "p2", "p1", _}

      # ghosts still get to drift and finish tasks (Among Us rule)
      assert :ok = Server.submit_intent(id, "p2", {:move_to, {1, 1}})
      Server.step(id)
      assert Server.state(id).players["p2"].pos != {5, 2}

      assert {:rejected, :dead} = Server.submit_intent(id, "p2", :report)
      assert {:rejected, :dead} = Server.submit_intent(id, "p2", :press_button)
      assert {:rejected, :dead} = Server.submit_intent(id, "p2", {:whisper, "boo", nil})
      assert {:rejected, :dead} = Server.submit_intent(id, "p2", {:kill, "p1"})
    end
  end

  describe "tick loop" do
    test "auto_tick advances the world on the configured cadence" do
      id = start_running(%{auto_tick: true, tick_ms: 5})

      :ok = Server.submit_intent(id, "p3", {:move_to, {1, 1}})
      assert_receive {:moved, "p3", _pos}, 500
    end

    test "tick does not advance while in a meeting" do
      id = start_running(%{auto_tick: true, tick_ms: 5})

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      :ok = Server.submit_intent(id, "p3", :report)
      assert_receive :meeting_called

      tick_at_meeting = Server.state(id).tick
      Process.sleep(50)
      assert Server.state(id).tick == tick_at_meeting
    end
  end
end
