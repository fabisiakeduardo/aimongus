defmodule Aimongus.Agent.MemoryTest do
  use ExUnit.Case, async: true

  alias Aimongus.Agent.Memory

  describe "new/1" do
    test "starts empty with the default bound" do
      memory = Memory.new()

      assert %Memory{hard: [], social: [], limit: 50} = memory
    end

    test "accepts a custom :limit" do
      assert %Memory{limit: 3} = Memory.new(limit: 3)
    end

    test "rejects a non-positive :limit" do
      assert_raise ArgumentError, fn -> Memory.new(limit: 0) end
    end
  end

  describe "remember_hard/2" do
    test "appends {tick, text} entries in order" do
      memory =
        Memory.new()
        |> Memory.remember_hard({12, "saw Blue in Electrical"})
        |> Memory.remember_hard({30, "found a body"})

      assert memory.hard == [{12, "saw Blue in Electrical"}, {30, "found a body"}]
      assert memory.social == []
    end

    test "accepts a bare text entry" do
      memory = Memory.remember_hard(Memory.new(), "the match started")

      assert memory.hard == [{nil, "the match started"}]
    end
  end

  describe "remember_social/2" do
    test "appends to the social list, not the hard list" do
      memory =
        Memory.new()
        |> Memory.remember_social({20, "Blue claimed Red vented"})

      assert memory.social == [{20, "Blue claimed Red vented"}]
      assert memory.hard == []
    end
  end

  describe "bound" do
    test "keeps only the last N hard entries" do
      memory =
        1..5
        |> Enum.reduce(Memory.new(limit: 3), fn tick, mem ->
          Memory.remember_hard(mem, {tick, "event #{tick}"})
        end)

      assert memory.hard == [{3, "event 3"}, {4, "event 4"}, {5, "event 5"}]
    end

    test "bounds the social list independently" do
      memory =
        1..5
        |> Enum.reduce(Memory.new(limit: 2), fn tick, mem ->
          Memory.remember_social(mem, {tick, "claim #{tick}"})
        end)

      assert memory.social == [{4, "claim 4"}, {5, "claim 5"}]
    end

    test "hard and social lists have independent bounds" do
      memory =
        Memory.new(limit: 2)
        |> Memory.remember_hard({1, "h1"})
        |> Memory.remember_hard({2, "h2"})
        |> Memory.remember_social({1, "s1"})
        |> Memory.remember_social({2, "s2"})

      assert memory.hard == [{1, "h1"}, {2, "h2"}]
      assert memory.social == [{1, "s1"}, {2, "s2"}]
    end
  end
end
