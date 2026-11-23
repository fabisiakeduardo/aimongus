defmodule Aimongus.LLM.IntentPipelineTest do
  use ExUnit.Case, async: true

  alias Aimongus.LLM.{Client, Intent, Stub}

  defp envelope(intent) do
    Jason.encode!(%{"reasoning" => "saw p2 vent", "intent" => intent})
  end

  describe "adapter selection" do
    test "a configured agent key resolves to its adapter" do
      # test env maps "p1" => NoopAdapter specifically to exercise the
      # per-agent lookup — a harmless test-support stand-in.
      assert Client.adapter_for("p1") == Aimongus.LLM.NoopAdapter
    end

    test "the per-agent override is safe to call with no opts" do
      # Guards the config mapping: the resolved adapter for "p1" must
      # never shell out or hit the network when invoked bare.
      assert {:ok, text} = Client.complete("p1", "any prompt")
      assert {:ok, %{intent: :nothing}} = Intent.parse(text)
    end

    test "unconfigured agents fall back to :default (Stub in test env)" do
      assert Client.adapter_for("p9") == Stub
      assert Client.adapter_for() == Stub
    end
  end

  describe "adapter → Intent.parse pipeline" do
    test "stub reply parses into the expected intent" do
      stub =
        start_supervised!({Stub, [envelope(%{"type" => "move_to", "target" => "Electrical"})]})

      assert {:ok, text} = Client.complete("p9", "decide now", stub: stub)

      assert {:ok, %{reasoning: "saw p2 vent", intent: {:move_to, "Electrical"}}} =
               Intent.parse(text)

      assert Stub.prompts(stub) == ["decide now"]
    end

    test "a sequence of scripted replies drives successive intents per agent" do
      stub =
        start_supervised!(
          {Stub,
           [
             envelope(%{"type" => "do_task", "target" => "T3"}),
             envelope(%{"type" => "vote", "target" => "p4"}),
             envelope(%{"type" => "nothing"})
           ]}
        )

      assert {:ok, %{intent: {:do_task, "T3"}}} =
               "p9" |> Client.complete("prompt 1", stub: stub) |> ok() |> Intent.parse()

      assert {:ok, %{intent: {:vote, "p4"}}} =
               "p9" |> Client.complete("prompt 2", stub: stub) |> ok() |> Intent.parse()

      assert {:ok, %{intent: :nothing}} =
               "p9" |> Client.complete("prompt 3", stub: stub) |> ok() |> Intent.parse()
    end

    test "a fenced stub reply still parses (LLMs do this)" do
      fenced = "```json\n" <> envelope(%{"type" => "speak", "text" => "it's red"}) <> "\n```"
      stub = start_supervised!({Stub, [fenced]})

      assert {:ok, %{intent: {:speak, "it's red"}}} =
               "p9" |> Client.complete("prompt", stub: stub) |> ok() |> Intent.parse()
    end

    test "adapter errors propagate instead of reaching the parser" do
      stub = start_supervised!({Stub, [{:error, :boom}]})

      assert {:error, :boom} = Client.complete("p9", "prompt", stub: stub)
    end
  end

  defp ok({:ok, text}), do: text
end
