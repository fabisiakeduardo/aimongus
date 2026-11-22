defmodule Aimongus.Replay.Player do
  @moduledoc """
  Replays a recorded match by re-broadcasting its events on PubSub.

  `start_link(replay_file)` reads a file written by
  `Aimongus.Replay.Recorder` and re-emits every event — bit-for-bit the
  same terms — on the **same** `"match:<match_id>"` topic the match was
  recorded under (the id comes from the file's header). `SpectateLive`
  subscribes by id, so a spectator watching `?match=<id>` cannot tell a
  replay from the live match.

  Timing respects the recorded `offset_ms` deltas, scaled by the
  `:speed` multiplier (`2.0` = double time, `0.5` = half speed).
  Scheduling is absolute — each event targets
  `start + offset_ms / speed` — so emit latency doesn't accumulate as
  drift over a long replay.

  The player exits `:normal` after the last event; pass `:notify` to
  also get a `:replay_finished` message.
  """

  use GenServer

  alias Aimongus.Replay

  ## Public API

  @doc """
  Starts replaying `replay_file`.

  Options:

    * `:speed` — cadence multiplier, `1.0` = recorded speed (default).
      Must be positive; larger is faster.
    * `:notify` — pid sent `:replay_finished` after the last event
    * `:topic` — PubSub topic override (default `"match:<header's id>"`)
  """
  @spec start_link(Path.t(), keyword()) :: GenServer.on_start()
  def start_link(replay_file, opts \\ []) do
    speed = Keyword.get(opts, :speed, 1.0)

    unless is_number(speed) and speed > 0 do
      raise ArgumentError, ":speed must be a positive number, got: #{inspect(speed)}"
    end

    GenServer.start_link(__MODULE__, {replay_file, opts})
  end

  ## GenServer callbacks

  @impl true
  def init({replay_file, opts}) do
    {header, events} = Replay.read(replay_file)

    state = %{
      topic: Keyword.get(opts, :topic, "match:#{header["match_id"]}"),
      speed: Keyword.get(opts, :speed, 1.0),
      notify: Keyword.get(opts, :notify),
      events: events,
      started: nil
    }

    {:ok, state, {:continue, :play}}
  end

  @impl true
  def handle_continue(:play, state) do
    state = %{state | started: System.monotonic_time(:millisecond)}

    case state.events do
      [] -> {:stop, :normal, notify_done(state)}
      _events -> {:noreply, schedule_next(state)}
    end
  end

  @impl true
  def handle_info(:emit, %{events: [{_offset, event} | rest]} = state) do
    Phoenix.PubSub.broadcast(Aimongus.PubSub, state.topic, event)
    state = %{state | events: rest}

    case rest do
      [] -> {:stop, :normal, notify_done(state)}
      _events -> {:noreply, schedule_next(state)}
    end
  end

  defp schedule_next(%{events: [{offset, _event} | _]} = state) do
    target = state.started + trunc(offset / state.speed)
    delay = max(0, target - System.monotonic_time(:millisecond))
    Process.send_after(self(), :emit, delay)
    state
  end

  defp notify_done(%{notify: nil} = state), do: state

  defp notify_done(%{notify: pid} = state) do
    send(pid, :replay_finished)
    state
  end
end
