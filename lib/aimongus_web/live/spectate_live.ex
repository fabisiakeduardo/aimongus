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
        running?: false,
        phase: :waiting,
        players: %{},
        bodies: [],
        task_pool: %{},
        working: %{},
        speaking: nil,
        votes: %{},
        minds: %{},
        winner: nil,
        feed: [],
        feed_seq: 0
      )
      |> refresh_state()

    {:ok, socket}
  end

  ## Match events

  @impl true
  def handle_info({:player_joined, _id, _name, _pos}, socket) do
    # the event carries no color/personality — resync against the server
    {:noreply, refresh_state(socket)}
  end

  def handle_info(:match_started, socket) do
    {:noreply, socket |> refresh_state() |> feed(:system, "Match started")}
  end

  def handle_info({:role_assigned, id, role}, socket) do
    {:noreply, update_player(socket, id, &%{&1 | role: role})}
  end

  def handle_info({:moved, id, pos}, socket) do
    socket =
      if Map.has_key?(socket.assigns.players, id) do
        update_player(socket, id, &%{&1 | pos: pos})
      else
        # an event for a match we never caught the start of (e.g. the
        # server was restarted under the same id) — resync
        refresh_state(socket)
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
     feed(
       socket,
       :system,
       "#{player_name(socket.assigns.players, id)} reported a body in #{room}"
     )}
  end

  def handle_info({:button_pressed, id}, socket) do
    {:noreply,
     feed(
       socket,
       :system,
       "#{player_name(socket.assigns.players, id)} pressed the emergency button"
     )}
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

    {:noreply, socket |> assign(phase: :meeting) |> feed(:system, text)}
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

    {:noreply, socket |> assign(votes: votes) |> feed(:event, text, player: id)}
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
      |> feed(:system, text)

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

    {:noreply, socket}
  end

  def handle_info({:reasoning, id, summary}, socket) do
    # the agents' private monologue — spectator-only. Stored for the
    # mind panel (Task 14); deliberately not mixed into the chat feed.
    {:noreply, assign(socket, minds: Map.put(socket.assigns.minds, id, summary))}
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
          winner: nil
        )

      state ->
        # the match may run a non-bundled map — resync everything
        assign(socket,
          running?: true,
          phase: state.phase,
          map: state.map,
          room_labels: room_labels(state.map),
          players: state.players,
          bodies: state.bodies,
          task_pool: state.tasks,
          working: %{},
          winner: state.winner
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

  @doc false
  # deterministic pastel tile tint per room — distinct rooms, no config
  def room_tint(name) do
    hue = name |> String.to_charlist() |> Enum.sum() |> rem(360)
    "hsl(#{hue}, 35%, 20%)"
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
  def feed_class(entry), do: "feed-item feed-#{entry.kind}"

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
