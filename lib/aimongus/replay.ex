defmodule Aimongus.Replay do
  @moduledoc """
  Match replay: record a live match's god-view event stream to disk,
  play it back later on the same PubSub topic.

    * `Aimongus.Replay.Recorder` — subscribes `"match:<id>"`, appends
      `{offset_ms, event}` lines to `priv/replays/<id>-<ts>.jsonl`
    * `Aimongus.Replay.Player` — reads a recording and re-broadcasts the
      identical terms on the recorded match's own topic at the recorded
      cadence, so `SpectateLive` (`?match=<id>`) renders it exactly like
      the live match

  Recordings are JSONL; see `Aimongus.Replay.Codec` for the tagged
  term encoding and `Aimongus.Replay.Recorder` for the file format.

      iex> {:ok, rec} = Aimongus.Replay.record("live")
      iex> {:ok, player} = Aimongus.Replay.play("priv/replays/live-20261122T152233Z.jsonl", speed: 4)
  """

  alias Aimongus.Replay.{Codec, Player, Recorder}

  @doc "The directory recordings are written to (`priv/replays`)."
  @spec dir() :: Path.t()
  def dir do
    case :code.priv_dir(:aimongus) do
      {:error, _reason} -> Path.expand("priv/replays")
      priv -> Path.join(List.to_string(priv), "replays")
    end
  end

  @doc "Convenience for `Aimongus.Replay.Recorder.start_link/2`."
  @spec record(term(), keyword()) :: GenServer.on_start()
  def record(match_id, opts \\ []), do: Recorder.start_link(match_id, opts)

  @doc "Convenience for `Aimongus.Replay.Player.start_link/2`."
  @spec play(Path.t(), keyword()) :: GenServer.on_start()
  def play(replay_file, opts \\ []), do: Player.start_link(replay_file, opts)

  @doc """
  Lists recordings in `dir` (default `dir/0`) as
  `%{path, match_id, recorded_at, events}` maps, newest first.
  """
  @spec list(Path.t()) :: [map()]
  def list(dir \\ dir()) do
    dir
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case summary(path) do
        nil -> []
        entry -> [entry]
      end
    end)
    |> Enum.sort_by(& &1.path, :desc)
  end

  @doc """
  Reads a recording into `{header, [{offset_ms, event}]}` — the raw
  material `Player` schedules from, and the deterministic comparison
  point for the recorded stream.
  """
  @spec read(Path.t()) :: {map(), [{non_neg_integer(), term()}]}
  def read(path) do
    [header_line | event_lines] =
      path |> File.read!() |> String.split("\n", trim: true)

    header = Jason.decode!(header_line)

    events =
      Enum.map(event_lines, fn line ->
        %{"t" => offset, "e" => encoded} = Jason.decode!(line)
        {offset, Codec.decode(encoded)}
      end)

    {header, events}
  end

  defp summary(path) do
    {header_line, line_count} =
      File.stream!(path)
      |> Enum.reduce({nil, 0}, fn line, {header, count} ->
        {header || String.trim_trailing(line), count + 1}
      end)

    with header_line when is_binary(header_line) <- header_line,
         {:ok, header} <- Jason.decode(header_line) do
      %{
        path: path,
        match_id: header["match_id"],
        recorded_at: header["recorded_at"],
        events: max(0, line_count - 1)
      }
    else
      _other -> nil
    end
  end
end
