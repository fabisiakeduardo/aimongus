defmodule Aimongus.Game.Pathfind do
  @moduledoc """
  A* pathfinding over the ship's tile grid.

  `path/3` finds a shortest 4-directional route between two walkable
  positions of an `Aimongus.Game.Map`, using the Manhattan distance as the
  heuristic. Every step of the returned path lands on a cell for which
  `Aimongus.Game.Map.walkable?/2` is true.
  """

  alias Aimongus.Game.Map, as: GameMap

  @dirs [{1, 0}, {-1, 0}, {0, 1}, {0, -1}]

  @doc """
  Returns `{:ok, path}` — a list of `{x, y}` positions from `from` to `to`
  inclusive — or `:unreachable` when either endpoint is not walkable or no
  route exists.
  """
  @spec path(GameMap.t(), GameMap.pos(), GameMap.pos()) ::
          {:ok, [GameMap.pos()]} | :unreachable
  def path(map, from, to) do
    cond do
      not GameMap.walkable?(map, from) -> :unreachable
      not GameMap.walkable?(map, to) -> :unreachable
      from == to -> {:ok, [from]}
      true -> search(map, from, to)
    end
  end

  ## A* over an open set ordered by f = g + h (a :gb_sets of {f, pos} pairs,
  ## which doubles as our priority queue since {f, pos} is unique per pos).

  defp search(map, from, to) do
    open = :gb_sets.singleton({heuristic(from, to), from})
    g_scores = %{from => 0}
    walk(map, to, open, g_scores, _came_from = %{}, _closed = MapSet.new())
  end

  defp walk(map, goal, open, g_scores, came_from, closed) do
    case :gb_sets.is_empty(open) do
      true ->
        :unreachable

      false ->
        {{_f, pos}, open} = :gb_sets.take_smallest(open)

        cond do
          pos == goal ->
            {:ok, reconstruct(came_from, pos)}

          MapSet.member?(closed, pos) ->
            # Stale queue entry superseded by a cheaper route already expanded.
            walk(map, goal, open, g_scores, came_from, closed)

          true ->
            g = Map.fetch!(g_scores, pos)
            closed = MapSet.put(closed, pos)

            {open, g_scores, came_from} =
              pos
              |> neighbors()
              |> Enum.filter(&GameMap.walkable?(map, &1))
              |> Enum.reject(&MapSet.member?(closed, &1))
              |> Enum.reduce({open, g_scores, came_from}, fn next, acc ->
                relax(acc, pos, next, g + 1, goal)
              end)

            walk(map, goal, open, g_scores, came_from, closed)
        end
    end
  end

  # Record `next` if reaching it via `pos` beats the best cost seen so far.
  defp relax({open, g_scores, came_from}, pos, next, tentative_g, goal) do
    if tentative_g < Map.get(g_scores, next, :infinity) do
      f = tentative_g + heuristic(next, goal)

      {:gb_sets.add_element({f, next}, open), Map.put(g_scores, next, tentative_g),
       Map.put(came_from, next, pos)}
    else
      {open, g_scores, came_from}
    end
  end

  # Walk came_from links from the goal back to the start, building the path
  # front-to-back as we go.
  defp reconstruct(came_from, pos), do: reconstruct(came_from, pos, [pos])

  defp reconstruct(came_from, pos, acc) do
    case Map.fetch(came_from, pos) do
      :error -> acc
      {:ok, parent} -> reconstruct(came_from, parent, [parent | acc])
    end
  end

  defp neighbors({x, y}), do: for({dx, dy} <- @dirs, do: {x + dx, y + dy})

  defp heuristic({x1, y1}, {x2, y2}), do: abs(x1 - x2) + abs(y1 - y2)
end
