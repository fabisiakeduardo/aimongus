defmodule Aimongus.LLM.DevinCLITest do
  use ExUnit.Case, async: true

  alias Aimongus.LLM.DevinCLI

  defp ok_fn(output), do: fn _binary, _args -> {output, 0} end

  test "returns trimmed stdout on exit 0" do
    assert {:ok, "{\"a\":1}"} =
             DevinCLI.complete("prompt", command_fn: ok_fn("  {\"a\":1}\n"))
  end

  test "strips a markdown fence wrapping the whole reply" do
    output = "```json\n{\"reasoning\":\"r\",\"intent\":{\"type\":\"nothing\"}}\n```\n"

    assert {:ok, "{\"reasoning\":\"r\",\"intent\":{\"type\":\"nothing\"}}"} =
             DevinCLI.complete("prompt", command_fn: ok_fn(output))
  end

  test "leaves unfenced output alone" do
    assert {:ok, "plain"} = DevinCLI.complete("prompt", command_fn: ok_fn("plain"))
  end

  test "non-zero exit returns {code, output}" do
    command_fn = fn _binary, _args -> {"boom on stderr", 2} end

    assert {:error, {2, "boom on stderr"}} =
             DevinCLI.complete("prompt", command_fn: command_fn)
  end

  test "the command runs as `<binary> -p <prompt>`" do
    test_pid = self()

    command_fn = fn binary, args ->
      send(test_pid, {:called, binary, args})
      {"ok", 0}
    end

    assert {:ok, "ok"} =
             DevinCLI.complete("the prompt", binary: "devin", command_fn: command_fn)

    assert_received {:called, "devin", ["-p", "the prompt"]}
  end

  test "missing binary returns an error without spawning anything" do
    assert {:error, {:command_not_found, "not-a-real-binary-xyz"}} =
             DevinCLI.complete("prompt", binary: "not-a-real-binary-xyz")
  end

  test "times out when the command hangs" do
    command_fn = fn _binary, _args ->
      Process.sleep(5_000)
      {"late", 0}
    end

    assert {:error, :timeout} =
             DevinCLI.complete("prompt", command_fn: command_fn, timeout: 20)
  end
end
