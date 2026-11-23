defmodule Aimongus.Game.WhisperTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.Server
  alias Aimongus.Game.Map, as: GameMap

  # Same layout as server_test: Cafeteria (C) / MedBay (M) joined by a
  # one-tile corridor at (6, 2). Emergency button at {2, 4}.
  #
  # Whisper geometry (whisper_radius 3.0, Euclidean):
  #   p1 {4, 2} — hears whispers from p2 (d 1) and p3 (d 1)
  #   p2 {5, 2} — audience from p1's spot: p1 (d 1), p3 (d ~1.41)
  #   p3 {4, 3} — ditto
  #   p4 {8, 3} — MedBay: ~3.16+ from every Cafeteria seat — never hears
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

  defp start_running(config \\ %{}) do
    match_id = "whisper-test-#{System.unique_integer([:positive])}"

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
    :ok = Server.start_match(match_id)
    match_id
  end

  describe "audience" do
    test "living players inside whisper_radius hear it — the event lists exactly who" do
      id = start_running()

      assert :ok = Server.submit_intent(id, "p2", {:whisper, "meet at nav", nil})

      # p1 ~1 tile, p3 ~1.41 tiles; p4 sits in MedBay ~3.16 tiles out.
      # The addressee is nil — an untargeted whisper.
      assert_received {:whisper, "p2", nil, audience, "meet at nav"}
      assert audience == ["p1", "p3"]
    end

    test "a named target inside the radius is the recorded addressee and hears it" do
      id = start_running()

      assert :ok = Server.submit_intent(id, "p1", {:whisper, "psst", "p3"})

      # everyone in radius hears; the event keeps who was *addressed*
      # (p3) distinct from who *heard* (p2, p3) so the UI can show both
      assert_received {:whisper, "p1", "p3", ["p2", "p3"], "psst"}
    end

    test "a named target outside the radius is addressed but does not hear (radius wins)" do
      id = start_running()

      assert :ok = Server.submit_intent(id, "p1", {:whisper, "follow me", "p4"})

      # p4 was addressed but is ~4.1 tiles out — not in the audience
      assert_received {:whisper, "p1", "p4", ["p2", "p3"], "follow me"}
    end

    test "nobody in range still emits the event with an empty audience" do
      id = start_running()

      assert :ok = Server.submit_intent(id, "p4", {:whisper, "anyone?", "p1"})
      assert_received {:whisper, "p4", "p1", [], "anyone?"}
    end

    test "dead players do not hear whispers" do
      id = start_running()

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", _pos}

      assert :ok = Server.submit_intent(id, "p3", {:whisper, "p2 is dead", nil})
      # p1 alone is in range; the late p2 hears nothing as a ghost
      assert_received {:whisper, "p3", nil, ["p1"], "p2 is dead"}
    end
  end

  describe "validation" do
    test "the two-element form {:whisper, text} is an untargeted whisper" do
      id = start_running()

      assert :ok = Server.submit_intent(id, "p2", {:whisper, "hello"})
      assert_received {:whisper, "p2", nil, ["p1", "p3"], "hello"}
    end

    test "a dead speaker cannot whisper — ghosts don't touch the living" do
      id = start_running()

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", _pos}

      assert {:rejected, :dead} = Server.submit_intent(id, "p2", {:whisper, "boo", "p3"})
      refute_received {:whisper, "p2", _, _, _}
    end

    test "an addressee that is not a player is rejected" do
      id = start_running()

      assert {:rejected, :unknown_target} =
               Server.submit_intent(id, "p1", {:whisper, "hi", "nobody"})

      refute_received {:whisper, "p1", _, _, _}
    end

    test "addressing a dead player is rejected" do
      id = start_running()

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      assert_received {:killed, "p2", "p1", _pos}

      assert {:rejected, :target_dead} =
               Server.submit_intent(id, "p3", {:whisper, "sorry", "p2"})
    end

    test "empty, oversized, or non-binary text is rejected" do
      id = start_running()

      assert {:rejected, :invalid_text} = Server.submit_intent(id, "p1", {:whisper, "", nil})

      assert {:rejected, :invalid_text} =
               Server.submit_intent(id, "p1", {:whisper, String.duplicate("x", 501), nil})

      assert {:rejected, :invalid_text} = Server.submit_intent(id, "p1", {:whisper, 42, nil})
    end

    test "whispering is a free-roam intent — meetings reject it as wrong_phase" do
      id = start_running()

      :ok = Server.submit_intent(id, "p1", {:kill, "p2"})
      :ok = Server.submit_intent(id, "p3", :report)
      assert_received {:meeting_started, _reason}

      assert {:rejected, :wrong_phase} = Server.submit_intent(id, "p1", {:whisper, "psst", "p3"})
    end
  end

  describe "cooldown" do
    test "a speaker is limited to one whisper per whisper_cooldown_ticks" do
      id = start_running(%{whisper_cooldown_ticks: 5})

      assert :ok = Server.submit_intent(id, "p1", {:whisper, "first", nil})
      assert_received {:whisper, "p1", nil, _, "first"}

      # spamming every poll tick is throttled — the rejection reports the wait
      assert {:rejected, {:cooldown, left}} =
               Server.submit_intent(id, "p1", {:whisper, "second", nil})

      assert left > 0
      refute_received {:whisper, "p1", nil, _, "second"}

      # the cooldown is per-speaker: p2 whispers freely meanwhile
      assert :ok = Server.submit_intent(id, "p2", {:whisper, "meanwhile", nil})
      assert_received {:whisper, "p2", nil, _, "meanwhile"}

      # after the cooldown elapses the speaker may whisper again
      for _ <- 1..5, do: Server.step(id)
      assert :ok = Server.submit_intent(id, "p1", {:whisper, "third", nil})
      assert_received {:whisper, "p1", nil, _, "third"}
    end
  end
end
