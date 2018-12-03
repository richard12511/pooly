defmodule Pooly.Server do
  use GenServer
  import Supervisor.Spec

  defmodule State do
    defstruct worker_sup: nil, size: nil, mfa: nil, monitors: [], workers: []
  end

  #api
  def start_link(worker_sup, pool_config) do
    GenServer.start_link(__MODULE__, [worker_sup, pool_config], name: __MODULE__)
  end

  def checkout, do: GenServer.call(__MODULE__, :checkout)
  def checkin(worker_pid), do: GenServer.cast(__MODULE__, {:checkin, worker_pid})
  def status, do: GenServer.call(__MODULE__, :status)

  #server
  def init([worker_sup, pool_config]) when is_pid(worker_sup) do
    Process.flag(:trap_exit, true)
    monitors = :ets.new(:monitors, [:private, :named_table])
    init(pool_config, %State{worker_sup: worker_sup, monitors: monitors})
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

  def handle_info(:start_worker_supervisor, state = %{worker_sup: worker_sup, mfa: mfa, size: size}) do
    {:ok, worker_sup} = Supervisor.start_child(worker_sup, supervisor_spec(mfa))
    workers = prepopulate(size, worker_sup)
    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}
  end

  def handle_info({:DOWN, ref, _,_,_}, state = %{workers: workers, monitors: monitors}) do
    case :ets.match(monitors, {:"$1", ref}) do
      [[pid]] ->
        true = :ets.delete(monitors, pid)
        {:noreply, %{state | workers: [pid | workers]}}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state = %{monitors: monitors, workers: workers, worker_sup: worker_sup}) do
    case :ets.lookup(monitors, pid) do
      [{pid, monitor_ref}] ->
        true = Process.demonitor(monitor_ref)
        true = :ets.delete(monitors, pid)
        {:noreply, %{state | workers: [new_worker(worker_sup) | workers]}}
      [[]] -> {:noreply, state}
    end
  end

  #private
  defp supervisor_spec(mfa), do: supervisor(Pooly.WorkerSupervisor, [mfa], [restart: :temporary])

  defp prepopulate(size, worker_sup), do: prepopulate(size, worker_sup, [])
  defp prepopulate(size, _worker_sup, workers) when size < 1, do: workers
  defp prepopulate(size, worker_sup, workers) do
    prepopulate(size - 1, worker_sup, [new_worker(worker_sup) | workers])
  end

  defp new_worker(worker_sup) do
    {:ok, worker} = Supervisor.start_child(worker_sup, [[]])
    worker
  end
end