defmodule Aimongus.LLM.IntentTest do
  use ExUnit.Case, async: true

  alias Aimongus.LLM.Intent

  defp envelope(type, extra \\ %{}, reasoning \\ "because reasons") do
    Jason.encode!(%{
      "reasoning" => reasoning,
      "intent" => Map.merge(%{"type" => type}, extra)
    })
  end

  describe "parse/1 — free-roam intents" do
    test "move_to a room name" do
      assert {:ok, %{intent: {:move_to, "Electrical"}}} =
               Intent.parse(envelope("move_to", %{"target" => "Electrical"}))
    end

    test "move_to explicit coordinates" do
      assert {:ok, %{intent: {:move_to, {4, 7}}}} =
               Intent.parse(envelope("move_to", %{"target" => [4, 7]}))
    end

    test "do_task" do
      assert {:ok, %{intent: {:do_task, "T3"}}} =
               Intent.parse(envelope("do_task", %{"target" => "T3"}))
    end

    test "kill" do
      assert {:ok, %{intent: {:kill, "p2"}}} =
               Intent.parse(envelope("kill", %{"target" => "p2"}))
    end

    test "report" do
      assert {:ok, %{intent: :report}} = Intent.parse(envelope("report"))
    end

    test "press_button" do
      assert {:ok, %{intent: :press_button}} = Intent.parse(envelope("press_button"))
    end

    test "whisper broadcast (no target field)" do
      assert {:ok, %{intent: {:whisper, "follow me", nil}}} =
               Intent.parse(envelope("whisper", %{"text" => "follow me"}))
    end

    test "whisper broadcast (explicit null target)" do
      assert {:ok, %{intent: {:whisper, "hi", nil}}} =
               Intent.parse(envelope("whisper", %{"text" => "hi", "target" => nil}))
    end

    test "whisper addressed to a player" do
      assert {:ok, %{intent: {:whisper, "it's red", "p4"}}} =
               Intent.parse(envelope("whisper", %{"text" => "it's red", "target" => "p4"}))
    end

    test "investigate" do
      assert {:ok, %{intent: {:investigate, "p1"}}} =
               Intent.parse(envelope("investigate", %{"target" => "p1"}))
    end

    test "protect" do
      assert {:ok, %{intent: {:protect, "p5"}}} =
               Intent.parse(envelope("protect", %{"target" => "p5"}))
    end

    test "nothing" do
      assert {:ok, %{intent: :nothing}} = Intent.parse(envelope("nothing"))
    end
  end

  describe "parse/1 — meeting intents" do
    test "speak" do
      assert {:ok, %{intent: {:speak, "I was in Medbay"}}} =
               Intent.parse(envelope("speak", %{"text" => "I was in Medbay"}))
    end

    test "vote a player" do
      assert {:ok, %{intent: {:vote, "p3"}}} =
               Intent.parse(envelope("vote", %{"target" => "p3"}))
    end

    test "vote skip" do
      assert {:ok, %{intent: {:vote, :skip}}} =
               Intent.parse(envelope("vote", %{"target" => "skip"}))
    end
  end

  describe "parse/1 — envelope" do
    test "returns the reasoning string" do
      assert {:ok, %{reasoning: "p2 vented", intent: :report}} =
               Intent.parse(envelope("report", %{}, "p2 vented"))
    end

    test "ignores extra fields in the envelope and the intent object" do
      json =
        Jason.encode!(%{
          "reasoning" => "r",
          "mood" => "sus",
          "intent" => %{"type" => "report", "confidence" => 0.9}
        })

      assert {:ok, %{intent: :report}} = Intent.parse(json)
    end

    test "strips a ```json code fence" do
      json = "```json\n" <> envelope("report") <> "\n```"

      assert {:ok, %{intent: :report}} = Intent.parse(json)
    end

    test "strips a bare code fence" do
      json = "```\n" <> envelope("nothing") <> "\n```"

      assert {:ok, %{intent: :nothing}} = Intent.parse(json)
    end

    test "tolerates surrounding whitespace" do
      assert {:ok, %{intent: :report}} = Intent.parse("  \n" <> envelope("report") <> "\n ")
    end
  end

  describe "parse/1 — errors" do
    test "malformed JSON" do
      assert {:error, _} = Intent.parse("{not json")
      assert {:error, _} = Intent.parse("")
    end

    test "top-level value that is not an object" do
      assert {:error, _} = Intent.parse("[1, 2, 3]")
      assert {:error, _} = Intent.parse("\"move_to\"")
      assert {:error, _} = Intent.parse("42")
    end

    test "missing intent key" do
      assert {:error, _} = Intent.parse(Jason.encode!(%{"reasoning" => "r"}))
    end

    test "intent is not an object" do
      json = Jason.encode!(%{"reasoning" => "r", "intent" => "report"})
      assert {:error, _} = Intent.parse(json)
    end

    test "missing reasoning" do
      assert {:error, _} =
               Intent.parse(Jason.encode!(%{"intent" => %{"type" => "report"}}))
    end

    test "non-string reasoning" do
      assert {:error, _} = Intent.parse(envelope("report", %{}, nil))
      assert {:error, _} = Intent.parse(envelope("report", %{}, 42))
    end

    test "missing type" do
      json = Jason.encode!(%{"reasoning" => "r", "intent" => %{"target" => "p1"}})
      assert {:error, _} = Intent.parse(json)
    end

    test "non-string type" do
      assert {:error, _} = Intent.parse(envelope(42))
    end

    test "unknown type" do
      assert {:error, {:unknown_intent, "dance"}} = Intent.parse(envelope("dance"))
    end

    test "missing target" do
      assert {:error, {:missing_field, "target"}} = Intent.parse(envelope("kill"))
      assert {:error, {:missing_field, "target"}} = Intent.parse(envelope("move_to"))
      assert {:error, {:missing_field, "target"}} = Intent.parse(envelope("do_task"))
      assert {:error, {:missing_field, "target"}} = Intent.parse(envelope("investigate"))
      assert {:error, {:missing_field, "target"}} = Intent.parse(envelope("protect"))
      assert {:error, {:missing_field, "target"}} = Intent.parse(envelope("vote"))
    end

    test "wrong-typed target" do
      assert {:error, {:invalid_field, "target"}} =
               Intent.parse(envelope("kill", %{"target" => 42}))

      assert {:error, {:invalid_field, "target"}} =
               Intent.parse(envelope("vote", %{"target" => nil}))

      assert {:error, {:invalid_field, "target"}} =
               Intent.parse(envelope("whisper", %{"text" => "hi", "target" => 7}))
    end

    test "missing or wrong-typed text" do
      assert {:error, {:missing_field, "text"}} = Intent.parse(envelope("speak"))
      assert {:error, {:missing_field, "text"}} = Intent.parse(envelope("whisper"))

      assert {:error, {:invalid_field, "text"}} =
               Intent.parse(envelope("speak", %{"text" => 5}))
    end

    test "move_to bad coordinate shapes" do
      assert {:error, {:invalid_field, "target"}} =
               Intent.parse(envelope("move_to", %{"target" => [1, "x"]}))

      assert {:error, {:invalid_field, "target"}} =
               Intent.parse(envelope("move_to", %{"target" => [1, 2, 3]}))

      assert {:error, {:invalid_field, "target"}} =
               Intent.parse(envelope("move_to", %{"target" => [1.5, 2]}))
    end

    test "non-binary input" do
      assert {:error, _} = Intent.parse(nil)
      assert {:error, _} = Intent.parse(%{"type" => "report"})
    end
  end
end
