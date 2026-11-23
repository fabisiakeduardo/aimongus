defmodule Aimongus.Game.MapTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.Map

  # Two rooms joined by floor and corridor cells, a task marker (T1) and an
  # emergency button (B) inside Cafeteria.
  @ascii """
  #########
  #CCCMMM.#
  #CT1CMM.#
  #CCC.MM.#
  #CB..MM.#
  #########

  C: Cafeteria
  M: MedBay
  """

  describe "parse/1" do
    test "returns a %Map{} with tiles keyed by {x, y} positions" do
      map = Map.parse(@ascii)

      assert %Map{} = map
      assert map.width == 9
      assert map.height == 6
      assert map.tiles[{0, 0}] == "#"
      assert map.tiles[{1, 1}] == "C"
      assert map.tiles[{7, 1}] == "."
    end

    test "walkable?/2 is true for floor cells and false for walls / out of bounds" do
      map = Map.parse(@ascii)

      assert Map.walkable?(map, {1, 1})
      assert Map.walkable?(map, {7, 1})
      refute Map.walkable?(map, {0, 0})
      refute Map.walkable?(map, {8, 5})
      refute Map.walkable?(map, {99, 99})
      refute Map.walkable?(map, {-1, 0})
    end

    test "rooms are keyed by legend names and list their floor positions" do
      map = Map.parse(@ascii)

      assert Map.room_names(map) == ["Cafeteria", "MedBay"]
      assert {1, 1} in map.rooms["Cafeteria"]
      assert {4, 1} in map.rooms["MedBay"]

      # corridor floor belongs to no room
      refute {7, 1} in map.rooms["Cafeteria"]
      refute {7, 1} in map.rooms["MedBay"]
    end

    test "task spots and the button are recorded and walkable" do
      map = Map.parse(@ascii)

      assert Map.task_spot(map, "T1") == {2, 2}
      assert map.button == {2, 4}

      assert Map.walkable?(map, {2, 2})
      assert Map.walkable?(map, {3, 2})
      assert Map.walkable?(map, {2, 4})
    end

    test "room_at/2 resolves floor positions to room names" do
      map = Map.parse(@ascii)

      assert Map.room_at(map, {1, 1}) == "Cafeteria"
      assert Map.room_at(map, {6, 3}) == "MedBay"
      # markers embedded in a room resolve to that room
      assert Map.room_at(map, {2, 2}) == "Cafeteria"
      assert Map.room_at(map, {2, 4}) == "Cafeteria"
      # corridor, walls and out-of-bounds resolve to nil
      assert Map.room_at(map, {7, 2}) == nil
      assert Map.room_at(map, {0, 0}) == nil
      assert Map.room_at(map, {99, 99}) == nil
    end

    test "marker cells are included in their room's position list" do
      map = Map.parse(@ascii)

      assert {2, 2} in map.rooms["Cafeteria"]
      assert {3, 2} in map.rooms["Cafeteria"]
      assert {2, 4} in map.rooms["Cafeteria"]
    end

    test "raises when the floor is not fully connected" do
      disconnected = """
      #####
      #C#M#
      #####

      C: Cafeteria
      M: MedBay
      """

      assert_raise ArgumentError, ~r/not fully connected/, fn ->
        Map.parse(disconnected)
      end
    end
  end

  describe "load/0 (bundled skeld_like map)" do
    test "loads a %Map{} with the expected named rooms" do
      map = Map.load()

      assert %Map{} = map
      names = Map.room_names(map)
      assert length(names) in 12..15

      for expected <-
            ~w(Cafeteria Weapons Navigation O2 Shields Communications Electrical
               MedBay Storage Reactor Admin Security) ++ ["Upper Engine", "Lower Engine"] do
        assert expected in names
      end
    end

    test "every task spot and the button is walkable and inside a room" do
      map = Map.load()

      assert map.tasks |> map_size() >= 8

      for {task_id, pos} <- map.tasks do
        assert Map.walkable?(map, pos), "task #{task_id} at #{inspect(pos)} is not walkable"
        assert Map.room_at(map, pos) != nil, "task #{task_id} at #{inspect(pos)} is not in a room"
      end

      assert Map.walkable?(map, map.button)
      assert Map.room_at(map, map.button) == "Cafeteria"
    end

    test "every room position is walkable and resolves back to its room" do
      map = Map.load()

      for {name, positions} <- map.rooms, pos <- positions do
        assert Map.walkable?(map, pos), "#{name} pos #{inspect(pos)} not walkable"
        assert Map.room_at(map, pos) == name
      end
    end

    test "all walkable tiles are mutually reachable (full connectivity)" do
      map = Map.load()

      walkable =
        for {pos, ch} <- map.tiles, ch != "#", into: MapSet.new(), do: pos

      [start | _] = MapSet.to_list(walkable)
      assert reachable_count(map, start) == MapSet.size(walkable)
    end
  end

  defp reachable_count(map, start) do
    bfs(:queue.from_list([start]), MapSet.new([start]), map)
  end

  defp bfs(queue, seen, map) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        MapSet.size(seen)

      {{:value, {x, y}}, queue} ->
        neighbors =
          for {dx, dy} <- [{1, 0}, {-1, 0}, {0, 1}, {0, -1}],
              pos = {x + dx, y + dy},
              Map.walkable?(map, pos),
              not MapSet.member?(seen, pos),
              do: pos

        queue = Enum.reduce(neighbors, queue, &:queue.in/2)
        seen = Enum.reduce(neighbors, seen, &MapSet.put(&2, &1))
        bfs(queue, seen, map)
    end
  end
end
