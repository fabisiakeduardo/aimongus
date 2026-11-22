defmodule Aimongus.Game.PersonalityTest do
  use ExUnit.Case, async: true

  alias Aimongus.Game.Personality

  describe "traits/0" do
    test "lists the six trait names" do
      assert Personality.traits() ==
               [:deceptiveness, :aggression, :paranoia, :chattiness, :loyalty, :risk]
    end
  end

  describe "random/0" do
    test "returns a %Personality{} with every trait in 1..10" do
      for _ <- 1..50 do
        card = Personality.random()

        assert %Personality{} = card

        for trait <- Personality.traits() do
          value = Map.fetch!(card, trait)
          assert is_integer(value), "#{trait} is not an integer: #{inspect(value)}"
          assert value in 1..10, "#{trait} out of range: #{value}"
        end
      end
    end

    test "produces varied cards" do
      cards = for _ <- 1..20, do: Personality.random()
      assert cards |> Enum.uniq() |> length() > 1
    end
  end

  describe "new/1" do
    test "accepts a complete set of in-range traits" do
      assert {:ok, %Personality{} = card} =
               Personality.new(%{
                 deceptiveness: 9,
                 aggression: 2,
                 paranoia: 5,
                 chattiness: 7,
                 loyalty: 1,
                 risk: 10
               })

      assert card.deceptiveness == 9
      assert card.risk == 10
    end

    test "rejects out-of-range values" do
      assert {:error, _} =
               Personality.new(%{
                 deceptiveness: 11,
                 aggression: 2,
                 paranoia: 5,
                 chattiness: 7,
                 loyalty: 1,
                 risk: 10
               })

      assert {:error, _} =
               Personality.new(%{
                 deceptiveness: 0,
                 aggression: 2,
                 paranoia: 5,
                 chattiness: 7,
                 loyalty: 1,
                 risk: 10
               })
    end

    test "rejects missing traits" do
      assert {:error, _} = Personality.new(%{deceptiveness: 5})
      assert {:error, _} = Personality.new(%{})
    end
  end

  describe "describe/1" do
    test "returns one descriptor string per trait" do
      {:ok, card} =
        Personality.new(%{
          deceptiveness: 9,
          aggression: 2,
          paranoia: 5,
          chattiness: 7,
          loyalty: 1,
          risk: 10
        })

      descriptions = Personality.describe(card)

      assert length(descriptions) == 6
      assert Enum.all?(descriptions, &is_binary/1)
      # extremes map to the low/high labels, middles to the mid label
      assert "a master of lies" in descriptions
      assert "peaceful" in descriptions
      assert "wary" in descriptions
      assert "reckless" in descriptions
    end
  end
end
