defmodule Pooly.PoolServer do
  use GenServer
  import Supervisor.Spec

  defmodule State do
    defstruct pool_sup: nil, worker_sup: nil, size: nil, mfa: nil, workers: nil, monitors: nil, name: nil
  end

  def start_link(pool_sup, pool_config) do
    GenServer.start_link(__MODULE__, [pool_sup, pool_config], name: name(pool_config[:name]))
  end
  def checkout(pool_name), do: GenServer.call(name(pool_name), :checkout)
  def checkin(pool_name, worker_pid), do: GenServer.cast(name(pool_name), {:checkin, worker_pid})
  def status(pool_name), do: GenServer.call(name(pool_name), :status)

  #server functions
  def init([pool_sup, pool_config]) when is_pid(pool_sup) do
    Process.flag(:trap_exit, true)
    init(pool_config, %State{pool_sup: pool_sup, monitors: :ets.new(:monitors, [:private])})
  end
  def init([{:name, name} | rest], state), do: init(rest, %{state | name: name})
  def init([{:mfa, mfa} | rest], state), do: init(rest, %{state | mfa: mfa})
  def init([{:size, size} | rest], state), do: init(rest, %{state | size: size})
  def init([], state), do: start_worker_supervisor(state)
  def init([_ | rest], state), do: init(rest, state)

  def handle_call(:checkout, {from_pid, _ref}, %{workers: workers, monitors: monitors} = state) do
    case workers do
      [worker_pid | rest] ->
        monitor_ref = Process.monitor(from_pid)
        true = :ets.insert(monitors, {worker_pid, monitor_ref})
        {:reply, worker_pid, %{state | workers: rest}}
      [] -> {:reply, :noproc, state}
    end
  end

  def handle_call(:status, _from, %{workers: workers, monitors: monitors} = state) do
    {:reply, {length(workers), :ets.info(monitors, :size)}, state}
  end

  def handle_cast({:checkin, worker_pid}, %{workers: workers, monitors: monitors} = state) do
    case :ets.lookup(monitors, worker_pid) do
      [{w_pid, monitor_ref}] ->
        true = Process.demonitor(monitor_ref)
        true = :ets.delete(monitors, w_pid)
        {:noreply, %{state | workers: [w_pid | workers]}}
      [] -> {:noreply, state}
    end
  end

  def handle_info(:start_worker_supervisor, state = %{pool_sup: pool_sup, size: size, mfa: mfa, name: name}) do
    {:ok, worker_sup} = Supervisor.start_child(pool_sup, worker_supervisor_spec(name, mfa))
    workers = prepopulate(size, worker_sup)
    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}
  end


  #handle down info
  def handle_info({:DOWN, monitor_ref, _, _, _}, state = %{workers: workers, monitors: monitors}) do
    case :ets.match(monitors, {:"$1", monitor_ref}) do
      [[worker_pid]] ->
        true = :ets.delete(monitors, worker_pid)
        {:noreply, %{state | workers: [worker_pid | workers]}}
      [] -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state = %{workers: workers, monitors: monitors, pool_sup: pool_sup}) do
    case :ets.lookup(monitors, pid) do
      [{w_pid, monitor_ref}] ->
        true = Process.demonitor(monitor_ref)
        true = :ets.delete(monitors, w_pid)
        {:noreply, %{state | workers: [new_worker(pool_sup) | workers]}}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, worker_sup, reason}, state = %{worker_sup: worker_sup}) do
    {:stop, reason, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  #private functions
  defp start_worker_supervisor(state) do
    send(self(), :start_worker_supervisor)
    {:ok, state}
  end

  defp prepopulate(size, worker_sup), do: prepopulate(size, worker_sup, [])
  defp prepopulate(size, _worker_sup, workers) when size < 1, do: workers
  defp prepopulate(size, worker_sup, workers), do: prepopulate(size-1, worker_sup, [new_worker(worker_sup) | workers])

  defp worker_supervisor_spec(name, mfa) do
    opts = [id: name <> "WorkerSupervisor", restart: :temporary]
    supervisor(Pooly.WorkerSupervisor, [self(), mfa], opts)
  end

  defp new_worker(worker_sup) do
    {:ok, worker} = Supervisor.start_child(worker_sup, [[]])
    worker
  end

  defp name(pool_name), do: :"#{pool_name}Server"
end

#defmodule Pooly.PoolServer do
#  use GenServer
#  import Supervisor.Spec
#  defmodule State do
#    defstruct pool_sup: nil, worker_sup: nil, monitors: nil, size: nil, workers: nil, name: nil, mfa: nil
#  end
#  def start_link(pool_sup, pool_config) do
#    GenServer.start_link(__MODULE__, [pool_sup, pool_config], name: name(pool_config[:name]))
#  end
#  def checkout(pool_name) do
#    GenServer.call(name(pool_name), :checkout)
#  end
#  def checkin(pool_name, worker_pid) do
#    GenServer.cast(name(pool_name), {:checkin, worker_pid})
#  end
#  def status(pool_name) do
#    GenServer.call(name(pool_name), :status)
#  end
#  #############
#  # Callbacks #
#  ############j
#  def init([pool_sup, pool_config]) when is_pid(pool_sup) do
#    Process.flag(:trap_exit, true)
#    monitors = :ets.new(:monitors, [:private])
#    init(pool_config, %State{pool_sup: pool_sup, monitors: monitors})
#  end
#  def init([{:name, name}|rest], state) do
#    init(rest,  %{state | name: name})
#  end
#  def init([{:mfa, mfa}|rest], state) do
#    init(rest,  %{state | mfa: mfa})
#  end
#  def init([{:size, size}|rest], state) do
#    init(rest, %{state | size: size})
#  end
#  def init([_|rest], state) do
#    init(rest, state)
#  end
#  def init([], state) do
#    send(self, :start_worker_supervisor)
#    {:ok, state}
#  end
#
#
#  def handle_call(:checkout, {from_pid, _ref}, %{workers: workers, monitors: monitors} = state) do
#    case workers do
#      [worker|rest] ->
#        ref = Process.monitor(from_pid)
#        true = :ets.insert(monitors, {worker, ref})
#        {:reply, worker, %{state | workers: rest}}
#      [] ->
#        {:reply, :noproc, state}
#    end
#  end
#
#  def handle_call(:status, _from, %{workers: workers, monitors: monitors} = state) do
#    {:reply, {length(workers), :ets.info(monitors, :size)}, state}
#  end
#
#  def handle_cast({:checkin, worker}, %{workers: workers, monitors: monitors} = state) do
#    case :ets.lookup(monitors, worker) do
#      [{pid, ref}] ->
#        true = Process.demonitor(ref)
#        true = :ets.delete(monitors, pid)
#        {:noreply, %{state | workers: [pid|workers]}}
#      [] ->
#        {:noreply, state}
#    end
#  end
#
#  def handle_info(:start_worker_supervisor, state = %{pool_sup: pool_sup, name: name, mfa: mfa, size: size}) do
#    {:ok, worker_sup} = Supervisor.start_child(pool_sup, supervisor_spec(name, mfa))
#    workers = prepopulate(size, worker_sup)
#    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}
#  end
#
#  def handle_info({:DOWN, ref, _, _, _}, state = %{monitors: monitors, workers: workers}) do
#    case :ets.match(monitors, {:"$1", ref}) do
#      [[pid]] ->
#        true = :ets.delete(monitors, pid)
#        new_state = %{state | workers: [pid|workers]}
#        {:noreply, new_state}
#      [[]] ->
#        {:noreply, state}
#    end
#  end
#
#  def handle_info({:EXIT, pid, _reason}, state = %{monitors: monitors, workers: workers, pool_sup: pool_sup}) do
#    case :ets.lookup(monitors, pid) do
#      [{pid, ref}] ->
#        true = Process.demonitor(ref)
#        true = :ets.delete(monitors, pid)
#        new_state = %{state | workers: [new_worker(pool_sup)|workers]}
#        {:noreply, new_state}
#      _ ->
#        {:noreply, state}
#    end
#  end
#
#  def terminate(_reason, _state) do
#    :ok
#  end
#
#  #####################
#  # Private Functions #
#  #####################
#  defp name(pool_name) do
#    :"#{pool_name}Server"
#  end
#  defp prepopulate(size, sup) do
#    prepopulate(size, sup, [])
#  end
#  defp prepopulate(size, _sup, workers) when size < 1 do
#    workers
#  end
#  defp prepopulate(size, sup, workers) do
#    prepopulate(size-1, sup, [new_worker(sup) | workers])
#  end
#  defp new_worker(sup) do
#    {:ok, worker} = Supervisor.start_child(sup, [[]])
#    worker
#  end
#  defp supervisor_spec(name, mfa) do
#    opts = [id: name <> "WorkerSupervisor", restart: :temporary]
#    supervisor(Pooly.WorkerSupervisor, [self(), mfa], opts)
#  end
#end


