defmodule Flume.Pipeline.BulkEvent.Worker do
  require Flume.{Instrumentation, Logger}

  alias Flume.{BulkEvent, Instrumentation, Logger}
  alias Flume.Pipeline.SystemEvent, as: SystemEventPipeline

  def process(%{name: pipeline_name} = pipeline, %BulkEvent{class: class} = bulk_event) do
    {duration, _} =
      Instrumentation.measure do
        Logger.debug("#{pipeline_name} [Consumer] received bulk event - #{inspect(bulk_event)}")

        do_process_event(pipeline, bulk_event)
      end

    Instrumentation.execute(
      [String.to_atom(pipeline_name), :worker, :duration],
      duration,
      %{module: Instrumentation.format_module(class)},
      pipeline[:instrument]
    )
  rescue
    e in [ArgumentError] ->
      Logger.error(
        "#{pipeline_name} [Consumer] error while processing event: #{Kernel.inspect(e)}"
      )
  end

  defp do_process_event(%{name: pipeline_name} = pipeline, %BulkEvent{
         class: class,
         function: function,
         args: args,
         events: events
       }) do
    function_name = String.to_atom(function)

    {duration, _} =
      Instrumentation.measure do
        [class]
        |> Module.safe_concat()
        |> apply(function_name, args)
      end

    Instrumentation.execute(
      [String.to_atom(pipeline_name), :worker, :job, :duration],
      duration,
      %{module: Instrumentation.format_module(class)},
      pipeline[:instrument]
    )

    Logger.debug("#{pipeline_name} [Consumer] processed bulk event: #{class}")

    # Mark all events as success
    events
    |> Enum.map(fn event -> {:success, event} end)
    |> SystemEventPipeline.enqueue()
  rescue
    e in _ ->
      error_message = Kernel.inspect(e)
      handle_failure(pipeline_name, class, events, error_message)
  catch
    :exit, {:timeout, message} ->
      handle_failure(pipeline_name, class, events, inspect(message))
  end

  defp handle_failure(pipeline_name, class, events, error_message) do
    Logger.error("#{pipeline_name} [Consumer] failed with error: #{error_message}", %{
      worker_name: class
    })

    # Mark all events as failed
    events
    |> Enum.map(fn event -> {:failed, event, error_message} end)
    |> SystemEventPipeline.enqueue()
  end
end
