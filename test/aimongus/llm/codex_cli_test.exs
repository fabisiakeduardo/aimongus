defmodule Aimongus.LLM.CodexCLITest do
  use ExUnit.Case, async: true

  alias Aimongus.LLM.CodexCLI

  test "invokes codex exec with ephemeral read-only flags and reads -o file" do
    payload = ~s({"reasoning":"heading to MedBay","intent":{"type":"move_to","target":"MedBay"}})

    command_fn = fn exe, args ->
      assert exe == "codex"
      assert "exec" in args
      assert "--ephemeral" in args
      assert "--skip-git-repo-check" in args
      assert "read-only" in args
      assert "gpt-5.6-luna" in args

      out_idx = Enum.find_index(args, &(&1 == "-o"))
      out_path = Enum.at(args, out_idx + 1)
      File.write!(out_path, "```json\n#{payload}\n```")

      {"noisy codex stdout banner", 0}
    end

    assert {:ok, ^payload} = CodexCLI.complete("test prompt", command_fn: command_fn)
  end

  test "falls back to stdout when -o file is not written" do
    payload = ~s({"reasoning":"ok","intent":{"type":"nothing"}})
    command_fn = fn _exe, _args -> {payload, 0} end

    assert {:ok, ^payload} = CodexCLI.complete("prompt", command_fn: command_fn)
  end

  test "returns error tuple on non-zero exit code" do
    command_fn = fn _exe, _args -> {"model error", 1} end

    assert {:error, {1, "model error"}} = CodexCLI.complete("prompt", command_fn: command_fn)
  end

  test "returns command_not_found when binary does not exist" do
    assert {:error, {:command_not_found, "definitely-no-codex-bin"}} =
             CodexCLI.complete("prompt", binary: "definitely-no-codex-bin")
  end

  test "returns timeout when CLI call exceeds timeout" do
    command_fn = fn _exe, _args ->
      Process.sleep(200)
      {"late", 0}
    end

    assert {:error, :timeout} =
             CodexCLI.complete("prompt", command_fn: command_fn, timeout: 20)
  end
end
