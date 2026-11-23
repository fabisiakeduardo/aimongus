defmodule Aimongus.LLM.PromptTest do
  use ExUnit.Case, async: true

  alias Aimongus.Agent.Memory
  alias Aimongus.Game.Personality
  alias Aimongus.LLM.Prompt

  @role_words ~w(impostor crewmate sheriff medic vigilante jester)

  defp personality do
    {:ok, card} =
      Personality.new(%{
        deceptiveness: 9,
        aggression: 2,
        paranoia: 5,
        chattiness: 8,
        loyalty: 3,
        risk: 6
      })

    card
  end

  defp base_view(overrides \\ %{}) do
    Map.merge(
      %{
        id: "red",
        name: "Red",
        color: "red",
        role: :impostor,
        phase: :free_roam,
        pos: {12, 3},
        room: "Cafeteria",
        tick: 42,
        alive?: true,
        personality: personality(),
        tasks: %{"T1" => false, "T3" => true},
        role_mix: [
          :impostor,
          :impostor,
          :sheriff,
          :medic,
          :jester,
          :crewmate,
          :crewmate,
          :crewmate,
          :crewmate
        ],
        visible_players: [],
        visible_bodies: [],
        whispers: [],
        memory: Memory.new()
      },
      overrides
    )
  end

  describe "build/1 — impostor blindness" do
    test "prompt says the agent's own role but never attaches a role to another player" do
      view =
        base_view(%{
          visible_players: [
            # NB: the raw view deliberately carries `role` — the prompt must
            # drop it. Impostor A must never learn impostor B's role.
            %{id: "blue", name: "Blue", pos: {13, 3}, room: "Cafeteria", role: :impostor},
            %{id: "green", name: "Green", pos: {20, 3}, room: nil, role: :sheriff}
          ]
        })

      prompt = Prompt.build(view)

      assert prompt =~ ~r/you are an impostor/i
      assert prompt =~ "Blue"
      assert prompt =~ "Green"

      # No single line may attach a role word to another player's name/id.
      for other <- ~w(blue green), role <- @role_words ++ ["serial killer"] do
        refute prompt =~ ~r/(?im)^.*#{other}[^\n]*\b#{role}\b.*$/,
               "prompt attaches #{role} to #{other}:\n#{prompt}"

        refute prompt =~ ~r/(?im)^.*\b#{role}\b[^\n]*\b#{other}\b.*$/,
               "prompt attaches #{role} to #{other}:\n#{prompt}"
      end
    end

    test "a crewmate's prompt names its own role correctly" do
      prompt = Prompt.build(base_view(%{role: :crewmate}))

      assert prompt =~ ~r/you are a crewmate/i
      refute prompt =~ ~r/you are an impostor/i
    end
  end

  describe "build/1 — vision isolation" do
    test "a player outside vision does not appear at all" do
      view =
        base_view(%{
          visible_players: [%{id: "blue", name: "Blue", pos: {13, 3}, room: "Cafeteria"}]
        })

      prompt = Prompt.build(view)

      assert prompt =~ "Blue"
      refute prompt =~ "Green"
      refute prompt =~ "(37, 21)"
    end

    test "entities listed in the view are rendered with their position" do
      view =
        base_view(%{
          visible_players: [
            %{id: "green", name: "Green", pos: {37, 21}, room: "Shields"}
          ]
        })

      prompt = Prompt.build(view)

      assert prompt =~ "Green"
      assert prompt =~ "Shields"
      assert prompt =~ "(37, 21)"
    end
  end

  describe "build/1 — memory" do
    test "social memory lines are explicitly marked as unverified claims" do
      memory =
        Memory.new()
        |> Memory.remember_social({20, "Blue claimed Red vented in Electrical"})
        |> Memory.remember_social({25, "Green said they were in Navigation"})

      prompt = Prompt.build(base_view(%{memory: memory}))

      for claim <- [
            "Blue claimed Red vented in Electrical",
            "Green said they were in Navigation"
          ] do
        assert prompt =~ ~r/UNVERIFIED[^\n]*#{Regex.escape(claim)}/i,
               "social claim not marked unverified: #{claim}"
      end
    end

    test "hard memory lines are NOT marked unverified" do
      memory =
        Memory.new()
        |> Memory.remember_hard({12, "you saw Blue in Electrical"})

      prompt = Prompt.build(base_view(%{memory: memory}))

      assert prompt =~ "you saw Blue in Electrical"
      refute prompt =~ ~r/UNVERIFIED[^\n]*you saw Blue in Electrical/i
    end
  end

  describe "build/1 — whisper privacy" do
    defp whisper_event do
      %{
        from: "blue",
        to: "red",
        audience: ["red", "blue"],
        text: "the pass phrase is banana-horizon"
      }
    end

    test "a whisper appears in a hearer's prompt" do
      prompt = Prompt.build(base_view(%{whispers: [whisper_event()]}))

      assert prompt =~ "banana-horizon"
    end

    test "the same whisper never appears in a non-hearer's prompt" do
      view = base_view(%{id: "green", name: "Green", whispers: [whisper_event()]})

      refute Prompt.build(view) =~ "banana-horizon"
    end

    test "whisper content is marked as an unverified claim" do
      prompt = Prompt.build(base_view(%{whispers: [whisper_event()]}))

      assert prompt =~ ~r/UNVERIFIED[^\n]*banana-horizon/i
    end

    test "an event without an audience fails closed — never rendered" do
      view = base_view(%{whispers: [%{from: "blue", to: "red", text: "banana-horizon"}]})

      refute Prompt.build(view) =~ "banana-horizon"
    end
  end

  describe "build/1 — personality and rules" do
    test "the personality card appears verbatim" do
      card = personality()
      prompt = Prompt.build(base_view(%{personality: card}))

      for phrase <- Personality.describe(card) do
        assert prompt =~ phrase, "missing personality phrase: #{phrase}"
      end
    end

    test "the rules text explains the game and the match's role mix" do
      prompt = Prompt.build(base_view())

      assert prompt =~ ~r/tasks/i
      assert prompt =~ ~r/eject/i
      assert prompt =~ ~r/whisper/i
      assert prompt =~ "2 impostors"
      assert prompt =~ "1 sheriff"
    end
  end

  describe "build/1 — reply schema" do
    test "the JSON envelope and free-roam intent types are embedded" do
      prompt = Prompt.build(base_view())

      assert prompt =~ ~s|"reasoning"|
      assert prompt =~ ~s|"intent"|
      assert prompt =~ ~s|"type"|

      for type <- ~w(move_to do_task kill whisper report press_button nothing) do
        assert prompt =~ ~s|"#{type}"|, "missing intent type #{type}"
      end

      # impostor gets kill; not meeting intents in free roam
      refute prompt =~ ~s|"type": "speak"|
      refute prompt =~ ~s|"type": "vote"|
    end

    test "a sheriff's schema offers investigate, a medic's offers protect" do
      sheriff = Prompt.build(base_view(%{role: :sheriff}))
      medic = Prompt.build(base_view(%{role: :medic}))

      assert sheriff =~ ~s|"type": "investigate"|
      refute sheriff =~ ~s|"type": "protect"|
      refute sheriff =~ ~s|"type": "kill"|

      assert medic =~ ~s|"type": "protect"|
      refute medic =~ ~s|"type": "investigate"|
      refute medic =~ ~s|"type": "kill"|
    end

    test "a crewmate is offered neither kill nor role abilities" do
      prompt = Prompt.build(base_view(%{role: :crewmate}))

      refute prompt =~ ~s|"type": "kill"|
      refute prompt =~ ~s|"type": "investigate"|
      refute prompt =~ ~s|"type": "protect"|
    end

    test "meeting phase offers speak and renders the transcript" do
      view =
        base_view(%{
          phase: :meeting,
          meeting: %{
            round: 1,
            your_turn?: true,
            history: [{"blue", "I was in Navigation the whole time"}, {"green", nil}]
          }
        })

      prompt = Prompt.build(view)

      assert prompt =~ ~s|"type": "speak"|
      assert prompt =~ "I was in Navigation the whole time"
      assert prompt =~ ~r/green.*(passed|silent|skipped)/i
    end

    test "a ghost gets only move/task/nothing in free roam and nothing in meetings" do
      free_roam = Prompt.build(base_view(%{alive?: false}))

      assert free_roam =~ ~s|"type": "move_to"|
      assert free_roam =~ ~s|"type": "do_task"|
      refute free_roam =~ ~s|"type": "kill"|
      refute free_roam =~ ~s|"type": "whisper"|

      meeting = Prompt.build(base_view(%{alive?: false, phase: :meeting}))

      refute meeting =~ ~s|"type": "speak"|
      assert meeting =~ ~s|"type": "nothing"|
    end

    test "an explicit allowed_intents allowlist is honored, with nothing always offered" do
      prompt = Prompt.build(base_view(%{allowed_intents: [:move_to, "whisper"]}))

      assert prompt =~ ~s|"type": "move_to"|
      assert prompt =~ ~s|"type": "whisper"|
      assert prompt =~ ~s|"type": "nothing"|
      refute prompt =~ ~s|"type": "kill"|
      refute prompt =~ ~s|"type": "report"|
    end

    test "voting phase offers vote with the skip literal" do
      view =
        base_view(%{
          phase: :voting,
          meeting: %{candidates: [%{id: "blue", name: "Blue"}, %{id: "green", name: "Green"}]}
        })

      prompt = Prompt.build(view)

      assert prompt =~ ~s|"type": "vote"|
      assert prompt =~ ~s|"skip"|
      assert prompt =~ "Blue"
      assert prompt =~ "Green"
    end
  end

  describe "build/1 — world details" do
    test "bodies in vision are reported, with a report hint" do
      view =
        base_view(%{
          visible_bodies: [
            %{player_id: "blue", name: "Blue", pos: {4, 20}, room: "Electrical"}
          ]
        })

      prompt = Prompt.build(view)

      assert prompt =~ ~r/Blue[^\n]*body/i
      assert prompt =~ "Electrical"
      assert prompt =~ "(4, 20)"
    end

    test "own task list and positions are rendered" do
      prompt = Prompt.build(base_view(%{tasks: %{"T3" => false, "T7" => true}}))

      assert prompt =~ "T3"
      assert prompt =~ "T7"
    end

    test "corridor position renders when no room" do
      prompt = Prompt.build(base_view(%{room: nil, pos: {30, 6}}))

      assert prompt =~ "(30, 6)"
    end
  end
end
