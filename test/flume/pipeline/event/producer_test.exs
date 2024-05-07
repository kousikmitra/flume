defmodule Flume.Pipeline.Event.ProducerTest do
  use Flume.TestWithRedis

  alias Flume.{Pipeline, JobFactory}
  alias Flume.Pipeline.Event.Producer
  alias Flume.Redis.Job

  @namespace Flume.Config.namespace()

  describe "handle_demand/2" do
    test "pull events from redis" do
      pipeline = %Pipeline{
        name: "pipeline_1",
        queue: "test",
        max_demand: 1000
      }

      downstream_name = Enum.join([pipeline.name, "producer_consumer"], "_") |> String.to_atom()

      events = JobFactory.generate_jobs("EchoWorker1", 3)
      Job.bulk_enqueue("#{@namespace}:queue:#{pipeline.queue}", events)

      {:ok, producer} = Producer.start_link(pipeline)
      {:ok, _} = EchoConsumer.start_link(producer, self(), name: downstream_name)

      Enum.each(events, fn event ->
        assert_receive {:received, [^event]}
      end)

      # The consumer will also stop, since it is subscribed to the stage
      GenStage.stop(producer)
    end

    test "should schedule one outstanding fetch" do
      pipeline = %Pipeline{
        name: "pipeline_1",
        queue: "test",
        max_demand: 1,
        batch_size: 1,
        rate_limit_count: 2,
        rate_limit_scale: 1000,
        rate_limit_key: "pipeline_1"
      }

      downstream_name = Enum.join([pipeline.name, "producer_consumer"], "_") |> String.to_atom()

      events = JobFactory.generate_jobs("EchoWorker1", 15)
      Job.bulk_enqueue("#{@namespace}:queue:#{pipeline.queue}", events)

      {:ok, producer} = Producer.start_link(pipeline)

      {:ok, _} =
        EchoConsumer.start_link(producer, self(),
          name: downstream_name,
          max_demand: 5,
          min_demand: 3
        )

      assert_receive_events(15, [])

      # The consumer will also stop, since it is subscribed to the stage
      GenStage.stop(producer)
    end
  end

  describe "pause/1" do
    test "pauses the producer from fetching more events" do
      pipeline_name = "batch_pipeline"
      queue_name = "batch"
      caller_name = :calling_process

      Process.register(self(), caller_name)

      pipeline = %Pipeline{
        name: pipeline_name,
        queue: queue_name,
        max_demand: 10,
        batch_size: 2
      }

      # Push events to Redis
      Enum.each(1..4, fn i ->
        Job.enqueue(
          "#{@namespace}:queue:#{queue_name}",
          JobFactory.generate("EchoWorker1", [i])
        )
      end)

      # Start the producer
      {:ok, producer} = Producer.start_link(pipeline)

      # Start the consumer
      {:ok, _} =
        EchoConsumer.start_link(
          producer,
          caller_name,
          name: :"#{pipeline_name}_consumer"
        )

      assert_receive {:received, [event_1]}
      assert_receive {:received, [event_2]}
      assert_receive {:received, [event_3]}
      assert_receive {:received, [event_4]}

      decoded_event_1 = Jason.decode!(event_1)
      decoded_event_2 = Jason.decode!(event_2)
      decoded_event_3 = Jason.decode!(event_3)
      decoded_event_4 = Jason.decode!(event_4)

      assert match?(%{"args" => [1], "class" => "EchoWorker1"}, decoded_event_1)
      assert match?(%{"args" => [2], "class" => "EchoWorker1"}, decoded_event_2)
      assert match?(%{"args" => [3], "class" => "EchoWorker1"}, decoded_event_3)
      assert match?(%{"args" => [4], "class" => "EchoWorker1"}, decoded_event_4)

      Producer.pause(pipeline_name, false)

      Enum.each(3..6, fn i ->
        Job.enqueue(
          "#{@namespace}:queue:#{queue_name}",
          JobFactory.generate("EchoWorker2", [i])
        )
      end)

      refute_receive {:received, [_event_1]}
      refute_receive {:received, [_event_2]}
      refute_receive {:received, [_event_3]}
      refute_receive {:received, [_event_4]}

      # The will stop the whole pipeline
      GenStage.stop(producer)
    end
  end

  describe "resume/1" do
    test "resumes the producer to fetch more events from the source" do
      pipeline_name = "batch_pipeline"
      queue_name = "batch"
      caller_name = :calling_process

      Process.register(self(), caller_name)

      pipeline = %Pipeline{
        name: pipeline_name,
        queue: queue_name,
        max_demand: 10,
        batch_size: 2
      }

      # Start the producer
      {:ok, producer} = Producer.start_link(pipeline)

      # Start the consumer
      {:ok, _} =
        EchoConsumer.start_link(
          producer,
          caller_name,
          name: :"#{pipeline_name}_consumer"
        )

      :ok = Producer.pause(pipeline_name, false)

      Enum.each(1..4, fn i ->
        Job.enqueue(
          "#{@namespace}:queue:#{queue_name}",
          JobFactory.generate("EchoWorker1", [i])
        )
      end)

      Enum.each(3..6, fn i ->
        Job.enqueue(
          "#{@namespace}:queue:#{queue_name}",
          JobFactory.generate("EchoWorker2", [i])
        )
      end)

      refute_receive {:received, [_event_1]}
      refute_receive {:received, [_event_2]}
      refute_receive {:received, [_event_3]}
      refute_receive {:received, [_event_4]}

      Producer.resume(pipeline_name, false)

      assert_receive {:received, [event_1]}, 2000
      assert_receive {:received, [event_2]}, 2000
      assert_receive {:received, [event_3]}, 2000
      assert_receive {:received, [event_4]}, 2000

      decoded_event_1 = Jason.decode!(event_1)
      decoded_event_2 = Jason.decode!(event_2)
      decoded_event_3 = Jason.decode!(event_3)
      decoded_event_4 = Jason.decode!(event_4)

      assert match?(%{"args" => [1], "class" => "EchoWorker1"}, decoded_event_1)
      assert match?(%{"args" => [2], "class" => "EchoWorker1"}, decoded_event_2)
      assert match?(%{"args" => [3], "class" => "EchoWorker1"}, decoded_event_3)
      assert match?(%{"args" => [4], "class" => "EchoWorker1"}, decoded_event_4)

      # The will stop the whole pipeline
      GenStage.stop(producer)
    end
  end

  describe "handle_cast/2 for pause related messages" do
    test "returns unchanged state if pipline has already been paused" do
      assert Producer.handle_cast(:pause, %{paused: true}) == {:noreply, [], %{paused: true}}
    end

    test "updates the paused state for a running pipeline" do
      assert Producer.handle_cast(:pause, %{paused: false}) == {:noreply, [], %{paused: true}}
    end
  end

  describe "handle_cast/2 for resume related messages" do
    test "returns unchanged state for running pipeline" do
      assert Producer.handle_cast(:resume, %{paused: false}) == {:noreply, [], %{paused: false}}
    end

    test "updates the paused state for a paused pipeline" do
      assert Producer.handle_cast(:resume, %{paused: true}) == {:noreply, [], %{paused: false}}
    end
  end

  def assert_receive_events(expected, received_so_far) do
    if length(received_so_far) == expected do
      :ok
    else
      receive do
        {:received, events} ->
          assert_receive_events(expected, events ++ received_so_far)
      after
        10_000 ->
          flunk("Failed to receive message after 10 seconds")
      end
    end
  end
end
