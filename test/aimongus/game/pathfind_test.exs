defmodule Aimongus.Game.PathfindTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.{Map, Pathfind}

  # Pure-corridor grid (no rooms/legend needed) with a wall column at x = 3
  # for rows 1..3, so trips across the map must detour down to row 4.
  #
  #   #########
  #   #..#....#
  #   #..#....#
  #   #..##...#
  #   #.......#
  #   #########
  @ascii """
  #########
  #..#....#
  #..#....#
  #..##...#
  #.......#
  #########
  """

  defp adjacent?({x1, y1}, {x2, y2}), do: abs(x1 - x2) + abs(y1 - y2) == 1

  # The returned path must start at `from`, end at `to`, walk only on floor
  # cells, and move one 4-directional step at a time.
  defp assert_path(map, path, from, to) do
    assert hd(path) == from
    assert List.last(path) == to
    assert Enum.all?(path, &Map.walkable?(map, &1))

    assert path
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [a, b] -> adjacent?(a, b) end)
  end

  describe "path/3 on an open corridor map" do
    test "returns the straight path between two floor tiles" do
      map = Map.parse(@ascii)

      assert {:ok, path} = Pathfind.path(map, {1, 4}, {7, 4})
      assert path == for(x <- 1..7, do: {x, 4})
    end

    test "returns a single-position path when from == to" do
      map = Map.parse(@ascii)

      assert {:ok, [{1, 1}]} = Pathfind.path(map, {1, 1}, {1, 1})
    end

    test "detours around walls without stepping on them" do
      map = Map.parse(@ascii)

      # The wall column at x = 3 forces the path down to row 4 and back up.
      assert {:ok, path} = Pathfind.path(map, {1, 1}, {7, 1})
      assert_path(map, path, {1, 1}, {7, 1})
      refute {3, 1} in path
      refute {3, 2} in path
      refute {3, 3} in path
      refute {4, 3} in path

      # Down 3, across 6, up 3: the shortest detour is 12 steps / 13 cells.
      assert length(path) == 13
    end

    test "returns :unreachable when the destination is a wall" do
      map = Map.parse(@ascii)

      assert :unreachable == Pathfind.path(map, {1, 1}, {3, 1})
    end

    test "returns :unreachable when the destination is out of bounds" do
      map = Map.parse(@ascii)

      assert :unreachable == Pathfind.path(map, {1, 1}, {99, 99})
      assert :unreachable == Pathfind.path(map, {1, 1}, {-1, 0})
    end

    test "returns :unreachable when the origin is a wall" do
      map = Map.parse(@ascii)

      assert :unreachable == Pathfind.path(map, {0, 0}, {1, 4})
    end

    test "returns :unreachable when the destination is sealed off" do
      # A floor cell ringed by walls; built directly since parse/1 would
      # reject a disconnected map.
      sealed = %Map{
        tiles: %{
          {0, 0} => ".",
          {1, 0} => "#",
          {0, 1} => "#",
          {1, 1} => "."
        }
      }

      assert :unreachable == Pathfind.path(sealed, {0, 0}, {1, 1})
    end
  end

  describe "path/3 on the bundled ship map" do
    test "routes between a task spot and the emergency button" do
      map = Map.load()
      from = Map.task_spot(map, "T1")
      to = Map.button_spot(map)

      assert {:ok, path} = Pathfind.path(map, from, to)
      assert_path(map, path, from, to)
      assert length(path) > 1
    end

    test "routes between two distant task spots" do
      map = Map.load()
      from = Map.task_spot(map, "T1")
      to = Map.task_spot(map, "T9")

      assert {:ok, path} = Pathfind.path(map, from, to)
      assert_path(map, path, from, to)

      {x1, y1} = from
      {x2, y2} = to
      assert length(path) >= abs(x1 - x2) + abs(y1 - y2) + 1
    end
  end
end
