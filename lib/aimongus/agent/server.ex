defmodule Aimongus.Agent.Server do
  @moduledoc """
  One process per agent: owns the pawn's private `Aimongus.Agent.Memory`,
  polls the LLM on a cadence and on trigger events, and submits the
  parsed intent back to `Aimongus.Game.Server`.

  This module is where the spec's information isolation is enforced.
  Three rules make it hold:

    * **Agents never see the god view.** The server never calls
      `Game.Server.state/1` and never subscribes to the `match:<id>`
      PubSub topic (roles, hints, votes and kill positions all flow
      there). It pulls `Game.Server.view_for/2` — the filtered
      per-player slice — and receives events only as casts the engine
      routes to *its* player (`Game.Server.register_agent/3`).
    * **The LLM can't take the agent down (or stall the lobby).** Each
      `Client.complete/3` runs in a `Task.Supervisor.async_nolink` task
      bounded by `:llm_timeout`. An adapter that hangs, errors, or
      crashes costs one decision cycle — and on a speak slot the server
      self-passes with `:nothing` so a hung model never holds the floor.
    * **Reasoning is spectator-only.** The model's `reasoning` is
      broadcast as `{:reasoning, player_id, summary}` on the match topic
      (which agents never subscribe to) and folded into the agent's own
      memory. It never enters another agent's view.

  ## Poll cycle

  Each poll: `view_for/2` → `Prompt.build/1` (view + memory) →
  `Client.complete/3` (timeout-bounded task) → `Intent.parse/1` →
  `Game.Server.submit_intent/3`. A `{:rejected, reason}` reply is
  written to hard memory as engine feedback; a `{:hint, ...}` reply from
  `investigate` likewise. Newly visible corpses are noticed by diffing
  the view's `visible_bodies` against what the agent already saw.

  Polls are *decision points*, not heartbeats: the LLM is only called
  when the pawn may act — free roam (always, incl. ghosts), its own
  speak slot, or voting while alive. A `{:speak_request}` for someone
  else, a lobby phase, or a meeting slot that's not yours costs no call.

  ## Triggers

  Routed casts (see `Aimongus.Game.Server` "Agent event routing") wake a
  poll immediately instead of waiting for the timer:

    * `{:heard_whisper, whisper}` — recorded to social memory, then a
      poll so the pawn can react
    * `:speak_request` — poll to answer the floor (LLM failure →
      `:nothing` passes the slot)
    * `{:meeting_started, reason}`, `:voting_started`, `:meeting_ended`,
      `:match_started`, `{:body_seen}` — poll
    * `{:heard_speech, id, text}` — buffered; flushed into social memory
      when the meeting ends (during the meeting the transcript lives in
      `view.meeting.history`, so remembering it live would render every
      line twice)
    * `{:voted, id, choice}` — social memory (votes are public)
    * `{:ejected, id, role}`, `:no_ejection`, `{:game_over, winner}` —
      hard memory; game over stops polling

  ## Options

    * `:poll_ms` — free-roam poll cadence in ms (default `6_000`), or
      `:manual` to disable the timer entirely; triggers still poll and
      `poll/1` drives cycles by hand (deterministic tests)
    * `:llm_opts` — keyword list passed to `Client.complete/3` (adapter
      opts, e.g. `stub: pid` for `Aimongus.LLM.Stub`)
    * `:llm_timeout` — ms bound on the adapter call (default `30_000`)
    * `:task_supervisor` — `Task.Supervisor` running LLM calls
      (default `Aimongus.AgentTaskSupervisor`)
    * `:memory` — initial `Aimongus.Agent.Memory`

  `start_link/3` registers the agent in `Aimongus.MatchRegistry` under
  `{match_id, player_id}` and returns `{:error, reason}` when the match
  or the player doesn't exist.
  """

  use GenServer

  alias Aimongus.Agent.Memory
  alias Aimongus.Game.Server, as: GameServer
  alias Aimongus.LLM.{Client, Intent, Prompt}

  require Logger

  @registry Aimongus.MatchRegistry
  @default_poll_ms 6_000
  @default_llm_timeout 30_000
  @task_supervisor Aimongus.AgentTaskSupervisor

  defstruct match_id: nil,
            player_id: nil,
            memory: nil,
            poll_ms: @default_poll_ms,
            llm_opts: [],
            llm_timeout: @default_llm_timeout,
            task_supervisor: @task_supervisor,
            tick: nil,
            seen_bodies: MapSet.new(),
            speech_log: [],
            over?: false

  ## Public API

  @doc """
  Starts an agent for `player_id` in `match_id` and registers it with
  the match engine. When the player doesn't exist or the match server
  isn't running, init stops with `:unknown_player` / `:match_down` —
  callers wanting the error tuple (rather than an exit through the
  link) should start unlinked or via a supervisor.
  """
  @spec start_link(term(), term(), keyword()) :: GenServer.on_start()
  def start_link(match_id, player_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {match_id, player_id, opts}, name: via(match_id, player_id))
  end

  @doc false
  def child_spec({match_id, player_id}), do: child_spec({match_id, player_id, []})

  def child_spec({match_id, player_id, opts}) do
    %{
      id: {__MODULE__, match_id, player_id},
      start: {__MODULE__, :start_link, [match_id, player_id, opts]}
    }
  end

  @doc """
  Runs one poll cycle synchronously and returns its outcome:

    * `{:submitted, intent, reply}` — an intent reached the engine
    * `{:skipped, reason}` — the view offered no decision (not your
      speak slot, lobby, game over, ...)
    * `{:error, reason}` — the LLM call or the view fetch failed

  Because calls are processed after earlier casts, `poll/1` also works
  as a mailbox sync: when it returns, every routed event already
  delivered has been handled — the deterministic test hook.
  """
  @spec poll(GenServer.server()) ::
          {:submitted, term(), term()} | {:skipped, term()} | {:error, term()}
  def poll(server), do: GenServer.call(server, :poll, :infinity)

  @doc "The agent's private `%Aimongus.Agent.Memory{}`."
  @spec memory(GenServer.server()) :: Memory.t()
  def memory(server), do: GenServer.call(server, :memory)

  @doc "The via-tuple the agent registers under in `Aimongus.MatchRegistry`."
  @spec via(term(), term()) :: {:via, Registry, {term(), tuple()}}
  def via(match_id, player_id), do: {:via, Registry, {@registry, {match_id, player_id}}}

  ## GenServer callbacks

  @impl true
  def init({match_id, player_id, opts}) do
    case try_register(match_id, player_id) do
      :ok ->
        state = %__MODULE__{
          match_id: match_id,
          player_id: player_id,
          memory: Keyword.get(opts, :memory, Memory.new()),
          poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
          llm_opts: Keyword.get(opts, :llm_opts, []),
          llm_timeout: Keyword.get(opts, :llm_timeout, @default_llm_timeout),
          task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor)
        }

        {:ok, schedule_poll(state)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp try_register(match_id, player_id) do
    GameServer.register_agent(match_id, player_id, self())
  catch
    :exit, _reason -> {:error, :match_down}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    {state, outcome} = poll_cycle(state)
    {:reply, outcome, state}
  end

  def handle_call(:memory, _from, state), do: {:reply, state.memory, state}

  @impl true
  def handle_info(:poll, state) do
    {state, _outcome} = poll_cycle(state)
    {:noreply, schedule_poll(state)}
  end

  # Stray task messages (`{ref, result}` / `{:DOWN, ...}`) from LLM calls
  # that timed out land here — the task was already accounted for.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:heard_whisper, whisper}, state) do
    text =
      case whisper.to do
        nil -> "#{whisper.from} whispered: \"#{whisper.text}\""
        to -> "#{whisper.from} whispered to #{to}: \"#{whisper.text}\""
      end

    {:noreply, state |> remember_social(text) |> wake()}
  end

  def handle_cast(:speak_request, state), do: {:noreply, wake(state)}

  def handle_cast({:meeting_started, reason}, state) do
    {:noreply,
     state |> remember_hard("a meeting was called — #{meeting_reason(reason)}") |> wake()}
  end

  def handle_cast({:heard_speech, speaker, text}, state) do
    # buffered, not remembered: during the meeting the transcript is
    # already in view.meeting.history — flushed to social memory at
    # :meeting_ended so the claims survive after the transcript is gone
    {:noreply, %{state | speech_log: state.speech_log ++ [{speaker, text}]}}
  end

  def handle_cast(:voting_started, state) do
    {:noreply, state |> remember_hard("the discussion ended — voting is open") |> wake()}
  end

  def handle_cast({:voted, voter, choice}, state) do
    {:noreply, remember_social(state, "#{voter} voted for #{choice}")}
  end

  def handle_cast({:ejected, id, nil}, state) do
    {:noreply, remember_hard(state, "#{id} was ejected (role not revealed)")}
  end

  def handle_cast({:ejected, id, role}, state) do
    {:noreply, remember_hard(state, "#{id} was ejected — revealed as #{role_name(role)}")}
  end

  def handle_cast(:no_ejection, state) do
    {:noreply, remember_hard(state, "the vote was inconclusive — nobody was ejected")}
  end

  def handle_cast(:meeting_ended, state) do
    {:noreply, state |> remember_hard("the meeting ended") |> flush_speeches() |> wake()}
  end

  def handle_cast({:game_over, winner}, state) do
    state =
      state
      |> remember_hard("the match is over — winner: #{inspect(winner)}")
      |> flush_speeches()

    {:noreply, %{state | over?: true}}
  end

  def handle_cast(:match_started, state), do: {:noreply, wake(state)}
  def handle_cast(:body_seen, state), do: {:noreply, wake(state)}

  # Unknown/misdirected events are dropped — an agent must survive a
  # message it doesn't understand, never crash on it.
  def handle_cast(_message, state), do: {:noreply, state}

  ## Poll cycle

  # Triggers run the same cycle as the timer: fetch the filtered view,
  # record world changes, then decide — but only call the LLM when the
  # pawn actually has a decision to make.
  defp poll_cycle(%{over?: true} = state), do: {state, {:skipped, :game_over}}

  defp poll_cycle(state) do
    case fetch_view(state) do
      {:ok, view} ->
        state = %{state | tick: Map.get(view, :tick)}
        state = note_new_bodies(state, view)

        if decidable?(view) do
          decide(state, view)
        else
          {state, {:skipped, skip_reason(view)}}
        end

      {:error, :match_down} ->
        # the engine is gone — the match this agent played no longer
        # exists; stay idle rather than hammering a dead registry key
        {%{state | over?: true}, {:error, :match_down}}

      {:error, reason} ->
        Logger.warning("agent #{inspect(state.player_id)} view_for failed: #{inspect(reason)}")

        {state, {:error, reason}}
    end
  end

  defp fetch_view(state) do
    GameServer.view_for(state.match_id, state.player_id)
  catch
    :exit, _reason -> {:error, :match_down}
  end

  # Only phases with a real pending decision burn an LLM call. In a
  # meeting that means "do I hold the floor?" — every other slot is
  # someone else's problem and speaking would be rejected anyway.
  defp decidable?(view) do
    case view.phase do
      :free_roam -> true
      :meeting -> get_in(view, [:meeting, :your_turn?]) == true
      :voting -> Map.get(view, :alive?, true)
      _other -> false
    end
  end

  defp skip_reason(%{phase: :meeting}), do: :not_your_turn
  defp skip_reason(%{phase: :voting}), do: :dead
  defp skip_reason(%{phase: phase}), do: phase

  defp decide(state, view) do
    prompt =
      view
      # heard whispers already live in social memory (delivered by cast
      # at event time) — passing view.whispers too would render each one
      # twice in the same section
      |> Map.delete(:whispers)
      |> Map.put(:memory, state.memory)
      |> Prompt.build()

    case llm_call(state, prompt) do
      {:ok, text} -> apply_llm_reply(state, view, text)
      {:error, reason} -> {fail_slot(state, view), {:error, {:llm, reason}}}
    end
  end

  defp apply_llm_reply(state, view, text) do
    case Intent.parse(text) do
      {:ok, %{reasoning: reasoning, intent: intent}} ->
        broadcast_reasoning(state, reasoning)
        state = remember_hard(state, "thought: #{reasoning}")

        case submit(state, intent) do
          {:error, :match_down} ->
            {%{state | over?: true}, {:error, :match_down}}

          reply ->
            state = note_reply(state, intent, reply)

            state =
              case reply do
                # a well-formed but illegal intent during our own speak
                # slot must not leave the floor held — pass it
                {:rejected, _reason} -> fail_slot(state, view)
                _other -> state
              end

            {state, {:submitted, intent, reply}}
        end

      {:error, reason} ->
        state =
          state
          |> remember_hard(
            "your last reply was malformed (#{inspect(reason)}) — reply with exactly one JSON object"
          )
          |> fail_slot(view)

        {state, {:error, {:parse, reason}}}
    end
  end

  # A failed decision cycle must still release the floor: during a speak
  # slot a hung or broken LLM answers with :nothing rather than stalling
  # the lobby until meeting_seconds expires.
  defp fail_slot(state, %{phase: :meeting, meeting: %{your_turn?: true}}) do
    submit(state, :nothing)
    state
  end

  defp fail_slot(state, _view), do: state

  defp note_reply(state, _intent, :ok), do: state

  defp note_reply(state, _intent, {:ok, {:hint, target, verdict}}) do
    remember_hard(state, "investigation result: #{target} reads #{verdict}")
  end

  defp note_reply(state, intent, {:rejected, reason}) do
    remember_hard(state, "your intent #{inspect(intent)} was rejected: #{inspect(reason)}")
  end

  defp submit(state, intent) do
    GameServer.submit_intent(state.match_id, state.player_id, intent)
  catch
    :exit, _reason -> {:error, :match_down}
  end

  defp broadcast_reasoning(state, reasoning) do
    # the match topic is god-view — agents never subscribe, so this is
    # spectator-only by construction (requirement: reasoning never
    # enters another agent's view)
    Phoenix.PubSub.broadcast(
      Aimongus.PubSub,
      "match:#{state.match_id}",
      {:reasoning, state.player_id, reasoning}
    )
  end

  # The adapter call runs unlinked under a Task.Supervisor: a crashed
  # adapter reports `{:exit, _}` here instead of taking the agent (and
  # the floor) down with it — the `Task.yield` {:exit} gap a linked
  # Task.async would leave open.
  defp llm_call(state, prompt) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Client.complete(state.player_id, prompt, state.llm_opts)
      end)

    case Task.yield(task, state.llm_timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:adapter_exit, reason}}
      nil -> {:error, :timeout}
    end
  end

  ## Memory

  defp note_new_bodies(state, view) do
    Enum.reduce(List.wrap(view[:visible_bodies]), state, fn body, state ->
      if MapSet.member?(state.seen_bodies, body.player_id) do
        state
      else
        name = body[:name] || to_string(body.player_id)

        state = %{
          state
          | seen_bodies: MapSet.put(state.seen_bodies, body.player_id)
        }

        remember_hard(state, "you found #{name}'s body at #{place(body)}")
      end
    end)
  end

  defp flush_speeches(state) do
    state =
      Enum.reduce(state.speech_log, state, fn {speaker, text}, state ->
        line =
          case text do
            nil -> "#{speaker} passed their speak slot"
            text -> "#{speaker} said in the meeting: \"#{text}\""
          end

        remember_social(state, line)
      end)

    %{state | speech_log: []}
  end

  defp remember_hard(state, text) do
    %{state | memory: Memory.remember_hard(state.memory, {state.tick, text})}
  end

  defp remember_social(state, text) do
    %{state | memory: Memory.remember_social(state.memory, {state.tick, text})}
  end

  defp place(%{room: nil, pos: pos}), do: "a corridor #{pos_str(pos)}"
  defp place(%{room: room}), do: room
  defp place(_other), do: "an unknown spot"

  defp pos_str({x, y}), do: "(#{x}, #{y})"
  defp pos_str(_other), do: ""

  defp meeting_reason({:report, id}), do: "#{id} reported a body"
  defp meeting_reason({:button, id}), do: "#{id} pressed the emergency button"
  defp meeting_reason(other), do: inspect(other)

  defp role_name(role), do: role |> to_string() |> String.replace("_", " ")

  ## Timer

  defp schedule_poll(%{over?: true} = state), do: state
  defp schedule_poll(%{poll_ms: :manual} = state), do: state

  defp schedule_poll(%{poll_ms: poll_ms} = state) when is_integer(poll_ms) do
    Process.send_after(self(), :poll, poll_ms)
    state
  end

  # A trigger cast that asks for an immediate decision cycle.
  defp wake(%{over?: true} = state), do: state

  defp wake(state) do
    {state, _outcome} = poll_cycle(state)
    state
  end
end
