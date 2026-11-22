defmodule Aimongus.LLM.DevinCLI do
  @moduledoc """
  Dev adapter for `Aimongus.LLM.Client`: shells out to
  `devin -p "<prompt>"` — a single-turn Devin CLI session that prints
  the reply to stdout and exits. Each agent poll spawns one `devin -p`
  call; it burns Devin quota instead of API keys, which is the point of
  the dev environment (near-zero marginal cost).

  `System.cmd/3` cannot capture stderr separately, so stderr is merged
  into stdout: a non-zero exit returns `{:error, {exit_code, output}}`
  where `output` is the combined stream.

  A ` ```json ... ``` ` fence wrapping the whole reply is stripped
  before the text is returned (`Aimongus.LLM.Intent.parse/1` strips it
  again downstream — belt and suspenders, models are stubborn).

  ## Options

    * `:timeout` — milliseconds before the CLI call is killed. Default
      `:timer.minutes(2)` (`devin -p` spins up a whole session), or
      `config :aimongus, Aimongus.LLM.DevinCLI` `:timeout`.
    * `:binary` — executable name, default `"devin"`.
    * `:command_fn` — `fn executable, args -> {output, exit_code} end`
      test seam replacing `System.cmd/2`; also skips the
      `find_executable` check.
  """

  @behaviour Aimongus.LLM.Client

  @fence ~r/\A\s*```[a-zA-Z]*\s*\n(?<body>.*?)\n?\s*```\s*\z/s
  @default_timeout :timer.minutes(2)

  @impl true
  def complete(prompt, opts) do
    binary = Keyword.get(opts, :binary, "devin")

    case command(opts, binary) do
      {:ok, run} -> run(binary, prompt, run, timeout(opts))
      :error -> {:error, {:command_not_found, binary}}
    end
  end

  defp run(binary, prompt, command_fn, timeout) do
    task = Task.async(fn -> command_fn.(binary, ["-p", prompt]) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, output |> strip_fence() |> String.trim()}
      {:ok, {output, exit_code}} -> {:error, {exit_code, output}}
      nil -> {:error, :timeout}
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

  defp timeout(opts) do
    Keyword.get(opts, :timeout) ||
      Application.get_env(:aimongus, __MODULE__, [])[:timeout] ||
      @default_timeout
  end

  defp strip_fence(text) do
    case Regex.named_captures(@fence, text) do
      %{"body" => body} -> body
      _no_fence -> text
    end
  end
end
