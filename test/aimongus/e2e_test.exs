defmodule Aimongus.E2ETest do
  use AimongusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Aimongus.Agent.Server, as: AgentServer
  alias Aimongus.Game.Map, as: GameMap
  alias Aimongus.Game.Server, as: GameServer
  alias Aimongus.LLM.Stub
  alias Aimongus.Replay
  alias Aimongus.Replay.Recorder

  defp json_reply(reasoning, intent) do
    Jason.encode!(%{reasoning: reasoning, intent: intent})
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "aimongus-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  # Dedicated PubSub collector process so Phoenix.LiveViewTest's own
  # mailbox traffic ({:plug_conn, :sent}, {:push_event, ...}) never mixes
  # with the match event stream.
  defp start_collector(topic) do
    parent = self()

    pid =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(Aimongus.PubSub, topic)
        send(parent, {:collector_ready, self()})
        collector_loop([])
      end)

    assert_receive {:collector_ready, ^pid}, 1_000
    pid
  end

  defp collector_loop(events) do
    receive do
      {:flush, caller, ref} ->
        send(caller, {ref, Enum.reverse(events)})
        collector_loop(events)

      {:wait_for, target, caller, ref} ->
        if target in events do
          send(caller, {ref, Enum.reverse(events)})
          collector_loop(events)
        else
          wait_loop(target, caller, ref, events)
        end

      ev ->
        collector_loop([ev | events])
    end
  end

  defp wait_loop(target, caller, ref, events) do
    receive do
      ^target = ev ->
        next = [ev | events]
        send(caller, {ref, Enum.reverse(next)})
        collector_loop(next)

      ev ->
        wait_loop(target, caller, ref, [ev | events])
    end
  end

  defp wait_collector(pid, target, timeout \\ 5_000) do
    ref = make_ref()
    send(pid, {:wait_for, target, self(), ref})

    receive do
      {^ref, events} -> events
    after
      timeout ->
        send(pid, {:flush, self(), ref})
        got = receive do: ({^ref, evs} -> evs), after: (200 -> [])

        flunk(
          "timed out waiting for #{inspect(target)}; got #{length(got)} events: #{inspect(got)}"
        )
    end
  end

  defp flush_collector(pid) do
    ref = make_ref()
    send(pid, {:flush, self(), ref})
    assert_receive {^ref, events}, 1_000
    events
  end

  defp engine_events(events) do
    Enum.reject(events, &match?({:reasoning, _, _}, &1))
  end

  describe "full scripted match" do
    test "walk -> kill -> report -> discuss -> vote -> eject -> game_over matches replay and LiveView",
         %{conn: conn} do
      match_id = "e2e-#{System.unique_integer([:positive])}"
      replay_dir = tmp_dir()
      map = GameMap.load()

      # Pick 4 deterministic Cafeteria tiles from the real bundled ship map:
      # Red (impostor) starts 3 tiles away from Blue so it genuinely walks
      # via A* before killing; Green starts within vision of Blue to see and
      # report the body; Pink stays nearby to join discussion and vote.
      cafeteria = Map.fetch!(map.rooms, "Cafeteria") |> Enum.sort()

      {bx, by} =
        blue_pos =
        Enum.find(cafeteria, fn {x, y} ->
          Enum.all?([{x - 3, y}, {x - 1, y}, {x + 2, y}], &GameMap.walkable?(map, &1))
        end)

      red_pos = {bx - 3, by}
      green_pos = {bx + 2, by}
      pink_pos = {bx - 1, by}

      # Subscribe via a clean collector BEFORE starting Recorder/GameServer so
      # every event from player_joined through game_over is captured in order.
      live_collector = start_collector("match:#{match_id}")

      recorder =
        start_supervised!(%{
          id: {Recorder, match_id},
          start: {Recorder, :start_link, [match_id, [dir: replay_dir]]}
        })

      replay_path = Recorder.path(recorder)

      # Sorted player ids: Blue, Green, Pink, Red.
      # shuffle_roles: false deals roles in sorted-id order, so Red is the sole impostor.
      players = [
        %{id: "Blue", name: "Blue", color: "blue", pos: blue_pos},
        %{id: "Green", name: "Green", color: "green", pos: green_pos},
        %{id: "Pink", name: "Pink", color: "pink", pos: pink_pos},
        %{id: "Red", name: "Red", color: "red", pos: red_pos}
      ]

      _game =
        start_supervised!(%{
          id: {GameServer, match_id},
          start:
            {GameServer, :start_link,
             [
               match_id,
               %{
                 map: map,
                 players: players,
                 roles: [:crewmate, :crewmate, :crewmate, :impostor],
                 shuffle_roles: false,
                 tasks_per_player: 2,
                 kill_cooldown_ticks: 0,
                 speech_rounds: 1,
                 meeting_seconds: 10,
                 vote_seconds: 10,
                 tick_ms: 15,
                 auto_tick: true
               }
             ]}
        })

      # Mount spectator LiveView BEFORE match starts so it watches live.
      {:ok, live_view, _html} = live(conn, "/watch?match=#{match_id}")

      # Phase-aware stateless Stub responders so agents cleanly drive every phase:
      # - Red (impostor): walks to Blue's tile, kills Blue once in range, lies in meeting, votes Green.
      red_respond = fn prompt ->
        cond do
          String.contains?(prompt, "phase voting") ->
            json_reply("deflect suspicion onto Green", %{type: "vote", target: "Green"})

          String.contains?(prompt, "phase meeting") ->
            json_reply("deny everything calmly", %{
              type: "speak",
              text: "I was nowhere near Blue, Green is framing me!"
            })

          String.contains?(prompt, "You are at Cafeteria (#{bx}, #{by}).") ->
            json_reply("in range of Blue, strike now", %{type: "kill", target: "Blue"})

          true ->
            json_reply("walk over to Blue in Cafeteria", %{
              type: "move_to",
              target: [bx, by]
            })
        end
      end

      # - Blue (victim): holds position so Red reliably reaches kill range.
      blue_respond = fn _prompt ->
        json_reply("checking my task list", %{type: "nothing"})
      end

      # - Green (witness): reports Blue's body as soon as it's visible, accuses Red, votes Red.
      green_respond = fn prompt ->
        cond do
          String.contains?(prompt, "phase voting") ->
            json_reply("Red was right on top of the body", %{type: "vote", target: "Red"})

          String.contains?(prompt, "phase meeting") ->
            json_reply("tell everyone I saw Red kill Blue", %{
              type: "speak",
              text: "I saw Red take out Blue right in Cafeteria!"
            })

          String.contains?(prompt, "Bodies in sight:") ->
            json_reply("body spotted — sound the alarm!", %{type: "report"})

          true ->
            json_reply("keep an eye on Cafeteria", %{type: "nothing"})
        end
      end

      # - Pink (crewmate): backs Green in discussion and votes Red out.
      pink_respond = fn prompt ->
        cond do
          String.contains?(prompt, "phase voting") ->
            json_reply("Green's eyewitness report is solid", %{type: "vote", target: "Red"})

          String.contains?(prompt, "phase meeting") ->
            json_reply("confirm Red ran straight at Blue", %{
              type: "speak",
              text: "Agreed, Red beelined straight for Blue. Voting Red."
            })

          true ->
            json_reply("stay put and watch", %{type: "nothing"})
        end
      end

      for {id, responder} <- [
            {"Red", red_respond},
            {"Blue", blue_respond},
            {"Green", green_respond},
            {"Pink", pink_respond}
          ] do
        start_supervised!(
          {AgentServer,
           {match_id, id,
            [
              poll_ms: 40,
              llm_opts: [adapter: Stub, respond: responder]
            ]}}
        )
      end

      :ok = GameServer.start_match(match_id)

      live_events = wait_collector(live_collector, {:game_over, :crew})

      # Ensure Recorder flushed every event including {:game_over, :crew} before stopping.
      _ = :sys.get_state(recorder)
      :ok = Recorder.stop(recorder)

      # 1. Verify the entire social-deduction arc actually occurred.
      assert :match_started in live_events
      assert Enum.any?(live_events, &match?({:moved, "Red", _}, &1))
      assert Enum.any?(live_events, &match?({:killed, "Blue", "Red", _}, &1))
      assert Enum.any?(live_events, &match?({:body_reported, "Green", _}, &1))
      assert Enum.any?(live_events, &match?({:meeting_started, {:report, "Green"}}, &1))
      assert Enum.any?(live_events, &match?({:spoke, "Green", _}, &1))
      assert Enum.any?(live_events, &match?({:spoke, "Pink", _}, &1))
      assert Enum.any?(live_events, &match?({:spoke, "Red", _}, &1))
      assert :voting_started in live_events
      assert Enum.any?(live_events, &match?({:voted, "Green", "Red"}, &1))
      assert Enum.any?(live_events, &match?({:voted, "Pink", "Red"}, &1))
      assert Enum.any?(live_events, &match?({:ejected, "Red", :impostor}, &1))
      assert List.last(live_events) == {:game_over, :crew}

      # 2. Verify LiveView reflected the finished match live.
      live_html = render(live_view)
      assert live_html =~ "Game over"
      assert live_html =~ "the Crew wins"
      assert has_element?(live_view, "#gameover-banner")
      assert has_element?(live_view, "#pawn-Red")

      # 3. Verify the recorded replay file matches the live event stream:
      #    - all GameServer events appear in identical strict FIFO order
      #    - all recorded events (including concurrent agent reasoning) match
      {header, recorded} = Replay.read(replay_path)
      assert header["match_id"] == match_id
      recorded_events = Enum.map(recorded, fn {_t, ev} -> ev end)

      # Truncate any reasoning events that raced in after :game_over.
      recorded_through_end =
        Enum.take_while(recorded_events, &(&1 != {:game_over, :crew})) ++ [{:game_over, :crew}]

      assert engine_events(recorded_through_end) == engine_events(live_events)
      assert Enum.sort(recorded_through_end) == Enum.sort(live_events)

      # 4. Play back the recording onto a brand-new topic with NO GameServer running
      #    and verify both the re-emitted stream and a SpectateLive watching the replay.
      replay_match_id = "e2e-replay-#{System.unique_integer([:positive])}"
      replay_collector = start_collector("match:#{replay_match_id}")
      {:ok, replay_view, _html} = live(conn, "/watch?match=#{replay_match_id}")

      {:ok, player_pid} =
        Replay.play(replay_path, speed: 1000.0, topic: "match:#{replay_match_id}")

      ref = Process.monitor(player_pid)
      assert_receive {:DOWN, ^ref, :process, ^player_pid, :normal}, 2_000

      replayed_events = flush_collector(replay_collector)
      assert replayed_events == recorded_events

      replay_html = render(replay_view)
      assert replay_html =~ "the Crew wins"
      assert has_element?(replay_view, "#gameover-banner")
      assert has_element?(replay_view, "#pawn-Red")
      assert has_element?(replay_view, "#pawn-Blue")
    end
  end
end
