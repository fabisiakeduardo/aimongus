defmodule Aimongus.Game.State do
  @moduledoc """
  Authoritative match state — a plain data structure, no processes.

  `%State{}` holds the phase machine position, the players (`%{id =>
  Player}`), unreported bodies, the task win pool, the current tick and the
  merged match config. Everything here is pure data; mutation happens
  through the functions in this module and legality checks live in
  `Aimongus.Game.Rules`.

  ## Config

  `new/1` accepts a map or keyword list merged over these defaults:

    * `:map` — an `Aimongus.Game.Map` (default: the bundled `skeld_like`)
    * `:vision_radius` — tiles, Euclidean (default `6.0`)
    * `:kill_range` — tiles, Euclidean (default `1.5`, i.e. adjacent incl. diagonals)
    * `:kill_cooldown_ticks` — ticks between kills (default `300`, ~30s at 10 Hz)
    * `:whisper_radius` — tiles, Euclidean (default `3.0`)
    * `:tasks_per_player` — task ids drawn per player (default `3`)
    * `:roles` — role list for the match (default: the 9-player mix:
      2 impostors, 1 sheriff, 1 medic, 1 jester, 4 crewmates)
    * `:reveal_role_on_eject` — used by the meeting phase (default `true`)
    * `:tick_ms` — real milliseconds per world tick (default `100`, ~10 Hz)
    * `:move_speed` — tiles a pawn advances per world tick (default `1`)
    * `:task_ticks` — ticks standing on a task spot to finish it
      (default `50`, ~5s at 10 Hz)
    * `:button_range` — Euclidean tiles from the `B` spot allowed to press
      the emergency button (default `1.5`, i.e. on or adjacent)

  ## Tasks and the win pool

  Every player receives a personal task list (`player.tasks`, `%{task_id =>
  done?}`), but only assignments of *task-capable* roles (`:crewmate`,
  `:sheriff`, `:medic`, `:vigilante`) enter `state.tasks` — the global win
  pool checked by `Rules.winner/1`. Impostors, the serial killer and the
  jester get identical-looking lists that are effectively fake: completing
  them never advances the pool.
  """

  alias Aimongus.Game.Map, as: GameMap
  alias Aimongus.Game.Rules

  defmodule Player do
    @moduledoc """
    A single pawn: identity, secret role, personality card, position and
    per-player ability state (kill cooldown, medic protection, vigilante
    shot, current movement path).
    """

    defstruct id: nil,
              name: nil,
              color: nil,
              role: :crewmate,
              personality: nil,
              pos: {0, 0},
              alive?: true,
              tasks: %{},
              path: [],
              kill_ready_at: 0,
              protected_until: nil,
              vigilante_shot_used?: false

    @type id :: term()
    @type t :: %__MODULE__{
            id: id(),
            name: String.t() | nil,
            color: term(),
            role: Aimongus.Game.State.role(),
            personality: Aimongus.Game.Personality.t() | nil,
            pos: Aimongus.Game.Map.pos(),
            alive?: boolean(),
            tasks: %{String.t() => boolean()},
            path: [Aimongus.Game.Map.pos()],
            kill_ready_at: non_neg_integer(),
            protected_until: non_neg_integer() | nil,
            vigilante_shot_used?: boolean()
          }
  end

  @roles [:impostor, :crewmate, :sheriff, :medic, :vigilante, :jester, :serial_killer]

  # Roles whose task assignments count toward the crew task win. Everyone
  # else gets a cosmetic (fake) list.
  @task_roles [:crewmate, :sheriff, :medic, :vigilante]

  @default_roles [
    :impostor,
    :impostor,
    :sheriff,
    :medic,
    :jester,
    :crewmate,
    :crewmate,
    :crewmate,
    :crewmate
  ]

  @default_config %{
    map: nil,
    vision_radius: 6.0,
    kill_range: 1.5,
    kill_cooldown_ticks: 300,
    whisper_radius: 3.0,
    tasks_per_player: 3,
    roles: @default_roles,
    reveal_role_on_eject: true,
    tick_ms: 100,
    move_speed: 1,
    task_ticks: 50,
    button_range: 1.5
  }

  defstruct phase: :lobby,
            players: %{},
            bodies: [],
            tasks: %{},
            tick: 0,
            config: %{},
            map: nil,
            winner: nil

  @type phase ::
          :lobby | :free_roam | :meeting | :voting | :eject | :game_over

  @type role ::
          :impostor | :crewmate | :sheriff | :medic | :vigilante | :jester | :serial_killer

  @type body :: %{
          player_id: Player.id(),
          pos: GameMap.pos(),
          by: Player.id(),
          tick: non_neg_integer()
        }

  @type t :: %__MODULE__{
          phase: phase(),
          players: %{Player.id() => Player.t()},
          bodies: [body()],
          tasks: %{String.t() => boolean()},
          tick: non_neg_integer(),
          config: map(),
          map: GameMap.t(),
          winner: nil | :crew | :impostors | {:solo, Player.id()}
        }

  @doc "Every role the game knows about."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc "Whether `role` is a valid role atom."
  @spec role?(term()) :: boolean()
  def role?(role), do: role in @roles

  @doc "Whether `role`'s tasks count toward the crew task win."
  @spec task_role?(term()) :: boolean()
  def task_role?(role), do: role in @task_roles

  @doc "Builds a fresh `%State{}` in `:lobby`; `config` merges over the defaults."
  @spec new(map() | keyword()) :: t()
  def new(config \\ %{}) do
    config = @default_config |> Map.merge(Map.new(config))

    Enum.each(config.roles, fn role ->
      unless role?(role) do
        raise ArgumentError, "unknown role in config :roles: #{inspect(role)}"
      end
    end)

    %__MODULE__{
      config: config,
      map: config.map || GameMap.load()
    }
  end

  @doc """
  Adds a player. `attrs` requires `:id`; accepts `:name`, `:color`,
  `:role`, `:pos`, `:personality`. `pos` defaults to the map's button spot
  (the Cafeteria gather point) or `{0, 0}` when the map has none.
  """
  @spec add_player(t(), map() | keyword()) :: t()
  def add_player(%__MODULE__{} = state, attrs) do
    attrs = Map.new(attrs)
    id = Map.fetch!(attrs, :id)

    if Map.has_key?(state.players, id) do
      raise ArgumentError, "player #{inspect(id)} already exists"
    end

    role = Map.get(attrs, :role, :crewmate)

    unless role?(role) do
      raise ArgumentError, "unknown role: #{inspect(role)}"
    end

    default_pos = GameMap.button_spot(state.map) || {0, 0}

    player = %Player{
      id: id,
      name: Map.get(attrs, :name),
      color: Map.get(attrs, :color),
      role: role,
      personality: Map.get(attrs, :personality),
      pos: Map.get(attrs, :pos, default_pos)
    }

    %{state | players: Map.put(state.players, id, player)}
  end

  @doc "Fetches a player by id, or `nil`."
  @spec player(t(), Player.id()) :: Player.t() | nil
  def player(%__MODULE__{players: players}, id), do: Map.get(players, id)

  @doc "Replaces (or inserts) a player struct, keyed by its `id`."
  @spec put_player(t(), Player.t()) :: t()
  def put_player(%__MODULE__{} = state, %Player{} = player) do
    %{state | players: Map.put(state.players, player.id, player)}
  end

  @doc "All living players, as a list."
  @spec alive_players(t()) :: [Player.t()]
  def alive_players(%__MODULE__{players: players}) do
    for {_id, p} <- players, p.alive?, do: p
  end

  @doc """
  Assigns roles from an explicit `%{player_id => role}` map. The caller
  (engine) builds the pairing — e.g. by shuffling `config.roles` — so this
  function stays deterministic. Raises on unknown roles or player ids.
  """
  @spec assign_roles(t(), %{Player.id() => role()}) :: t()
  def assign_roles(%__MODULE__{} = state, role_map) when is_map(role_map) do
    Enum.each(role_map, fn {id, role} ->
      unless role?(role), do: raise(ArgumentError, "unknown role: #{inspect(role)}")

      unless Map.has_key?(state.players, id),
        do: raise(ArgumentError, "unknown player id: #{inspect(id)}")
    end)

    players =
      Map.new(state.players, fn {id, p} ->
        {id, %{p | role: Map.get(role_map, id, p.role)}}
      end)

    %{state | players: players}
  end

  @doc """
  Deals `config.tasks_per_player` task ids from the map to every player.

  Assignments belonging to task-capable roles are also registered in
  `state.tasks` (the win pool); killers' and the jester's lists are fakes.
  """
  @spec assign_tasks(t()) :: t()
  def assign_tasks(%__MODULE__{} = state) do
    task_ids = Map.keys(state.map.tasks)
    n = state.config.tasks_per_player

    Enum.reduce(state.players, state, fn {id, player}, state ->
      assigned = task_ids |> Enum.shuffle() |> Enum.take(n)

      state = put_in(state.players[id].tasks, Map.new(assigned, &{&1, false}))

      if task_role?(player.role) do
        pool = Enum.reduce(assigned, state.tasks, &Map.put_new(&2, &1, false))
        %{state | tasks: pool}
      else
        state
      end
    end)
  end

  @doc """
  Marks `task_id` done for `player_id`. If the player is task-capable and
  the task is in the win pool, the pool entry flips to done too. No-ops for
  unknown players or tasks the player was never assigned.
  """
  @spec complete_task(t(), Player.id(), String.t()) :: t()
  def complete_task(%__MODULE__{} = state, player_id, task_id) do
    case state.players[player_id] do
      %Player{tasks: tasks} = player ->
        if Map.has_key?(tasks, task_id) do
          state = put_in(state.players[player_id].tasks[task_id], true)

          if task_role?(player.role) and Map.has_key?(state.tasks, task_id) do
            put_in(state.tasks[task_id], true)
          else
            state
          end
        else
          state
        end

      nil ->
        state
    end
  end

  @doc """
  Applies a kill: victim dies and drops a body at their position, the
  killer's cooldown is set to `tick + kill_cooldown_ticks` (and a
  vigilante's single shot is consumed).

  Checks `Rules.can_kill?/3` first; returns `{:error, :illegal_kill}`
  without touching state when the kill is not legal.
  """
  @spec kill(t(), Player.id(), Player.id()) :: {:ok, t()} | {:error, :illegal_kill}
  def kill(%__MODULE__{} = state, killer_id, victim_id) do
    if Rules.can_kill?(state, killer_id, victim_id) do
      victim = %{state.players[victim_id] | alive?: false, path: []}

      killer =
        %{state.players[killer_id] | kill_ready_at: state.tick + state.config.kill_cooldown_ticks}

      killer =
        if killer.role == :vigilante,
          do: %{killer | vigilante_shot_used?: true},
          else: killer

      body = %{
        player_id: victim_id,
        pos: state.players[victim_id].pos,
        by: killer_id,
        tick: state.tick
      }

      players = state.players |> Map.put(victim_id, victim) |> Map.put(killer_id, killer)
      {:ok, %{state | players: players, bodies: [body | state.bodies]}}
    else
      {:error, :illegal_kill}
    end
  end
end
