defmodule Aimongus.Agent.ServerTest do
  use ExUnit.Case, async: true

  alias Aimongus.Agent.Server, as: AgentServer
  alias Aimongus.Game.Server, as: GameServer
  alias Aimongus.Game.Map, as: GameMap
  alias Aimongus.LLM.Stub

  # Same layout as the game tests: Cafeteria (C) / MedBay (M) joined by a
  # one-tile corridor at (6, 2). Emergency button at {2, 4}.
  #
  # Player ids are words, NOT "p1" — the test env maps "p1" to the
  # fixed-reply NoopAdapter specifically to exercise per-agent adapter
  # selection. Every id here falls through to the :default adapter, which
  # is the scripted Aimongus.LLM.Stub in test.
  #
  # Sorted ids deal roles in order with shuffle_roles: false — "alpha"
  # takes the first role in the list.
  @ascii """
  ############
  #CCCCC#MMMM#
  #CT1CC.MMMM#
  #CT2CC#MMMM#
  #CBCCC#MMMM#
  ############

  C: Cafeteria
  M: MedBay
  """

  defp test_map, do: GameMap.parse(@ascii)

  defp default_players do
    [
      %{id: "alpha", pos: {4, 2}},
      %{id: "beta", pos: {5, 2}},
      %{id: "delta", pos: {8, 3}},
      %{id: "gamma", pos: {4, 3}}
    ]
  end

  defp envelope(intent, reasoning \\ "test reasoning") do
    Jason.encode!(%{"reasoning" => reasoning, "intent" => intent})
  end

  defp nothing_envelope, do: envelope(%{"type" => "nothing"})

  defp start_world(config \\ %{}) do
    match_id = "agent-test-#{System.unique_integer([:positive])}"

    config =
      %{
        map: test_map(),
        players: default_players(),
        roles: [:impostor, :crewmate, :crewmate, :crewmate],
        shuffle_roles: false,
        tasks_per_player: 2,
        auto_tick: false,
        speech_rounds: 1
      }
      |> Map.merge(config)

    {:ok, _pid} = GameServer.start_link(match_id, config)
    # the TEST is the spectator — the god-view topic is fine to subscribe
    Phoenix.PubSub.subscribe(Aimongus.PubSub, "match:#{match_id}")
    match_id
  end

  defp start_running(config \\ %{}) do
    match_id = start_world(config)
    :ok = GameServer.start_match(match_id)
    match_id
  end

  # Starts a scripted Stub plus an AgentServer bound to it. `opts`:
  #   :script   — Stub queue entries (default [nothing]); functions run
  #               inside the stub process (sleep/raise test seams)
  #   :respond  — stateless Stub responder fn (no prompt recording)
  #   everything else is forwarded to AgentServer.start_link/3
  defp start_agent(match_id, player_id, opts \\ []) do
    # unique child id — one test may run several scripted stubs
    stub =
      start_supervised!(%{
        id: {Stub, System.unique_integer([:positive])},
        start: {Stub, :start_link, [Keyword.get(opts, :script, [nothing_envelope()])]}
      })

    llm_opts =
      case Keyword.fetch(opts, :respond) do
        {:ok, fun} -> [respond: fun]
        :error -> [stub: stub]
      end

    agent_opts =
      [poll_ms: :manual, llm_opts: llm_opts]
      |> Keyword.merge(Keyword.drop(opts, [:script, :respond, :llm_opts]))

    pid = start_supervised!({AgentServer, {match_id, player_id, agent_opts}})
    {pid, stub}
  end

  # Drives the match into a meeting: alpha (impostor) kills beta at
  # {5, 2}, gamma (same room, sees the body) reports. Living speakers:
  # alpha, delta, gamma — in that sorted order.
  defp call_meeting(match_id) do
    :ok = GameServer.submit_intent(match_id, "alpha", {:kill, "beta"})
    assert_received {:killed, "beta", "alpha", {5, 2}}

    :ok = GameServer.submit_intent(match_id, "gamma", :report)
    assert_received :meeting_called
    assert_received {:meeting_started, {:report, "gamma"}}
  end

  defp prompts_contain(stub, needle) do
    Enum.any?(Stub.prompts(stub), &(&1 =~ needle))
  end

  describe "polling" do
    test "a stub move_to intent lands in the engine and the pawn moves" do
      match_id = start_running()

      {pid, _stub} =
        start_agent(match_id, "gamma",
          script: [envelope(%{"type" => "move_to", "target" => "MedBay"})]
        )

      assert {:submitted, {:move_to, "MedBay"}, :ok} = AgentServer.poll(pid)
      assert GameServer.state(match_id).players["gamma"].path != []

      GameServer.step(match_id)
      assert_received {:moved, "gamma", _pos}
    end

    test "reasoning is broadcast to spectators and never reaches other agents" do
      match_id = start_running()

      {alpha, _alpha_stub} =
        start_agent(match_id, "alpha",
          script: [envelope(%{"type" => "nothing"}, "i saw beta vent")]
        )

      {delta, delta_stub} = start_agent(match_id, "delta")

      assert {:submitted, :nothing, :ok} = AgentServer.poll(alpha)
      assert_received {:reasoning, "alpha", "i saw beta vent"}

      AgentServer.poll(delta)
      refute prompts_contain(delta_stub, "i saw beta vent")
    end

    test "poll_ms schedules polls on a timer" do
      match_id = start_running()
      {_pid, stub} = start_agent(match_id, "gamma", poll_ms: 20)

      Process.sleep(150)
      assert length(Stub.prompts(stub)) >= 2
    end

    test "a failed LLM call does not kill the agent — it retries next cycle" do
      match_id = start_running()

      {pid, _stub} =
        start_agent(match_id, "gamma", script: [{:error, :boom}, nothing_envelope()])

      assert {:error, _reason} = AgentServer.poll(pid)
      assert Process.alive?(pid)
      assert {:submitted, :nothing, :ok} = AgentServer.poll(pid)
    end

    test "a crashing adapter task does not take the agent down" do
      match_id = start_running()

      # the fun runs inside the stub agent — it dies on the raise (and
      # its supervisor restarts it with the same script, so the next
      # poll crashes the same way)
      {pid, _stub} =
        start_agent(match_id, "gamma", script: [fn _prompt -> raise "kaboom" end])

      assert {:error, _reason} = AgentServer.poll(pid)
      assert Process.alive?(pid)
      assert {:error, _reason} = AgentServer.poll(pid)
      assert Process.alive?(pid)
    end

    test "a rejected intent is fed back into hard memory" do
      match_id = start_running()

      {pid, _stub} =
        start_agent(match_id, "gamma",
          script: [envelope(%{"type" => "kill", "target" => "beta"})]
        )

      assert {:submitted, {:kill, "beta"}, {:rejected, :cannot_kill}} =
               AgentServer.poll(pid)

      assert Enum.any?(AgentServer.memory(pid).hard, fn {_tick, text} ->
               text =~ "cannot_kill"
             end)
    end

    test "match_started wakes agents in the lobby" do
      match_id = start_world()
      {pid, stub} = start_agent(match_id, "gamma")

      :ok = GameServer.start_match(match_id)

      # poll/1 syncs the agent's mailbox: the :match_started wake-poll
      # already ran by the time this second poll returns, so two prompts
      # means the trigger fired — one prompt would mean it did not
      AgentServer.poll(pid)
      assert length(Stub.prompts(stub)) >= 2
    end
  end

  describe "registration" do
    test "starting an agent for a missing player or match fails cleanly" do
      match_id = start_running()

      # unlinked start: a failed registration returns the stop reason as
      # an error tuple instead of propagating an exit to the caller
      assert {:error, :unknown_player} =
               GenServer.start(AgentServer, {match_id, "ghost", poll_ms: :manual})

      assert {:error, :match_down} =
               GenServer.start(AgentServer, {"no-such-match", "alpha", poll_ms: :manual})
    end
  end

  describe "information isolation" do
    test "a heard whisper enters social memory and the next prompt; non-hearers never see it" do
      match_id = start_running()
      {alpha, alpha_stub} = start_agent(match_id, "alpha")
      {gamma, gamma_stub} = start_agent(match_id, "gamma")
      {delta, delta_stub} = start_agent(match_id, "delta")
      {beta, beta_stub} = start_agent(match_id, "beta")

      # beta whispers at {5, 2}: alpha (d 1) and gamma (d ~1.41) hear it;
      # delta sits in MedBay (~3.16 out) and the speaker hears nothing
      assert :ok = GameServer.submit_intent(match_id, "beta", {:whisper, "secret msg", nil})

      AgentServer.poll(alpha)
      AgentServer.poll(gamma)
      AgentServer.poll(delta)
      AgentServer.poll(beta)

      assert prompts_contain(alpha_stub, "secret msg")
      assert prompts_contain(gamma_stub, "secret msg")
      refute prompts_contain(delta_stub, "secret msg")
      refute prompts_contain(beta_stub, "secret msg")

      assert Enum.any?(AgentServer.memory(gamma).social, fn {_tick, text} ->
               text =~ "secret msg"
             end)
    end

    test "a sheriff's hint comes back as the intent reply — never routed to other agents" do
      match_id = start_running(%{roles: [:sheriff, :impostor, :crewmate, :crewmate]})

      {alpha, _stub} =
        start_agent(match_id, "alpha",
          script: [envelope(%{"type" => "investigate", "target" => "beta"})]
        )

      {gamma, gamma_stub} = start_agent(match_id, "gamma")

      assert {:submitted, {:investigate, "beta"}, {:ok, {:hint, "beta", :suspicious}}} =
               AgentServer.poll(alpha)

      # the god-view spectator feed gets its tagged copy — agents don't
      assert_received {:hint, "alpha", "beta", :suspicious}

      assert Enum.any?(AgentServer.memory(alpha).hard, fn {_tick, text} ->
               text =~ "beta" and text =~ "suspicious"
             end)

      AgentServer.poll(gamma)
      refute prompts_contain(gamma_stub, "suspicious")
      refute prompts_contain(gamma_stub, "hint")
    end

    test "an impostor's view and prompt never reveal another player's role" do
      # alpha and beta are BOTH impostors — friendly fire is on and even
      # impostors don't know each other. Five players so the impostors
      # don't already have the majority at start (2 vs 3 keeps playing).
      match_id =
        start_running(%{
          players: default_players() ++ [%{id: "epsilon", pos: {9, 1}}],
          roles: [:impostor, :impostor, :crewmate, :crewmate, :crewmate]
        })

      assert {:ok, view} = GameServer.view_for(match_id, "alpha")
      assert view.role == :impostor
      assert view.phase == :free_roam

      # alpha sees beta and gamma (same room); delta sits in MedBay
      assert view.visible_players |> Enum.map(& &1.id) |> Enum.sort() ==
               ["beta", "gamma"]

      for player <- view.visible_players do
        assert player |> Map.keys() |> Enum.sort() == [:color, :id, :name, :pos, :room]
      end

      {pid, stub} = start_agent(match_id, "alpha")
      AgentServer.poll(pid)
      [prompt] = Stub.prompts(stub)

      assert prompt =~ "you are an impostor"

      # the same prompt line that mentions beta must never mention a role
      refute prompt =~ ~r/"beta"[^\n]*impostor/
      refute prompt =~ ~r/impostor[^\n]*"beta"/
    end

    test "view_for rejects unknown players" do
      match_id = start_running()
      assert {:error, :unknown_player} = GameServer.view_for(match_id, "nobody")
    end
  end

  describe "trigger events" do
    test "a new visible body wakes the poll and lands in hard memory" do
      match_id = start_running()
      {_alpha, _alpha_stub} = start_agent(match_id, "alpha")
      {gamma, gamma_stub} = start_agent(match_id, "gamma")
      {delta, delta_stub} = start_agent(match_id, "delta")

      # alpha kills beta at {5, 2} — visible from alpha's and gamma's
      # Cafeteria seats, not from delta's MedBay spot
      :ok = GameServer.submit_intent(match_id, "alpha", {:kill, "beta"})
      assert_received {:killed, "beta", "alpha", {5, 2}}

      AgentServer.poll(gamma)

      assert Enum.any?(AgentServer.memory(gamma).hard, fn {_tick, text} ->
               text =~ "body"
             end)

      assert prompts_contain(gamma_stub, "beta's body")

      AgentServer.poll(delta)
      refute prompts_contain(delta_stub, "beta's body")
      refute prompts_contain(delta_stub, "Bodies in sight")
    end

    test "a speak_request is routed only to the floor holder and the speech lands" do
      match_id = start_running()

      # keyed on prompt content so the reply is right no matter when the
      # routed trigger lands — a wake-poll can also fire in free_roam
      # (e.g. :body_seen just before the report) where speak is illegal
      speak_or_pass = fn prompt ->
        if prompt =~ "It is YOUR turn to speak",
          do: envelope(%{"type" => "speak", "text" => "i was in medbay"}),
          else: nothing_envelope()
      end

      {alpha, _alpha_stub} = start_agent(match_id, "alpha", respond: speak_or_pass)
      {delta, _delta_stub} = start_agent(match_id, "delta")
      {gamma, gamma_stub} = start_agent(match_id, "gamma")

      # sync alpha between kill and report: its :body_seen wake must
      # finish while still in free_roam, otherwise an in-flight free-roam
      # decision can legally land inside the meeting (:nothing would
      # pass the floor — the engine is right, but the test needs the
      # deterministic order)
      :ok = GameServer.submit_intent(match_id, "alpha", {:kill, "beta"})
      assert_received {:killed, "beta", "alpha", {5, 2}}
      AgentServer.poll(alpha)
      :ok = GameServer.submit_intent(match_id, "gamma", :report)
      assert_received {:meeting_started, {:report, "gamma"}}

      # alpha's routed speak_request already triggered its poll — the
      # explicit poll just syncs the mailbox (the floor has moved on, so
      # the second poll decides nothing)
      AgentServer.poll(alpha)
      assert_received {:spoke, "alpha", "i was in medbay"}

      # the slot cascaded: delta and gamma answered their own requests
      AgentServer.poll(delta)
      assert_received {:spoke, "delta", nil}
      AgentServer.poll(gamma)
      assert_received {:spoke, "gamma", nil}
      assert_received :voting_started

      # gamma's speak prompt shows the floor line and the public
      # transcript — that's in-game information, not a leak
      assert prompts_contain(gamma_stub, "It is YOUR turn to speak")
      assert prompts_contain(gamma_stub, "i was in medbay")
    end

    test "a hung LLM during a speak slot self-times out and passes with :nothing" do
      match_id = start_running()

      {alpha, _stub} =
        start_agent(match_id, "alpha",
          script: [
            fn _prompt ->
              Process.sleep(500)
              envelope(%{"type" => "speak", "text" => "too late"})
            end
          ],
          llm_timeout: 50
        )

      {_delta, _ds} = start_agent(match_id, "delta")
      {_gamma, _gs} = start_agent(match_id, "gamma")

      call_meeting(match_id)

      AgentServer.poll(alpha)
      assert_received {:spoke, "alpha", nil}
    end

    test "voting_started wakes every living agent; votes tally and eject" do
      match_id = start_running()

      respond = fn prompt ->
        if prompt =~ "VOTING IN PROGRESS",
          do: envelope(%{"type" => "vote", "target" => "skip"}),
          else: nothing_envelope()
      end

      {_alpha, _as} = start_agent(match_id, "alpha", respond: respond)
      {_delta, _ds} = start_agent(match_id, "delta", respond: respond)
      {_gamma, _gs} = start_agent(match_id, "gamma", respond: respond)

      call_meeting(match_id)

      # the whole meeting self-drives through routed triggers: each
      # speak_request wakes its holder (who passes with :nothing), then
      # :voting_started wakes every living agent to vote :skip — no
      # manual polls needed, the events arrive asynchronously
      assert_receive :voting_started, 1_000
      assert_receive {:voted, "alpha", :skip}, 1_000
      assert_receive {:voted, "delta", :skip}, 1_000
      assert_receive {:voted, "gamma", :skip}, 1_000
      assert_receive :no_ejection, 1_000

      state = GameServer.step(match_id)
      assert state.phase == :free_roam
      assert_received :meeting_ended
    end
  end
end
