defmodule Aimongus.LLM.Client do
  @moduledoc """
  Behaviour for the LLM provider that drives agents.

  `complete/2` receives a rendered prompt and implementation-specific
  `opts` (model, api keys, timeouts, test seams ...) and returns the
  raw text the model produced — expected to be the
  `{"reasoning": ..., "intent": ...}` JSON envelope
  `Aimongus.LLM.Intent.parse/1` accepts. Adapters stay dumb pipes;
  parsing is the caller's job.

  Implementations are expected to be stateless; the agent runtime (the
  `Aimongus.Agent` side) picks a module per agent via `adapter_for/1` —
  `Application.get_env(:aimongus, :llm_adapters)` maps agent ids to
  adapter modules with a `:default` fallback — and calls it once per
  decision point.
  """

  @callback complete(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Resolves the adapter module configured for `agent`.

  Reads `Application.get_env(:aimongus, :llm_adapters)` — a map of
  agent id => adapter module, with `:default` as fallback. Returns
  `nil` when nothing is configured.
  """
  @spec adapter_for(term()) :: module() | nil
  def adapter_for(agent \\ :default) do
    adapters = Application.get_env(:aimongus, :llm_adapters, %{})
    Map.get(adapters, agent) || Map.get(adapters, :default)
  end

  @doc """
  Resolves `agent`'s configured adapter and calls its `complete/2`.

  Every resolved call — success or error — is reported to
  `Aimongus.Match.Manager.track_call/2` so the daily
  `DAILY_LLM_BUDGET_USD` guard counts real spend. No manager running →
  the report is a no-op.

  Returns `{:error, {:no_adapter, agent}}` when no adapter is
  configured for the agent (and no `:default` exists).
  """
  @spec complete(term(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def complete(agent, prompt, opts \\ []) do
    case adapter_for(agent) do
      nil ->
        {:error, {:no_adapter, agent}}

      adapter ->
        Aimongus.Match.Manager.track_call(adapter, model: opts[:model])
        adapter.complete(prompt, opts)
    end
  end
end
