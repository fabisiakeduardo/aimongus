defmodule Aimongus.Match.ManagerTest do
  use ExUnit.Case, async: true

  alias Aimongus.Match.Manager
  alias Aimongus.Game.Server
  alias Aimongus.Game.Map, as: GameMap
  alias Aimongus.Replay
  alias Aimongus.Replay.Recorder

  # Same layout as the game tests: Cafeteria (C) / MedBay (M) joined by a
  # one-tile corridor at (6, 2). Emergency button at {2, 4}.
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

  defp players do
    [
      %{id: "red", pos: {4, 2}},
      %{id: "blue", pos: {5, 2}},
      %{id: "green", pos: {8, 3}}
    ]
  end

  defp unique_id, do: "mgr-#{System.unique_integer([:positive])}"

  # A manager driven by tiny deterministic matches: no agent processes,
  # no recorder, the stall cap ending each match on its first 10ms tick.
  # Each gets a unique via-tuple name — registering the default
  # `Aimongus.Match.Manager` atom would collide across async tests
  # (tests hold the pid anyway; only the admin endpoint needs the
  # global name).
  defp start_manager(opts) do
    opts =
      [
        match_id: unique_id(),
        name:
          {:via, Registry,
           {Aimongus.MatchRegistry, {:manager, System.unique_integer([:positive])}}},
        players: players(),
        agents: false,
        record: false,
        inter_match_seconds: 0.05,
        game_config: %{
          map: test_map(),
          roles: [:impostor, :crewmate, :crewmate],
          shuffle_roles: false,
          tasks_per_player: 2
        }
      ]
      |> Keyword.merge(opts)

    start_supervised!({Manager, opts})
  end

  defp game_pid(match_id) do
    case Registry.lookup(Aimongus.MatchRegistry, match_id) do
      [{pid, _value}] -> pid
      _other -> nil
    end
  end

  defp broadcast(match_id, event) do
    Phoenix.PubSub.broadcast(Aimongus.PubSub, "match:#{match_id}", event)
  end

  # Polls `fun` every 10ms until it returns a truthy value (or ~3s pass).
  defp eventually(fun, tries \\ 300) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(10)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "aimongus-mgr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  # Records `events` on `match_id` into `dir` — the file the replay
  # fallback then picks up.
  defp record_script(dir, match_id, events) do
    {:ok, rec} = Recorder.start_link(match_id, dir: dir)
    path = Recorder.path(rec)

    for event <- events, do: broadcast(match_id, event)

    _ = :sys.get_state(rec)
    :ok = Recorder.stop(rec)
    path
  end

  describe "live match loop" do
    test "starts a match and a new one follows game_over after the interval" do
      match_id = unique_id()

      mgr =
        start_manager(
          match_id: match_id,
          game_config: %{
            map: test_map(),
            roles: [:impostor, :crewmate, :crewmate],
            shuffle_roles: false,
            tasks_per_player: 2,
            auto_tick: true,
            tick_ms: 10,
            # the stall cap ends the match on its first tick
            match_max_seconds: 0
          }
        )

      pid1 = eventually(fn -> game_pid(match_id) end)
      assert is_pid(pid1)
      assert Manager.status(mgr).mode in [:live, :waiting]

      # game_over (stall cap) → inter-match wait → a fresh GameServer
      # registers under the same match id
      pid2 =
        eventually(fn ->
          case game_pid(match_id) do
            pid when is_pid(pid) and pid != pid1 -> pid
            _other -> nil
          end
        end)

      assert is_pid(pid2)
      assert Process.alive?(pid2)
    end

    test "players join with the configured ids and random personalities" do
      match_id = unique_id()
      start_manager(match_id: match_id, autostart: true)

      assert eventually(fn ->
               case game_pid(match_id) do
                 nil -> nil
                 _pid -> Server.state(match_id)
               end
             end)

      state = Server.state(match_id)
      assert Map.keys(state.players) |> Enum.sort() == ["blue", "green", "red"]

      assert Enum.all?(state.players, fn {_id, p} ->
               match?(%Aimongus.Game.Personality{}, p.personality)
             end)
    end

    test "an external game_over broadcast also triggers the restart loop" do
      match_id = unique_id()
      start_manager(match_id: match_id, game_config: %{map: test_map(), auto_tick: false})

      pid1 = eventually(fn -> game_pid(match_id) end)
      assert is_pid(pid1)

      broadcast(match_id, {:game_over, :crew})

      pid2 =
        eventually(fn ->
          case game_pid(match_id) do
            pid when is_pid(pid) and pid != pid1 -> pid
            _other -> nil
          end
        end)

      assert is_pid(pid2)
    end
  end

  describe "budget guard" do
    test "llm_call casts accrue spend at the configured per-adapter cost" do
      mgr =
        start_manager(
          budget_usd: 10.0,
          call_costs: %{Aimongus.LLM.OpenRouter => 0.25, Aimongus.LLM.DevinCLI => 0.0}
        )

      GenServer.cast(mgr, {:llm_call, Aimongus.LLM.OpenRouter, []})
      GenServer.cast(mgr, {:llm_call, Aimongus.LLM.OpenRouter, []})
      GenServer.cast(mgr, {:llm_call, Aimongus.LLM.DevinCLI, []})
      _ = Manager.status(mgr)

      assert Manager.status(mgr).spent == 0.5
    end

    test "per-model cost maps charge the model's rate, defaulting per adapter" do
      mgr =
        start_manager(
          budget_usd: 10.0,
          call_costs: %{
            Aimongus.LLM.OpenRouter => %{"smart/model" => 0.10, default: 0.01}
          }
        )

      GenServer.cast(mgr, {:llm_call, Aimongus.LLM.OpenRouter, model: "smart/model"})
      GenServer.cast(mgr, {:llm_call, Aimongus.LLM.OpenRouter, model: "cheap/model"})
      _ = Manager.status(mgr)

      assert Manager.status(mgr).spent == 0.11
    end

    test "an exhausted budget starts a replay instead of a live match" do
      dir = tmp_dir()
      match_id = unique_id()

      # recorded under a throwaway id — the manager re-broadcasts it on
      # its own match topic, so subscribing first races nothing
      path =
        record_script(dir, unique_id(), [
          {:player_joined, "red", "Red", {4, 2}},
          :match_started
        ])

      Phoenix.PubSub.subscribe(Aimongus.PubSub, "match:#{match_id}")

      mgr =
        start_manager(
          match_id: match_id,
          budget_usd: 0.0,
          replay_dir: dir,
          replay_speed: 50
        )

      assert eventually(fn -> Manager.status(mgr).mode == :replay end)
      assert game_pid(match_id) == nil

      assert_receive {:player_joined, "red", "Red", {4, 2}}, 2_000
      assert_receive :match_started, 2_000

      assert Replay.list(dir) |> Enum.map(& &1.path) == [path]
    end

    test "budget exhaustion applies to the NEXT match, not the running one" do
      dir = tmp_dir()
      match_id = unique_id()
      record_script(dir, unique_id(), [:match_started])

      mgr =
        start_manager(
          match_id: match_id,
          budget_usd: 0.01,
          call_costs: %{Aimongus.LLM.OpenRouter => 1.0},
          replay_dir: dir,
          replay_speed: 50,
          game_config: %{map: test_map(), auto_tick: false}
        )

      # first match is already live — the spend lands mid-match
      assert eventually(fn -> game_pid(match_id) != nil end)
      GenServer.cast(mgr, {:llm_call, Aimongus.LLM.OpenRouter, []})
      _ = Manager.status(mgr)

      broadcast(match_id, {:game_over, :impostors})

      assert eventually(fn -> Manager.status(mgr).mode == :replay end)
      assert game_pid(match_id) == nil
    end
  end

  describe "replay fallback" do
    test "no configured adapters → replay, never a live match" do
      dir = tmp_dir()
      match_id = unique_id()
      record_script(dir, unique_id(), [{:player_joined, "red", "Red", {4, 2}}])

      Phoenix.PubSub.subscribe(Aimongus.PubSub, "match:#{match_id}")

      mgr =
        start_manager(
          match_id: match_id,
          agents: true,
          adapter_lookup: fn _id -> nil end,
          replay_dir: dir,
          replay_speed: 50
        )

      assert eventually(fn -> Manager.status(mgr).mode == :replay end)
      assert game_pid(match_id) == nil
      assert_receive {:player_joined, "red", "Red", {4, 2}}, 2_000
    end

    test "with no recordings the manager idles and retries" do
      match_id = unique_id()

      mgr =
        start_manager(
          match_id: match_id,
          budget_usd: 0.0,
          replay_dir: tmp_dir(),
          idle_retry_ms: 40
        )

      assert eventually(fn -> Manager.status(mgr).mode == :idle end)
      assert game_pid(match_id) == nil
    end
  end

  describe "new_match/1" do
    test "restarts the loop immediately without waiting out the interval" do
      match_id = unique_id()
      mgr = start_manager(match_id: match_id, inter_match_seconds: 60)

      pid1 = eventually(fn -> game_pid(match_id) end)
      assert is_pid(pid1)

      assert :ok = Manager.new_match(mgr)

      pid2 =
        eventually(fn ->
          case game_pid(match_id) do
            pid when is_pid(pid) and pid != pid1 -> pid
            _other -> nil
          end
        end)

      assert is_pid(pid2)
    end

    test "new_match/2 applies agent_count, roles, and speed overrides" do
      match_id = unique_id()
      mgr = start_manager(match_id: match_id, players: nil, inter_match_seconds: 60)

      pid1 = eventually(fn -> game_pid(match_id) end)
      assert is_pid(pid1)

      assert :ok =
               Manager.new_match(mgr, %{
                 agent_count: 5,
                 roles: [:impostor, :sheriff, :jester, :crewmate, :crewmate],
                 speed: 2.0
               })

      pid2 =
        eventually(fn ->
          case game_pid(match_id) do
            pid when is_pid(pid) and pid != pid1 -> pid
            _other -> nil
          end
        end)

      assert is_pid(pid2)
      state = Server.state(match_id)
      assert map_size(state.players) == 5
      assert state.config.roles == [:impostor, :sheriff, :jester, :crewmate, :crewmate]
      assert state.config.tick_ms == 50
      assert Manager.status(mgr).speed == 2.0
    end
  end
end
