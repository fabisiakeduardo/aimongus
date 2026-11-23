defmodule Aimongus.Game.RolesTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.Server
  alias Aimongus.Game.Map, as: GameMap

  # Same Cafeteria/MedBay layout as server_test/meeting_test: corridor
  # door at (6, 2), tasks T1 {2,2} / T2 {2,3}, button B at {2,4}.
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

  # roles zip onto sorted ids with shuffle_roles: false — p1 sheriff,
  # p2 impostor, p3 medic, p4 crewmate alone in MedBay.
  defp default_players do
    [
      %{id: "p1", pos: {4, 2}},
      %{id: "p2", pos: {5, 2}},
      %{id: "p3", pos: {4, 3}},
      %{id: "p4", pos: {8, 3}}
    ]
  end

  defp start_server(config) do
    match_id = "roles-test-#{System.unique_integer([:positive])}"

    config =
      %{
        map: test_map(),
        players: default_players(),
        roles: [:sheriff, :impostor, :medic, :crewmate],
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

  defp start_running(config \\ %{}) do
    match_id = start_server(config)
    :ok = Server.start_match(match_id)
    match_id
  end

  describe "investigate (sheriff)" do
    test "returns a private hint reply; spectators get a hint event" do
      id = start_running()

      assert {:ok, {:hint, "p2", :suspicious}} =
               Server.submit_intent(id, "p1", {:investigate, "p2"})

      # god-view spectators see the hint on the match topic; agents only
      # ever receive the reply
      assert_received {:hint, "p1", "p2", :suspicious}

      state = Server.state(id)
      assert state.players["p1"].ability_ready_at > state.tick
    end

    test "impostors and the serial killer read suspicious; everyone else innocent" do
      id =
        start_running(%{
          players: [
            %{id: "p1", pos: {4, 2}},
            %{id: "p2", pos: {5, 2}},
            %{id: "p3", pos: {4, 3}},
            %{id: "p4", pos: {3, 3}},
            %{id: "p5", pos: {5, 3}},
            %{id: "p6", pos: {3, 4}}
          ],
          roles: [:sheriff, :impostor, :serial_killer, :medic, :jester, :vigilante],
          investigate_cooldown_ticks: 0
        })

      assert {:ok, {:hint, "p2", :suspicious}} =
               Server.submit_intent(id, "p1", {:investigate, "p2"})

      assert {:ok, {:hint, "p3", :suspicious}} =
               Server.submit_intent(id, "p1", {:investigate, "p3"})

      assert {:ok, {:hint, "p4", :innocent}} =
               Server.submit_intent(id, "p1", {:investigate, "p4"})

      assert {:ok, {:hint, "p5", :innocent}} =
               Server.submit_intent(id, "p1", {:investigate, "p5"})

      assert {:ok, {:hint, "p6", :innocent}} =
               Server.submit_intent(id, "p1", {:investigate, "p6"})
    end

    test "rejects non-sheriffs, self, and unknown or out-of-range targets" do
      id = start_running()

      # p3 is a medic, not a sheriff
      assert {:rejected, :cannot_investigate} =
               Server.submit_intent(id, "p3", {:investigate, "p2"})

      # investigating yourself is pointless
      assert {:rejected, :cannot_investigate} =
               Server.submit_intent(id, "p1", {:investigate, "p1"})

      assert {:rejected, :unknown_target} =
               Server.submit_intent(id, "p1", {:investigate, "ghost"})

      # p4 sits in MedBay ~4.1 tiles away — beyond investigate_range
      assert {:rejected, :out_of_range} =
               Server.submit_intent(id, "p1", {:investigate, "p4"})
    end

    test "rejects on cooldown with the remaining ticks" do
      id = start_running(%{investigate_cooldown_ticks: 10})

      assert {:ok, {:hint, "p2", :suspicious}} =
               Server.submit_intent(id, "p1", {:investigate, "p2"})

      assert {:rejected, {:cooldown, 10}} =
               Server.submit_intent(id, "p1", {:investigate, "p3"})
    end

    test "dead sheriffs cannot investigate; dead targets cannot be investigated" do
      id =
        start_running(%{
          players: default_players() ++ [%{id: "p5", pos: {8, 2}}],
          roles: [:sheriff, :impostor, :medic, :crewmate, :crewmate],
          kill_cooldown_ticks: 0
        })

      :ok = Server.submit_intent(id, "p2", {:kill, "p3"})
      assert_received {:killed, "p3", "p2", _}

      assert {:rejected, :target_dead} =
               Server.submit_intent(id, "p1", {:investigate, "p3"})

      :ok = Server.submit_intent(id, "p2", {:kill, "p1"})
      assert_received {:killed, "p1", "p2", _}

      assert {:rejected, :dead} =
               Server.submit_intent(id, "p1", {:investigate, "p2"})
    end
  end

  describe "protect (medic)" do
    test "shields a target for the configured window" do
      id = start_running(%{protect_duration_ticks: 25})

      assert :ok = Server.submit_intent(id, "p3", {:protect, "p1"})
      assert_received {:protected, "p3", "p1"}

      state = Server.state(id)
      assert state.players["p1"].protected_until == state.tick + 25
    end

    test "a kill on a protected target is blocked — shield and cooldown spent" do
      id = start_running(%{protect_duration_ticks: 30, kill_cooldown_ticks: 40})

      :ok = Server.submit_intent(id, "p3", {:protect, "p1"})
      assert_received {:protected, "p3", "p1"}

      assert {:rejected, :blocked} = Server.submit_intent(id, "p2", {:kill, "p1"})
      assert_received {:kill_blocked, "p1"}
      refute_received {:killed, _, _, _}

      state = Server.state(id)
      # the shield held: victim lives, protection consumed, no body, and
      # the attacker's kill cooldown still ticks (the attempt happened)
      assert state.players["p1"].alive?
      assert state.players["p1"].protected_until == nil
      assert state.players["p2"].kill_ready_at == state.tick + 40
      assert state.bodies == []
    end

    test "the shield lapses: once the window passes the next kill lands" do
      id = start_running(%{protect_duration_ticks: 2})

      :ok = Server.submit_intent(id, "p3", {:protect, "p1"})
      assert_received {:protected, "p3", "p1"}

      # tick advances past the protection window
      Server.step(id)
      Server.step(id)

      assert :ok = Server.submit_intent(id, "p2", {:kill, "p1"})
      assert_received {:killed, "p1", "p2", {4, 2}}
    end

    test "rejects non-medics, unknown or out-of-range targets, and cooldown" do
      id = start_running(%{protect_cooldown_ticks: 10})

      # p1 is a sheriff, not a medic
      assert {:rejected, :cannot_protect} =
               Server.submit_intent(id, "p1", {:protect, "p2"})

      assert {:rejected, :unknown_target} =
               Server.submit_intent(id, "p3", {:protect, "ghost"})

      # p4 is ~4.1 tiles out in MedBay
      assert {:rejected, :out_of_range} =
               Server.submit_intent(id, "p3", {:protect, "p4"})

      # self-protection is legal — shields the medic and starts the cooldown
      assert :ok = Server.submit_intent(id, "p3", {:protect, "p3"})
      assert Server.state(id).players["p3"].protected_until != nil

      assert {:rejected, {:cooldown, 10}} =
               Server.submit_intent(id, "p3", {:protect, "p1"})
    end

    test "dead medics cannot protect; dead players cannot be protected" do
      id =
        start_running(%{
          players: default_players() ++ [%{id: "p5", pos: {8, 2}}],
          roles: [:sheriff, :impostor, :medic, :crewmate, :crewmate],
          kill_cooldown_ticks: 0
        })

      :ok = Server.submit_intent(id, "p2", {:kill, "p1"})
      assert_received {:killed, "p1", "p2", _}

      assert {:rejected, :target_dead} =
               Server.submit_intent(id, "p3", {:protect, "p1"})

      :ok = Server.submit_intent(id, "p2", {:kill, "p3"})
      assert_received {:killed, "p3", "p2", _}

      assert {:rejected, :dead} = Server.submit_intent(id, "p3", {:protect, "p4"})
    end
  end

  describe "vigilante" do
    test "the single shot works once; the second kill intent is :already_used" do
      id =
        start_running(%{
          roles: [:vigilante, :crewmate, :impostor, :crewmate],
          kill_cooldown_ticks: 0
        })

      assert :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", {5, 2}}
      assert Server.state(id).players["p1"].vigilante_shot_used?

      # p3 is in range — the rejection is the spent shot, not geometry
      assert {:rejected, :already_used} = Server.submit_intent(id, "p1", {:kill, "p3"})
    end

    test "a blocked vigilante shot is still spent" do
      id =
        start_running(%{
          roles: [:vigilante, :crewmate, :medic, :impostor],
          protect_duration_ticks: 30,
          kill_cooldown_ticks: 0
        })

      :ok = Server.submit_intent(id, "p3", {:protect, "p2"})
      assert_received {:protected, "p3", "p2"}

      assert {:rejected, :blocked} = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:kill_blocked, "p2"}

      assert {:rejected, :already_used} = Server.submit_intent(id, "p1", {:kill, "p3"})
    end
  end

  describe "jester" do
    test "ejecting the jester is an immediate solo win" do
      id = start_running(%{roles: [:impostor, :crewmate, :jester, :crewmate]})

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", _}

      :ok = Server.submit_intent(id, "p3", :report)
      assert_received {:meeting_started, {:report, "p3"}}

      for speaker <- ["p1", "p3", "p4"] do
        assert_received {:speak_request, ^speaker}
        :ok = Server.submit_intent(id, speaker, {:speak, "#{speaker} speaks"})
      end

      assert_received :voting_started

      :ok = Server.submit_intent(id, "p1", {:vote, "p3"})
      :ok = Server.submit_intent(id, "p3", {:vote, "p1"})
      :ok = Server.submit_intent(id, "p4", {:vote, "p3"})

      assert_received {:ejected, "p3", :jester}
      assert_received {:game_over, {:solo, "p3"}}

      state = Server.state(id)
      assert state.phase == :game_over
      assert state.winner == {:solo, "p3"}
      refute state.players["p3"].alive?
    end
  end

  describe "blind impostors" do
    test "an impostor can kill the other impostor — friendly fire is on" do
      id =
        start_running(%{
          players: default_players() ++ [%{id: "p5", pos: {8, 2}}],
          roles: [:impostor, :impostor, :crewmate, :crewmate, :crewmate]
        })

      assert :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", {5, 2}}

      state = Server.state(id)
      refute state.players["p2"].alive?
      # one impostor vs two crew — the match continues
      assert state.phase == :free_roam
    end
  end

  describe "serial killer" do
    test "last one standing is a solo win" do
      id =
        start_running(%{
          players: [
            %{id: "p1", pos: {4, 2}},
            %{id: "p2", pos: {5, 2}},
            %{id: "p3", pos: {4, 3}}
          ],
          roles: [:serial_killer, :crewmate, :crewmate],
          kill_cooldown_ticks: 0
        })

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", _}
      refute_received {:game_over, _}

      :ok = Server.submit_intent(id, "p1", {:kill, "p3"})
      assert_received {:killed, "p3", "p1", _}
      assert_received {:game_over, {:solo, "p1"}}

      assert Server.state(id).winner == {:solo, "p1"}
    end
  end

  describe "phase gating" do
    test "ability intents are free-roam only" do
      id = start_running()

      :ok = Server.submit_intent(id, "p2", {:kill, "p1"})
      assert_received {:killed, "p1", "p2", _}

      :ok = Server.submit_intent(id, "p3", :report)
      assert_received {:meeting_started, {:report, "p3"}}

      assert {:rejected, :wrong_phase} =
               Server.submit_intent(id, "p3", {:investigate, "p2"})

      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p3", {:protect, "p4"})
    end
  end
end
