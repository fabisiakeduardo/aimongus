defmodule Aimongus.Match.Manager do
  @moduledoc """
  Owns the single public match lifecycle: one live match at a time under
  `match_id` (default `"live"` — the id `SpectateLive` watches without a
  `?match=` param), a new one `inter_match_seconds` after every
  `{:game_over, _}`, forever.

  ## What a live match is

    1. a `Aimongus.Replay.Recorder` subscribed to `"match:<id>"` first, so
       even the lobby `player_joined` events land in the recording
    2. a `Aimongus.Game.Server` booted with the configured players
    3. one `Aimongus.Agent.Server` per player — each resolves its own LLM
       adapter through `Aimongus.LLM.Client.adapter_for/1`
       (`Application.get_env(:aimongus, :llm_adapters)`)
    4. `Game.Server.start_match/1`

  Default roster: the nine Among Us colors ("Red", "Blue", ... ) each
  dealt `Aimongus.Game.Personality.random/0` at every match start, roles
  from `config.roles` (the engine's 9-player default when unset).

  ## Budget guard

  `DAILY_LLM_BUDGET_USD` caps LLM spend per UTC day (unset/empty =
  unlimited — the dev default). Every adapter call is counted
  (`Aimongus.LLM.Client.complete/3` reports via `track_call/2`) at a
  per-adapter rate from `config :aimongus, :llm_call_costs` — a number,
  or a `%{model => cost, default: cost}` map for per-model pricing.
  `DevinCLI`/`Stub` are $0 (dev/test spend nothing). When `spent >=
  budget` the manager starts no new live match — a *running* match is
  never cut off; exhaustion applies to the next decide. Spend resets
  automatically on the first decision of a new UTC day. **Limitation:**
  `spent` is in-memory — a manager crash or node restart reverts the
  day's tally to $0, so the budget is a circuit breaker against runaway
  cost, not accounting.

  ## Replay fallback

  Whenever a live match can't run — budget exhausted, or no adapter
  configured for the roster — the manager picks a random recording from
  the ten most recent in `:replay_dir` (default `Aimongus.Replay.dir/0`)
  and `Replay.play`s it with `topic: "match:<match_id>"` so spectators
  at `/watch` see it exactly like the live match. When the replay ends
  the manager decides again (a new UTC day may have unblocked live
  play); with no recordings at all it idles and retries every
  `:idle_retry_ms`.

  ## Admin control

  `new_match/1` tears down whatever is running and decides again —
  `AimongusWeb.AdminController` exposes it at `POST /admin/new-match`
  behind `AIMONGUS_ADMIN_TOKEN`.

  ## Options (`start_link/1`; also read from `config :aimongus, __MODULE__`)

    * `:match_id` — registry key + PubSub topic suffix (default `"live"`)
    * `:players` — `Game.Server` player attr maps; defaults to the nine
      color names with a fresh `Personality.random/0` each
    * `:roles` — role list override (default: the engine's mix)
    * `:game_config` — extra `Game.Server` config (map override etc.)
    * `:agents` — spawn `Agent.Server`s (default `true`); `false` runs
      the engine without LLM drivers (dev/tests)
    * `:adapter_lookup` — `fn player_id -> module | nil end` adapter
      resolver used for the "can we run live?" check (default
      `Aimongus.LLM.Client.adapter_for/1`)
    * `:agent_opts` — extra `Agent.Server` opts (e.g. `:llm_opts`)
    * `:record` — attach a `Recorder` to each live match (default `true`)
    * `:recorder_opts` — e.g. `[dir: path]` for the recorder
    * `:inter_match_seconds` — pause between matches (default `30`,
      config `inter_match_seconds`); floats allowed
    * `:replay_dir` — where fallback recordings are found (default
      `Replay.dir/0`)
    * `:replay_speed` — playback multiplier for replays (default `1.0`)
    * `:idle_retry_ms` — re-decide cadence when nothing can run
      (default `60_000`)
    * `:budget_usd` — daily cap override (default:
      `DAILY_LLM_BUDGET_USD`; `nil` = unlimited)
    * `:call_costs` — per-adapter USD-per-call table (default:
      `Application.get_env(:aimongus, :llm_call_costs, %{})`)
    * `:autostart` — decide immediately on boot (default `true`); with
      `false` the manager waits for `new_match/1`
    * `:name` — process name (default `Aimongus.Match.Manager`)
  """

  use GenServer

  require Logger

  alias Aimongus.Agent.Server, as: AgentServer
  alias Aimongus.Game.{Personality, Server}
  alias Aimongus.LLM.Client
  alias Aimongus.Replay
  alias Aimongus.Replay.Recorder

  @default_match_id "live"
  @player_names ~w(Red Blue Green Pink Orange Yellow Black White Purple)
  @default_inter_match_seconds 30
  @default_idle_retry_ms 60_000
  @default_replay_speed 1.0
  # how many of the newest recordings the random replay pick draws from
  @replay_pool 10
  @stop_timeout 5_000

  defstruct match_id: @default_match_id,
            players: nil,
            roles: nil,
            game_config: %{},
            agents?: true,
            adapter_lookup: &Client.adapter_for/1,
            agent_opts: [],
            record?: true,
            recorder_opts: [],
            inter_match_ms: @default_inter_match_seconds * 1_000,
            replay_dir: nil,
            replay_speed: @default_replay_speed,
            idle_retry_ms: @default_idle_retry_ms,
            budget: nil,
            call_costs: %{},
            spent: 0.0,
            spend_day: nil,
            mode: :idle,
            game_pid: nil,
            agent_pids: [],
            recorder_pid: nil,
            replay_pid: nil,
            restart_ref: nil,
            idle_ref: nil

  ## Public API

  @doc "Starts the manager. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Tears down whatever is running and immediately starts the next match
  (or replay, if live play is blocked) — the admin "restart the match"
  control. `{:reply, :ok}` once the new thing is running.
  """
  @spec new_match(GenServer.server()) :: :ok
  def new_match(server \\ __MODULE__), do: GenServer.call(server, :new_match, :infinity)

  @doc """
  A snapshot for admin/observability: `%{mode, match_id, spent, budget,
  players}` — `mode` is `:live`, `:waiting` (between matches), `:replay`
  or `:idle`.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Records one LLM adapter call against today's budget. Called by
  `Aimongus.LLM.Client.complete/3`; a no-op when no manager runs under
  the global name (tests run their own instances and can instead cast
  `{:llm_call, adapter, meta}` directly).
  """
  @spec track_call(module(), keyword()) :: :ok
  def track_call(adapter, meta \\ []) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:llm_call, adapter, meta})
    end

    :ok
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = Application.get_env(:aimongus, __MODULE__, [])

    state = %__MODULE__{
      match_id: opt(opts, config, :match_id, @default_match_id),
      players: Keyword.get(opts, :players),
      roles: opt(opts, config, :roles),
      game_config: Map.new(opt(opts, config, :game_config, %{})),
      agents?: opt(opts, config, :agents, true),
      adapter_lookup: Keyword.get(opts, :adapter_lookup, &Client.adapter_for/1),
      agent_opts: opt(opts, config, :agent_opts, []),
      record?: opt(opts, config, :record, true),
      recorder_opts: opt(opts, config, :recorder_opts, []),
      inter_match_ms:
        seconds_ms(opt(opts, config, :inter_match_seconds, @default_inter_match_seconds)),
      replay_dir: opt(opts, config, :replay_dir, Replay.dir()),
      replay_speed: opt(opts, config, :replay_speed, @default_replay_speed),
      idle_retry_ms: opt(opts, config, :idle_retry_ms, @default_idle_retry_ms),
      budget: opt(opts, config, :budget_usd, env_budget()),
      call_costs:
        opt(opts, config, :call_costs, Application.get_env(:aimongus, :llm_call_costs, %{})),
      spend_day: Date.utc_today()
    }

    Phoenix.PubSub.subscribe(Aimongus.PubSub, topic(state))

    if opt(opts, config, :autostart, true) do
      {:ok, state, {:continue, :decide}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:decide, state), do: {:noreply, decide(state)}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_of(state), state}
  end

  def handle_call(:new_match, _from, state) do
    state = state |> cancel_timers() |> decide()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:llm_call, adapter, meta}, state) do
    state = refresh_day(state)
    {:noreply, %{state | spent: state.spent + cost_for(state, adapter, meta)}}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_info({:game_over, winner}, %{mode: :live} = state) do
    Logger.info("match #{state.match_id} over — winner: #{inspect(winner)}")

    # agents stop now (their registry keys must be free for the next
    # match); the GameServer stays up so spectators keep seeing the
    # final board during the inter-match pause. The recorder stops too:
    # its mailbox already holds :game_over (PubSub dispatch completed
    # before this handle_info ran) and nothing else will arrive.
    state = state |> stop_agents() |> stop_recorder()
    ref = schedule_restart(state)
    {:noreply, %{state | mode: :waiting, restart_ref: ref}}
  end

  # a game_over for a match we already moved past (double broadcast,
  # stale message) — ignore
  def handle_info({:game_over, _winner}, state), do: {:noreply, state}

  # timers carry their ref: cancel_timer can't retract a message already
  # delivered, so a stale :next_match must not force an unscheduled
  # teardown+restart after new_match pivoted
  def handle_info({:next_match, ref}, state) do
    if ref == state.restart_ref do
      {:noreply, decide(%{state | restart_ref: nil})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:retry, ref}, state) do
    if ref == state.idle_ref do
      {:noreply, decide(%{state | idle_ref: nil})}
    else
      {:noreply, state}
    end
  end

  # the GameServer died without broadcasting :game_over — treat it as a
  # match end so the loop survives a crashed engine
  def handle_info({:EXIT, pid, reason}, %{game_pid: pid} = state) do
    unless reason == :normal do
      Logger.warning("match #{state.match_id} engine exited: #{inspect(reason)}")
    end

    state = %{state | game_pid: nil} |> stop_agents() |> stop_recorder()

    case state.mode do
      :live ->
        ref = schedule_restart(state)
        {:noreply, %{state | mode: :waiting, restart_ref: ref}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid in state.agent_pids ->
        Logger.warning("agent #{inspect(pid)} exited: #{inspect(reason)}")
        {:noreply, %{state | agent_pids: List.delete(state.agent_pids, pid)}}

      pid == state.recorder_pid ->
        {:noreply, %{state | recorder_pid: nil}}

      pid == state.replay_pid ->
        # the player is linked — its exit IS the completion signal,
        # already tagged by pid (stale :replay_finished-style races are
        # impossible: this clause only fires for the *current* pid).
        # Normal end or crash both warrant a fresh decision.
        unless reason == :normal do
          Logger.warning("replay #{inspect(pid)} crashed: #{inspect(reason)}")
        end

        {:noreply, decide(%{state | replay_pid: nil})}

      true ->
        {:noreply, state}
    end
  end

  # agent runtime stray task messages, PubSub events we don't act on
  # (player_joined, moved, ...) — all ignored
  def handle_info(_message, state), do: {:noreply, state}

  ## Decisions

  defp decide(state) do
    state = state |> refresh_day() |> teardown()

    cond do
      budget_exhausted?(state) ->
        Logger.info("daily LLM budget exhausted ($#{fmt(state.spent)} / $#{fmt(state.budget)})")
        start_replay(state)

      state.agents? and not adapters_ready?(state) ->
        Logger.warning("no LLM adapter configured for the roster — replaying instead")
        start_replay(state)

      true ->
        start_live(state)
    end
  end

  defp start_live(state) do
    players = roster(state)
    recorder_pid = if state.record?, do: start_recorder(state), else: nil

    config =
      state.game_config
      |> Map.put(:players, players)
      |> put_unless_nil(:roles, state.roles)

    case safe_start(fn -> Server.start_link(state.match_id, config) end) do
      {:ok, game_pid} ->
        agent_pids = if state.agents?, do: start_agents(state, players), else: []

        case safe_start(fn -> Server.start_match(state.match_id) end) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("start_match failed for #{state.match_id}: #{inspect(reason)}")
        end

        Logger.info("match #{state.match_id} live (#{length(players)} players)")

        %{
          state
          | mode: :live,
            game_pid: game_pid,
            agent_pids: agent_pids,
            recorder_pid: recorder_pid,
            replay_pid: nil
        }

      {:error, reason} ->
        Logger.error("could not start match #{state.match_id}: #{inspect(reason)}")
        if recorder_pid, do: safe_stop(recorder_pid)
        start_replay(state)
    end
  end

  defp start_recorder(state) do
    opts = Keyword.put(state.recorder_opts, :dir, replay_record_dir(state))

    case safe_start(fn -> Recorder.start_link(state.match_id, opts) end) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        Logger.error("recorder failed for #{state.match_id}: #{inspect(reason)}")
        nil
    end
  end

  # recordings of the "live" match go to the same dir replays are picked
  # from — every match becomes tomorrow's fallback material
  defp replay_record_dir(state), do: state.replay_dir

  defp start_agents(state, players) do
    for player <- players do
      case safe_start(fn ->
             AgentServer.start_link(state.match_id, player.id, state.agent_opts)
           end) do
        {:ok, pid} ->
          pid

        {:error, reason} ->
          Logger.error("agent #{player.id} failed to start: #{inspect(reason)}")
          nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp start_replay(state) do
    case pick_replay(state) do
      nil ->
        Logger.warning("no replay available — idling #{state.idle_retry_ms}ms")
        %{state | mode: :idle, idle_ref: schedule_idle(state), replay_pid: nil}

      path ->
        opts = [speed: state.replay_speed, topic: topic(state)]

        case safe_start(fn -> Replay.play(path, opts) end) do
          {:ok, pid} ->
            Logger.info("replaying #{Path.basename(path)} on #{topic(state)}")
            %{state | mode: :replay, replay_pid: pid}

          {:error, reason} ->
            Logger.error("replay #{path} failed: #{inspect(reason)}")
            %{state | mode: :idle, idle_ref: schedule_idle(state)}
        end
    end
  end

  defp pick_replay(state) do
    state.replay_dir
    |> Replay.list()
    |> Enum.take(@replay_pool)
    |> case do
      [] -> nil
      pool -> Enum.random(pool).path
    end
  end

  ## Budget

  defp env_budget do
    case System.get_env("DAILY_LLM_BUDGET_USD") do
      nil ->
        nil

      "" ->
        nil

      raw ->
        case Float.parse(raw) do
          {value, _rest} when value >= 0 -> value
          _other -> raise ArgumentError, "DAILY_LLM_BUDGET_USD is not a number: #{raw}"
        end
    end
  end

  defp budget_exhausted?(%{budget: nil}), do: false
  defp budget_exhausted?(%{budget: budget, spent: spent}), do: spent >= budget

  defp refresh_day(%{spend_day: day} = state) do
    if day == Date.utc_today(),
      do: state,
      else: %{state | spent: 0.0, spend_day: Date.utc_today()}
  end

  defp adapters_ready?(state) do
    Enum.all?(roster(state), fn player -> state.adapter_lookup.(player.id) != nil end)
  end

  # `nil` budget means unlimited; a number is the flat per-call rate; a
  # map is per-model with a `:default` key for unlisted models
  defp cost_for(state, adapter, meta) do
    case Map.get(state.call_costs, adapter, Map.get(state.call_costs, :default, 0.0)) do
      rate when is_number(rate) -> rate
      rates when is_map(rates) -> Map.get(rates, meta[:model], Map.get(rates, :default, 0.0))
      _other -> 0.0
    end
  end

  ## Roster

  # Re-rolled per match: the nine color-name players, each with a fresh
  # personality card. `players:` config overrides (tests use pawns with
  # fixed positions).
  defp roster(%{players: nil}) do
    for name <- @player_names do
      %{id: name, name: name, color: String.downcase(name), personality: Personality.random()}
    end
  end

  defp roster(%{players: players}), do: players

  ## Teardown helpers

  defp teardown(state) do
    state
    |> stop_game()
    |> stop_agents()
    |> stop_recorder()
    |> stop_replay()
  end

  defp stop_game(%{game_pid: nil} = state), do: state

  defp stop_game(%{game_pid: pid} = state) do
    safe_stop(pid)
    %{state | game_pid: nil}
  end

  defp stop_agents(%{agent_pids: pids} = state) do
    for pid <- pids, do: safe_stop(pid)
    %{state | agent_pids: []}
  end

  defp stop_recorder(%{recorder_pid: nil} = state), do: state

  defp stop_recorder(%{recorder_pid: pid} = state) do
    safe_stop(pid)
    %{state | recorder_pid: nil}
  end

  defp stop_replay(%{replay_pid: nil} = state), do: state

  defp stop_replay(%{replay_pid: pid} = state) do
    safe_stop(pid)
    %{state | replay_pid: nil}
  end

  # ref-tagged self-messages: a delivered-but-stale timer (cancel_timer
  # can't retract it) is dropped by the ref check in handle_info
  defp schedule_restart(state) do
    ref = make_ref()
    Process.send_after(self(), {:next_match, ref}, state.inter_match_ms)
    ref
  end

  defp schedule_idle(state) do
    ref = make_ref()
    Process.send_after(self(), {:retry, ref}, state.idle_retry_ms)
    ref
  end

  # invalidating the stored refs is what cancels the timers — the
  # messages may still fire, but their tag no longer matches and
  # handle_info drops them
  defp cancel_timers(state), do: %{state | restart_ref: nil, idle_ref: nil}

  # Linked processes: a failed start can exit us — guard, and a stopped
  # child may already be gone — also fine.
  defp safe_start(fun) do
    fun.()
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_stop(pid) do
    GenServer.stop(pid, :normal, @stop_timeout)
  catch
    :exit, _reason -> :ok
  end

  ## Small helpers

  defp opt(opts, config, key, default \\ nil) do
    Keyword.get(opts, key, Keyword.get(config, key, default))
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp seconds_ms(seconds), do: max(0, round(seconds * 1_000))

  defp topic(state), do: "match:#{state.match_id}"

  defp fmt(number) when is_number(number), do: :erlang.float_to_binary(number, decimals: 2)
  defp fmt(other), do: inspect(other)

  defp status_of(state) do
    %{
      mode: state.mode,
      match_id: state.match_id,
      spent: state.spent,
      budget: state.budget,
      players: length(roster(state))
    }
  end
end
