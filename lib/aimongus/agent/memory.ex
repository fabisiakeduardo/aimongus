defmodule Aimongus.Agent.Memory do
  @moduledoc """
  An agent's private two-tier memory — the only thing separating what a
  pawn knows from what the match knows.

    * `hard` — events the engine vouched for: things the pawn itself
      observed (a player entering vision, a body found, its own intent
      being rejected). Ground truth; the prompt presents these as the
      agent's own eyes.
    * `social` — claims other agents made (meeting statements, whispers
      the pawn overheard). Never verified: the prompt marks every social
      line as an unverified claim, and an agent may only cite hard
      memory as eyewitness evidence.

  Entries are `{tick, text}` tuples; `tick` may be `nil` when no world
  clock applies (a bare `text` string given to `remember_*` is stored as
  `{nil, text}`). Both lists are bounded independently to `limit`
  entries each — when a list is full the *oldest* entries drop, so
  recency beats ancient history.
  """

  @default_limit 50

  defstruct hard: [], social: [], limit: @default_limit

  @type entry :: {non_neg_integer() | nil, String.t()}
  @type t :: %__MODULE__{
          hard: [entry()],
          social: [entry()],
          limit: pos_integer()
        }

  @doc """
  An empty memory. `:limit` (default `#{@default_limit}`) caps *each*
  list; it must be a positive integer.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    unless is_integer(limit) and limit > 0 do
      raise ArgumentError, ":limit must be a positive integer, got: #{inspect(limit)}"
    end

    %__MODULE__{limit: limit}
  end

  @doc """
  Appends a ground-truth observation — `{tick, text}` or bare `text`.
  """
  @spec remember_hard(t(), entry() | String.t()) :: t()
  def remember_hard(%__MODULE__{} = memory, entry) do
    %{memory | hard: append(memory.hard, entry, memory.limit)}
  end

  @doc """
  Appends a claim another player made (meeting speech, an overheard
  whisper) — `{tick, text}` or bare `text`.
  """
  @spec remember_social(t(), entry() | String.t()) :: t()
  def remember_social(%__MODULE__{} = memory, entry) do
    %{memory | social: append(memory.social, entry, memory.limit)}
  end

  defp append(entries, entry, limit) do
    (entries ++ [normalize(entry)]) |> Enum.take(-limit)
  end

  defp normalize({tick, text}) when is_binary(text), do: {tick, text}
  defp normalize(text) when is_binary(text), do: {nil, text}
end
