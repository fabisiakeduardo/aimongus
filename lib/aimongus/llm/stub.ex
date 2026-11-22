defmodule Aimongus.LLM.Stub do
  @moduledoc """
  Test adapter for `Aimongus.LLM.Client` — returns scripted responses
  instead of calling a real LLM.

  Two ways to script it:

    * **Queued server** — `start_supervised!({Stub, [entry, ...]})`
      starts an agent holding a queue; every `complete/2` call with
      `stub: pid` pops the next entry. This is how tests script a
      *sequence* of replies for one agent. `prompts/1` returns every
      prompt the server received, oldest first, for assertions.

    * **Stateless opts** — `respond: fn prompt -> ... end` computes a
      reply per call, or `responses: [entry, ...]` replies with the
      first entry (single-shot use — a list in opts cannot sequence
      because `complete/2` is stateless; use the queued server for
      that).

  Script entries may be a binary (shorthand for `{:ok, text}`),
  `{:ok, text}`, `{:error, reason}`, or a 1-arity function that is
  called with the prompt and whose result is normalised the same way.
  An exhausted queue returns `{:error, :script_exhausted}`; no script
  at all returns `{:error, :no_script}`.
  """

  @behaviour Aimongus.LLM.Client

  use Agent

  @doc "Starts a scripted stub. `script` is a list of entries — see moduledoc."
  @spec start_link([term()]) :: {:ok, pid()}
  def start_link(script) when is_list(script) do
    Agent.start_link(fn -> %{queue: script, prompts: []} end)
  end

  @impl true
  def complete(prompt, opts) do
    cond do
      server = opts[:stub] -> pop(server, prompt)
      responder = opts[:respond] -> normalize(responder.(prompt))
      responses = opts[:responses] -> first(responses, prompt)
      true -> {:error, :no_script}
    end
  end

  @doc "Every prompt this scripted stub received, oldest first."
  @spec prompts(GenServer.server()) :: [String.t()]
  def prompts(server), do: Agent.get(server, fn state -> Enum.reverse(state.prompts) end)

  defp pop(server, prompt) do
    Agent.get_and_update(server, fn state ->
      state = %{state | prompts: [prompt | state.prompts]}

      case state.queue do
        [] -> {{:error, :script_exhausted}, state}
        [entry | rest] -> {apply_entry(entry, prompt), %{state | queue: rest}}
      end
    end)
  end

  defp first([], _prompt), do: {:error, :script_exhausted}
  defp first([entry | _rest], prompt), do: apply_entry(entry, prompt)

  defp apply_entry(fun, prompt) when is_function(fun, 1), do: normalize(fun.(prompt))
  defp apply_entry(entry, _prompt), do: normalize(entry)

  defp normalize({:ok, _text} = ok), do: ok
  defp normalize({:error, _reason} = error), do: error
  defp normalize(text) when is_binary(text), do: {:ok, text}
end
