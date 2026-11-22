defmodule Aimongus.LLM.Intent do
  @moduledoc """
  Parses the JSON envelope an LLM returns into a `Aimongus.Game.Server`
  intent tuple.

  ## Schema

      {"reasoning": "p2 vented in Electrical",
       "intent": {"type": "move_to", "target": "Electrical"}}

  `reasoning` is required (it feeds the agent's memory/trace) and must be
  a string. `intent.type` is mapped through a strict allowlist — the same
  tuples `Game.Server.submit_intent/3` accepts:

    * `"move_to"` — `target`: room name string or `[x, y]` integer pair →
      `{:move_to, "Room"} | {:move_to, {x, y}}`
    * `"do_task"` — `target`: task id → `{:do_task, task_id}`
    * `"kill"` / `"investigate"` / `"protect"` — `target`: player id →
      `{:kill, id} | {:investigate, id} | {:protect, id}`
    * `"whisper"` — `text` required, `target` optional/`null` →
      `{:whisper, text, id | nil}`
    * `"speak"` — `text` → `{:speak, text}`
    * `"vote"` — `target`: player id or `"skip"` → `{:vote, id | :skip}`
    * `"report"`, `"press_button"`, `"nothing"` → bare atoms, no fields

  Unknown types, missing fields, and malformed JSON all return
  `{:error, reason}` — the parser is syntactic only; the game server
  owns semantic validation (range, role, phase, alive-ness).

  A ` ```json ... ``` ` code fence wrapping the whole reply is stripped
  before decoding (LLMs do this despite instructions).
  """

  @fence ~r/\A\s*```[a-zA-Z]*\s*\n(?<body>.*?)\n?\s*```\s*\z/s

  @type parsed :: %{reasoning: String.t(), intent: term()}

  @doc """
  Decodes `json_text` and maps it to an intent tuple.

  Returns `{:ok, %{reasoning: reasoning, intent: intent}}` or
  `{:error, reason}` where reason is `:invalid_json`, `:invalid_envelope`,
  `{:missing_field, name}`, `{:invalid_field, name}`, or
  `{:unknown_intent, type}`.
  """
  @spec parse(term()) :: {:ok, parsed()} | {:error, term()}
  def parse(json_text) when is_binary(json_text) do
    with {:ok, decoded} <- decode(json_text),
         {:ok, reasoning} <- take(decoded, "reasoning", &cast_string/1),
         {:ok, intent} <- take(decoded, "intent", &cast_map/1),
         {:ok, intent} <- to_intent(intent) do
      {:ok, %{reasoning: reasoning, intent: intent}}
    end
  end

  def parse(_other), do: {:error, :invalid_envelope}

  defp decode(json_text) do
    case Jason.decode(strip_fence(json_text)) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _not_an_object} -> {:error, :invalid_envelope}
      {:error, _decode_error} -> {:error, :invalid_json}
    end
  end

  defp strip_fence(text) do
    case Regex.named_captures(@fence, text) do
      %{"body" => body} -> body
      _no_fence -> text
    end
  end

  defp to_intent(intent) do
    case take(intent, "type", &cast_string/1) do
      {:ok, type} -> build(type, intent)
      error -> error
    end
  end

  defp build(type, intent) do
    case type do
      "move_to" -> take(intent, "target", &cast_destination/1) |> tagged(:move_to)
      "do_task" -> take(intent, "target", &cast_string/1) |> tagged(:do_task)
      "kill" -> take(intent, "target", &cast_string/1) |> tagged(:kill)
      "investigate" -> take(intent, "target", &cast_string/1) |> tagged(:investigate)
      "protect" -> take(intent, "target", &cast_string/1) |> tagged(:protect)
      "speak" -> take(intent, "text", &cast_string/1) |> tagged(:speak)
      "vote" -> take(intent, "target", &cast_vote_choice/1) |> tagged(:vote)
      "whisper" -> cast_whisper(intent)
      "report" -> {:ok, :report}
      "press_button" -> {:ok, :press_button}
      "nothing" -> {:ok, :nothing}
      unknown -> {:error, {:unknown_intent, unknown}}
    end
  end

  defp cast_whisper(intent) do
    with {:ok, text} <- take(intent, "text", &cast_string/1),
         {:ok, target} <- optional_target(intent) do
      {:ok, {:whisper, text, target}}
    end
  end

  # Absent and explicit `null` both mean "whisper to the room".
  defp optional_target(intent) do
    case Map.fetch(intent, "target") do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, target} when is_binary(target) -> {:ok, target}
      {:ok, _other} -> {:error, {:invalid_field, "target"}}
    end
  end

  defp cast_string(value) when is_binary(value), do: {:ok, value}
  defp cast_string(_other), do: :error

  defp cast_map(value) when is_map(value), do: {:ok, value}
  defp cast_map(_other), do: :error

  # A room name, or an [x, y] integer pair → {x, y} grid cell.
  defp cast_destination(value) when is_binary(value), do: {:ok, value}
  defp cast_destination([x, y]) when is_integer(x) and is_integer(y), do: {:ok, {x, y}}
  defp cast_destination(_other), do: :error

  defp cast_vote_choice("skip"), do: {:ok, :skip}
  defp cast_vote_choice(value) when is_binary(value), do: {:ok, value}
  defp cast_vote_choice(_other), do: :error

  defp take(map, field, cast) do
    case Map.fetch(map, field) do
      :error ->
        {:error, {:missing_field, field}}

      {:ok, value} ->
        case cast.(value) do
          {:ok, casted} -> {:ok, casted}
          :error -> {:error, {:invalid_field, field}}
        end
    end
  end

  defp tagged({:ok, value}, tag), do: {:ok, {tag, value}}
  defp tagged({:error, _reason} = error, _tag), do: error
end
