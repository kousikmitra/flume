defmodule Flume.Consumer do
  use GenStage

  require Logger

  # Client API
  def start_link(pipeline_name) do
    GenStage.start_link(__MODULE__, pipeline_name)
  end

  # Server Callbacks
  def init(pipeline_name) do
    upstream = Enum.join([pipeline_name, "producer_consumer"], "_")
    {:consumer, pipeline_name, subscribe_to: [{String.to_atom(upstream), min_demand: 0, max_demand: 1}]}
  end

  def handle_events(events, _from, pipeline_name) do
    # Inspect the events.
    Logger.info("#{pipeline_name} Consumer received #{length events} events")
    Logger.info(events)

    # We are a consumer, so we would never emit items.
    {:noreply, [], pipeline_name}
  end
end
