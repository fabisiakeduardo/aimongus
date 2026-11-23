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
        choice = vote_choice(prompt)

        Jason.encode!(%{
          reasoning: "weighing the meeting claims before casting my ballot",
          intent: %{type: "vote", target: choice}
        })

      String.contains?(prompt, "phase meeting") ->
        line = meeting_line(prompt)

        Jason.encode!(%{
          reasoning: "sharing what I know with the table",
          intent: %{type: "speak", text: line}
        })

      # Killers walk away from bodies — a self-report three seconds
      # after the murder reads as scripted. Ghosts see everything but
      # can't call meetings. Living crew reports what it finds.
      String.contains?(prompt, "Bodies in sight:") and not killer?(prompt) and
          not String.contains?(prompt, "You are DEAD") ->
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
            room = patrol_room(prompt)

            Jason.encode!(%{
              reasoning: "patrolling toward #{room}",
              intent: %{type: "move_to", target: room}
            })
        end
    end
  end

  # Meeting talk that reacts to the transcript: a witness speaks up,
  # an accused pawn defends itself, others second a real accusation or
  # press the table for the report details — nobody talks in a vacuum.
  defp meeting_line(prompt) do
    me = self_name(prompt)

    cond do
      Regex.match?(~r/#{safe(me)} \(id "[^"]+"\) called this meeting — they reported a body/, prompt) ->
        "I found the body — that's why I called this meeting. Who was near the scene?"

      Regex.match?(~r/#{safe(me)} \(id "[^"]+"\) called this meeting — they pressed/, prompt) ->
        "I pressed the button — something felt very wrong out there."

      match = Regex.run(~r/I SAW ([A-Z][a-z]+) kill ([A-Z][a-z]+)/, prompt) ->
        [_, killer, victim] = match
        "I SAW #{killer} kill #{victim} with my own eyes — vote #{killer}!"

      accused?(prompt, me) ->
        Enum.random([
          "That wasn't me — check the alibis before you throw a crewmate out the airlock.",
          "Wrong bean. I was doing tasks — who actually SAW anything?",
          "You want to eject me on a hunch? Ask the witness what they really saw."
        ])

      match = Regex.run(~r/vote ([A-Z][a-z]+)/, prompt) ->
        [_, accused] = match
        Enum.random([
          "If #{accused} was seen at the body, that's enough for me — #{accused} goes.",
          "Second that. #{accused} has been too quiet all match.",
          "#{accused}? I can believe it — they were nowhere near their tasks."
        ])

      true ->
        Enum.random([
          "Where was the body found — and who was seen near it?",
          "I want alibis: everyone name your room when the alarm went off.",
          "Someone is lying in this room. Say where you were.",
          "Too quiet in here. Anyone willing to vouch for their room?"
        ])
    end
  end

  # Vote like a player: follow a witnessed kill or a seconded
  # accusation, never vote for yourself, skip when nothing sticks.
  defp vote_choice(prompt) do
    me_id =
      case Regex.run(~r/player id "([^"]+)"/, prompt) do
        [_, id] -> id
        _ -> nil
      end

    accused =
      cond do
        match = Regex.run(~r/I SAW ([A-Z][a-z]+) kill/, prompt) -> List.last(match)
        match = Regex.run(~r/vote ([A-Z][a-z]+)/, prompt) -> List.last(match)
        true -> nil
      end

    candidates =
      ~r/\(id "([^"]+)"\)/
      |> Regex.scan(prompt)
      |> Enum.map(&List.last/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == me_id))

    cond do
      accused && accused != me_id && accused in candidates -> accused
      accused && accused != me_id -> accused
      candidates == [] -> "skip"
      Enum.random(1..3) == 1 -> "skip"
      true -> Enum.random(candidates)
    end
  end

  defp self_name(prompt) do
    case Regex.run(~r/as "([^"]+)" \(player id/, prompt) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp safe(nil), do: "N0MATCH"
  defp safe(name), do: Regex.escape(name)

  defp accused?(_prompt, nil), do: false

  defp accused?(prompt, me) do
    Regex.match?(~r/vote #{Regex.escape(me)}\b/i, prompt) or
      Regex.match?(~r/I SAW #{Regex.escape(me)} kill/, prompt)
  end

  defp killer?(prompt) do
    Regex.match?(~r/you are an? (impostor|serial killer)\./, prompt)
  end

  # Each demo agent patrols its own shuffle of the ship — keyed by the
  # "player id" line in the prompt — so pawns fan out to different
  # sectors instead of conga-lining down the same corridor.
  defp patrol_room(prompt) do
    id =
      case Regex.run(~r/player id "([^"]+)"/, prompt) do
        [_, id] -> id
        _ -> ""
      end

    @demo_rooms
    |> Enum.sort_by(&:erlang.phash2({id, &1}))
    |> Enum.take(4)
    |> Enum.random()
  end

  # A kill is only worth it on an isolated target: with a second pawn in
  # sight, the murder gets a living witness who will report and accuse.
  defp lone_target?(prompt) do
    ~r/- [^\n]+ \(id "[^"]+"\)/
    |> Regex.scan(prompt)
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
