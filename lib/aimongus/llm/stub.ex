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

  @demo_rooms ~w(Cafeteria Weapons Navigation O2 Shields Storage Admin Electrical MedBay Reactor)

  @doc """
  Phase-aware zero-cost responder for local `AIMONGUS_LLM=stub mix phx.server`
  smoke runs. Parses cues from the rendered prompt and returns a valid
  `{"reasoning", "intent"}` JSON string so pawns walk, work tasks, report
  bodies, speak in meetings and vote without hitting a real LLM.
  """
  @spec demo_responder(String.t()) :: String.t()
  def demo_responder(prompt) when is_binary(prompt) do
    cond do
      String.contains?(prompt, "phase voting") ->
        choice =
          case Regex.scan(~r/\(id "([^"]+)"\)/, prompt) do
            [] -> "skip"
            matches -> matches |> Enum.random() |> List.last()
          end

        Jason.encode!(%{
          reasoning: "weighing the meeting claims before casting my ballot",
          intent: %{type: "vote", target: choice}
        })

      String.contains?(prompt, "phase meeting") ->
        line =
          case Regex.run(~r/I SAW (\S+) kill (\S+)/, prompt) do
            [_, killer, victim] ->
              "I SAW #{killer} kill #{victim} with my own eyes — vote #{killer}!"

            nil ->
              Enum.random([
                "I was working on tasks in MedBay when the alarm went off.",
                "Someone was loitering near Electrical — check alibis!",
                "I saw movement heading out of Cafeteria right before the report.",
                "Too quiet in here. Anyone willing to vouch for their room?"
              ])
          end

        Jason.encode!(%{
          reasoning: "sharing what I know with the table",
          intent: %{type: "speak", text: line}
        })

      String.contains?(prompt, "Bodies in sight:") ->
        Jason.encode!(%{
          reasoning: "spotted a body — calling a meeting immediately",
          intent: %{type: "report"}
        })

      String.contains?(prompt, ~s|"type": "kill"|) and
          lone_target?(prompt) ->
        [_, target] = Regex.run(~r/- [^\n]+ \(id "([^"]+)"\)/, prompt)

        Jason.encode!(%{
          reasoning: "#{target} is alone with me — no witnesses",
          intent: %{type: "kill", target: target}
        })

      true ->
        case Regex.run(~r/- (T\d+)[^\n]*not done/, prompt) do
          [_, task_id] ->
            Jason.encode!(%{
              reasoning: "heading to finish #{task_id}",
              intent: %{type: "do_task", target: task_id}
            })

          nil ->
            room = Enum.random(@demo_rooms)

            Jason.encode!(%{
              reasoning: "patrolling toward #{room}",
              intent: %{type: "move_to", target: room}
            })
        end
    end
  end

  # A kill is only worth it on an isolated target: with a second pawn in
  # sight, the murder gets a living witness who will report and accuse.
  defp lone_target?(prompt) do
    prompt
    |> Regex.scan(~r/- [^\n]+ \(id "[^"]+"\)/)
    |> length() == 1
  end

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
