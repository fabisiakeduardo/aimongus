defmodule Aimongus.Game.Personality do
  @moduledoc """
  A trait card that shapes how an agent plays.

  Six traits, each an integer in `1..10`: `deceptiveness`, `aggression`,
  `paranoia`, `chattiness`, `loyalty`, `risk` (risk-taking). Cards are
  assigned at match start — either via config or `random/0` — and are
  spectator-visible so viewers can pick a villain to root against. Two
  impostors with different cards should play visibly differently.

  `describe/1` renders the card as short adjective phrases suitable for
  injection into an agent's system prompt (Task 10).
  """

  @traits [:deceptiveness, :aggression, :paranoia, :chattiness, :loyalty, :risk]

  @enforce_keys @traits
  defstruct @traits

  @type trait ::
          :deceptiveness | :aggression | :paranoia | :chattiness | :loyalty | :risk

  @type t :: %__MODULE__{
          deceptiveness: 1..10,
          aggression: 1..10,
          paranoia: 1..10,
          chattiness: 1..10,
          loyalty: 1..10,
          risk: 1..10
        }

  # {low (1-3), mid (4-7), high (8-10)} adjective phrases per trait, written
  # to read naturally after "you are ..." in a system prompt.
  @labels %{
    deceptiveness: {"honest to a fault", "somewhat deceptive", "a master of lies"},
    aggression: {"peaceful", "assertive", "ruthless"},
    paranoia: {"trusting", "wary", "deeply paranoid"},
    chattiness: {"quiet", "talkative", "a chatterbox"},
    loyalty: {"self-serving", "dependable", "fiercely loyal"},
    risk: {"cautious", "calculated", "reckless"}
  }

  @doc "The ordered list of trait names on the card."
  @spec traits() :: [trait()]
  def traits, do: @traits

  @doc "Builds a card from a map or keyword list with every trait valued in `1..10`."
  @spec new(%{trait() => integer()} | keyword()) :: {:ok, t()} | {:error, term()}
  def new(values) when is_list(values), do: values |> Map.new() |> new()

  def new(values) when is_map(values) do
    Enum.reduce_while(@traits, {:ok, %{}}, fn trait, {:ok, acc} ->
      case Map.fetch(values, trait) do
        {:ok, v} when is_integer(v) and v in 1..10 ->
          {:cont, {:ok, Map.put(acc, trait, v)}}

        {:ok, v} ->
          {:halt, {:error, {trait, {:out_of_range, v}}}}

        :error ->
          {:halt, {:error, {trait, :missing}}}
      end
    end)
    |> case do
      {:ok, attrs} -> {:ok, struct!(__MODULE__, attrs)}
      error -> error
    end
  end

  @doc "A fully random card — each trait independently in `1..10`."
  @spec random() :: t()
  def random do
    struct!(__MODULE__, Map.new(@traits, fn t -> {t, Enum.random(1..10)} end))
  end

  @doc """
  Renders the card as one short adjective phrase per trait.

  Values `1..3` map to the low label, `4..7` to the middle, `8..10` to the
  high label, e.g. `["a master of lies", "peaceful", "wary", ...]`.
  """
  @spec describe(t()) :: [String.t()]
  def describe(%__MODULE__{} = card) do
    Enum.map(@traits, fn trait ->
      card |> Map.fetch!(trait) |> label_for(trait)
    end)
  end

  defp label_for(value, trait) do
    {low, mid, high} = Map.fetch!(@labels, trait)

    cond do
      value <= 3 -> low
      value <= 7 -> mid
      true -> high
    end
  end
end
