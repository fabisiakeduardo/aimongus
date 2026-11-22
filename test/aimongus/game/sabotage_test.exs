defmodule Aimongus.Game.SabotageTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.{Rules, Server}
  alias Aimongus.Game.Map, as: GameMap

  # Reactor (R) and Electrical (E) — the two fix rooms — joined by a
  # one-tile corridor at (6, 2). Button at {2, 4}.
  @ascii """
  ############
  #RRRRR#EEEE#
  #RT1RR.EEEE#
  #RRRRR#EEEE#
  #RBRRR#EEEE#
  ############

  R: Reactor
  E: Electrical
  """

  defp test_map, do: GameMap.parse(@ascii)

  defp players do
    [
      %{id: "p1", pos: {4, 2}},
      %{id: "p2", pos: {5, 2}},
      %{id: "p3", pos: {8, 2}},
      %{id: "p4", pos: {8, 3}}
    ]
  end

  defp start_server(config \\ %{}) do
    match_id = "test-#{System.unique_integer([:positive])}"

    config =
      %{
        map: test_map(),
        players: players(),
        roles: [:impostor, :crewmate, :crewmate, :crewmate],
        shuffle_roles: false,
        tasks_per_player: 1,
        auto_tick: false
      }
      |> Map.merge(Map.new(config))

    {:ok, _pid} = Server.start_link(match_id, config)
    Phoenix.PubSub.subscribe(Aimongus.PubSub, "match:#{match_id}")
    Server.start_match(match_id)
    match_id
  end

  describe "sabotage intent" do
    test "impostor can trigger lights; crewmate cannot" do
      match_id = start_server()

      assert {:rejected, :cannot_sabotage} =
               Server.submit_intent(match_id, "p2", {:sabotage, :lights})

      assert :ok = Server.submit_intent(match_id, "p1", {:sabotage, :lights})
      assert_receive {:sabotaged, :lights, "p1", nil}

      # one at a time — even the saboteur can't stack another
      assert {:rejected, :sabotage_active} =
               Server.submit_intent(match_id, "p1", {:sabotage, :reactor})
    end

    test "sabotage cooldown is per-saboteur after a fix" do
      match_id = start_server()
      assert :ok = Server.submit_intent(match_id, "p1", {:sabotage, :lights})

      # p2 walks into Electrical (already there at {8,2}) and fixes
      assert :ok = Server.submit_intent(match_id, "p3", :fix)

      for _ <- 1..45, do: Server.step(match_id)
      assert_receive {:sabotage_fixed, :lights, ["p3"]}

      # cooldown now blocks the saboteur
      assert {:rejected, {:cooldown, n}} =
               Server.submit_intent(match_id, "p1", {:sabotage, :lights})

      assert n > 0
    end

    test "lights shrinks living vision to the sabotage radius" do
      match_id = start_server()
      state = Server.state(match_id)

      # p1 at {4,2} can see p3 at {8,2} (distance 4 < vision 6, corridor LOS)
      assert Rules.visible?(state, "p1", {8, 2})

      assert :ok = Server.submit_intent(match_id, "p1", {:sabotage, :lights})
      state = Server.state(match_id)

      refute Rules.visible?(state, "p1", {8, 2})
    end

    test "button is dead while a sabotage runs" do
      match_id = start_server()
      assert :ok = Server.submit_intent(match_id, "p1", {:sabotage, :lights})

      # p2 at the button ({2,4} is inside Reactor's B spot — move p2 there)
      assert :ok = Server.submit_intent(match_id, "p2", {:move_to, {2, 4}})
      for _ <- 1..10, do: Server.step(match_id)

      assert {:rejected, :sabotage_active} =
               Server.submit_intent(match_id, "p2", :press_button)
    end
  end

  describe "reactor meltdown" do
    test "unfixed reactor ends the match for the impostors" do
      match_id = start_server(reactor_meltdown_ticks: 5)

      assert :ok = Server.submit_intent(match_id, "p1", {:sabotage, :reactor})
      assert_receive {:sabotaged, :reactor, "p1", seconds}
      assert seconds > 0

      for _ <- 1..8, do: Server.step(match_id)

      assert_receive {:meltdown, :reactor}
      assert_receive {:game_over, :impostors}
      assert Server.state(match_id).phase == :game_over
    end

    test "a fixer in the wrong room can't channel" do
      match_id = start_server()
      assert :ok = Server.submit_intent(match_id, "p1", {:sabotage, :reactor})

      # p3 is in Electrical, not Reactor — reactor's fix room is Reactor
      assert {:rejected, :not_at_console} =
               Server.submit_intent(match_id, "p3", :fix)
    end

    test "fixing clears the meltdown" do
      match_id = start_server(reactor_meltdown_ticks: 30, sabotage_fix_ticks: 5)

      assert :ok = Server.submit_intent(match_id, "p1", {:sabotage, :reactor})

      # p1 is already in Reactor ({4,2}); killers can fix too — anyone
      # standing at the console channels
      assert :ok = Server.submit_intent(match_id, "p1", :fix)

      for _ <- 1..8, do: Server.step(match_id)

      assert_receive {:sabotage_fixed, :reactor, ["p1"]}
      assert Server.state(match_id).sabotage == nil
    end

    test "moving abandons the fix" do
      match_id = start_server(reactor_meltdown_ticks: 50, sabotage_fix_ticks: 20)

      assert :ok = Server.submit_intent(match_id, "p1", {:sabotage, :reactor})
      assert :ok = Server.submit_intent(match_id, "p1", :fix)

      for _ <- 1..5, do: Server.step(match_id)
      assert Server.state(match_id).sabotage.progress > 0

      assert :ok = Server.submit_intent(match_id, "p1", {:move_to, "Electrical"})
      assert MapSet.size(Server.state(match_id).sabotage.fixers) == 0
    end
  end

  describe "view_for" do
    test "everyone sees the alarm + fix room; the saboteur's id stays hidden" do
      match_id = start_server()
      assert :ok = Server.submit_intent(match_id, "p1", {:sabotage, :lights})

      {:ok, view} = Server.view_for(match_id, "p2")
      assert view.sabotage == %{kind: :lights, fix_room: "Electrical"}
      refute Map.has_key?(view.sabotage, :by)
    end
  end
end
