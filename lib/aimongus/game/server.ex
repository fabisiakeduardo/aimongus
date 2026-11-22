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
    * `state(match_id)` — the current `%Aimongus.Game.State{}`
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

  ## Intents (free-roam only)

    * `{:move_to, {x, y} | "Room Name"}` — A* path to the cell; for a room
      name, to the reachable room cell with the shortest route among the
      Manhattan-closest candidates. Replaces any task in progress.
    * `{:do_task, task_id}` — paths to the task spot, then works it. The
      task must be on the player's own list (impostor fake lists work too
      — they just never touch the win pool). Abandoning resets progress.
    * `{:kill, target}` — checked through `Rules.can_kill?/3` with
      precise rejection reasons (see below).
    * `:report` — reports the nearest unreported body the player can see
      (`Rules.visible?/3`). Marks that body `reported?: true` — other
      bodies stay hidden — then calls a meeting.
    * `:press_button` — within `config.button_range` of the map's `B`
      spot; calls a meeting.
    * `{:whisper, text, target?}` — broadcasts
      `{:whisper, from, audience, text}` where `audience` is
      `Rules.whisper_audience/2`. Radius-only per the SDD ruling: `target`
      selects an addressee, never extends the audience.
    * `:nothing` — idles; clears path and task progress.

  A meeting freezes the world: paths are dropped, actions discarded and
  the phase becomes `:meeting` (Task 5 owns everything after that).

  ## Rejections

  Intents submitted outside `:free_roam` are rejected — not queued —
  with `{:rejected, :wrong_phase}` (meetings re-prompt agents anyway, so
  queuing would replay stale decisions). Other reasons:

    * `:unknown_player`, `:unknown_intent`
    * `:unreachable`, `:unknown_room`, `:bad_destination` (move)
    * `:unknown_task`, `:not_assigned`, `:task_done` (do_task)
    * `:dead`, `:unknown_target`, `:target_dead`, `:cannot_kill`,
      `{:cooldown, ticks_left}`, `:out_of_range` (kill)
    * `:no_body` (report), `:no_button`, `:not_at_button` (press_button)
    * `:invalid_text` (whisper)

  ## Ghosts

  Dead players keep Among Us ghost privileges: `move_to`, `do_task` and
  `:nothing` still work (that's why `state.tasks` keeps dead players'
  assignments in the pool). `kill`, `report`, `press_button` and
  `whisper` return `{:rejected, :dead}` — ghosts don't touch the living.

  ## Events

  Broadcast on `Aimongus.PubSub`, topic `"match:<match_id>"`. Spectators
  are god-view per the spec, so role assignments are public:

    * `{:player_joined, id, name, pos}`
    * `:match_started` then `{:role_assigned, id, role}` per player
    * `{:moved, id, pos}`
    * `{:task_progress, id, task_id, pct}` (integer 0–100),
      `{:task_done, id, task_id}`
    * `{:killed, victim_id, killer_id, pos}`
    * `{:body_reported, reporter_id, pos}`, `{:button_pressed, id}`,
      `:meeting_called`
    * `{:whisper, from_id, audience_ids, text}`
    * `{:game_over, winner}` where `winner` is `Rules.winner/1`'s shape

  `Rules.winner/1` is only evaluated once the match is in `:free_roam`
  (it's phase-blind): at `start_match` (degenerate role mixes end
  immediately, which is correct Among Us semantics) and after every kill
  and task completion.
  """

  use GenServer

  alias Aimongus.Game.{Pathfind, Personality, Rules, State}
  alias Aimongus.Game.Map, as: GameMap

  @registry Aimongus.MatchRegistry
  @room_candidates 8
  @max_whisper_bytes 500

  defstruct match_id: nil,
            state: nil,
            actions: %{},
            tick_ms: 100,
            auto_tick?: true,
            shuffle_roles?: true

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
  """
  @spec submit_intent(term(), State.Player.id(), term()) ::
          :ok | {:rejected, term()}
  def submit_intent(match_id, player_id, intent) do
    GenServer.call(via(match_id), {:intent, player_id, intent})
  end

  @doc "The authoritative `%State{}` snapshot."
  @spec state(term()) :: State.t()
  def state(match_id), do: GenServer.call(via(match_id), :state)

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
    server = %{server | state: %{state | phase: :free_roam}}

    broadcast(server, :match_started)
    Enum.each(ids, &broadcast(server, {:role_assigned, &1, state.players[&1].role}))

    check_winner(server)
  end

  defp maybe_advance(%{state: %{phase: :free_roam}} = server), do: advance_tick(server)
  defp maybe_advance(server), do: server

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
    cond do
      server.state.phase != :free_roam -> {{:rejected, :wrong_phase}, server}
      not Map.has_key?(server.state.players, player_id) -> {{:rejected, :unknown_player}, server}
      true -> dispatch_intent(server, player_id, intent)
    end
  end

  defp dispatch_intent(server, id, {:move_to, dest}), do: exec_move(server, id, dest)
  defp dispatch_intent(server, id, {:do_task, task_id}), do: exec_task(server, id, task_id)
  defp dispatch_intent(server, id, {:kill, target}), do: exec_kill(server, id, target)
  defp dispatch_intent(server, id, :report), do: exec_report(server, id)
  defp dispatch_intent(server, id, :press_button), do: exec_button(server, id)
  defp dispatch_intent(server, id, {:whisper, text}), do: exec_whisper(server, id, text)

  defp dispatch_intent(server, id, {:whisper, text, _target}),
    do: exec_whisper(server, id, text)

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
        not Rules.kill_capable?(killer) -> :cannot_kill
        state.tick < killer.kill_ready_at -> {:cooldown, killer.kill_ready_at - state.tick}
        Rules.distance(killer.pos, victim.pos) > state.config.kill_range -> :out_of_range
        true -> nil
      end

    if rejection do
      {{:rejected, rejection}, server}
    else
      case State.kill(state, id, target_id) do
        {:ok, state} ->
          victim_pos = state.players[target_id].pos

          server = %{
            server
            | state: state,
              actions: server.actions |> Map.delete(id) |> Map.delete(target_id)
          }

          broadcast(server, {:killed, target_id, id, victim_pos})
          {:ok, check_winner(server)}

        {:error, :illegal_kill} ->
          {{:rejected, :illegal_kill}, server}
      end
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
          {:ok, call_meeting(server)}
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
        {:ok, call_meeting(server)}
    end
  end

  defp exec_whisper(server, id, text) do
    player = server.state.players[id]

    cond do
      not player.alive? ->
        {{:rejected, :dead}, server}

      not is_binary(text) or text == "" or byte_size(text) > @max_whisper_bytes ->
        {{:rejected, :invalid_text}, server}

      true ->
        audience = Rules.whisper_audience(server.state, id)
        broadcast(server, {:whisper, id, audience, text})
        {:ok, server}
    end
  end

  ## Meetings & game over

  # Freezes the world exactly where it stands (Task 5 takes it from here).
  defp call_meeting(server) do
    players =
      Map.new(server.state.players, fn {id, player} -> {id, %{player | path: []}} end)

    server = %{server | state: %{server.state | players: players, phase: :meeting}, actions: %{}}
    broadcast(server, :meeting_called)
    server
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
    :ok
  end

  defp manhattan({x1, y1}, {x2, y2}), do: abs(x1 - x2) + abs(y1 - y2)
end
