defmodule Aimongus.LLM.NoopAdapter do
  @moduledoc """
  Test-support `Aimongus.LLM.Client` adapter that never touches the
  outside world: returns a fixed "do nothing" intent envelope.

  Used as the non-default entry in the test env's `:llm_adapters`
  config so per-agent selection tests resolve to something that is
  safe to call without opts — no CLI, no HTTP, no keys.
  """

  @behaviour Aimongus.LLM.Client

  @impl true
  def complete(_prompt, _opts) do
    {:ok, ~s({"reasoning":"noop adapter","intent":{"type":"nothing"}})}
  end
end
