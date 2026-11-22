defmodule Aimongus.Game.Server do
  @moduledoc """
  The match engine: a `GenServer` that owns the authoritative
  `Aimongus.Game.State`, runs the free-roam world tick, and executes agent
  intents through the legality checks in `Aimongus.Game.Rules`.

  One server per match, registered in `Aimongus.MatchRegistry` under the
  match id, so every public call takes `match_id` instead of a pid.

  ## Public API

    * `start_link(match_id, config)` — boots a match in `:lobby`. `config`
      is merged over `Aimongus.Game.State` defaults; the server also reads
      these keys:
        * `:players` — list of attr maps (`State.add_player/2` shape)
          joined automatically at boot
        * `:auto_tick` — run the world tick on a timer (default `true`)
        * `:shuffle_roles` — shuffle `config.roles` before dealing
          (default `true`; `false` deals the list as-is to the
          alphabetically sorted player ids — deterministic, for tests)
    * `add_player(match_id, attrs)` — join the lobby; assigns a random
      `Personality` unless `:personality` is given
    * `start_match(match_id)` — deals roles/tasks, enters `:free_roam`
    * `submit_intent(match_id, player_id, intent)` — deterministic
      executor; returns `:ok` or `{:rejected, reason}` (the rejection is
      what Task 12 feeds back into the agent's memory)
    * `state(match_id)` — the current `%Aimongus.Game.State{}` — **the
      god view**: spectators only. Agents must never be given it; they
      pull `view_for/2` instead
    * `view_for(match_id, player_id)` — the per-player filtered view
      `Aimongus.Agent.Server` builds each prompt from: the player's own
      role/status/tasks, only the players and bodies `Rules.visible?/3`
      lets them see, whispers they heard, meeting history, phase. Never
      another player's role, cooldowns, or path
    * `register_agent(match_id, player_id, pid)` — binds an agent-runtime
      process to a player so the engine can route that player's events
      to it as casts (see "Agent event routing" below)
    * `step(match_id)` — synchronous single world tick (test/debug tool;
      returns the post-tick state)

  ## Tick loop

  `Process.send_after` drives the loop at `config.tick_ms` (~10 Hz by
  default). `state.tick` — the world clock that kill cooldowns and task
  progress measure against — only advances in `:free_roam`; the timer
  keeps firing through `:meeting` so later phases can hang deadlines off
  it, but the world itself is frozen.

  Each free-roam tick:

    1. `tick += 1`
    2. every player with a path advances up to `config.move_speed`
       waypoints → `{:moved, id, pos}`
    3. every player whose action is `{:do_task, ...}` and who stands on
       the task spot accrues one work tick → `{:task_progress, ...}` /
       `{:task_done, ...}` at `config.task_ticks`

  ## Intents — free roam

    * `{:move_to, {x, y} | "Room Name"}` — A* path to the cell; for a room
      name, to the reachable room cell with the shortest route among the
      Manhattan-closest candidates. Replaces any task in progress.
    * `{:do_task, task_id}` — paths to the task spot, then works it. The
      task must be on the player's own list (impostor fake lists work too
      — they just never touch the win pool). Abandoning resets progress.
    * `{:kill, target}` — checked through `Rules.can_kill?/3` with
      precise rejection reasons (see below). Kill-capable: impostors,
      the serial killer, and the vigilante (exactly one shot — a second
      `kill` intent rejects `:already_used`). A kill on a medic-shielded
      target is *blocked*, not illegal: the shield is consumed, the
      attacker still spends their cooldown (and a vigilante's shot), the
      reply is `{:rejected, :blocked}` and `{:kill_blocked, victim}` is
      broadcast.
    * `{:investigate, target}` — sheriff only, within
      `config.investigate_range`, on `config.investigate_cooldown_ticks`.
      The verdict comes back in the reply:
      `{:ok, {:hint, target, :suspicious | :innocent}}`
      (`Rules.suspicion/1` — impostors and the serial killer read
      suspicious). A `{:hint, sheriff, target, verdict}` copy is
      broadcast for the god-view spectator feed; other agents never
      see it.
    * `{:protect, target}` — medic only, within `config.protect_range`,
      on `config.protect_cooldown_ticks`. Sets the target's
      `protected_until` to `tick + config.protect_duration_ticks` and
      broadcasts `{:protected, medic, target}`.
    * `:report` — reports the nearest unreported body the player can see
      (`Rules.visible?/3`). Marks that body `reported?: true` — other
      bodies stay hidden — then calls a meeting.
    * `:press_button` — within `config.button_range` of the map's `B`
      spot; calls a meeting.
    * `{:whisper, text, target?}` — broadcasts
      `{:whisper, from, target, audience, text}` where `audience` is
      `Rules.whisper_audience/2`. Radius-only per the SDD ruling: `target`
      selects an addressee, never extends the audience — the event keeps
      both so consumers can tell "addressed" from "heard". `nil` target
      means an untargeted whisper. Each speaker is rate-limited to one
      whisper per `config.whisper_cooldown_ticks`.
    * `:nothing` — idles; clears path and task progress.

  `{:speak, text}` and `{:vote, choice}` submitted in `:free_roam` are
  real intents in the wrong phase — `{:rejected, :wrong_phase}`.

  ## Meetings

  `report`/`press_button` freezes the world (paths dropped, actions
  discarded, `state.tick` stops advancing) and opens `:meeting`. From
  there the phase machine runs:

    1. **`:meeting` (discussion)** — `config.speech_rounds` rounds; each
       round every living player gets one speak slot in sorted-id order.
       The server broadcasts `{:speak_request, id}` per slot — the prompt
       Task 12's agent runtime answers with a `{:speak, text}` intent
       (`:nothing` passes the slot silently, broadcast as
       `{:spoke, id, nil}`). Only the floor holder's speak is accepted
       (`{:rejected, :not_your_turn}` otherwise). `meeting_seconds` caps
       the whole discussion: on expiry, unspoken slots are skipped.
    2. **`:voting`** — living players submit `{:vote, player_id | :skip}`
       (or `:nothing` to abstain). Re-voting is legal; the latest ballot
       counts. `vote_seconds` is the deadline — votes never cast count
       as `:skip`. Tallying is plurality: the unique top candidate is
       ejected; a tie or a `:skip` plurality ejects nobody.
    3. **`:eject`** — transient phase holding until the next tick/step so
       `{:ejected, id, role}` / `:no_ejection` is observable. Resolving
       clears `state.bodies` (Among Us corpse cleanup), preserves
       positions and kill cooldowns, re-evaluates `Rules.winner/1`, then
       lands in `:free_roam` (`:meeting_ended`) or `:game_over`.
       Exception: ejecting the **jester** is an immediate solo win —
       the phase goes straight to `:game_over, {:solo, id}` (the
       `:eject` transient is skipped; `{:ejected, ...}` still fires).

  Deadlines are wall-clock (monotonic ms) checked from `maybe_advance` —
  the recurring `:tick` timer keeps firing through meetings, and
  `step/1` drives them deterministically in tests. `server.meeting`
  holds the run bookkeeping (speaker queue, speech `history`, `votes`,
  deadline) — Task 12 reads `history` to prompt each speaker.

  ## Stall cap

  `config.match_max_seconds` (default 900 — 15 min) is a hard wall-clock
  deadline on the whole match, set at `start_match` and checked from
  `maybe_advance` on every tick in every live phase, so a stuck game can
  never burn tokens indefinitely. On expiry the match goes to
  `:game_over`: a pending `Rules.winner/1` wins first (e.g. the cap
  firing mid-`:eject` after the last impostor was voted out), otherwise
  the heuristic applies — `server.kills >= config.kill_threshold`
  (default 2) → `:impostors` pressed their advantage, else `:crew` by
  survival. `kills` counts murders only; ejections don't. The timeout
  broadcasts `{:match_timeout, winner}` then `{:game_over, winner}`.
  `match_max_seconds: nil` disables the cap; `0` expires on the first
  tick after start (the test-driving pattern, same as
  `meeting_seconds: 0`).

  ## Rejections

  Intents submitted in the wrong phase are rejected — not queued — with
  `{:rejected, :wrong_phase}` (meetings re-prompt agents anyway, so
  queuing would replay stale decisions). Other reasons:

    * `:unknown_player`, `:unknown_intent`
    * `:unreachable`, `:unknown_room`, `:bad_destination` (move)
    * `:unknown_task`, `:not_assigned`, `:task_done` (do_task)
    * `:dead`, `:unknown_target`, `:target_dead`, `:cannot_kill`,
      `:already_used` (vigilante's spent shot), `:blocked` (target was
      medic-protected), `{:cooldown, ticks_left}`, `:out_of_range` (kill)
    * `:cannot_investigate` (non-sheriff or self) — investigate otherwise
      reuses `:dead`, `:unknown_target`, `:target_dead`,
      `{:cooldown, ticks_left}`, `:out_of_range`
    * `:cannot_protect` (non-medic) — protect otherwise reuses `:dead`,
      `:unknown_target`, `:target_dead`, `{:cooldown, ticks_left}`,
      `:out_of_range`
    * `:no_body` (report), `:no_button`, `:not_at_button` (press_button)
    * `:invalid_text` (whisper, speak); whisper also rejects
      `:unknown_target`/`:target_dead` for a bad addressee and
      `{:cooldown, ticks_left}` inside `whisper_cooldown_ticks`
    * `:not_your_turn` (speak), `:unknown_target`, `:target_dead` (vote)

  ## Ghosts

  Dead players keep Among Us ghost privileges: `move_to`, `do_task` and
  `:nothing` still work (that's why `state.tasks` keeps dead players'
  assignments in the pool). `kill`, `investigate`, `protect`, `report`,
  `press_button` and `whisper` return `{:rejected, :dead}` — ghosts
  don't touch the living.
  Ghosts are also silent in meetings: `speak` and `vote` return
  `{:rejected, :dead}`.

  ## Events

  Broadcast on `Aimongus.PubSub`, topic `"match:<match_id>"`. Spectators
  are god-view per the spec, so role assignments are public:

    * `{:player_joined, id, name, pos}`
    * `:match_started` then `{:role_assigned, id, role}` per player
    * `{:moved, id, pos}`
    * `{:task_progress, id, task_id, pct}` (integer 0–100),
      `{:task_done, id, task_id}`
    * `{:killed, victim_id, killer_id, pos}`,
      `{:kill_blocked, victim_id}` (a medic shield held)
    * `{:hint, sheriff_id, target_id, :suspicious | :innocent}` — the
      investigator's copy comes back as the intent reply; this event is
      for the spectator feed (agents must never be routed it — see the
      `submit_intent/3` doc)
    * `{:protected, medic_id, target_id}`
    * `{:body_reported, reporter_id, pos}`, `{:button_pressed, id}`,
      `:meeting_called`
    * `{:meeting_started, {:report, id} | {:button, id}}`
    * `{:speak_request, id}` — that player's speak slot opened
    * `{:spoke, id, text | nil}` — `nil` when the speaker passed
    * `:voting_started`, `{:voted, id, choice}`
    * `{:ejected, id, role | nil}` (role is `nil` when
      `config.reveal_role_on_eject` is false), `:no_ejection`
    * `:meeting_ended` — the world is live again in `:free_roam`
    * `{:whisper, from_id, addressee_id | nil, audience_ids, text}` —
      the addressee is who was named; the audience is who actually heard
    * `{:match_timeout, winner}` — the stall cap fired (see "Stall cap");
      always followed by `{:game_over, winner}`
    * `{:game_over, winner}` where `winner` is `Rules.winner/1`'s shape

  `Rules.winner/1` is only evaluated once the match is in `:free_roam`
  (it's phase-blind): at `start_match` (degenerate role mixes end
  immediately, which is correct Among Us semantics), after every kill
  and task completion, and when an ejection resolves.

  ## Agent event routing

  The `match:<id>` PubSub topic is god-view: it carries role
  assignments, sheriff hints, votes and kill positions. Agent processes
  (`Aimongus.Agent.Server`) therefore **never subscribe** to it. Instead
  they call `register_agent/3`, and the engine pushes each agent only
  the events that player is entitled to — as plain casts:

    * `{:heard_whisper, %{from:, to:, audience:, text:}}` — only to
      players inside the whisper's audience
    * `:speak_request` — only to the player holding the floor
    * `{:body_seen}` — only to players whose vision covers a new corpse
      (checked server-side with `Rules.visible?/3` at kill time; the
      cast carries no content — the corpse arrives via `view_for/2`)
    * public meeting events to every registered agent:
      `:match_started`, `{:meeting_started, reason}`,
      `{:heard_speech, speaker, text | nil}`, `:voting_started`,
      `{:voted, voter, choice}`, `{:ejected, id, role | nil}`,
      `:no_ejection`, `:meeting_ended`, `{:game_over, winner}`

  Everything else on the topic — `{:role_assigned, ...}`, `{:moved,
  ...}`, `{:hint, ...}`, `{:killed, ...}`, `{:protected, ...}`,
  `{:task_progress, ...}` — is deliberately never routed; agents learn
  the world through `view_for/2` alone.
  """

  use GenServer

  alias Aimongus.Game.{Pathfind, Personality, Rules, State}
  alias Aimongus.Game.Map, as: GameMap

  @registry Aimongus.MatchRegistry
  @room_candidates 8
  @max_whisper_bytes 500
  @max_speech_bytes 1_000
  @heard_whisper_limit 10

  defstruct match_id: nil,
            state: nil,
            actions: %{},
            meeting: nil,
            kills: 0,
            match_deadline: nil,
            tick_ms: 100,
            auto_tick?: true,
            shuffle_roles?: true,
            agents: %{},
            heard_whispers: %{}

  ## Public API

  @doc "Boots a match server in `:lobby`, registered under `match_id`."
  @spec start_link(term(), map() | keyword()) :: GenServer.on_start()
  def start_link(match_id, config \\ %{}) do
    GenServer.start_link(__MODULE__, {match_id, config}, name: via(match_id))
  end

  @doc """
  Applies one intent for `player_id`.

  Returns `:ok` when accepted or `{:rejected, reason}` — the tuple the
  agent runtime (Task 12) folds back into that agent's memory.
  `{:investigate, target}` is the one intent with a payload reply:
  `{:ok, {:hint, target, :suspicious | :innocent}}`.
  """
  @spec submit_intent(term(), State.Player.id(), term()) ::
          :ok | {:ok, term()} | {:rejected, term()}
  def submit_intent(match_id, player_id, intent) do
    GenServer.call(via(match_id), {:intent, player_id, intent})
  end

  @doc "The authoritative `%State{}` snapshot — god view, spectators only."
  @spec state(term()) :: State.t()
  def state(match_id), do: GenServer.call(via(match_id), :state)

  @doc """
  The filtered per-player view the agent runtime builds each prompt
  from. See the moduledoc's "Agent event routing" and
  `Aimongus.LLM.Prompt`'s `agent_view` contract for what is (and is not)
  inside. `{:error, :unknown_player}` for unknown ids.
  """
  @spec view_for(term(), State.Player.id()) :: {:ok, map()} | {:error, :unknown_player}
  def view_for(match_id, player_id) do
    GenServer.call(via(match_id), {:view_for, player_id})
  end

  @doc """
  Registers `pid` as the agent-runtime process playing `player_id` so
  the engine can route that player's events to it as casts (see
  "Agent event routing" in the moduledoc). Re-registering replaces the
  pid (a restarted agent takes over seamlessly).
  """
  @spec register_agent(term(), State.Player.id(), pid()) ::
          :ok | {:error, :unknown_player}
  def register_agent(match_id, player_id, pid) when is_pid(pid) do
    GenServer.call(via(match_id), {:register_agent, player_id, pid})
  end

  @doc """
  Joins a lobby player (`State.add_player/2` attrs; `:personality`
  defaults to `Personality.random/0`). Returns `{:ok, player_id}` or
  `{:error, reason}`.
  """
  @spec add_player(term(), map() | keyword()) :: {:ok, term()} | {:error, term()}
  def add_player(match_id, attrs) do
    GenServer.call(via(match_id), {:add_player, attrs})
  end

  @doc """
  Deals roles and tasks and enters `:free_roam`.

  With `shuffle_roles: false`, `config.roles` is dealt in order to the
  alphabetically sorted player ids (deterministic); otherwise it's
  shuffled first. Extra players past the role list become `:crewmate`.
  """
  @spec start_match(term()) :: :ok | {:error, term()}
  def start_match(match_id), do: GenServer.call(via(match_id), :start_match)

  @doc "Advances one world tick synchronously (test/debug); returns the new state."
  @spec step(term()) :: State.t()
  def step(match_id), do: GenServer.call(via(match_id), :step)

  defp via(match_id), do: {:via, Registry, {@registry, match_id}}

  ## GenServer callbacks

  @impl true
  def init({match_id, config}) do
    config = Map.new(config)
    {players, config} = Map.pop(config, :players, [])

    server = %__MODULE__{
      match_id: match_id,
      state: State.new(config),
      tick_ms: Map.get(config, :tick_ms, 100),
      auto_tick?: Map.get(config, :auto_tick, true),
      shuffle_roles?: Map.get(config, :shuffle_roles, true)
    }

    server = Enum.reduce(players, server, &insert_player(&2, &1))

    if server.auto_tick?, do: schedule_tick(server.tick_ms)

    {:ok, server}
  end

  @impl true
  def handle_call(:state, _from, server), do: {:reply, server.state, server}

  def handle_call({:view_for, player_id}, _from, server) do
    {:reply, agent_view(server, player_id), server}
  end

  def handle_call({:register_agent, player_id, pid}, _from, server) do
    if Map.has_key?(server.state.players, player_id) do
      {:reply, :ok, %{server | agents: Map.put(server.agents, player_id, pid)}}
    else
      {:reply, {:error, :unknown_player}, server}
    end
  end

  def handle_call({:add_player, attrs}, _from, server) do
    attrs = Map.new(attrs)

    cond do
      server.state.phase != :lobby ->
        {:reply, {:error, :not_lobby}, server}

      not Map.has_key?(attrs, :id) ->
        {:reply, {:error, :id_required}, server}

      Map.has_key?(server.state.players, attrs.id) ->
        {:reply, {:error, :duplicate_player}, server}

      true ->
        server = insert_player(server, attrs)
        {:reply, {:ok, attrs.id}, server}
    end
  end

  def handle_call(:start_match, _from, server) do
    cond do
      server.state.phase != :lobby ->
        {:reply, {:error, :already_started}, server}

      map_size(server.state.players) == 0 ->
        {:reply, {:error, :no_players}, server}

      true ->
        {:reply, :ok, begin_match(server)}
    end
  end

  def handle_call(:step, _from, server) do
    server = maybe_advance(server)
    {:reply, server.state, server}
  end

  def handle_call({:intent, player_id, intent}, _from, server) do
    {reply, server} = execute_intent(server, player_id, intent)
    {:reply, reply, server}
  end

  @impl true
  def handle_info(:tick, server) do
    server = maybe_advance(server)
    if server.auto_tick?, do: schedule_tick(server.tick_ms)
    {:noreply, server}
  end

  defp schedule_tick(tick_ms), do: Process.send_after(self(), :tick, tick_ms)

  defp insert_player(server, attrs) do
    attrs = attrs |> Map.new() |> Map.put_new_lazy(:personality, &Personality.random/0)
    state = State.add_player(server.state, attrs)
    player = state.players[attrs.id]
    broadcast(server, {:player_joined, player.id, player.name, player.pos})
    %{server | state: state}
  end

  defp begin_match(server) do
    ids = server.state.players |> Map.keys() |> Enum.sort()
    roles = server.state.config.roles
    roles = if server.shuffle_roles?, do: Enum.shuffle(roles), else: roles

    role_map =
      ids
      |> Enum.with_index()
      |> Map.new(fn {id, i} -> {id, Enum.at(roles, i, :crewmate)} end)

    state = server.state |> State.assign_roles(role_map) |> State.assign_tasks()

    server = %{
      server
      | state: %{state | phase: :free_roam},
        match_deadline: deadline_in(state.config.match_max_seconds)
    }

    broadcast(server, :match_started)
    Enum.each(ids, &broadcast(server, {:role_assigned, &1, state.players[&1].role}))

    check_winner(server)
  end

  defp maybe_advance(%{state: %{phase: phase}} = server)
       when phase in [:free_roam, :meeting, :voting, :eject] do
    if deadline_passed?(server.match_deadline),
      do: timeout_match(server),
      else: advance_phase(server)
  end

  defp maybe_advance(server), do: server

  defp advance_phase(%{state: %{phase: :free_roam}} = server), do: advance_tick(server)
  defp advance_phase(%{state: %{phase: :meeting}} = server), do: advance_meeting(server)
  defp advance_phase(%{state: %{phase: :voting}} = server), do: advance_voting(server)
  defp advance_phase(%{state: %{phase: :eject}} = server), do: resolve_eject(server)

  ## Tick

  defp advance_tick(server) do
    server = %{server | state: %{server.state | tick: server.state.tick + 1}}

    server.state.players
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(server, &step_player(&2, &1))
  end

  defp step_player(server, id) do
    server |> advance_position(id) |> advance_action(id)
  end

  defp advance_position(server, id) do
    player = server.state.players[id]

    case player.path do
      [] ->
        server

      path ->
        {steps, rest} = Enum.split(path, server.state.config.move_speed)
        pos = List.last(steps)
        server = put_in(server.state.players[id], %{player | pos: pos, path: rest})
        broadcast(server, {:moved, id, pos})
        server
    end
  end

  defp advance_action(server, id) do
    case server.actions[id] do
      {:task, task_id, done} ->
        spot = GameMap.task_spot(server.state.map, task_id)

        if server.state.players[id].pos == spot do
          work_task(server, id, task_id, done + 1)
        else
          server
        end

      _other ->
        server
    end
  end

  defp work_task(server, id, task_id, done) do
    total = server.state.config.task_ticks

    if done >= total do
      server = %{
        server
        | state: State.complete_task(server.state, id, task_id),
          actions: Map.delete(server.actions, id)
      }

      broadcast(server, {:task_done, id, task_id})
      check_winner(server)
    else
      server = %{server | actions: Map.put(server.actions, id, {:task, task_id, done})}
      broadcast(server, {:task_progress, id, task_id, round(done * 100 / total)})
      server
    end
  end

  ## Intent execution

  defp execute_intent(server, player_id, intent) do
    case server.state.phase do
      :free_roam ->
        if Map.has_key?(server.state.players, player_id) do
          dispatch_intent(server, player_id, intent)
        else
          {{:rejected, :unknown_player}, server}
        end

      :meeting ->
        meeting_intent(server, player_id, intent)

      :voting ->
        voting_intent(server, player_id, intent)

      _other ->
        {{:rejected, :wrong_phase}, server}
    end
  end

  defp dispatch_intent(server, id, {:move_to, dest}), do: exec_move(server, id, dest)
  defp dispatch_intent(server, id, {:do_task, task_id}), do: exec_task(server, id, task_id)
  defp dispatch_intent(server, id, {:kill, target}), do: exec_kill(server, id, target)

  defp dispatch_intent(server, id, {:investigate, target}),
    do: exec_investigate(server, id, target)

  defp dispatch_intent(server, id, {:protect, target}), do: exec_protect(server, id, target)
  defp dispatch_intent(server, id, :report), do: exec_report(server, id)
  defp dispatch_intent(server, id, :press_button), do: exec_button(server, id)
  defp dispatch_intent(server, id, {:whisper, text}), do: exec_whisper(server, id, text, nil)

  defp dispatch_intent(server, id, {:whisper, text, target}),
    do: exec_whisper(server, id, text, target)

  # speak/vote are real intents — just wrong phase while roaming
  defp dispatch_intent(server, _id, {:speak, _}), do: {{:rejected, :wrong_phase}, server}
  defp dispatch_intent(server, _id, {:vote, _}), do: {{:rejected, :wrong_phase}, server}

  defp dispatch_intent(server, id, :nothing) do
    {:ok, stop_player(server, id)}
  end

  defp dispatch_intent(server, _id, _other), do: {{:rejected, :unknown_intent}, server}

  # move_to / do_task / :nothing are the ghost-legal intents; the rest
  # gate on `alive?` inside their own executors.

  defp exec_move(server, id, dest) do
    map = server.state.map
    from = server.state.players[id].pos

    case resolve_destination(map, from, dest) do
      {:ok, path} ->
        # Pathfind includes `from` as the first element — drop it.
        server = %{
          put_in(server.state.players[id].path, tl(path))
          | actions: Map.delete(server.actions, id)
        }

        {:ok, server}

      {:error, reason} ->
        {{:rejected, reason}, server}
    end
  end

  defp resolve_destination(map, from, {x, y} = pos)
       when is_integer(x) and is_integer(y) and x >= 0 and y >= 0 do
    case Pathfind.path(map, from, pos) do
      {:ok, path} -> {:ok, path}
      :unreachable -> {:error, :unreachable}
    end
  end

  defp resolve_destination(map, from, room) when is_binary(room) do
    case Map.fetch(map.rooms, room) do
      :error ->
        {:error, :unknown_room}

      {:ok, cells} ->
        cells
        |> Enum.sort_by(&manhattan(from, &1))
        |> Enum.take(@room_candidates)
        |> Enum.map(&Pathfind.path(map, from, &1))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, path} -> path end)
        |> Enum.min_by(&length/1, fn -> nil end)
        |> case do
          nil -> {:error, :unreachable}
          path -> {:ok, path}
        end
    end
  end

  defp resolve_destination(_map, _from, _bad), do: {:error, :bad_destination}

  defp exec_task(server, id, task_id) do
    state = server.state
    player = state.players[id]

    cond do
      not is_binary(task_id) or not Map.has_key?(state.map.tasks, task_id) ->
        {{:rejected, :unknown_task}, server}

      not Map.has_key?(player.tasks, task_id) ->
        {{:rejected, :not_assigned}, server}

      player.tasks[task_id] ->
        {{:rejected, :task_done}, server}

      true ->
        spot = GameMap.task_spot(state.map, task_id)

        case Pathfind.path(state.map, player.pos, spot) do
          :unreachable ->
            {{:rejected, :unreachable}, server}

          {:ok, path} ->
            server = %{
              put_in(server.state.players[id].path, tl(path))
              | actions: Map.put(server.actions, id, {:task, task_id, 0})
            }

            {:ok, server}
        end
    end
  end

  defp exec_kill(server, id, target_id) do
    state = server.state
    killer = state.players[id]
    victim = state.players[target_id]

    rejection =
      cond do
        not killer.alive? -> :dead
        victim == nil -> :unknown_target
        not victim.alive? -> :target_dead
        id == target_id -> :cannot_kill
        not Rules.kill_capable?(killer) -> kill_incapable_reason(killer)
        state.tick < killer.kill_ready_at -> {:cooldown, killer.kill_ready_at - state.tick}
        Rules.distance(killer.pos, victim.pos) > state.config.kill_range -> :out_of_range
        true -> nil
      end

    if rejection do
      {{:rejected, rejection}, server}
    else
      do_kill(server, id, target_id)
    end
  end

  # A spent vigilante shot gets its own reason so the agent is told the
  # shot is gone — everyone else who can't kill just can't kill.
  defp kill_incapable_reason(%{role: :vigilante, vigilante_shot_used?: true}), do: :already_used
  defp kill_incapable_reason(_killer), do: :cannot_kill

  defp do_kill(server, id, target_id) do
    state = server.state
    victim = state.players[target_id]

    if Rules.protected?(state, victim) do
      blocked_kill(server, id, target_id)
    else
      case State.kill(state, id, target_id) do
        {:ok, state} ->
          victim_pos = state.players[target_id].pos

          server = %{
            server
            | state: state,
              actions: server.actions |> Map.delete(id) |> Map.delete(target_id),
              kills: server.kills + 1
          }

          broadcast(server, {:killed, target_id, id, victim_pos})
          {:ok, check_winner(server)}

        {:error, :illegal_kill} ->
          {{:rejected, :illegal_kill}, server}
      end
    end
  end

  # The attempt lands but the medic's shield holds: the protection is
  # consumed, and the attacker still spends their cooldown — and a
  # vigilante's single shot — because the kill was attempted, just
  # blocked. The attacker's rejection is `:blocked` (they learn the
  # shield held; that's the drama), spectators get `{:kill_blocked, id}`.
  defp blocked_kill(server, id, target_id) do
    state = server.state

    victim = %{state.players[target_id] | protected_until: nil}

    killer = %{
      state.players[id]
      | kill_ready_at: state.tick + state.config.kill_cooldown_ticks
    }

    killer =
      if killer.role == :vigilante,
        do: %{killer | vigilante_shot_used?: true},
        else: killer

    players = state.players |> Map.put(target_id, victim) |> Map.put(id, killer)
    server = %{server | state: %{state | players: players}}

    broadcast(server, {:kill_blocked, target_id})
    {{:rejected, :blocked}, server}
  end

  defp exec_investigate(server, id, target_id) do
    state = server.state
    sheriff = state.players[id]
    target = state.players[target_id]

    rejection =
      cond do
        not sheriff.alive? ->
          :dead

        sheriff.role != :sheriff or id == target_id ->
          :cannot_investigate

        target == nil ->
          :unknown_target

        not target.alive? ->
          :target_dead

        state.tick < sheriff.ability_ready_at ->
          {:cooldown, sheriff.ability_ready_at - state.tick}

        Rules.distance(sheriff.pos, target.pos) > state.config.investigate_range ->
          :out_of_range

        true ->
          nil
      end

    if rejection do
      {{:rejected, rejection}, server}
    else
      sheriff = %{
        sheriff
        | ability_ready_at: state.tick + state.config.investigate_cooldown_ticks
      }

      server = put_in(server.state.players[id], sheriff)

      # the hint is private: it comes back as the intent reply (the
      # channel Task 12 folds into the sheriff's memory). A copy is
      # broadcast tagged with the sheriff's id for the god-view
      # spectator feed — it is never routed to other agents.
      verdict = Rules.suspicion(target)
      broadcast(server, {:hint, id, target_id, verdict})
      {{:ok, {:hint, target_id, verdict}}, server}
    end
  end

  defp exec_protect(server, id, target_id) do
    state = server.state
    medic = state.players[id]
    target = state.players[target_id]

    rejection =
      cond do
        not medic.alive? -> :dead
        medic.role != :medic -> :cannot_protect
        target == nil -> :unknown_target
        not target.alive? -> :target_dead
        state.tick < medic.ability_ready_at -> {:cooldown, medic.ability_ready_at - state.tick}
        Rules.distance(medic.pos, target.pos) > state.config.protect_range -> :out_of_range
        true -> nil
      end

    if rejection do
      {{:rejected, rejection}, server}
    else
      # Map.update! on the medic (not a struct replace) so self-protection
      # lands both fields on the same player
      players =
        state.players
        |> Map.put(target_id, %{
          target
          | protected_until: state.tick + state.config.protect_duration_ticks
        })
        |> Map.update!(
          id,
          &%{&1 | ability_ready_at: state.tick + state.config.protect_cooldown_ticks}
        )

      server = %{server | state: %{state | players: players}}

      broadcast(server, {:protected, id, target_id})
      {:ok, server}
    end
  end

  defp exec_report(server, id) do
    state = server.state
    player = state.players[id]

    if player.alive? do
      visible_bodies =
        state.bodies
        |> Enum.with_index()
        |> Enum.reject(fn {body, _idx} -> Map.get(body, :reported?, false) end)
        |> Enum.filter(fn {body, _idx} -> Rules.visible?(state, id, body.pos) end)

      case Enum.min_by(
             visible_bodies,
             fn {body, _idx} -> Rules.distance(player.pos, body.pos) end,
             fn -> nil end
           ) do
        nil ->
          {{:rejected, :no_body}, server}

        {body, idx} ->
          bodies = List.update_at(state.bodies, idx, &Map.put(&1, :reported?, true))
          server = %{server | state: %{state | bodies: bodies}}
          broadcast(server, {:body_reported, id, body.pos})
          {:ok, call_meeting(server, {:report, id})}
      end
    else
      {{:rejected, :dead}, server}
    end
  end

  defp exec_button(server, id) do
    state = server.state
    player = state.players[id]

    cond do
      not player.alive? ->
        {{:rejected, :dead}, server}

      state.map.button == nil ->
        {{:rejected, :no_button}, server}

      Rules.distance(player.pos, state.map.button) > state.config.button_range ->
        {{:rejected, :not_at_button}, server}

      true ->
        broadcast(server, {:button_pressed, id})
        {:ok, call_meeting(server, {:button, id})}
    end
  end

  # `target` is the *addressee*, not an audience extension (radius wins
  # per the SDD ruling): it must be a living player, and the broadcast
  # carries it alongside the audience so consumers can tell "addressed"
  # from "heard". The speaker's `whisper_ready_at` rate-limits the feed
  # — an agent polling every tick would otherwise spam it.
  defp exec_whisper(server, id, text, target) do
    state = server.state
    player = state.players[id]
    addressee = if target == nil, do: nil, else: state.players[target]

    rejection =
      cond do
        not player.alive? -> :dead
        target != nil and addressee == nil -> :unknown_target
        target != nil and not addressee.alive? -> :target_dead
        invalid_text?(text, @max_whisper_bytes) -> :invalid_text
        state.tick < player.whisper_ready_at -> {:cooldown, player.whisper_ready_at - state.tick}
        true -> nil
      end

    if rejection do
      {{:rejected, rejection}, server}
    else
      audience = Rules.whisper_audience(state, id)

      player = %{player | whisper_ready_at: state.tick + state.config.whisper_cooldown_ticks}
      server = put_in(server.state.players[id], player)

      server = note_whisper(server, id, target, audience, text)
      broadcast(server, {:whisper, id, target, audience, text})
      {:ok, server}
    end
  end

  # Each hearer's own copy of the whisper is buffered per player —
  # `view_for/2` serves it so a consumer that only pulls views still
  # sees what the player heard. Bounded to the most recent
  # @heard_whisper_limit so prompts stay small.
  defp note_whisper(server, from, target, audience, text) do
    whisper = %{from: from, to: target, audience: audience, text: text}

    heard =
      Enum.reduce(audience, server.heard_whispers, fn hearer, acc ->
        Map.update(acc, hearer, [whisper], fn list ->
          Enum.take(list ++ [whisper], -@heard_whisper_limit)
        end)
      end)

    %{server | heard_whispers: heard}
  end

  ## Meetings

  # Meeting bookkeeping lives in `server.meeting` (process state, not the
  # authoritative %State{}): the speech history agents get prompted with
  # (Task 12), the speaker queue, collected votes and the current phase's
  # wall-clock deadline.
  #
  #   %{reason: {:report, id} | {:button, id},
  #     round: current speech round (1..speech_rounds),
  #     current: player id holding the floor,
  #     queue: remaining speaker ids this round,
  #     history: [{speaker_id, text | nil}] in speak order,
  #     votes: %{voter_id => choice},
  #     deadline: monotonic ms the current phase expires at (nil = none)}

  # Freezes the world exactly where it stands and opens the discussion:
  # `speech_rounds` rounds in which every living player gets one speak
  # slot, in sorted-id order. `{:speak_request, id}` on the match topic is
  # the prompt Task 12's agent runtime turns into a `speak` intent.
  defp call_meeting(server, reason) do
    players =
      Map.new(server.state.players, fn {id, player} -> {id, %{player | path: []}} end)

    [current | queue] = alive_ids(server.state)

    meeting = %{
      reason: reason,
      round: 1,
      current: current,
      queue: queue,
      history: [],
      votes: %{},
      deadline: deadline_in(server.state.config.meeting_seconds)
    }

    server = %{
      server
      | state: %{server.state | players: players, phase: :meeting},
        actions: %{},
        meeting: meeting
    }

    broadcast(server, :meeting_called)
    broadcast(server, {:meeting_started, reason})
    broadcast(server, {:speak_request, current})
    server
  end

  defp meeting_intent(server, id, {:speak, text}), do: exec_speak(server, id, text)

  # :nothing passes the floor — a speak slot with no statement
  defp meeting_intent(server, id, :nothing), do: exec_speak(server, id, nil)

  defp meeting_intent(server, _id, _intent), do: {{:rejected, :wrong_phase}, server}

  defp exec_speak(server, id, text) do
    player = server.state.players[id]

    cond do
      player == nil ->
        {{:rejected, :unknown_player}, server}

      not player.alive? ->
        # ghosts are silent in meetings
        {{:rejected, :dead}, server}

      server.meeting.current != id ->
        {{:rejected, :not_your_turn}, server}

      text != nil and invalid_text?(text, @max_speech_bytes) ->
        {{:rejected, :invalid_text}, server}

      true ->
        {:ok, advance_speaker(server, id, text)}
    end
  end

  defp advance_speaker(server, id, text) do
    meeting = server.meeting
    broadcast(server, {:spoke, id, text})
    meeting = %{meeting | history: meeting.history ++ [{id, text}]}

    case meeting.queue do
      [next | rest] ->
        server = %{server | meeting: %{meeting | current: next, queue: rest}}
        broadcast(server, {:speak_request, next})
        server

      [] ->
        if meeting.round < server.state.config.speech_rounds do
          [next | rest] = alive_ids(server.state)

          server = %{
            server
            | meeting: %{meeting | round: meeting.round + 1, current: next, queue: rest}
          }

          broadcast(server, {:speak_request, next})
          server
        else
          start_voting(%{server | meeting: meeting})
        end
    end
  end

  # The meeting deadline is a wall-clock cap on the *whole* discussion: a
  # hung speaker stalls their slot until it expires, then remaining slots
  # are skipped. Checked from `maybe_advance` — the recurring :tick keeps
  # firing through meetings and `step/1` drives it in tests.
  defp advance_meeting(server) do
    if deadline_passed?(server.meeting.deadline), do: start_voting(server), else: server
  end

  defp start_voting(server) do
    meeting = %{
      server.meeting
      | current: nil,
        queue: [],
        deadline: deadline_in(server.state.config.vote_seconds)
    }

    server = %{server | state: %{server.state | phase: :voting}, meeting: meeting}
    broadcast(server, :voting_started)
    server
  end

  defp voting_intent(server, id, {:vote, choice}), do: exec_vote(server, id, choice)

  # :nothing abstains — equivalent to voting :skip
  defp voting_intent(server, id, :nothing), do: exec_vote(server, id, :skip)

  defp voting_intent(server, _id, _intent), do: {{:rejected, :wrong_phase}, server}

  defp exec_vote(server, id, choice) do
    player = server.state.players[id]
    target = server.state.players[choice]

    cond do
      player == nil ->
        {{:rejected, :unknown_player}, server}

      not player.alive? ->
        {{:rejected, :dead}, server}

      choice != :skip and target == nil ->
        {{:rejected, :unknown_target}, server}

      choice != :skip and not target.alive? ->
        {{:rejected, :target_dead}, server}

      true ->
        # re-voting is legal: the latest ballot is what counts
        meeting = %{server.meeting | votes: Map.put(server.meeting.votes, id, choice)}
        server = %{server | meeting: meeting}
        broadcast(server, {:voted, id, choice})

        if all_voted?(server), do: {:ok, tally(server)}, else: {:ok, server}
    end
  end

  defp all_voted?(server) do
    voted = Map.keys(server.meeting.votes)
    server.state |> alive_ids() |> Enum.all?(&(&1 in voted))
  end

  defp advance_voting(server) do
    if deadline_passed?(server.meeting.deadline), do: tally(server), else: server
  end

  # Plurality ejects: the unique top candidate is ejected unless it is
  # :skip or the top is tied — both mean nobody goes out the airlock.
  # Players who never voted count as :skip.
  defp tally(server) do
    votes =
      server.state
      |> alive_ids()
      |> Map.new(fn id -> {id, Map.get(server.meeting.votes, id, :skip)} end)

    counts =
      Enum.reduce(votes, %{}, fn {_voter, choice}, acc ->
        Map.update(acc, choice, 1, &(&1 + 1))
      end)

    top = counts |> Map.values() |> Enum.max()
    leaders = for {choice, n} <- counts, n == top, do: choice

    server = %{server | state: %{server.state | phase: :eject}}

    case leaders do
      [choice] when choice != :skip ->
        role = server.state.players[choice].role
        server = put_in(server.state.players[choice].alive?, false)
        revealed = if server.state.config.reveal_role_on_eject, do: role, else: nil
        broadcast(server, {:ejected, choice, revealed})

        if role == :jester do
          # the jester wins by being ejected — game over on the spot,
          # skipping the :eject transient (the ejection event above is
          # already observable; the solo win resolves immediately)
          winner = {:solo, choice}

          server = %{
            server
            | state: %{server.state | phase: :game_over, winner: winner},
              meeting: nil
          }

          broadcast(server, {:game_over, winner})
          server
        else
          server
        end

      _tied_or_skip ->
        broadcast(server, :no_ejection)
        server
    end
  end

  # :eject is a real but transient phase — it holds until the next
  # :tick/step so the ejection event is observable before play resumes.
  # Resolving ends the meeting: corpses are cleaned up (Among Us rule),
  # positions and kill cooldowns are preserved (the world clock was
  # frozen), and the winner is re-evaluated.
  defp resolve_eject(server) do
    state = %{server.state | bodies: []}
    server = %{server | state: state, meeting: nil}

    case Rules.winner(state) do
      nil ->
        server = %{server | state: %{state | phase: :free_roam}}
        broadcast(server, :meeting_ended)
        server

      winner ->
        server = %{server | state: %{state | phase: :game_over, winner: winner}}
        broadcast(server, {:game_over, winner})
        server
    end
  end

  defp alive_ids(state) do
    state |> State.alive_players() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp deadline_in(nil), do: nil
  defp deadline_in(seconds), do: System.monotonic_time(:millisecond) + round(seconds * 1000)

  defp deadline_passed?(nil), do: false
  defp deadline_passed?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp invalid_text?(text, max_bytes) do
    not is_binary(text) or text == "" or byte_size(text) > max_bytes
  end

  ## Game over

  # The stall cap: a hard wall-clock deadline on the whole match, so a
  # stuck game can never burn tokens indefinitely. Checked from
  # `maybe_advance` on every tick in every live phase — the world may be
  # frozen mid-meeting but the recurring :tick (or a test `step/1`) still
  # lands here. When the cap fires mid-`:eject` a real winner may already
  # be pending (e.g. the last impostor was just voted out), so
  # `Rules.winner/1` gets first say; only a genuinely undecided match
  # falls to the heuristic.
  defp timeout_match(server) do
    winner = Rules.winner(server.state) || stall_winner(server)

    server = %{
      server
      | state: %{server.state | phase: :game_over, winner: winner},
        meeting: nil
    }

    broadcast(server, {:match_timeout, winner})
    broadcast(server, {:game_over, winner})
    server
  end

  # Survival heuristic: enough kills means the impostors pressed their
  # advantage; anything less means the crew outlasted them. `kills` counts
  # actual murders — ejections are democracy, not kills.
  defp stall_winner(server) do
    if server.kills >= server.state.config.kill_threshold, do: :impostors, else: :crew
  end

  defp check_winner(%{state: %{phase: :free_roam}} = server) do
    case Rules.winner(server.state) do
      nil ->
        server

      winner ->
        server = %{server | state: %{server.state | phase: :game_over, winner: winner}}
        broadcast(server, {:game_over, winner})
        server
    end
  end

  defp check_winner(server), do: server

  defp stop_player(server, id) do
    %{
      put_in(server.state.players[id].path, [])
      | actions: Map.delete(server.actions, id)
    }
  end

  ## Helpers

  defp broadcast(server, event) do
    Phoenix.PubSub.broadcast(Aimongus.PubSub, "match:#{server.match_id}", event)
    route_to_agents(server, event)
    :ok
  end

  # Per-agent routing — see "Agent event routing" in the moduledoc.
  # Agents never subscribe to the god-view topic; the engine casts each
  # agent only the events its player may know. Everything not listed
  # here is spectator-only and deliberately never reaches an agent.
  defp route_to_agents(server, event) do
    case event do
      {:whisper, from, target, audience, text} ->
        whisper = %{from: from, to: target, audience: audience, text: text}
        cast_players(server, audience, {:heard_whisper, whisper})

      {:speak_request, id} ->
        cast_player(server, id, :speak_request)

      :match_started ->
        cast_all(server, :match_started)

      {:meeting_started, reason} ->
        cast_all(server, {:meeting_started, reason})

      {:spoke, id, text} ->
        cast_all(server, {:heard_speech, id, text})

      :voting_started ->
        cast_all(server, :voting_started)

      {:voted, id, choice} ->
        cast_all(server, {:voted, id, choice})

      {:ejected, id, role} ->
        cast_all(server, {:ejected, id, role})

      :no_ejection ->
        cast_all(server, :no_ejection)

      :meeting_ended ->
        cast_all(server, :meeting_ended)

      {:game_over, winner} ->
        cast_all(server, {:game_over, winner})

      {:killed, _victim_id, _killer_id, pos} ->
        # A bare "look again" nudge to agents whose vision covers the
        # corpse — decided server-side with the post-kill state. The
        # cast itself carries no information; the corpse (and who it is)
        # reaches the agent through its next `view_for/2`.
        for {id, pid} <- server.agents,
            Rules.visible?(server.state, id, pos) do
          GenServer.cast(pid, :body_seen)
        end

        :ok

      _other ->
        # Never routed: role_assigned, moved, task_progress/task_done,
        # hint, killed (content), protected, kill_blocked,
        # body_reported, button_pressed, meeting_called, match_timeout.
        :ok
    end

    :ok
  end

  defp cast_all(server, message) do
    Enum.each(server.agents, fn {_id, pid} -> GenServer.cast(pid, message) end)
  end

  defp cast_players(server, ids, message) do
    Enum.each(ids, &cast_player(server, &1, message))
  end

  defp cast_player(server, id, message) do
    case server.agents[id] do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end

  ## Filtered agent view

  # The view contract `Aimongus.LLM.Prompt.build/1` consumes — assembled
  # strictly from what `player_id` may know: own internals, visible
  # players/bodies (whitelisted fields only), whispers they heard, and
  # the public meeting transcript.
  defp agent_view(server, player_id) do
    state = server.state

    case state.players[player_id] do
      nil ->
        {:error, :unknown_player}

      player ->
        {:ok,
         %{
           id: player.id,
           name: player.name,
           color: player.color,
           role: player.role,
           phase: state.phase,
           pos: player.pos,
           room: GameMap.room_at(state.map, player.pos),
           tick: state.tick,
           alive?: player.alive?,
           personality: player.personality,
           # frequencies, not the ordered list — with deterministic
           # dealing (shuffle_roles: false) the list's order encodes
           # the whole role assignment
           role_mix: Enum.frequencies(state.config.roles),
           tasks: task_view(state, player),
           vigilante_shot_used?: player.vigilante_shot_used?,
           visible_players: visible_players(state, player),
           visible_bodies: visible_bodies(state, player),
           whispers: Map.get(server.heard_whispers, player_id, []),
           meeting: meeting_view(server, player_id)
         }}
    end
  end

  # Whitelist — id/name/color/pos/room only. Role, cooldowns, path and
  # alive-ness never leave the engine for another player's pawn.
  defp visible_players(state, viewer) do
    for {id, p} <- state.players,
        id != viewer.id,
        p.alive?,
        Rules.visible?(state, viewer.id, p.pos) do
      %{
        id: p.id,
        name: p.name,
        color: p.color,
        pos: p.pos,
        room: GameMap.room_at(state.map, p.pos)
      }
    end
    |> Enum.sort_by(& &1.id)
  end

  defp visible_bodies(state, viewer) do
    for body <- state.bodies,
        Rules.visible?(state, viewer.id, body.pos) do
      %{
        player_id: body.player_id,
        name: state.players[body.player_id].name,
        pos: body.pos,
        room: GameMap.room_at(state.map, body.pos),
        reported?: Map.get(body, :reported?, false)
      }
    end
  end

  defp task_view(state, player) do
    player.tasks
    |> Enum.map(fn {task_id, done?} ->
      %{id: task_id, done?: done?, room: task_room(state, task_id)}
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp task_room(state, task_id) do
    case Map.get(state.map.tasks, task_id) do
      nil -> nil
      pos -> GameMap.room_at(state.map, pos)
    end
  end

  # Public meeting transcript — every living player hears the whole
  # discussion, so history is shared; `your_turn?` and `candidates` are
  # the only per-player bits.
  defp meeting_view(%{state: %{phase: :meeting}, meeting: %{} = meeting}, player_id) do
    %{history: meeting.history, round: meeting.round, your_turn?: meeting.current == player_id}
  end

  defp meeting_view(%{state: %{phase: :voting} = state, meeting: %{} = meeting}, _id) do
    candidates =
      state
      |> State.alive_players()
      |> Enum.map(&%{id: &1.id, name: &1.name})
      |> Enum.sort_by(& &1.id)

    %{history: meeting.history, round: meeting.round, candidates: candidates}
  end

  defp meeting_view(_server, _player_id), do: nil

  defp manhattan({x1, y1}, {x2, y2}), do: abs(x1 - x2) + abs(y1 - y2)
end
