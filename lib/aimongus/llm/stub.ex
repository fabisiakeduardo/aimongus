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

      # A killer lingering on their own victim's corpse is the most
      # suspicious thing possible — walk away and pretend it never
      # happened. Anyone else's body gets reported above instead.
      String.contains?(prompt, "Bodies in sight:") and killer?(prompt) ->
        room = flee_room(prompt)

        Jason.encode!(%{
          reasoning: "walking away from the body before anyone connects me to it",
          intent: %{type: "move_to", target: room}
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
      Regex.match?(
        ~r/#{safe(me)} \(id "[^"]+"\) called this meeting — they reported a body/,
        prompt
      ) ->
        "I found the body — that's why I called this meeting. Who was near the scene?"

      Regex.match?(~r/#{safe(me)} \(id "[^"]+"\) called this meeting — they pressed/, prompt) ->
        "I pressed the button — something felt very wrong out there."

      match = Regex.run(~r/I SAW ([A-Z][a-z]+) kill ([A-Z][a-z]+)/, prompt) ->
        [_, killer, victim] = match
        "I SAW #{killer} kill #{victim} with my own eyes — vote #{killer}!"

      # Under fire: crew gives their REAL alibi and asks who can vouch;
      # a killer fabricates one — claims a room nowhere near the scene
      # and deflects suspicion onto someone else entirely.
      accused?(prompt, me) ->
        defense_line(prompt, me)

      # Somebody just claimed an alibi — check my own sightings. If I
      # actually saw them there, back them up; that's how tables clear
      # innocent players instead of ejecting on vibes.
      line = corroboration(prompt, me) ->
        line

      match = Regex.run(~r/vote ([A-Z][a-z]+)/, prompt) ->
        [_, accused] = match
        accuser = accuser_of(prompt, accused)

        Enum.random([
          "#{accuser} has a point — #{accused} was nowhere near their tasks.",
          "Second that, #{accuser}. #{accused} has been too quiet all match.",
          "Easy #{accuser} — ejecting #{accused} on a hunch is how impostors win.",
          "#{accused}? If #{accuser} saw it, that's enough for me."
        ])

      (last = last_speech(prompt)) && addressed_to_me?(last, me) ->
        {who, _} = last

        "#{who} — I was at #{my_room(prompt)}, doing tasks. Check the log if you don't believe me."

      (last = last_speech(prompt)) && asks_alibi?(elem(last, 1)) ->
        {who, _} = last

        Enum.random([
          "Fair question, #{who} — I was at #{my_room(prompt)}. What about you?",
          "Answering #{who}: #{my_room(prompt)}, on tasks the whole time.",
          "#{who} — #{my_room(prompt)}. And I'd like your alibi too."
        ])

      (last = last_speech(prompt)) && question?(elem(last, 1)) ->
        {who, _} = last

        Enum.random([
          "#{who}, honest answer — I didn't see the body or the killer.",
          "#{who}: I was on tasks at #{my_room(prompt)}, saw nothing suspicious.",
          "Can't help you there, #{who} — my vision's been empty all match."
        ])

      true ->
        suspect = my_suspect(prompt)
        room = body_room(prompt)

        cond do
          # Seen at the scene — that's evidence, cite it.
          room && Regex.match?(~r/- #{safe(suspect)}: at #{Regex.escape(room)},/, prompt) ->
            Enum.random([
              "I saw #{suspect} at #{room} right where the body turned up — explain that.",
              "#{suspect} was AT #{room} before the report. That's not a coincidence."
            ])

          # Never seen all match — pressure them for an alibi.
          Regex.match?(~r/- #{safe(suspect)}: never seen/, prompt) ->
            Enum.random([
              "Nobody has seen #{suspect} all game — where HAVE you been, #{suspect}?",
              "#{suspect} hasn't crossed anyone's path the whole match. Ghost work.",
              "Say your alibi, #{suspect} — none of us can place you anywhere."
            ])

          true ->
            Enum.random([
              "#{suspect}, where exactly were you when the body dropped? Answer that first.",
              "I've been watching #{suspect} — faking tasks, skipping rooms. I'm voting #{suspect}.",
              "#{suspect} is way too comfortable in this meeting. Say your alibi, #{suspect}.",
              "My vote's on #{suspect} — somebody here saw more than they're admitting."
            ])
        end
    end
  end

  # Suspicion grounded in the pawn's own LAST SEEN ledger — like a real
  # player: who was seen near the body room, else who was never seen at
  # all ("where have you been all game?"). Falls back to a stable pick
  # so the accusation still holds across rounds.
  defp my_suspect(prompt) do
    me = self_name(prompt)

    never_seen =
      ~r/- ([A-Z][a-z]+): never seen this match/
      |> Regex.scan(prompt)
      |> Enum.map(&List.last/1)
      |> Enum.reject(&(&1 == me))

    seen_near_body = seen_at_room(prompt, body_room(prompt), me)

    me_id =
      case Regex.run(~r/player id "([^"]+)"/, prompt) do
        [_, id] -> id
        _ -> ""
      end

    cond do
      seen_near_body != [] -> Enum.random(seen_near_body)
      never_seen != [] -> Enum.min_by(never_seen, &:erlang.phash2({me_id, &1}))
      true -> "someone"
    end
  end

  # Where the reported body was — remembered as hard memory ("you
  # found X's body at Room") or inferred from the meeting reason.
  defp body_room(prompt) do
    case Regex.run(~r/body at ([A-Za-z]+)/, prompt) do
      [_, room] -> room
      _ -> nil
    end
  end

  defp seen_at_room(_prompt, nil, _me), do: []

  defp seen_at_room(prompt, room, me) do
    ~r/- ([A-Z][a-z]+): at #{Regex.escape(room)},/
    |> Regex.scan(prompt)
    |> Enum.map(&List.last/1)
    |> Enum.reject(&(&1 == me))
  end

  # The last line someone actually said in this meeting — conversation
  # means answering THAT, not broadcasting into the void.
  defp last_speech(prompt) do
    ~r/- ([A-Z][a-z]+): "([^"]+)"/
    |> Regex.scan(prompt)
    |> List.last()
    |> case do
      [_, who, text] -> {who, text}
      _ -> nil
    end
  end

  defp addressed_to_me?({who, text}, me) do
    me && who != me && String.contains?(text, me)
  end

  defp asks_alibi?(text) do
    Regex.match?(~r/alibi|where were you|name your room|where was it/i, text)
  end

  # Accused at the table. Crew answers truthfully — real room, and a
  # name-drop of whoever actually crossed their path so the table can
  # vouch. A killer fabricates: claims a room away from the scene and
  # deflects the heat onto someone else. A fabricated alibi is exactly
  # what `corroboration/2` is there to catch.
  defp defense_line(prompt, me) do
    if killer?(prompt) do
      scapegoat = scapegoat(prompt, me)
      scene = body_room(prompt) || "Cafeteria"
      room = Enum.random(@demo_rooms -- [scene])

      Enum.random([
        "I was at #{room} on tasks — nowhere near the scene. #{scapegoat} though? #{scapegoat} has been a ghost all game.",
        "Not me. I was at #{room}. You want someone to look at — #{scapegoat} hasn't crossed a single room with anyone.",
        "#{accuser_of(prompt, me)} is pointing at me awfully fast after a body drops. I was at #{room} — keep an eye on #{scapegoat}."
      ])
    else
      case vouch(prompt, me) do
        {ally, room} ->
          Enum.random([
            "I was at #{room} — #{ally} was right there with me, ask them.",
            "Not me — #{ally} saw me at #{room} not long ago. Check with them."
          ])

        nil ->
          Enum.random([
            "That wasn't me — I was at #{my_room(prompt)} on tasks. Check the sightings before you eject a crewmate.",
            "Wrong bean. I was at #{my_room(prompt)} — nobody around, but I had nothing to do with that body.",
            "You want to eject me on a hunch? I was at #{my_room(prompt)} doing tasks the whole time."
          ])
      end
    end
  end

  # Reads the last line said at the table: if it's an alibi claim, compare
  # the claimed room against MY OWN sightings of that player. Match →
  # vouch for them (clears an innocent). Mismatch → call the lie out
  # loud; that's how a fabricated killer alibi gets torn down mid-meeting.
  defp corroboration(prompt, me) do
    with {who, text} <- last_speech(prompt),
         true <- who != me,
         [_, claimed] <- Regex.run(~r/(?:was at|working in|been in|on tasks at) (#{room_alt()})\b/i, text),
         seen when not is_nil(seen) <- last_seen_room(prompt, who) do
      if String.trim(claimed) == seen do
        Enum.random([
          "That checks out — I saw #{who} at #{seen} too. Alibi holds.",
          "#{who}'s telling the truth, I crossed paths with them at #{seen}."
        ])
      else
        Enum.random([
          "That's a lie — I saw #{who} at #{seen}, not #{claimed}.",
          "#{who} says #{claimed} but I literally saw them at #{seen}. Careful."
        ])
      end
    else
      _ -> nil
    end
  end

  defp room_alt do
    (@demo_rooms ++ ["Upper Engine", "Lower Engine", "Security", "Communications"])
    |> Enum.map(&Regex.escape/1)
    |> Enum.join("|")
  end

  defp last_seen_room(prompt, who) do
    case Regex.run(~r/- #{safe(who)}: at (.+?), \d+ ticks ago/, prompt) do
      [_, room] -> String.trim(room)
      _ -> nil
    end
  end

  # Whoever I saw at MY room can vouch for my alibi.
  defp vouch(prompt, me) do
    case my_room(prompt) do
      "somewhere" ->
        nil

      room ->
        ~r/- ([A-Z][a-z]+): at #{Regex.escape(room)}, \d+ ticks ago/
        |> Regex.scan(prompt)
        |> Enum.map(&List.last/1)
        |> Enum.reject(&(&1 == me))
        |> case do
          [] -> nil
          [ally | _] -> {ally, room}
        end
    end
  end

  # A killer under fire redirects the table: pick whoever already looks
  # off (never-seen, seen near the scene) — else bite the accuser back.
  defp scapegoat(prompt, me) do
    case my_suspect(prompt) do
      "someone" -> accuser_of(prompt, me)
      suspect -> suspect
    end
  end

  defp question?(text), do: String.ends_with?(String.trim(text), "?")

  defp accuser_of(prompt, accused) do
    case Regex.run(
           ~r/- ([A-Z][a-z]+): "[^"]*(?:vote|saw|sus)[^"]*#{Regex.escape(accused)}/i,
           prompt
         ) do
      [_, who] -> who
      _ -> "They"
    end
  end

  defp my_room(prompt) do
    case Regex.run(~r/You are at ([A-Za-z]+)/, prompt) do
      [_, room] -> room
      _ -> "somewhere"
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

    lies = Regex.scan(~r/lie — I saw ([A-Z][a-z]+)/, prompt)
    votes = Regex.scan(~r/vote ([A-Z][a-z]+)/, prompt)

    accused =
      cond do
        match = Regex.run(~r/I SAW ([A-Z][a-z]+) kill/, prompt) ->
          List.last(match)

        # A called-out lie is damning — pile onto whoever fabricated
        # an alibi the table could disprove.
        lies != [] ->
          lies |> List.last() |> List.last()

        # Momentum: follow the most recent vote call, not the first.
        votes != [] ->
          votes |> List.last() |> List.last()

        true ->
          nil
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

  # Anywhere but here — a killer leaves the room the body is in.
  defp flee_room(prompt) do
    case Regex.run(~r/You are at ([A-Za-z]+)/, prompt) do
      [_, here] -> Enum.random(@demo_rooms -- [here])
      _ -> Enum.random(@demo_rooms)
    end
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
