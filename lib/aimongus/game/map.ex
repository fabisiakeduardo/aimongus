defmodule Aimongus.Game.Map do
  @moduledoc """
  Parses and exposes the ship's ASCII tilemap.

  The map text has two sections separated by a blank line:

    * a rectangular grid of cells
    * a legend mapping room letters to room names (`X: Name`)

  Grid characters:

    * `#` — wall (not walkable)
    * `.` — corridor floor (walkable, belongs to no room)
    * `A`-`Z` letters (except `B` and `T`) — room floor; every room letter
      must appear in the legend
    * `B` — the emergency button spot
    * `T` followed by digits, e.g. `T3` or `T10` — a task spot with id
      `"T3"`/`"T10"`; the task position is the `T` cell

  Positions are `{x, y}` tuples with `{0, 0}` at the top-left corner.

  `parse/1` validates the map: rows must be uniform, every letter needs a
  legend entry, task markers need digits, there is exactly one button, and
  a flood fill from any walkable cell must reach every walkable cell.
  """

  defstruct tiles: %{},
            rooms: %{},
            room_cells: %{},
            legend: %{},
            tasks: %{},
            button: nil,
            width: 0,
            height: 0

  @type pos :: {non_neg_integer(), non_neg_integer()}
  @type t :: %__MODULE__{
          tiles: %{pos() => String.t()},
          rooms: %{String.t() => [pos()]},
          room_cells: %{pos() => String.t()},
          legend: %{String.t() => String.t()},
          tasks: %{String.t() => pos()},
          button: pos() | nil,
          width: non_neg_integer(),
          height: non_neg_integer()
        }

  @map_path Path.expand("maps/skeld_like.txt", __DIR__)
  @external_resource @map_path
  @map_text File.read!(@map_path)
  @cache_key {__MODULE__, :bundled_map}

  @dirs [{1, 0}, {-1, 0}, {0, 1}, {0, -1}]

  @doc "Returns the bundled `skeld_like` ship map (parsed once, then cached)."
  @spec load() :: t()
  def load do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        map = parse(@map_text)
        :persistent_term.put(@cache_key, map)
        map

      map ->
        map
    end
  end

  @doc "Parses map text (grid + legend) into a validated `%Map{}`."
  @spec parse(String.t()) :: t()
  def parse(text) when is_binary(text) do
    {grid_lines, legend_lines} = split_sections(text)
    {tiles, width, height} = parse_grid(grid_lines)
    legend = parse_legend(legend_lines)

    validate_chars!(tiles)

    letter_cells = for {pos, ch} <- tiles, room_letter?(ch), do: {pos, ch}
    validate_letters!(letter_cells, legend)

    tasks = parse_tasks(tiles)
    button = parse_button(tiles)

    validate_connected!(tiles)

    {rooms, room_cells} = build_rooms(tiles, letter_cells, legend)

    %__MODULE__{
      tiles: tiles,
      rooms: rooms,
      room_cells: room_cells,
      legend: legend,
      tasks: tasks,
      button: button,
      width: width,
      height: height
    }
  end

  @doc "Whether `pos` is a floor cell a character can stand on."
  @spec walkable?(t(), pos()) :: boolean()
  def walkable?(%__MODULE__{tiles: tiles}, pos) do
    case Map.get(tiles, pos) do
      nil -> false
      "#" -> false
      _other -> true
    end
  end

  @doc "The name of the room containing `pos`, or `nil` for corridors/walls."
  @spec room_at(t(), pos()) :: String.t() | nil
  def room_at(%__MODULE__{room_cells: room_cells}, pos), do: Map.get(room_cells, pos)

  @doc "Sorted list of the map's room names."
  @spec room_names(t()) :: [String.t()]
  def room_names(%__MODULE__{rooms: rooms}), do: rooms |> Map.keys() |> Enum.sort()

  @doc "Position of task `task_id` (e.g. `\"T3\"`); raises for unknown ids."
  @spec task_spot(t(), String.t()) :: pos()
  def task_spot(%__MODULE__{tasks: tasks}, task_id), do: Map.fetch!(tasks, task_id)

  @doc "Position of the emergency button spot, or `nil`."
  @spec button_spot(t()) :: pos() | nil
  def button_spot(%__MODULE__{button: button}), do: button

  ## Parsing

  defp split_sections(text) do
    lines = text |> String.split("\n") |> Enum.map(&String.trim_trailing/1)
    {grid, rest} = Enum.split_while(lines, &(&1 != ""))
    legend = rest |> Enum.drop(1) |> Enum.reject(&(&1 == ""))
    {grid, legend}
  end

  defp parse_grid([]), do: raise(ArgumentError, "map has no grid rows")

  defp parse_grid(lines) do
    rows = Enum.map(lines, &String.graphemes/1)

    width =
      case rows |> Enum.map(&length/1) |> Enum.uniq() do
        [w] -> w
        widths -> raise ArgumentError, "map rows have inconsistent widths: #{inspect(widths)}"
      end

    tiles =
      for {row, y} <- Enum.with_index(rows),
          {ch, x} <- Enum.with_index(row),
          into: %{},
          do: {{x, y}, ch}

    {tiles, width, length(rows)}
  end

  defp parse_legend(lines) do
    Map.new(lines, fn line ->
      case Regex.run(~r/^([A-Z])\s*:\s*(.+)$/, line) do
        [_, letter, name] -> {letter, String.trim(name)}
        _ -> raise ArgumentError, "invalid legend line: #{inspect(line)}"
      end
    end)
  end

  defp validate_chars!(tiles) do
    Enum.each(tiles, fn {pos, ch} ->
      unless ch in ~w(# . B T) or room_letter?(ch) or digit?(ch) do
        raise ArgumentError, "invalid map character #{inspect(ch)} at #{inspect(pos)}"
      end
    end)
  end

  defp validate_letters!(letter_cells, legend) do
    Enum.each(letter_cells, fn {pos, ch} ->
      unless Map.has_key?(legend, ch) do
        raise ArgumentError, "room letter #{inspect(ch)} at #{inspect(pos)} has no legend entry"
      end
    end)

    used = letter_cells |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    case Map.keys(legend) -- MapSet.to_list(used) do
      [] -> :ok
      unused -> raise ArgumentError, "legend letters never used on the map: #{inspect(unused)}"
    end
  end

  defp parse_tasks(tiles) do
    {tasks, digit_cells} =
      tiles
      |> Enum.filter(fn {_pos, ch} -> ch == "T" end)
      |> Enum.map_reduce([], fn {{x, y} = pos, _}, acc ->
        digits = digit_run(tiles, x, y)

        if digits == "" do
          raise ArgumentError, "task marker T at #{inspect(pos)} is not followed by digits"
        end

        cells = for i <- 1..String.length(digits), do: {x + i, y}
        {{pos, "T" <> digits}, cells ++ acc}
      end)

    stray =
      tiles
      |> Enum.filter(fn {_pos, ch} -> digit?(ch) end)
      |> Enum.map(&elem(&1, 0))
      |> Kernel.--(digit_cells)

    if stray != [] do
      raise ArgumentError, "digit cells not part of a T<n> marker: #{inspect(stray)}"
    end

    Enum.reduce(tasks, %{}, fn {pos, id}, acc ->
      if Map.has_key?(acc, id) do
        raise ArgumentError, "duplicate task id #{inspect(id)}"
      end

      Map.put(acc, id, pos)
    end)
  end

  defp digit_run(tiles, x, y) do
    Stream.iterate(x + 1, &(&1 + 1))
    |> Enum.reduce_while("", fn nx, acc ->
      case Map.get(tiles, {nx, y}) do
        ch when is_binary(ch) -> if digit?(ch), do: {:cont, acc <> ch}, else: {:halt, acc}
        nil -> {:halt, acc}
      end
    end)
  end

  defp parse_button(tiles) do
    case for {pos, "B"} <- tiles, do: pos do
      [] -> nil
      [pos] -> pos
      many -> raise ArgumentError, "multiple emergency buttons: #{inspect(many)}"
    end
  end

  ## Rooms

  defp build_rooms(tiles, letter_cells, legend) do
    room_cells = Map.new(letter_cells, fn {pos, ch} -> {pos, legend[ch]} end)

    room_cells =
      tiles
      |> Enum.filter(fn {_pos, ch} -> marker?(ch) end)
      |> Enum.reduce(room_cells, fn {pos, _}, acc ->
        case marker_room(tiles, legend, pos) do
          nil -> acc
          name -> Map.put(acc, pos, name)
        end
      end)

    rooms =
      room_cells
      |> Enum.group_by(fn {_pos, name} -> name end, fn {pos, _name} -> pos end)
      |> Map.new(fn {name, positions} -> {name, Enum.sort(positions)} end)

    {rooms, room_cells}
  end

  # BFS through marker cells (B/T/digits) to the nearest room-letter cell.
  defp marker_room(tiles, legend, start) do
    do_marker_room(:queue.from_list([start]), MapSet.new([start]), tiles, legend)
  end

  defp do_marker_room(queue, seen, tiles, legend) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        nil

      {{:value, {x, y}}, queue} ->
        neighbors =
          for {dx, dy} <- @dirs, do: {{x + dx, y + dy}, Map.get(tiles, {x + dx, y + dy})}

        case Enum.find(neighbors, fn {_pos, ch} -> room_letter?(ch) end) do
          {_pos, letter} ->
            legend[letter]

          nil ->
            next =
              for {pos, ch} <- neighbors,
                  marker?(ch),
                  not MapSet.member?(seen, pos),
                  do: pos

            queue = Enum.reduce(next, queue, &:queue.in/2)
            seen = Enum.reduce(next, seen, &MapSet.put(&2, &1))
            do_marker_room(queue, seen, tiles, legend)
        end
    end
  end

  ## Connectivity

  defp validate_connected!(tiles) do
    walkable = for {pos, ch} <- tiles, ch != "#", into: MapSet.new(), do: pos

    case Enum.take(walkable, 1) do
      [] ->
        raise ArgumentError, "map has no walkable tiles"

      [start] ->
        seen = flood(:queue.from_list([start]), MapSet.new([start]), tiles)
        missing = MapSet.difference(walkable, seen)

        unless MapSet.size(missing) == 0 do
          sample = missing |> Enum.take(5) |> inspect()

          raise ArgumentError,
                "map floor is not fully connected: #{MapSet.size(missing)} unreachable tiles #{sample}"
        end
    end
  end

  defp flood(queue, seen, tiles) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        seen

      {{:value, {x, y}}, queue} ->
        next =
          for {dx, dy} <- @dirs,
              pos = {x + dx, y + dy},
              Map.get(tiles, pos) not in [nil, "#"],
              not MapSet.member?(seen, pos),
              do: pos

        queue = Enum.reduce(next, queue, &:queue.in/2)
        seen = Enum.reduce(next, seen, &MapSet.put(&2, &1))
        flood(queue, seen, tiles)
    end
  end

  ## Character classes

  defp room_letter?(ch), do: is_binary(ch) and ch =~ ~r/^[A-Z]$/ and ch not in ~w(B T)
  defp digit?(ch), do: is_binary(ch) and ch =~ ~r/^[0-9]$/
  defp marker?(ch), do: ch in ~w(B T) or digit?(ch)
end
