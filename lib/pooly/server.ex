defmodule Pooly.Server do
  use GenServer
  defmodule State do
    defstruct sup: nil, size: nil, mfa: nil
  end

  #api
  def start_link(sup, pool_config) do
    GenServer.start_link(__MODULE__, [sup, pool_config], name: __MODULE__)
  end

  def checkout, do: GenServer.call(__MODULE__, :checkout)
  def checkin(worker_pid), do: GenServer.cast(__MODULE__, {:checkin, worker_pid})
  def status, do: GenServer.call(__MODULE__, :status)

  #server
  def init([sup, pool_config]) when is_pid(sup) do
    monitors = :ets.insert(:monitors, [:private])
    init(pool_config, %State{sup: sup, monitors: monitors})
  end

  def init([{:mfa, mfa} | rest], state), do: init(rest, %{state | mfa: mfa})
  def init([{:size, size} | rest], state), do: init(rest, %{state | size: size})
  def init([_, rest], state), do: init(rest, state)
  def init([], state) do
    send(self(), :start_worker_supervisor)
    {:ok, state}
  end

  def handle_call(:checkout, {from_pid, _ref}, %{workers: workers, monitors: monitors} = state) do
    case workers do
      [worker | rest] ->
        monitor_ref = Process.monitor(from_pid)
        true = :ets.insert(monitors, {worker, monitor_ref})
        {:reply, worker, %{state | workers: rest}}
    end
  end

  def handle_call(:status, _from, %{workers: workers, monitors: monitors} = state) do
    {:reply, {length(workers), :ets.info(monitors, :size)}, state}
  end

  def handle_cast({:checkin, worker}, %{workers: workers, monitors: monitors} = state) do
    case :ets.lookup(monitors, worker) do
      [{pid, monitor_ref}] ->
        true = Process.demonitor(monitor_ref)
        true = :ets.delete(monitors, pid)
        {:noreply, %{state | workers: [pid | workers]}}
      [] -> {:noreply, state}
    end
  end

  def handle_info(:start_worker_supervisor, state = %{sup: sup, mfa: mfa, size: size}) do
    {:ok, worker_sup} = Supervisor.start_child(sup, supervisor_spec(mfa))
    workers = prepopulate(size, worker_sup)
    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}
  end

  #private
  defp supervisor_spec(mfa), do: supervisor(Pooly.WorkerSupervisor, [mfa], [restart: :temporary])

  defp prepopulate(size, sup), do: prepopulate(size, sup, [])
  defp prepopulate(size, sup, workers) when size < 1, do: workers
  defp prepopulate(size, sup, workers) do
    prepopulate(size - 1, sup, [new_worker(sup) | workers])
  end

  defp new_worker(sup) do
    {:ok, worker} = Supervisor.start_child(sup, [[]])
    worker
  end
end