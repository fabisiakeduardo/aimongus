defmodule Aimongus.Game.StateTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.{Personality, State}
  alias Aimongus.Game.Map, as: GameMap
  alias Aimongus.Game.State.Player

  # Cafeteria (C) and MedBay (M) separated by a wall column with a one-tile
  # door at (5, 2); two task markers inside Cafeteria.
  @ascii """
  ##########
  #CCCC#MMM#
  #CT1C.MMM#
  #CT2C#MMM#
  ##########

  C: Cafeteria
  M: MedBay
  """

  defp new_state(config \\ %{}) do
    State.new(Map.merge(%{map: GameMap.parse(@ascii)}, config))
  end

  describe "new/1" do
    test "starts in :lobby with empty players/bodies and tick 0" do
      state = State.new(%{})

      assert %State{} = state
      assert state.phase == :lobby
      assert state.players == %{}
      assert state.bodies == []
      assert state.tick == 0
      assert %GameMap{} = state.map
    end

    test "merges config over defaults" do
      state = State.new(%{vision_radius: 9.0, tasks_per_player: 2})

      assert state.config.vision_radius == 9.0
      assert state.config.tasks_per_player == 2
      assert state.config.kill_cooldown_ticks > 0
      assert state.config.whisper_radius > 0
      assert state.config.kill_range > 0
      assert state.config.roles != []
    end

    test "default role mix is the 9-player game from the spec" do
      roles = State.new(%{}).config.roles |> Enum.sort()

      assert roles ==
               [
                 :crewmate,
                 :crewmate,
                 :crewmate,
                 :crewmate,
                 :impostor,
                 :impostor,
                 :jester,
                 :medic,
                 :sheriff
               ]
    end

    test "accepts a keyword list" do
      assert State.new(vision_radius: 4.5).config.vision_radius == 4.5
    end

    test "raises on unknown roles in config" do
      assert_raise ArgumentError, ~r/unknown role/, fn ->
        State.new(%{roles: [:impostor, :pirate]})
      end
    end
  end

  describe "add_player/2" do
    test "adds an alive player keyed by id" do
      state = new_state() |> State.add_player(%{id: "red", name: "Red", color: :red})

      player = State.player(state, "red")
      assert %Player{} = player
      assert player.id == "red"
      assert player.name == "Red"
      assert player.role == :crewmate
      assert player.alive? == true
      assert player.tasks == %{}
    end

    test "defaults pos to the button spot when the map has one, else {0,0}" do
      state = new_state() |> State.add_player(%{id: "a"})
      assert State.player(state, "a").pos == {0, 0}

      with_button = """
      #####
      #CBC#
      #####

      C: Cafeteria
      """

      state = State.new(%{map: GameMap.parse(with_button)}) |> State.add_player(%{id: "a"})
      assert State.player(state, "a").pos == {2, 1}
    end

    test "accepts role, pos and personality overrides" do
      card = %Personality{
        deceptiveness: 9,
        aggression: 8,
        paranoia: 3,
        chattiness: 5,
        loyalty: 4,
        risk: 7
      }

      state =
        new_state()
        |> State.add_player(%{id: "a", pos: {2, 2}, role: :impostor, personality: card})

      player = State.player(state, "a")
      assert player.pos == {2, 2}
      assert player.role == :impostor
      assert player.personality == card
    end

    test "raises on an unknown role" do
      assert_raise ArgumentError, ~r/unknown role/, fn ->
        new_state() |> State.add_player(%{id: "a", role: :pirate})
      end
    end

    test "raises on duplicate id" do
      state = new_state() |> State.add_player(%{id: "a"})

      assert_raise ArgumentError, ~r/already exists/, fn ->
        State.add_player(state, %{id: "a"})
      end
    end
  end

  describe "alive_players/1" do
    test "returns only living players" do
      state =
        new_state()
        |> State.add_player(%{id: "a", pos: {1, 1}})
        |> State.add_player(%{id: "b", pos: {2, 1}})
        |> put_in([Access.key(:players), "b", Access.key(:alive?)], false)

      assert [%Player{id: "a"}] = State.alive_players(state)
    end
  end

  describe "assign_roles/2" do
    test "sets each player's role from an explicit id => role map" do
      state =
        new_state()
        |> State.add_player(%{id: "a"})
        |> State.add_player(%{id: "b"})
        |> State.assign_roles(%{"a" => :impostor, "b" => :jester})

      assert State.player(state, "a").role == :impostor
      assert State.player(state, "b").role == :jester
    end

    test "raises on unknown role or unknown player" do
      state = new_state() |> State.add_player(%{id: "a"})

      assert_raise ArgumentError, fn -> State.assign_roles(state, %{"a" => :pirate}) end
      assert_raise ArgumentError, fn -> State.assign_roles(state, %{"zzz" => :crewmate}) end
    end
  end

  describe "assign_tasks/1" do
    test "gives every player up to tasks_per_player task ids" do
      state =
        new_state(%{tasks_per_player: 5})
        |> State.add_player(%{id: "crew"})
        |> State.add_player(%{id: "imp"})
        |> State.assign_roles(%{"crew" => :crewmate, "imp" => :impostor})
        |> State.assign_tasks()

      # only T1 and T2 exist on the test map, so players get all of them
      assert State.player(state, "crew").tasks |> map_size() == 2
      assert State.player(state, "imp").tasks |> map_size() == 2
    end

    test "only task-capable roles' tasks enter the win pool" do
      state =
        new_state(%{tasks_per_player: 2})
        |> State.add_player(%{id: "crew"})
        |> State.add_player(%{id: "sheriff"})
        |> State.add_player(%{id: "imp"})
        |> State.add_player(%{id: "jester"})
        |> State.add_player(%{id: "sk"})
        |> State.assign_roles(%{
          "crew" => :crewmate,
          "sheriff" => :sheriff,
          "imp" => :impostor,
          "jester" => :jester,
          "sk" => :serial_killer
        })
        |> State.assign_tasks()

      # crew + sheriff draw from T1/T2; killers' and jester's tasks are fakes
      assert state.tasks |> map_size() > 0
      assert Enum.all?(state.tasks, fn {_id, done?} -> done? == false end)
      assert Enum.all?(Map.keys(state.tasks), &(&1 in ["T1", "T2"]))
    end
  end

  describe "complete_task/3" do
    test "marks the player's task and the win-pool task done" do
      state =
        new_state(%{tasks_per_player: 2})
        |> State.add_player(%{id: "crew"})
        |> State.assign_tasks()

      [task_id | _] = State.player(state, "crew").tasks |> Map.keys()
      state = State.complete_task(state, "crew", task_id)

      assert State.player(state, "crew").tasks[task_id] == true
      assert state.tasks[task_id] == true
    end

    test "a killer's completed task does not advance the win pool" do
      state =
        new_state(%{tasks_per_player: 2})
        |> State.add_player(%{id: "crew"})
        |> State.add_player(%{id: "imp"})
        |> State.assign_roles(%{"imp" => :impostor})
        |> State.assign_tasks()

      [task_id | _] = State.player(state, "imp").tasks |> Map.keys()
      state = State.complete_task(state, "imp", task_id)

      assert State.player(state, "imp").tasks[task_id] == true

      # either not in the pool at all, or still undone if a crew player drew it
      refute state.tasks[task_id] == true
    end
  end

  describe "kill/3" do
    test "legal kill marks victim dead, drops a body, sets cooldown" do
      state =
        new_state(%{kill_range: 2.0, kill_cooldown_ticks: 300})
        |> State.add_player(%{id: "imp", pos: {1, 1}, role: :impostor})
        |> State.add_player(%{id: "crew", pos: {2, 1}})

      assert {:ok, state} = State.kill(state, "imp", "crew")

      victim = State.player(state, "crew")
      assert victim.alive? == false
      assert [%{player_id: "crew", pos: {2, 1}, by: "imp", tick: 0}] = state.bodies

      killer = State.player(state, "imp")
      assert killer.kill_ready_at == 300
    end

    test "illegal kill returns an error and changes nothing" do
      state =
        new_state(%{kill_range: 1.0})
        |> State.add_player(%{id: "imp", pos: {1, 1}, role: :impostor})
        |> State.add_player(%{id: "crew", pos: {6, 1}})

      assert {:error, :illegal_kill} = State.kill(state, "imp", "crew")
      assert State.player(state, "crew").alive? == true
      assert state.bodies == []
    end

    test "consumes the vigilante's single shot" do
      state =
        new_state(%{kill_range: 2.0})
        |> State.add_player(%{id: "vig", pos: {1, 1}, role: :vigilante})
        |> State.add_player(%{id: "a", pos: {2, 1}})
        |> State.add_player(%{id: "b", pos: {3, 1}})

      assert {:ok, state} = State.kill(state, "vig", "a")
      assert State.player(state, "vig").vigilante_shot_used? == true
      assert {:error, :illegal_kill} = State.kill(state, "vig", "b")
    end
  end
end
