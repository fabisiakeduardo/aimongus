defmodule Aimongus.LLM.Client do
  @moduledoc """
  Behaviour for the LLM provider that drives agents.

  `complete/2` receives a rendered prompt and implementation-specific
  `opts` (model, temperature, api keys, ...) and returns the decoded JSON
  envelope the model produced — the same `{"reasoning": ..., "intent": ...}`
  shape `Aimongus.LLM.Intent.parse/1` accepts, as a string-keyed map.

  Implementations are expected to be stateless; the agent runtime (the
  `Aimongus.Agent` side) picks a module from config and calls it once per
  decision point.
  """

  @callback complete(prompt :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
