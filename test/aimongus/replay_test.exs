defmodule Aimongus.ReplayTest do
  use ExUnit.Case, async: true

  alias Aimongus.Replay
  alias Aimongus.Replay.{Codec, Player, Recorder}

  # Every event shape the Game.Server moduledoc broadcasts on
  # `match:<id>`, plus the spectator-only `{:reasoning, ...}` event the
  # AgentServer adds on the same topic. Positions are tuples, roles are
  # atoms, whisper audiences are lists — the codec must survive all of it.
  @events [
    {:player_joined, "p1", "Red", {4, 2}},
    {:player_joined, "p2", "Blue", {5, 2}},
    :match_started,
    {:role_assigned, "p1", :impostor},
    {:role_assigned, "p2", :crewmate},
    {:moved, "p2", {5, 3}},
    {:task_progress, "p2", "T1", 50},
    {:task_done, "p2", "T1"},
    {:killed, "p2", "p1", {6, 2}},
    {:kill_blocked, "p3"},
    {:hint, "p4", "p1", :suspicious},
    {:hint, "p4", "p2", :innocent},
    {:protected, "p4", "p3"},
    {:body_reported, "p3", {6, 2}},
    {:button_pressed, "p3"},
    :meeting_called,
    {:meeting_started, {:report, "p3"}},
    {:meeting_started, {:button, "p1"}},
    {:speak_request, "p1"},
    {:spoke, "p1", "i was in medbay the whole time"},
    {:spoke, "p2", nil},
    :voting_started,
    {:voted, "p1", "p2"},
    {:voted, "p2", :skip},
    {:ejected, "p2", :crewmate},
    {:ejected, "p9", nil},
    :no_ejection,
    :meeting_ended,
    {:whisper, "p1", "p2", ["p1", "p2"], "meet me in nav"},
    {:whisper, "p1", nil, ["p1"], "muttering to myself"},
    {:reasoning, "p1", "p2 was nowhere near the body"},
    {:match_timeout, :impostors},
    {:game_over, :crew},
    {:game_over, :impostors},
    {:game_over, {:solo, "p5"}}
  ]

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "aimongus-replays-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp broadcast(match_id, event) do
    Phoenix.PubSub.broadcast(Aimongus.PubSub, "match:#{match_id}", event)
  end

  # Records @events on `match_id` into `dir`, returns the file path.
  defp record_script(dir, match_id, events \\ @events) do
    {:ok, rec} = Recorder.start_link(match_id, dir: dir)
    path = Recorder.path(rec)

    for event <- events, do: broadcast(match_id, event)

    # sync the recorder's mailbox so every event is on disk before close
    _ = :sys.get_state(rec)
    :ok = Recorder.stop(rec)
    path
  end

  defp receive_n(0, acc), do: Enum.reverse(acc)

  defp receive_n(n, acc) do
    receive do
      event -> receive_n(n - 1, [event | acc])
    after
      2_000 -> flunk("timed out waiting for replayed event #{inspect(acc)}")
    end
  end

  describe "Codec" do
    test "roundtrips every game event type through JSON" do
      for event <- @events do
        decoded =
          event
          |> Codec.encode()
          |> Jason.encode!()
          |> Jason.decode!()
          |> Codec.decode()

        assert decoded == event, "roundtrip failed for #{inspect(event)}"
      end
    end

    test "roundtrips maps, floats and nested terms" do
      terms = [
        %{"b" => {2, 3}, :c => [:d], a: 1},
        %{"t" => "a string key that looks like a tag"},
        [1, "two", :three, {4, 5}],
        3.14,
        {:nested, {:deeply, {:tuples, :ok}}}
      ]

      for term <- terms do
        assert term ==
                 term |> Codec.encode() |> Jason.encode!() |> Jason.decode!() |> Codec.decode()
      end
    end
  end

  describe "Recorder" do
    test "writes a header line then one JSONL line per broadcast event" do
      dir = tmp_dir()
      match_id = "rec-#{System.unique_integer([:positive])}"
      path = record_script(dir, match_id)

      assert Path.dirname(path) == dir
      assert Path.basename(path) =~ match_id

      {header, events} = Replay.read(path)

      assert header["match_id"] == match_id
      assert is_binary(header["recorded_at"])

      assert Enum.map(events, &elem(&1, 1)) == @events

      offsets = Enum.map(events, &elem(&1, 0))
      assert offsets == Enum.sort(offsets)
      assert Enum.all?(offsets, &(is_integer(&1) and &1 >= 0))
    end

    test "keeps recording under the same file across its lifetime" do
      dir = tmp_dir()
      match_id = "rec-#{System.unique_integer([:positive])}"
      {:ok, rec} = Recorder.start_link(match_id, dir: dir)
      path = Recorder.path(rec)

      broadcast(match_id, :match_started)
      _ = :sys.get_state(rec)
      broadcast(match_id, {:moved, "p1", {1, 1}})
      _ = :sys.get_state(rec)
      :ok = Recorder.stop(rec)

      {_header, events} = Replay.read(path)
      assert Enum.map(events, &elem(&1, 1)) == [:match_started, {:moved, "p1", {1, 1}}]
    end
  end

  describe "Player" do
    test "re-emits the identical event stream on the recorded match topic" do
      dir = tmp_dir()
      match_id = "play-#{System.unique_integer([:positive])}"
      path = record_script(dir, match_id)

      # subscribing AFTER recording so the mailbox only holds replay output
      Phoenix.PubSub.subscribe(Aimongus.PubSub, "match:#{match_id}")

      {:ok, player} = Player.start_link(path, speed: 1_000)
      ref = Process.monitor(player)

      assert receive_n(length(@events), []) == @events
      assert_receive {:DOWN, ^ref, :process, ^player, :normal}
    end

    test "respects recorded cadence scaled by the speed multiplier" do
      dir = tmp_dir()
      match_id = "pace-#{System.unique_integer([:positive])}"
      path = Path.join(dir, "#{match_id}-paced.jsonl")

      # a synthetic recording with deterministic offsets — recorded
      # bursts land within a few ms, too tight to measure reliably
      header =
        Jason.encode!(%{
          "v" => 1,
          "match_id" => match_id,
          "recorded_at" => "2026-11-22T00:00:00Z"
        })

      lines =
        for {offset, event} <- [
              {0, :match_started},
              {200, {:moved, "p1", {1, 1}}},
              {600, {:moved, "p1", {2, 2}}}
            ] do
          Jason.encode!(%{"t" => offset, "e" => Codec.encode(event)})
        end

      File.write!(path, Enum.join([header | lines], "\n") <> "\n")

      Phoenix.PubSub.subscribe(Aimongus.PubSub, "match:#{match_id}")

      # 4x speed: the 600ms offset should land at ~150ms, not ~600ms
      started = System.monotonic_time(:millisecond)
      {:ok, player} = Player.start_link(path, speed: 4)
      ref = Process.monitor(player)

      assert receive_n(3, []) == [:match_started, {:moved, "p1", {1, 1}}, {:moved, "p1", {2, 2}}]
      elapsed = System.monotonic_time(:millisecond) - started

      # lower bound proves the player actually waits out the cadence
      # (a stream-everything-at-once implementation lands in ~0ms);
      # upper bound proves the multiplier applied (unscaled = ~600ms)
      assert elapsed >= 100
      assert elapsed < 450
      assert_receive {:DOWN, ^ref, :process, ^player, :normal}
    end

    test "notifies :replay_finished when a notify pid is given" do
      dir = tmp_dir()
      match_id = "fin-#{System.unique_integer([:positive])}"
      path = record_script(dir, match_id, [:match_started])

      {:ok, _player} = Player.start_link(path, speed: 100, notify: self())

      assert_receive :replay_finished
    end
  end

  describe "list/1" do
    test "returns replay files with header metadata" do
      dir = tmp_dir()
      match_id = "listed-#{System.unique_integer([:positive])}"
      path = record_script(dir, match_id)

      assert [entry] = Replay.list(dir)
      assert entry.path == path
      assert entry.match_id == match_id
      assert entry.events == length(@events)
    end

    test "returns [] for a missing directory" do
      assert Replay.list(Path.join(System.tmp_dir!(), "no-such-replay-dir")) == []
    end
  end
end
