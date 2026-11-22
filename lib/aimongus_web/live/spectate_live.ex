defmodule AimongusWeb.SpectateLive do
  @moduledoc """
  The god-view spectator page: a live SVG render of the ship map with
  pawns, bodies, task spots and the emergency button, plus a right-rail
  event/chat feed.

  ## Which match?

  v1 runs a single match at a time. The LiveView watches the match whose
  `GameServer` is registered in `Aimongus.MatchRegistry` under the id
  `match` — the `?match=<id>` param selects it, defaulting to `"live"`
  (the id the forthcoming MatchManager will run the public match under).
  If no server is running under that id the page shows "Waiting for
  match…" and picks the game up as soon as `player_joined` /
  `match_started` events arrive — it is subscribed to
  `"match:<id>"` before any server exists, so nothing is missed.

  ## Events

  Everything broadcast on the match topic is handled in `handle_info/2`
  (see `Aimongus.Game.Server`'s moduledoc for the full list). The topic
  is god-view: roles, kill positions and sheriff hints are all
  spectator-visible. Impostors are marked on the map only by a subtle
  dashed ring — this page is the commentators' view, not a player's.
  """

  use AimongusWeb, :live_view

  alias Aimongus.Game.Server
  alias Aimongus.Game.Map, as: GameMap
  alias Aimongus.Game.Personality
  alias Aimongus.Game.State

  @feed_limit 200
  @cell 26

  # Kill-capable roles get the subtle god-view marker on their pawn.
  @murder_roles [:impostor, :serial_killer]

  @impl true
  def mount(params, _session, socket) do
    match_id = Map.get(params, "match", "live")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Aimongus.PubSub, "match:#{match_id}")
    end

    map = GameMap.load()

    socket =
      socket
      |> assign(
        page_title: "AImongUS — spectate",
        match_id: match_id,
        map: map,
        cell: @cell,
        room_labels: room_labels(map),
        room_hues: room_hues(map),
        decor: map_decor(map),
        fx: [],
        fx_seq: 0,
        ejected_ids: MapSet.new(),
        running?: false,
        phase: :waiting,
        players: %{},
        bodies: [],
        task_pool: %{},
        working: %{},
        speaking: nil,
        votes: %{},
        minds: %{},
        selected_agent: nil,
        winner: nil,
        # starts muted: browsers block audio before the first user
        # gesture, so the header toggle doubles as the unlock click
        muted: true,
        feed: [],
        feed_seq: 0
      )
      |> refresh_state()

    {:ok, socket}
  end

  ## UI events

  # Click a pawn to open its mind panel; click the same pawn again to
  # close. The value arrives as a string — player ids may be atoms, so
  # match against `to_string/1` of each known id.
  @impl true
  def handle_event("select_agent", %{"id" => raw}, socket) do
    id = Enum.find(Map.keys(socket.assigns.players), &(to_string(&1) == raw))

    selected =
      if id && socket.assigns.selected_agent != id, do: id, else: nil

    {:noreply, assign(socket, selected_agent: selected)}
  end

  def handle_event("deselect_agent", _params, socket) do
    {:noreply, assign(socket, selected_agent: nil)}
  end

  # The SoundHook listens for "sound" pushes; `control` syncs mute state
  # and whether the ambient hum should be running, so unmuting mid-match
  # picks the hum up immediately. The toggle click is also the user
  # gesture that satisfies the browser autoplay policy.
  def handle_event("toggle_sound", _params, socket) do
    muted = not socket.assigns.muted
    ambient = not muted and ambient?(socket)

    {:noreply,
     socket
     |> assign(muted: muted)
     |> push_event("sound", %{name: "control", muted: muted, ambient: ambient})}
  end

  ## Match events

  @impl true
  def handle_info({:player_joined, id, name, pos}, socket) do
    # the event carries no color/personality — resync against the server
    # when there is one. During a replay there isn't, so the event
    # itself must populate the pawn or nothing ever renders.
    {:noreply, resync_or(socket, fn socket -> upsert_replay_player(socket, id, name, pos) end)}
  end

  def handle_info(:match_started, socket) do
    socket =
      socket
      |> assign(
        ejected_ids: MapSet.new(),
        bodies: [],
        working: %{},
        speaking: nil,
        votes: %{},
        minds: %{},
        winner: nil
      )
      |> resync_or(fn socket ->
        assign(socket, running?: true, phase: :free_roam)
      end)

    {:noreply, socket |> feed(:system, "Match started") |> sound("ambient")}
  end

  def handle_info({:role_assigned, id, role}, socket) do
    {:noreply, update_player(socket, id, &%{&1 | role: role})}
  end

  def handle_info({:moved, id, pos}, socket) do
    socket =
      if Map.has_key?(socket.assigns.players, id) do
        socket
        |> update_player(id, &%{&1 | pos: pos})
        |> assign(working: Map.delete(socket.assigns.working, id))
      else
        # an event for a match we never caught the start of — resync
        # against the server if there is one; during a replay there
        # isn't, so upsert a bare pawn from the event itself
        resync_or(socket, fn socket -> upsert_replay_player(socket, id, nil, pos) end)
      end

    {:noreply, socket}
  end

  def handle_info({:task_progress, id, task_id, pct}, socket) do
    {:noreply, assign(socket, working: Map.put(socket.assigns.working, id, {task_id, pct}))}
  end

  def handle_info({:task_done, id, task_id}, socket) do
    pool =
      if Map.has_key?(socket.assigns.task_pool, task_id),
        do: Map.put(socket.assigns.task_pool, task_id, true),
        else: socket.assigns.task_pool

    socket =
      socket
      |> assign(task_pool: pool, working: Map.delete(socket.assigns.working, id))
      |> feed(:event, "finished a task", player: id)

    {:noreply, socket}
  end

  def handle_info({:killed, victim, by, pos}, socket) do
    body = %{player_id: victim, pos: pos}

    socket =
      socket
      |> update_player(victim, &%{&1 | alive?: false, pos: pos})
      |> assign(
        bodies: [body | socket.assigns.bodies],
        working: Map.delete(socket.assigns.working, victim)
      )
      |> feed(:event, "was killed by #{player_name(socket.assigns.players, by)}", player: victim)
      |> fx(pos, :kill)
      |> sound("kill")

    {:noreply, socket}
  end

  def handle_info({:kill_blocked, victim}, socket) do
    {:noreply, feed(socket, :event, "survived an attack — the shield held", player: victim)}
  end

  def handle_info({:hint, sheriff, target, verdict}, socket) do
    verdict_text = if verdict == :suspicious, do: "suspicious", else: "innocent"

    {:noreply,
     feed(
       socket,
       :event,
       "investigated #{player_name(socket.assigns.players, target)}: " <>
         verdict_text,
       player: sheriff
     )}
  end

  def handle_info({:protected, medic, target}, socket) do
    {:noreply,
     feed(socket, :event, "shielded #{player_name(socket.assigns.players, target)}",
       player: medic
     )}
  end

  def handle_info({:body_reported, id, pos}, socket) do
    room = GameMap.room_at(socket.assigns.map, pos) || "a corridor"

    {:noreply,
     socket
     |> feed(
       :system,
       "#{player_name(socket.assigns.players, id)} reported a body in #{room}"
     )
     |> fx(pos, :ping)
     |> sound("report")}
  end

  def handle_info({:button_pressed, id}, socket) do
    socket =
      socket
      |> feed(
        :system,
        "#{player_name(socket.assigns.players, id)} pressed the emergency button"
      )
      |> sound("report")

    {:noreply,
     if(socket.assigns.map.button, do: fx(socket, socket.assigns.map.button, :ping), else: socket)}
  end

  def handle_info(:meeting_called, socket) do
    {:noreply, assign(socket, phase: :meeting)}
  end

  def handle_info({:meeting_started, reason}, socket) do
    text =
      case reason do
        {:report, id} ->
          "Discussion — body reported by #{player_name(socket.assigns.players, id)}"

        {:button, id} ->
          "Emergency meeting called by #{player_name(socket.assigns.players, id)}"

        _other ->
          "Meeting started"
      end

    {:noreply, socket |> assign(phase: :meeting) |> feed(:system, text) |> sound("siren")}
  end

  def handle_info({:speak_request, id}, socket) do
    {:noreply, assign(socket, speaking: id)}
  end

  def handle_info({:spoke, id, nil}, socket) do
    {:noreply, feed(socket, :system, "#{player_name(socket.assigns.players, id)} said nothing")}
  end

  def handle_info({:spoke, id, text}, socket) do
    {:noreply, feed(socket, :speech, text, player: id)}
  end

  def handle_info(:voting_started, socket) do
    socket =
      socket
      |> assign(phase: :voting, votes: %{}, speaking: nil)
      |> feed(:system, "Discussion over — time to vote")

    {:noreply, socket}
  end

  def handle_info({:voted, id, choice}, socket) do
    votes = Map.put(socket.assigns.votes, id, choice)

    text =
      if choice == :skip,
        do: "skipped their vote",
        else: "voted for #{player_name(socket.assigns.players, choice)}"

    {:noreply, socket |> assign(votes: votes) |> feed(:event, text, player: id) |> sound("vote")}
  end

  def handle_info({:ejected, id, role}, socket) do
    name = player_name(socket.assigns.players, id)

    text =
      case role do
        nil -> "#{name} was ejected"
        role -> "#{name} was ejected — they were #{role_label(role)}"
      end

    socket =
      socket
      |> update_player(id, &%{&1 | alive?: false})
      |> assign(ejected_ids: MapSet.put(socket.assigns.ejected_ids, id))
      |> feed(:system, text)
      |> sound("eject")

    {:noreply, socket}
  end

  def handle_info(:no_ejection, socket) do
    {:noreply, feed(socket, :system, "No one was ejected")}
  end

  def handle_info(:meeting_ended, socket) do
    socket =
      socket
      |> assign(phase: :free_roam, bodies: [], speaking: nil, votes: %{})
      |> feed(:system, "Meeting ended — back to work")

    {:noreply, socket}
  end

  def handle_info({:whisper, from, target, _audience, text}, socket) do
    {:noreply, feed(socket, :whisper, text, player: from, target: target)}
  end

  def handle_info({:match_timeout, _winner}, socket) do
    {:noreply, feed(socket, :system, "The match hit its time limit")}
  end

  def handle_info({:game_over, winner}, socket) do
    socket =
      socket
      |> assign(phase: :game_over, winner: winner, speaking: nil)
      |> feed(:system, "Game over — #{winner_text(socket.assigns.players, winner)}")
      |> sound(game_over_sound(winner))

    {:noreply, socket}
  end

  def handle_info({:reasoning, id, summary}, socket) do
    # the agents' private monologue — spectator-only. Stored for the
    # mind panel (Task 14); deliberately not mixed into the chat feed.
    {:noreply, assign(socket, minds: Map.put(socket.assigns.minds, id, summary))}
  end

  # Self-cleanup for one-shot map effects (kill flash, report ping): the
  # entry is dropped once its animation has finished. If the message is
  # lost the leftover is invisible anyway — every fx animation ends on a
  # zero-opacity frame.
  def handle_info({:fx_clear, seq}, socket) do
    {:noreply, assign(socket, fx: Enum.reject(socket.assigns.fx, &(&1.seq == seq)))}
  end

  def handle_info(_unknown, socket), do: {:noreply, socket}

  ## State

  defp refresh_state(socket) do
    case fetch_state(socket.assigns.match_id) do
      nil ->
        assign(socket,
          running?: false,
          phase: :waiting,
          players: %{},
          bodies: [],
          task_pool: %{},
          working: %{},
          speaking: nil,
          votes: %{},
          minds: %{},
          selected_agent: nil,
          winner: nil,
          ejected_ids: MapSet.new()
        )

      state ->
        # the match may run a non-bundled map — resync everything
        selected = socket.assigns.selected_agent

        ejected =
          MapSet.filter(socket.assigns.ejected_ids, fn id ->
            match?(%{alive?: false}, state.players[id])
          end)

        assign(socket,
          running?: true,
          phase: state.phase,
          map: state.map,
          room_labels: room_labels(state.map),
          room_hues: room_hues(state.map),
          decor: map_decor(state.map),
          players: state.players,
          bodies: state.bodies,
          task_pool: state.tasks,
          working: %{},
          selected_agent: if(Map.has_key?(state.players, selected), do: selected),
          winner: state.winner,
          ejected_ids: ejected
        )
    end
  end

  defp fetch_state(match_id) do
    case Registry.lookup(Aimongus.MatchRegistry, match_id) do
      [] ->
        nil

      _registered ->
        try do
          Server.state(match_id)
        catch
          :exit, _reason -> nil
        end
    end
  end

  # Resync against the GameServer when one is registered; run `fallback`
  # when there isn't — replay mode, where broadcast events are the only
  # source of truth.
  defp resync_or(socket, fallback) do
    if fetch_state(socket.assigns.match_id) do
      refresh_state(socket)
    else
      fallback.(socket)
    end
  end

  # A bare pawn built purely from a broadcast event — replay mode only,
  # where no GameServer exists to resync from. Keeps any fields a prior
  # event already supplied (a joined name survives a later bare :moved).
  defp upsert_replay_player(socket, id, name, pos) do
    player =
      case socket.assigns.players[id] do
        %State.Player{} = existing ->
          %{existing | name: name || existing.name, pos: pos || existing.pos}

        _other ->
          %State.Player{id: id, name: name, pos: pos || {0, 0}}
      end

    assign(socket,
      players: Map.put(socket.assigns.players, id, player),
      running?: true,
      phase: if(socket.assigns.phase == :waiting, do: :lobby, else: socket.assigns.phase)
    )
  end

  defp update_player(socket, id, fun) do
    case socket.assigns.players[id] do
      nil -> socket
      player -> assign(socket, players: Map.put(socket.assigns.players, id, fun.(player)))
    end
  end

  defp feed(socket, kind, text, opts \\ []) do
    seq = socket.assigns.feed_seq + 1

    entry = %{
      seq: seq,
      kind: kind,
      player: Keyword.get(opts, :player),
      target: Keyword.get(opts, :target),
      text: text
    }

    assign(socket,
      feed: Enum.take([entry | socket.assigns.feed], @feed_limit),
      feed_seq: seq
    )
  end

  # Push a named sound cue to the `SoundHook` JS hook. The client maps
  # each name to a synthesized WebAudio cue and no-ops while muted.
  defp sound(socket, name), do: push_event(socket, "sound", %{name: name})

  # Queue a one-shot map effect (`:kill` flash, `:ping` report ring) at a
  # tile position. Entries self-clear via `{:fx_clear, seq}` a beat after
  # their animation ends.
  defp fx(socket, pos, kind) do
    seq = socket.assigns.fx_seq + 1
    Process.send_after(self(), {:fx_clear, seq}, 2_500)

    assign(socket,
      fx: Enum.take([%{seq: seq, kind: kind, pos: pos} | socket.assigns.fx], 12),
      fx_seq: seq
    )
  end

  # The ship hum loops while a match is live; game over silences it.
  defp ambient?(socket) do
    socket.assigns.running? and socket.assigns.phase not in [:waiting, :game_over]
  end

  # God-view framing: a crew victory is the "win" sting; impostors or a
  # solo killer taking the match is the "lose" sting.
  defp game_over_sound(:crew), do: "win"
  defp game_over_sound(_other), do: "lose"

  ## Template helpers

  @doc false
  def player_name(players, id) do
    case players[id] do
      %{name: name} when is_binary(name) -> name
      _other -> to_string(id)
    end
  end

  @doc false
  def winner_text(players, winner) do
    case winner do
      :crew -> "the Crew wins"
      :impostors -> "the Impostors win"
      {:solo, id} -> "#{player_name(players, id)} wins it all"
      other -> inspect(other)
    end
  end

  @doc false
  def role_label(role) do
    case role do
      :serial_killer -> "the Serial Killer"
      other -> other |> to_string() |> String.replace("_", " ") |> String.capitalize()
    end
  end

  @doc false
  def murder_role?(role), do: role in @murder_roles

  @doc false
  def phase_badge(assigns) do
    case assigns.phase do
      :waiting -> {"Waiting for match", "bg-slate-700/60 text-slate-300"}
      :lobby -> {"Lobby", "bg-sky-500/20 text-sky-300"}
      :free_roam -> {"Free roam", "bg-emerald-500/20 text-emerald-300"}
      :meeting -> {"Meeting", "bg-amber-500/20 text-amber-300"}
      :voting -> {"Voting", "bg-amber-500/20 text-amber-300"}
      :eject -> {"Ejection", "bg-amber-500/20 text-amber-300"}
      :game_over -> {"Game over", "bg-rose-500/20 text-rose-300"}
      _other -> {"Live", "bg-sky-500/20 text-sky-300"}
    end
  end

  @doc false
  def tasks_done(task_pool), do: Enum.count(task_pool, fn {_id, done?} -> done? end)

  @doc false
  def tasks_total(task_pool), do: map_size(task_pool)

  ## Map art direction
  #
  # The map renders as a "stylized space station seen from above": every
  # room gets its own hue, floors checker two shades of that hue, walls
  # cast inner shadows onto neighbouring floor, doors get amber sills,
  # and each room is ringed by a neon edge drawn along its perimeter.

  # Curated hue per bundled room name (all distinct); anything else
  # falls back to a curated wheel indexed by sorted-name order, so
  # custom maps still get well-separated colors.
  @room_palette %{
    "Admin" => 275,
    "Cafeteria" => 35,
    "Electrical" => 52,
    "MedBay" => 195,
    "Navigation" => 218,
    "O2" => 160,
    "Reactor" => 262,
    "Shields" => 140,
    "Storage" => 22,
    "Weapons" => 345
  }

  @palette_wheel [205, 160, 35, 275, 345, 120, 300, 22, 52, 190, 320, 80]

  @dirs4 [{1, 0}, {-1, 0}, {0, 1}, {0, -1}]

  @doc false
  def room_hues(map) do
    map.rooms
    |> Map.keys()
    |> Enum.sort()
    |> Enum.with_index()
    |> Map.new(fn {name, i} ->
      hue =
        Map.get(@room_palette, name) ||
          Enum.at(@palette_wheel, rem(i, length(@palette_wheel)))

      {name, hue}
    end)
  end

  # Static per-map decoration derived once: neon room-edge paths, wall
  # shadow sides, and door sills (corridor tiles touching a room).
  defp map_decor(map) do
    %{
      edges: room_edge_paths(map),
      shadows: floor_shadows(map),
      sills: door_sills(map),
      doors: door_tiles(map)
    }
  end

  # One SVG path per room tracing every boundary segment where the room
  # meets something that isn't itself (wall, corridor, another room).
  defp room_edge_paths(map) do
    for {name, positions} <- map.rooms do
      cells = MapSet.new(positions)

      d =
        for {x, y} <- positions,
            {dx, dy} <- @dirs4,
            not MapSet.member?(cells, {x + dx, y + dy}) do
          edge_segment(x, y, dx, dy)
        end
        |> Enum.join(" ")

      %{name: name, d: d}
    end
  end

  defp edge_segment(x, y, dx, dy) do
    c = @cell

    cond do
      dx == 1 -> "M#{(x + 1) * c} #{y * c}v#{c}"
      dx == -1 -> "M#{x * c} #{y * c}v#{c}"
      dy == 1 -> "M#{x * c} #{(y + 1) * c}h#{c}"
      dy == -1 -> "M#{x * c} #{y * c}h#{c}"
    end
  end

  # Every floor tile side that touches a wall (or the void beyond the
  # hull) gets a soft shadow — that's what makes walls feel raised.
  # Entries are ready-to-render pixel rects plus the gradient id suffix.
  defp floor_shadows(map) do
    for {{x, y}, ch} <- map.tiles,
        ch != "#",
        {dx, dy} <- @dirs4,
        Map.get(map.tiles, {x + dx, y + dy}, "#") == "#" do
      Map.put(shadow_rect(x, y, dx, dy), :side, shadow_side(dx, dy))
    end
  end

  defp shadow_side(0, -1), do: :n
  defp shadow_side(0, 1), do: :s
  defp shadow_side(-1, 0), do: :w
  defp shadow_side(1, 0), do: :e

  defp shadow_rect(x, y, dx, dy) do
    c = @cell
    t = 6

    cond do
      dy == -1 -> %{x: x * c, y: y * c, w: c, h: t}
      dy == 1 -> %{x: x * c, y: (y + 1) * c - t, w: c, h: t}
      dx == -1 -> %{x: x * c, y: y * c, w: t, h: c}
      dx == 1 -> %{x: (x + 1) * c - t, y: y * c, w: t, h: c}
    end
  end

  # Corridor tiles that share a side with a room are doorways; the sill
  # is drawn on the room-facing edge of the corridor tile.
  defp door_sills(map) do
    for {{x, y}, "."} <- map.tiles,
        {dx, dy} <- @dirs4,
        room_letter?(Map.get(map.tiles, {x + dx, y + dy})) do
      sill_rect(x, y, dx, dy)
    end
  end

  defp door_tiles(map) do
    MapSet.new(door_sills(map), &{&1.tile_x, &1.tile_y})
  end

  defp sill_rect(x, y, dx, dy) do
    c = @cell

    rect =
      cond do
        dy == -1 -> %{x: x * c + 3, y: y * c + 1, w: c - 6, h: 2.5}
        dy == 1 -> %{x: x * c + 3, y: (y + 1) * c - 3.5, w: c - 6, h: 2.5}
        dx == -1 -> %{x: x * c + 1, y: y * c + 3, w: 2.5, h: c - 6}
        dx == 1 -> %{x: (x + 1) * c - 3.5, y: y * c + 3, w: 2.5, h: c - 6}
      end

    Map.merge(rect, %{tile_x: x, tile_y: y})
  end

  defp room_letter?(ch), do: is_binary(ch) and ch != "#" and ch != "."

  @doc false
  # Checkerboard floor fill: rooms tint two shades of their hue,
  # corridors two shades of steel-blue, walls near-black, doorway tiles
  # a hair warmer so thresholds read.
  def tile_fill(map, hues, doors, {x, y} = pos) do
    alt? = rem(x + y, 2) == 0

    case tile_kind(map, pos) do
      :wall ->
        "#060a13"

      :corridor ->
        cond do
          MapSet.member?(doors, pos) -> "#1b2340"
          alt? -> "#151d30"
          true -> "#121a2b"
        end

      {:room, name} ->
        hue = Map.get(hues, name, 215)
        if alt?, do: "hsl(#{hue}, 45%, 16%)", else: "hsl(#{hue}, 45%, 13%)"
    end
  end

  @doc false
  # Neon edge color for a room's perimeter path.
  def room_edge_color(hues, name) do
    "hsl(#{Map.get(hues, name, 215)}, 90%, 62%)"
  end

  @doc false
  def tile_kind(map, pos) do
    case Map.get(map.tiles, pos) do
      "#" -> :wall
      "." -> :corridor
      _other -> if name = GameMap.room_at(map, pos), do: {:room, name}, else: :corridor
    end
  end

  @doc false
  def pawn_center({x, y}), do: {x * @cell + div(@cell, 2), y * @cell + div(@cell, 2)}

  @doc false
  # players sorted by id string — a stable render order so LiveView diffs
  # land on the right pawn elements
  def sorted_players(players) do
    players |> Enum.sort_by(fn {id, _p} -> to_string(id) end)
  end

  @doc false
  def alive_count(players), do: Enum.count(players, fn {_id, p} -> p.alive? end)

  @doc false
  # Living players in pawn render order — seats around the meeting table.
  def alive_players(players) do
    for {id, p} <- sorted_players(players), p.alive?, do: {id, p}
  end

  @doc false
  def feed_class(entry), do: "feed-item feed-#{entry.kind}"

  @doc false
  # Mind panel rows for a player's personality card: one per trait, in
  # `Personality.traits/0` order, pairing the raw 1-10 value with the
  # adjective phrase `Personality.describe/1` gives it.
  def trait_rows(player) do
    case player.personality do
      %Personality{} = card ->
        for {trait, phrase} <- Enum.zip(Personality.traits(), Personality.describe(card)) do
          %{
            trait: trait,
            label: trait |> to_string() |> String.capitalize(),
            value: Map.fetch!(card, trait),
            phrase: phrase
          }
        end

      _other ->
        []
    end
  end

  @doc false
  def agent_room(map, player), do: GameMap.room_at(map, player.pos) || "a corridor"

  @doc false
  # the pawn/feed color for a player id; the same player gets the same
  # color everywhere
  def player_color(players, id) do
    case players[id] do
      nil -> "#94a3b8"
      player -> pawn_color(player)
    end
  end

  @doc false
  def pawn_color(player) do
    named_color(player.color) || fallback_color(player.id)
  end

  @doc false
  # Darkened variant of a "#rrggbb" pawn color — used for the backpack
  # and leg shading so the sprite reads as one shaded object.
  def shade("#" <> _ = hex, factor) do
    <<r, g, b>> = hex |> String.trim_leading("#") |> Base.decode16!(case: :mixed)
    "#" <> Base.encode16(<<round(r * factor), round(g * factor), round(b * factor)>>)
  end

  def shade(_other, _factor), do: "#334155"

  @doc false
  # Per-pawn animation offset so the idle bobs don't move in lockstep.
  def bob_delay(id), do: rem(:erlang.phash2(id), 2600)

  @doc false
  def meeting?(phase), do: phase in [:meeting, :voting]

  @doc false
  # Meeting-banner copy: hazard-yellow while discussing, alarm-red once
  # the vote is on.
  def meeting_banner(phase) do
    case phase do
      :meeting -> {"Emergency meeting", ""}
      :voting -> {"Vote now", "voting"}
      _other -> {"Emergency meeting", ""}
    end
  end

  @doc false
  # Chips around the meeting table: absolute-positioned on an ellipse.
  def seat_style(index, count) do
    angle = 2 * :math.pi() * index / max(count, 1) - :math.pi() / 2
    left = 50 + 46 * :math.cos(angle)
    top = 50 + 46 * :math.sin(angle)
    "left: #{Float.round(left, 2)}%; top: #{Float.round(top, 2)}%"
  end

  @doc false
  # Accent color for the winner banner.
  def winner_accent(winner) do
    case winner do
      :crew -> "#22d3ee"
      :impostors -> "#f87171"
      _other -> "#fbbf24"
    end
  end

  @colors %{
    "red" => "#ef4444",
    "blue" => "#3b82f6",
    "green" => "#22c55e",
    "pink" => "#ec4899",
    "orange" => "#f97316",
    "yellow" => "#eab308",
    "black" => "#52525b",
    "white" => "#e4e4e7",
    "purple" => "#a855f7",
    "cyan" => "#22d3ee",
    "lime" => "#a3e635",
    "brown" => "#a16207",
    "banana" => "#fde047",
    "gray" => "#9ca3af",
    "grey" => "#9ca3af",
    "tan" => "#d2b48c",
    "coral" => "#fb7185",
    "maroon" => "#7f1d1d"
  }

  @fallback_colors [
    "#ef4444",
    "#3b82f6",
    "#22c55e",
    "#ec4899",
    "#f97316",
    "#eab308",
    "#a855f7",
    "#22d3ee",
    "#a3e635",
    "#fb7185"
  ]

  defp named_color(color) when is_atom(color), do: named_color(Atom.to_string(color))
  defp named_color(color) when is_binary(color), do: Map.get(@colors, String.downcase(color))
  defp named_color(_other), do: nil

  defp fallback_color(id) do
    Enum.at(@fallback_colors, rem(:erlang.phash2(id), length(@fallback_colors)))
  end

  defp room_labels(map) do
    for {name, positions} <- map.rooms do
      {count, sx, sy} =
        Enum.reduce(positions, {0, 0, 0}, fn {x, y}, {n, ax, ay} -> {n + 1, ax + x, ay + y} end)

      cx = sx / count * @cell + @cell / 2
      cy = sy / count * @cell + @cell / 2
      %{name: name, x: Float.round(cx, 1), y: Float.round(cy, 1)}
    end
  end
end
