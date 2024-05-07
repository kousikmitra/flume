defmodule Flume.Pipeline.Event.Producer do
  @moduledoc """
  Polls for a batch of events from the source (Redis queue).
  This stage acts as a Producer in the GenStage pipeline.

  [**Producer**] <- ProducerConsumer <- Consumer
  """
  use GenStage

  require Flume.{Instrumentation, Logger}

  alias Flume.{Logger, Instrumentation, Utils, Config}
  alias Flume.Queue.Manager, as: QueueManager
  alias Flume.Pipeline.Event, as: EventPipeline

  # 2 seconds
  @default_interval 2000
  @lock_poll_interval Config.dequeue_lock_poll_interval()

  # Client API
  def start_link(%{name: pipeline_name, queue: _queue} = state) do
    GenStage.start_link(__MODULE__, state, name: process_name(pipeline_name))
  end

  def pause(pipeline_name, async, timeout \\ 5000)

  def pause(pipeline_name, true = _async, _timeout) do
    GenStage.cast(process_name(pipeline_name), :pause)
  end

  def pause(pipeline_name, false = _async, timeout) do
    GenStage.call(process_name(pipeline_name), :pause, timeout)
  end

  def resume(pipeline_name, async, timeout \\ 5000)

  def resume(pipeline_name, true = _async, _timeout) do
    GenStage.cast(process_name(pipeline_name), :resume)
  end

  def resume(pipeline_name, false = _async, timeout) do
    GenStage.call(process_name(pipeline_name), :resume, timeout)
  end

  # Server callbacks
  def init(%{name: name} = state) do
    state =
      state
      |> Map.put(:paused, EventPipeline.paused_state(name))
      |> Map.put(:fetch_events_scheduled, false)
      |> Map.put(:demand, 0)

    {:producer, state}
  end

  def handle_demand(demand, state) when demand > 0 do
    Logger.debug("#{state.name} [Producer] handling demand of #{demand}")

    new_demand = state.demand + demand
    state = Map.put(state, :demand, new_demand)

    dispatch_events(state)
  end

  def handle_info(:fetch_events, state) do
    # This callback is invoked by the Process.send_after/3 message below.
    state = Map.put(state, :fetch_events_scheduled, false)
    dispatch_events(state)
  end

  def handle_call(:pause, _from, %{paused: true} = state) do
    {:reply, :ok, [], state}
  end

  def handle_call(:pause, _from, state) do
    state = Map.put(state, :paused, true)

    {:reply, :ok, [], state}
  end

  def handle_call(:resume, _from, %{paused: true} = state) do
    state = Map.put(state, :paused, false)

    {:reply, :ok, [], state}
  end

  def handle_call(:resume, _from, state) do
    {:reply, :ok, [], state}
  end

  def handle_cast(:pause, %{paused: true} = state) do
    {:noreply, [], state}
  end

  def handle_cast(:pause, state) do
    state = Map.put(state, :paused, true)

    {:noreply, [], state}
  end

  def handle_cast(:resume, %{paused: true} = state) do
    state = Map.put(state, :paused, false)

    {:noreply, [], state}
  end

  def handle_cast(:resume, state) do
    {:noreply, [], state}
  end

  defp dispatch_events(%{paused: true} = state) do
    state = schedule_fetch_events(state)

    {:noreply, [], state}
  end

  defp dispatch_events(%{demand: demand, batch_size: nil} = state) when demand > 0 do
    Logger.debug("#{state.name} [Producer] pulling #{demand} events")

    {duration, _} =
      Instrumentation.measure do
        fetch_result = take(demand, state)
      end

    case fetch_result do
      {:ok, events} -> handle_successful_fetch(events, state, duration)
      {:error, :locked} -> handle_locked_fetch(state)
    end
  end

  defp dispatch_events(%{demand: demand, batch_size: batch_size} = state)
       when demand > 0 and batch_size > 0 do
    events_to_ask = demand * batch_size

    Logger.debug("#{state.name} [Producer] pulling #{events_to_ask} events")

    {duration, _} =
      Instrumentation.measure do
        fetch_result = take(events_to_ask, state)
      end

    case fetch_result do
      {:ok, events} -> handle_successful_fetch(events, state, duration, batch_size)
      {:error, :locked} -> handle_locked_fetch(state)
    end
  end

  defp dispatch_events(state) do
    state = schedule_fetch_events(state)

    {:noreply, [], state}
  end

  defp handle_successful_fetch(events, state, fetch_duration, batch_size \\ 1) do
    count = length(events)
    Logger.debug("#{state.name} [Producer] pulled #{count} events from source")

    queue_atom = String.to_atom(state.queue)

    Instrumentation.execute(
      [queue_atom, :dequeue],
      %{count: count, latency: fetch_duration, payload_size: Utils.payload_size(events)},
      state.instrument
    )

    new_demand = state.demand - round(count / batch_size)
    state = Map.put(state, :demand, new_demand)

    state = schedule_fetch_events(state)

    {:noreply, events, state}
  end

  defp handle_locked_fetch(state) do
    state = schedule_fetch_events(state, @lock_poll_interval)

    {:noreply, [], state}
  end

  defp schedule_fetch_events(state), do: schedule_fetch_events(state, @default_interval)

  defp schedule_fetch_events(%{fetch_events_scheduled: true} = state, _), do: state

  defp schedule_fetch_events(%{demand: demand} = state, interval)
       when demand > 0 do
    # Schedule the next request
    Process.send_after(self(), :fetch_events, interval)
    Map.put(state, :fetch_events_scheduled, true)
  end

  defp schedule_fetch_events(state, _interval), do: state

  # For regular pipelines
  defp take(demand, %{rate_limit_count: nil, rate_limit_scale: nil} = state) do
    QueueManager.fetch_jobs(Config.namespace(), state.queue, demand)
  end

  # For rate-limited pipelines
  defp take(
         demand,
         %{rate_limit_count: rate_limit_count, rate_limit_scale: rate_limit_scale} = state
       ) do
    QueueManager.fetch_jobs(
      Config.namespace(),
      state.queue,
      demand,
      %{
        rate_limit_count: rate_limit_count,
        rate_limit_scale: rate_limit_scale,
        rate_limit_key: Map.get(state, :rate_limit_key)
      }
    )
  end

  def process_name(pipeline_name), do: :"#{pipeline_name}_producer"
end
