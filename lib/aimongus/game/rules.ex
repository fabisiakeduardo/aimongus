defmodule Aimongus.Game.Rules do
  @moduledoc """
  Pure game rules over `Aimongus.Game.State` — no processes, no mutation.

  ## Vision approximation

  `visible?/3` implements the spec's "same-room / corridor line" LOS
  approximation rather than true polygonal line-of-sight: a target
  position is visible when both

    * the Euclidean distance from the viewer is `<= vision_radius`, and
    * either both positions are inside the same room (`Map.room_at/2`
      equal and non-nil — rooms are open rectangles), or they share a row
      or column and every tile on that straight segment is walkable
      (corridors and doorways are axis-aligned lines).

  A straight line that happens to cross rooms is still "visible" — the
  approximation models open doorways, not strict wall occlusion.

  Dead players are ghosts: they see everything. Unknown viewers see
  nothing.

  ## Kills

  `can_kill?/3` checks only: killer role is kill-capable (`:impostor`,
  `:serial_killer`, or `:vigilante` with its single shot unspent), killer
  and victim are distinct living players, victim is within `kill_range`
  (Euclidean), and the killer is off cooldown (`tick >= kill_ready_at`).

  It deliberately does **not** check team or vision: friendly fire is ON
  (blind impostors may kill each other) and kills may legally happen
  through walls at point-blank range — the range is short enough that the
  corner cases are rare and the rule stays simple.

  ## Whispers

  `whisper_audience/2` is radius-only: every living player within
  `whisper_radius` of the speaker hears it. A named `target` selects *who
  is addressed* but cannot extend the audience beyond the radius (radius
  wins, per the SDD ruling in `progress.md`).

  ## Win conditions

  `winner/1` evaluates, in order:

    1. a serial killer alone among the living → `{:solo, id}`
    2. nobody alive → `:impostors` (everyone was killed)
    3. living impostors `>=` living non-impostors → `:impostors`
    4. no impostors and no serial killers alive → `:crew` (killers ejected)
    5. every task in the win pool done (and the pool non-empty) → `:crew`
    6. otherwise `nil` — the match continues

  The jester's solo win is **not** evaluated here: it triggers at eject
  time (Task 6), not from state inspection.
  """

  alias Aimongus.Game.Map, as: GameMap
  alias Aimongus.Game.State
  alias Aimongus.Game.State.Player

  @kill_roles [:impostor, :serial_killer]

  @doc "Euclidean distance between two `{x, y}` tile positions, in tiles."
  @spec distance(GameMap.pos(), GameMap.pos()) :: float()
  def distance({x1, y1}, {x2, y2}) do
    dx = x1 - x2
    dy = y1 - y2
    :math.sqrt(dx * dx + dy * dy)
  end

  @doc """
  Whether `viewer_id` can see `target_pos` right now. See the moduledoc
  for the room/line-of-sight approximation.
  """
  @spec visible?(State.t(), Player.id(), GameMap.pos()) :: boolean()
  def visible?(%State{} = state, viewer_id, target_pos) do
    case State.player(state, viewer_id) do
      nil ->
        false

      %Player{alive?: false} ->
        # ghosts observe everything; the engine decides what to feed them
        true

      %Player{pos: pos} ->
        distance(pos, target_pos) <= state.config.vision_radius and
          los?(state.map, pos, target_pos)
    end
  end

  @doc """
  Whether `killer_id` may kill `victim_id` right now — role, range,
  cooldown, both alive. No team check: friendly fire is ON.
  """
  @spec can_kill?(State.t(), Player.id(), Player.id()) :: boolean()
  def can_kill?(%State{} = state, killer_id, victim_id) do
    with %Player{} = killer <- State.player(state, killer_id),
         %Player{} = victim <- State.player(state, victim_id),
         true <- killer_id != victim_id,
         true <- killer.alive?,
         true <- victim.alive?,
         true <- kill_capable?(killer),
         true <- state.tick >= killer.kill_ready_at,
         true <- distance(killer.pos, victim.pos) <= state.config.kill_range do
      true
    else
      _ -> false
    end
  end

  @doc """
  Living players within `whisper_radius` of `from_id` — the audience that
  hears a whisper. Excludes the speaker; a dead or unknown speaker has no
  audience.
  """
  @spec whisper_audience(State.t(), Player.id()) :: [Player.id()]
  def whisper_audience(%State{} = state, from_id) do
    case State.player(state, from_id) do
      %Player{alive?: true, pos: pos} ->
        radius = state.config.whisper_radius

        state.players
        |> Enum.filter(fn {id, p} ->
          id != from_id and p.alive? and distance(pos, p.pos) <= radius
        end)
        |> Enum.map(&elem(&1, 0))
        # deterministic order — the audience list travels in events and
        # replay tests compare event streams
        |> Enum.sort()

      _no_speaker ->
        []
    end
  end

  @doc """
  `nil` while the match continues, otherwise `:crew`, `:impostors` or
  `{:solo, player_id}` (serial killer last one standing). Jester's solo
  win is decided at eject time, not here.
  """
  @spec winner(State.t()) :: nil | :crew | :impostors | {:solo, Player.id()}
  def winner(%State{players: players}) when map_size(players) == 0, do: nil

  def winner(%State{} = state) do
    alive = State.alive_players(state)
    impostors = Enum.count(alive, &(&1.role == :impostor))
    serial_killers = Enum.filter(alive, &(&1.role == :serial_killer))
    non_impostors = length(alive) - impostors

    cond do
      length(alive) == 1 and hd(alive).role == :serial_killer ->
        {:solo, hd(alive).id}

      alive == [] ->
        :impostors

      impostors > 0 and impostors >= non_impostors ->
        :impostors

      impostors == 0 and serial_killers == [] ->
        :crew

      tasks_done?(state) ->
        :crew

      true ->
        nil
    end
  end

  defp tasks_done?(%State{tasks: tasks}) do
    map_size(tasks) > 0 and Enum.all?(tasks, fn {_id, done?} -> done? end)
  end

  @doc """
  Whether `player`'s role can kill at all — `:impostor`/`:serial_killer`
  always, `:vigilante` while its single shot is unspent. Range, cooldown
  and liveness are checked separately by `can_kill?/3`; the engine uses
  this to give precise intent-rejection reasons.
  """
  @spec kill_capable?(Player.t()) :: boolean()
  def kill_capable?(%Player{role: role, vigilante_shot_used?: shot_used?}) do
    role in @kill_roles or (role == :vigilante and not shot_used?)
  end

  @doc """
  The sheriff's read on a player — `:suspicious` for the secret killers
  (`:impostor`, `:serial_killer`), `:innocent` for everyone else,
  including the other neutrals (jester, vigilante).
  """
  @spec suspicion(Player.t()) :: :suspicious | :innocent
  def suspicion(%Player{role: role}) do
    if role in [:impostor, :serial_killer], do: :suspicious, else: :innocent
  end

  @doc """
  Whether `player` is currently under a medic shield — i.e. `tick` is
  still inside `protected_until`'s window.
  """
  @spec protected?(State.t(), Player.t()) :: boolean()
  def protected?(%State{} = state, %Player{protected_until: protected_until}) do
    protected_until != nil and state.tick < protected_until
  end

  defp los?(map, from, to) do
    same_room?(map, from, to) or clear_line?(map, from, to)
  end

  defp same_room?(map, a, b) do
    case {GameMap.room_at(map, a), GameMap.room_at(map, b)} do
      {nil, _} -> false
      {_, nil} -> false
      {room_a, room_b} -> room_a == room_b
    end
  end

  # Same row or column with every tile on the segment walkable.
  defp clear_line?(map, {x, y1}, {x, y2}) do
    Enum.all?(y1..y2, fn y -> GameMap.walkable?(map, {x, y}) end)
  end

  defp clear_line?(map, {x1, y}, {x2, y}) do
    Enum.all?(x1..x2, fn x -> GameMap.walkable?(map, {x, y}) end)
  end

  defp clear_line?(_map, _from, _to), do: false
end
