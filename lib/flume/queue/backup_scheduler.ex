defmodule Flume.Queue.BackupScheduler do
  require Flume.Logger

  use GenServer

  alias Flume.Logger
  alias Flume.Queue.Manager

  # 15 minutes
  @default_visibility_timeout 900

  defmodule State do
    defstruct namespace: nil, scheduler_poll_interval: nil, queue: nil
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts \\ []) do
    state = struct(State, opts)
    schedule_work(state.scheduler_poll_interval)

    {:ok, state}
  end

  def handle_info(:schedule_work, state) do
    work(state)
    schedule_work(state.scheduler_poll_interval)

    {:noreply, state}
  end

  # TODO: Deprecated, remove this later!
  defp work(%State{queue: nil} = state) do
    Manager.enqueue_backup_jobs_old(state.namespace, time_before_visibility_timeout())
    |> case do
      {:ok, 0} ->
        Logger.debug("#{__MODULE__}: No backup jobs to enqueue")

      {:ok, count} ->
        Logger.debug("#{__MODULE__}: Enqueue #{count} jobs from backup queue")

      {:error, error_message} ->
        Logger.error("#{__MODULE__}: Failed to enqueue jobs - #{Kernel.inspect(error_message)}")
    end
  end

  defp work(state) do
    Manager.enqueue_backup_jobs(state.namespace, time_before_visibility_timeout(), state.queue)
    |> case do
      {:ok, 0} ->
        Logger.debug("#{__MODULE__}: No backup jobs to enqueue")

      {:ok, count} ->
        Logger.debug("#{__MODULE__}: Enqueue #{count} jobs from backup queue")

      {:error, error_message} ->
        Logger.error("#{__MODULE__}: Failed to enqueue jobs - #{Kernel.inspect(error_message)}")
    end
  end

  defp schedule_work(scheduler_poll_interval) do
    Process.send_after(self(), :schedule_work, scheduler_poll_interval)
  end

  defp time_before_visibility_timeout do
    DateTime.utc_now()
    |> DateTime.to_unix()
    |> Kernel.-(@default_visibility_timeout)
    |> DateTime.from_unix!()
  end
end
