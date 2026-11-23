defmodule Aimongus.Replay.Recorder do
  @moduledoc """
  Records a match's event stream to disk for later replay.

  `start_link(match_id)` subscribes to the god-view PubSub topic
  `"match:<match_id>"` (the same topic `Aimongus.Game.Server` and the
  agent runtime broadcast on, so `{:reasoning, ...}` events are captured
  too) and appends one JSON line per event to
  `<dir>/<match_id>-<utc-timestamp>.jsonl` — `dir` defaults to
  `Aimongus.Replay.dir/0` (`priv/replays`).

  ## File format

    * line 1 — header: `%{"v" => 1, "match_id" => ..., "recorded_at" => iso8601}`
    * one line per event: `%{"t" => offset_ms, "e" => encoded_event}`

  `offset_ms` is the monotonic-millisecond delay since the recorder
  started; events arrive in publish order, so offsets are non-decreasing.
  `Aimongus.Replay.Player` re-emits on the same topic at these offsets.
  """

  use GenServer

  alias Aimongus.Replay
  alias Aimongus.Replay.Codec

  @format_version 1

  ## Public API

  @doc """
  Starts a recorder for `match_id`.

  Options:

    * `:dir` — output directory (default `Aimongus.Replay.dir/0`)
  """
  @spec start_link(term(), keyword()) :: GenServer.on_start()
  def start_link(match_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {match_id, opts})
  end

  @doc "The path of the file being recorded."
  @spec path(GenServer.server()) :: Path.t()
  def path(recorder), do: GenServer.call(recorder, :path)

  @doc "Stops the recorder and closes the file."
  @spec stop(GenServer.server()) :: :ok
  def stop(recorder), do: GenServer.stop(recorder)

  ## GenServer callbacks

  @impl true
  def init({match_id, opts}) do
    dir = Keyword.get(opts, :dir, Replay.dir())
    File.mkdir_p!(dir)
    path = unique_path(dir, "#{sanitize(match_id)}-#{timestamp()}.jsonl")

    {:ok, io} = File.open(path, [:write, :utf8])

    header = %{
      "v" => @format_version,
      "match_id" => to_string(match_id),
      "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    write_line(io, header)

    Phoenix.PubSub.subscribe(Aimongus.PubSub, "match:#{match_id}")

    {:ok, %{io: io, path: path, t0: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  @impl true
  def handle_info(event, state) do
    offset = System.monotonic_time(:millisecond) - state.t0
    write_line(state.io, %{"t" => offset, "e" => Codec.encode(event)})
    {:noreply, state}
  end

  defp write_line(io, term) do
    IO.write(io, [Jason.encode!(term), "\n"])
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(:basic)
  end

  defp sanitize(match_id), do: match_id |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")

  # second-granularity timestamps can collide for back-to-back matches
  # under the same id — disambiguate rather than overwrite a recording
  defp unique_path(dir, base) do
    path = Path.join(dir, base)

    if File.exists?(path) do
      suffix = System.unique_integer([:positive])
      Path.join(dir, String.replace_suffix(base, ".jsonl", "-#{suffix}.jsonl"))
    else
      path
    end
  end
end
