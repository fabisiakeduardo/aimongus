defmodule Aimongus.LLM.StubTest do
  use ExUnit.Case, async: true

  alias Aimongus.LLM.Stub

  describe "scripted server (stub: pid)" do
    test "pops scripted responses in order" do
      stub = start_supervised!({Stub, ["first", "second"]})

      assert {:ok, "first"} = Stub.complete("prompt", stub: stub)
      assert {:ok, "second"} = Stub.complete("prompt", stub: stub)
    end

    test "{:error, reason} entries pass through" do
      stub = start_supervised!({Stub, [{:error, :boom}]})

      assert {:error, :boom} = Stub.complete("prompt", stub: stub)
    end

    test "function entries receive the prompt" do
      stub = start_supervised!({Stub, [fn prompt -> {:ok, "echo: " <> prompt} end]})

      assert {:ok, "echo: hello"} = Stub.complete("hello", stub: stub)
    end

    test "exhausted script returns an error" do
      stub = start_supervised!({Stub, ["only"]})

      assert {:ok, "only"} = Stub.complete("prompt", stub: stub)
      assert {:error, :script_exhausted} = Stub.complete("prompt", stub: stub)
    end

    test "records the prompts it received" do
      stub = start_supervised!({Stub, ["a", "b"]})

      Stub.complete("one", stub: stub)
      Stub.complete("two", stub: stub)

      assert Stub.prompts(stub) == ["one", "two"]
    end
  end

  describe "stateless opts" do
    test "respond: fun is called with the prompt" do
      assert {:ok, "echo: hi"} =
               Stub.complete("hi", respond: fn prompt -> {:ok, "echo: " <> prompt} end)
    end

    test "responses: list returns the first entry" do
      assert {:ok, "only"} = Stub.complete("prompt", responses: ["only"])
    end

    test "empty responses: list returns an error" do
      assert {:error, :script_exhausted} = Stub.complete("prompt", responses: [])
    end

    test "no script configured returns an error" do
      assert {:error, :no_script} = Stub.complete("prompt", [])
    end
  end

  describe "demo_responder/1" do
    test "produces valid parseable JSON intents for every phase" do
      alias Aimongus.LLM.Intent

      prompts = [
        "RIGHT NOW — phase free_roam\nYour tasks:\n- T1 in Cafeteria — not done",
        "RIGHT NOW — phase free_roam\nBodies in sight:\n- Blue's body at Cafeteria",
        "RIGHT NOW — phase meeting\nIt is YOUR turn to speak",
        "RIGHT NOW — phase voting\nPlayers you can vote for: Red (id \"Red\"), Blue (id \"Blue\")."
      ]

      for prompt <- prompts do
        assert {:ok, text} = Stub.complete(prompt, respond: &Stub.demo_responder/1)
        assert {:ok, %{reasoning: r, intent: _intent}} = Intent.parse(text)
        assert is_binary(r) and r != ""
      end
    end
  end
end
