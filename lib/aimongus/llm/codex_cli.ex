defmodule Aimongus.LLM.CodexCLI do
  @moduledoc """
  Local OpenAI adapter for `Aimongus.LLM.Client`: shells out to
  `codex exec --ephemeral --skip-git-repo-check --sandbox read-only`
  using a fast, low-cost model (default `"gpt-5.6-luna"` with
  `model_reasoning_effort="low"`), writing the model's final message to
  a temporary file via `-o` so Codex progress logs on stdout/stderr
  never corrupt the JSON payload.

  ## Options

    * `:model` — model slug passed to `-m` (default `CODEX_MODEL` env var
      or `"gpt-5.6-luna"`)
    * `:reasoning_effort` — value for `-c model_reasoning_effort=...`
      (default `CODEX_REASONING_EFFORT` env var or `"low"`)
    * `:timeout` — milliseconds before the CLI call is killed (default
      `60_000`)
    * `:binary` — executable name (default `"codex"`)
    * `:workdir` — directory passed to `-C` (default `System.tmp_dir!()`
      so Codex doesn't waste tokens ingesting repository files)
    * `:command_fn` — `fn executable, args -> {output, exit_code} end`
      test seam replacing `System.cmd/3`
  """

  @behaviour Aimongus.LLM.Client

  @fence ~r/\A\s*```[a-zA-Z]*\s*\n(?<body>.*?)\n?\s*```\s*\z/s
  @default_model "gpt-5.6-luna"
  @default_effort "low"
  @default_timeout 60_000

  @impl true
  def complete(prompt, opts) do
    binary = Keyword.get(opts, :binary, "codex")

    case command(opts, binary) do
      {:ok, run_fn} -> run(binary, prompt, run_fn, opts)
      :error -> {:error, {:command_not_found, binary}}
    end
  end

  defp run(binary, prompt, command_fn, opts) do
    out_file = temp_output_path()
    args = build_args(prompt, out_file, opts)

    try do
      task = Task.async(fn -> command_fn.(binary, args) end)

      case Task.yield(task, timeout(opts)) || Task.shutdown(task) do
        {:ok, {output, 0}} ->
          text = read_response(out_file, output)
          {:ok, text |> strip_fence() |> String.trim()}

        {:ok, {output, exit_code}} ->
          {:error, {exit_code, output}}

        nil ->
          {:error, :timeout}
      end
    after
      File.rm(out_file)
    end
  end

  defp build_args(prompt, out_file, opts) do
    workdir = Keyword.get(opts, :workdir, System.tmp_dir!())
    model = model(opts)
    effort = reasoning_effort(opts)

    [
      "exec",
      "-C",
      workdir,
      "--ephemeral",
      "--skip-git-repo-check",
      "--sandbox",
      "read-only",
      "-m",
      model,
      "-c",
      ~s(model_reasoning_effort="#{effort}"),
      "-o",
      out_file,
      prompt
    ]
  end

  defp read_response(out_file, fallback_stdout) do
    case File.read(out_file) do
      {:ok, content} when byte_size(content) > 0 -> content
      _other -> fallback_stdout
    end
  end

  defp command(opts, binary) do
    case Keyword.get(opts, :command_fn) do
      fun when is_function(fun, 2) ->
        {:ok, fun}

      nil ->
        if System.find_executable(binary) do
          {:ok, fn exe, args -> System.cmd(exe, args, stderr_to_stdout: true) end}
        else
          :error
        end
    end
  end

  defp model(opts) do
    Keyword.get(opts, :model) ||
      System.get_env("CODEX_MODEL") ||
      Application.get_env(:aimongus, __MODULE__, [])[:model] ||
      @default_model
  end

  defp reasoning_effort(opts) do
    Keyword.get(opts, :reasoning_effort) ||
      System.get_env("CODEX_REASONING_EFFORT") ||
      Application.get_env(:aimongus, __MODULE__, [])[:reasoning_effort] ||
      @default_effort
  end

  defp timeout(opts) do
    Keyword.get(opts, :timeout) ||
      Application.get_env(:aimongus, __MODULE__, [])[:timeout] ||
      @default_timeout
  end

  defp temp_output_path do
    Path.join(System.tmp_dir!(), "aimongus-codex-#{System.unique_integer([:positive])}.out")
  end

  defp strip_fence(text) do
    case Regex.named_captures(@fence, text) do
      %{"body" => body} -> body
      _no_fence -> text
    end
  end
end
