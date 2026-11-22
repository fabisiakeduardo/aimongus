defmodule Aimongus.Game.RulesTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.{Rules, State}
  alias Aimongus.Game.Map, as: GameMap

  # Cafeteria (C) and MedBay (M) separated by a wall column with a one-tile
  # door at (5, 2). Two task markers inside Cafeteria.
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

  defp add_players(state, players) do
    Enum.reduce(players, state, fn attrs, s -> State.add_player(s, attrs) end)
  end

  defp kill_player(state, id) do
    put_in(state.players[id].alive?, false)
  end

  describe "visible?/3" do
    test "sees positions inside the same room within radius" do
      state = new_state(%{vision_radius: 6.0}) |> add_players([%{id: "a", pos: {1, 1}}])

      assert Rules.visible?(state, "a", {4, 1})
      assert Rules.visible?(state, "a", {2, 3})
    end

    test "sees along a straight corridor line through a door" do
      state = new_state(%{vision_radius: 8.0}) |> add_players([%{id: "a", pos: {1, 2}}])

      # row y=2 is fully walkable from Cafeteria through the door into MedBay
      assert Rules.visible?(state, "a", {8, 2})
    end

    test "does not see a different room when the straight line hits a wall" do
      state = new_state(%{vision_radius: 8.0}) |> add_players([%{id: "a", pos: {1, 1}}])

      # same row, but (5,1) is a wall
      refute Rules.visible?(state, "a", {6, 1})
    end

    test "does not see into another room on a diagonal" do
      state = new_state(%{vision_radius: 8.0}) |> add_players([%{id: "a", pos: {1, 1}}])

      refute Rules.visible?(state, "a", {6, 2})
    end

    test "does not see beyond the vision radius even with a clear line" do
      state = new_state(%{vision_radius: 4.0}) |> add_players([%{id: "a", pos: {1, 2}}])

      refute Rules.visible?(state, "a", {6, 2})
    end

    test "a dead viewer sees everything" do
      state =
        new_state(%{vision_radius: 2.0})
        |> add_players([%{id: "a", pos: {1, 1}}])
        |> kill_player("a")

      assert Rules.visible?(state, "a", {8, 3})
    end

    test "unknown viewer sees nothing" do
      state = new_state(%{vision_radius: 6.0})
      refute Rules.visible?(state, "ghost", {1, 1})
    end
  end

  describe "can_kill?/3" do
    defp killer_state(config \\ %{kill_range: 2.0}) do
      new_state(config)
      |> add_players([
        %{id: "imp", pos: {4, 2}, role: :impostor},
        %{id: "crew", pos: {6, 2}},
        %{id: "far", pos: {1, 1}},
        %{id: "imp2", pos: {3, 2}, role: :impostor},
        %{id: "sk", pos: {7, 2}, role: :serial_killer},
        %{id: "vig", pos: {1, 3}, role: :vigilante},
        %{id: "vig_near", pos: {2, 3}}
      ])
    end

    test "true when killer is an impostor in range, off cooldown, both alive" do
      assert Rules.can_kill?(killer_state(), "imp", "crew")
    end

    test "friendly fire: an impostor can kill another impostor" do
      assert Rules.can_kill?(killer_state(), "imp", "imp2")
    end

    test "serial killer can kill" do
      assert Rules.can_kill?(killer_state(), "sk", "crew")
    end

    test "vigilante can kill until the single shot is spent" do
      state = killer_state()
      assert Rules.can_kill?(state, "vig", "vig_near")

      state = put_in(state.players["vig"].vigilante_shot_used?, true)
      refute Rules.can_kill?(state, "vig", "vig_near")
    end

    test "false when out of range" do
      refute Rules.can_kill?(killer_state(), "imp", "far")
    end

    test "false while on cooldown, true again after" do
      state =
        killer_state() |> put_in([Access.key(:players), "imp", Access.key(:kill_ready_at)], 100)

      refute Rules.can_kill?(state, "imp", "crew")
      assert Rules.can_kill?(%{state | tick: 100}, "imp", "crew")
    end

    test "false when the victim is dead" do
      state = killer_state() |> kill_player("crew")
      refute Rules.can_kill?(state, "imp", "crew")
    end

    test "false when the killer is dead" do
      state = killer_state() |> kill_player("imp")
      refute Rules.can_kill?(state, "imp", "crew")
    end

    test "false for non-killer roles" do
      for role <- [:crewmate, :sheriff, :medic, :jester] do
        state =
          new_state(%{kill_range: 5.0})
          |> add_players([%{id: "k", pos: {1, 1}, role: role}, %{id: "v", pos: {2, 1}}])

        refute Rules.can_kill?(state, "k", "v"), "expected #{role} to not be able to kill"
      end
    end

    test "false for self-kill or unknown players" do
      state = killer_state()
      refute Rules.can_kill?(state, "imp", "imp")
      refute Rules.can_kill?(state, "imp", "nobody")
      refute Rules.can_kill?(state, "nobody", "crew")
    end
  end

  describe "whisper_audience/2" do
    test "returns alive players inside the whisper radius, excluding the speaker" do
      state =
        new_state(%{whisper_radius: 3.0})
        |> add_players([
          %{id: "speaker", pos: {1, 1}},
          %{id: "near", pos: {3, 1}},
          %{id: "far", pos: {6, 1}},
          %{id: "dead_near", pos: {2, 1}}
        ])
        |> kill_player("dead_near")

      audience = Rules.whisper_audience(state, "speaker") |> Enum.sort()
      assert audience == ["near"]
    end

    test "empty audience when nobody is close" do
      state =
        new_state(%{whisper_radius: 2.0})
        |> add_players([%{id: "speaker", pos: {1, 1}}, %{id: "far", pos: {8, 3}}])

      assert Rules.whisper_audience(state, "speaker") == []
    end

    test "a dead or unknown speaker whispers to no one" do
      state =
        new_state(%{whisper_radius: 3.0})
        |> add_players([%{id: "speaker", pos: {1, 1}}, %{id: "near", pos: {2, 1}}])
        |> kill_player("speaker")

      assert Rules.whisper_audience(state, "speaker") == []
      assert Rules.whisper_audience(state, "ghost") == []
    end
  end

  describe "winner/1" do
    defp state_with(players) do
      state = new_state()

      state =
        Enum.reduce(players, state, fn {id, role, _alive?}, s ->
          s |> State.add_player(%{id: id, pos: {1, 1}}) |> State.assign_roles(%{id => role})
        end)

      Enum.reduce(players, state, fn
        {id, _role, false}, s -> kill_player(s, id)
        {_id, _role, true}, s -> s
      end)
    end

    test "nil while impostors are outnumbered" do
      state =
        state_with([
          {"i1", :impostor, true},
          {"i2", :impostor, true},
          {"c1", :crewmate, true},
          {"c2", :crewmate, true},
          {"c3", :crewmate, true},
          {"c4", :crewmate, true}
        ])

      assert Rules.winner(state) == nil
    end

    test "impostors win when their count reaches remaining non-impostors" do
      state =
        state_with([
          {"i1", :impostor, true},
          {"i2", :impostor, true},
          {"c1", :crewmate, true},
          {"c2", :crewmate, true},
          {"c3", :crewmate, false}
        ])

      assert Rules.winner(state) == :impostors
    end

    test "a lone impostor against one non-impostor wins" do
      state = state_with([{"i1", :impostor, true}, {"c1", :sheriff, true}])
      assert Rules.winner(state) == :impostors
    end

    test "crew wins when no killers remain" do
      state =
        state_with([
          {"i1", :impostor, false},
          {"c1", :crewmate, true},
          {"j1", :jester, true}
        ])

      assert Rules.winner(state) == :crew
    end

    test "crew wins when all win-pool tasks are done" do
      state =
        state_with([{"i1", :impostor, true}, {"c1", :crewmate, true}, {"c2", :crewmate, true}])
        |> Map.put(:tasks, %{"T1" => true, "T2" => true})

      assert Rules.winner(state) == :crew
    end

    test "an empty task pool is not a task win" do
      state =
        state_with([{"i1", :impostor, true}, {"c1", :crewmate, true}, {"c2", :crewmate, true}])

      assert Rules.winner(state) == nil
    end

    test "serial killer wins solo as the last one standing" do
      state =
        state_with([
          {"sk", :serial_killer, true},
          {"i1", :impostor, false},
          {"c1", :crewmate, false}
        ])

      assert Rules.winner(state) == {:solo, "sk"}
    end

    test "serial killer keeps playing while others live" do
      state =
        state_with([
          {"sk", :serial_killer, true},
          {"c1", :crewmate, true},
          {"c2", :crewmate, true}
        ])

      assert Rules.winner(state) == nil
    end

    test "impostor vs serial killer standoff goes to the impostors" do
      state = state_with([{"i1", :impostor, true}, {"sk", :serial_killer, true}])
      assert Rules.winner(state) == :impostors
    end

    test "everyone dead is a win for the killers" do
      state = state_with([{"i1", :impostor, false}, {"c1", :crewmate, false}])
      assert Rules.winner(state) == :impostors
    end

    test "an empty lobby is nobody's win" do
      assert Rules.winner(new_state()) == nil
    end
  end
end
