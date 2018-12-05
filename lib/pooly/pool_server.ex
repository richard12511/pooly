defmodule Pooly.PoolServer do
  use GenServer
  import Supervisor.Spec

  defmodule State do
    defstruct pool_sup: nil, worker_sup: nil, monitors: nil, size: nil, workers: nil, name: nil, mfa: nil,
    max_overflow: nil, overflow: nil, waiting: nil
  end

  def start_link(pool_sup, pool_config) do
    GenServer.start_link(__MODULE__, [pool_sup, pool_config], name: name(pool_config[:name]))
  end

  def checkout(pool_name, block, timeout) do
    GenServer.call(name(pool_name), {:checkout, block}, timeout)
  end

  def checkin(pool_name, worker_pid) do
    GenServer.cast(name(pool_name), {:checkin, worker_pid})
  end

  def status(pool_name) do
    GenServer.call(name(pool_name), :status)
  end

  def terminate(_reason, _state) do
    :ok
  end

  #############
  # Callbacks #
  ############j

  def init([pool_sup, pool_config]) when is_pid(pool_sup) do
    Process.flag(:trap_exit, true)
    monitors = :ets.new(:monitors, [:private])
    waiting = :queue.new
    init(pool_config, %State{pool_sup: pool_sup, monitors: monitors, waiting: waiting, overflow: 0})
  end

  def init([{:name, name}|rest], state) do
    init(rest,  %{state | name: name})
  end

  def init([{:mfa, mfa}|rest], state) do
    init(rest,  %{state | mfa: mfa})
  end

  def init([{:size, size}|rest], state) do
    init(rest, %{state | size: size})
  end

  def init([{:max_overflow, max_overflow}|rest], state) do
    init(rest, %{state | max_overflow: max_overflow})
  end

  def init([], state) do
    send(self(), :start_worker_supervisor)
    {:ok, state}
  end

  def init([_|rest], state) do
    init(rest, state)
  end

  def handle_call({:checkout, block}, {from_pid, _ref} = from, state) do
    %{
      worker_sup: worker_sup, workers: workers, monitors: monitors,
      overflow: overflow, max_overflow: max_overflow, waiting: waiting
    } = state

    case workers do
      [worker|rest] ->
        ref = Process.monitor(from_pid)
        true = :ets.insert(monitors, {worker, ref})
        {:reply, worker, %{state | workers: rest}}
      [] when max_overflow > 0 and overflow < max_overflow ->
        {worker_pid, monitor_ref} = new_worker(worker_sup, from_pid)
        true = :ets.insert(monitors, {worker_pid, monitor_ref})
        {:reply, worker_pid, %{state | overflow: overflow + 1}}
      [] when block == true ->
        monitor_ref = Process.monitor(from)
        waiting = :queue.in({from, monitor_ref}, waiting)
        {:noreply, %{state | waiting: waiting}, :infinity}
      [] ->
        {:reply, :full, state}
    end
  end

  def handle_call(:status, _from, %{workers: workers, monitors: monitors} = state) do
    {:reply, {state_name(state), length(workers), :ets.info(monitors, :size)}, state}
  end

  def handle_cast({:checkin, worker}, %{workers: _workers, monitors: monitors} = state) do
    case :ets.lookup(monitors, worker) do
      [{pid, ref}] ->
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        {:noreply, handle_checkin(pid, state)}
      [] ->
        {:noreply, state}
    end
  end

  def handle_info(:start_worker_supervisor, state = %{pool_sup: pool_sup, name: name, mfa: mfa, size: size}) do
    {:ok, worker_sup} = Supervisor.start_child(pool_sup, supervisor_spec(name, mfa))
    workers = prepopulate(size, worker_sup)
    {:noreply, %{state | worker_sup: worker_sup, workers: workers}}
  end

  def handle_info({:DOWN, ref, _, _, _}, state = %{monitors: monitors, workers: workers}) do
    case :ets.match(monitors, {:"$1", ref}) do
      [[pid]] ->
        true = :ets.delete(monitors, pid)
        new_state = %{state | workers: [pid|workers]}
        {:noreply, new_state}

      [[]] ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, worker_sup, reason}, state = %{worker_sup: worker_sup}) do
    IO.puts("handle_info stop")
    {:stop, reason, state}
  end

  def handle_info({:EXIT, pid, _reason}, state = %{monitors: monitors, workers: _workers, worker_sup: _worker_sup}) do
    IO.puts("handle_info worker exit")
    case :ets.lookup(monitors, pid) do
      [{pid, ref}] ->
        true = Process.demonitor(ref)
        true = :ets.delete(monitors, pid)
        new_state = handle_worker_exit(pid, state)
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  #####################
  # Private Functions #
  #####################

  defp name(pool_name) do
    :"#{pool_name}Server"
  end

  defp prepopulate(size, sup) do
    prepopulate(size, sup, [])
  end

  defp prepopulate(size, _sup, workers) when size < 1 do
    workers
  end

  defp prepopulate(size, sup, workers) do
    prepopulate(size-1, sup, [new_worker(sup) | workers])
  end

  defp new_worker(sup) do
    {:ok, worker} = Supervisor.start_child(sup, [[]])
    true = Process.link(worker)
    worker
  end

  defp new_worker(sup, from_pid) do
    pid = new_worker(sup)
    monitor_ref = Process.monitor(from_pid)
    {pid, monitor_ref}
  end

  defp supervisor_spec(name, mfa) do
    # NOTE: The reason this is set to temporary is because the WorkerSupervisor
    #       is started by the PoolServer.
    opts = [id: name <> "WorkerSupervisor", shutdown: 10000, restart: :temporary]
    supervisor(Pooly.WorkerSupervisor, [self(), mfa], opts)
  end

  defp handle_checkin(worker_pid, state) do
    %{
      worker_sup: worker_sup, workers: workers, monitors: monitors,
      overflow: overflow, waiting: waiting
    } = state

    case :queue.out(waiting) do
      {{:value, {from, ref}}, left} ->
        true = :ets.insert(monitors, {worker_pid, ref})
        GenServer.reply(from, worker_pid)
        %{state | waiting: left}
      {:empty, empty} when overflow > 0 ->
        :ok = dismiss_worker(worker_sup, worker_pid)
        %{state | waiting: empty, overflow: overflow-1}
      {:empty, empty} -> %{state | wating: empty, overflow: 0, workers: [worker_pid | workers]}
    end
  end

  defp handle_worker_exit(_worker_pid, state) do
    %{
      worker_sup: worker_sup, workers: workers, monitors: monitors,
      overflow: overflow, waiting: waiting
    } = state

    case :queue.out(waiting) do
      {{:value, {from, ref}}, left} ->
        new_worker_pid = new_worker(worker_sup)
        true = :ets.insert(monitors, {new_worker_pid, ref})
        GenServer.reply(from, new_worker_pid)
        %{state | waiting: left}

      {:empty, empty} when overflow > 0 -> %{state | waiting: empty, overflow: overflow-1}

      {:empty, empty} -> %{state | waiting: empty, overflow: 0, workers: [new_worker(worker_sup) | workers]}
    end
  end

  defp dismiss_worker(worker_sup, worker_pid) do
    true = Process.unlink(worker_pid)
    Supervisor.terminate_child(worker_sup, worker_pid)
  end

  defp state_name(%State{overflow: overflow, max_overflow: max_overflow, workers: workers}) when overflow < 1 do
    case length(workers) == 0 do
      true ->
        if max_overflow < 1 do
          :full
        else
          :overflow
        end
      false -> :ready
    end
  end

  defp state_name(%State{overflow: max_overflow, max_overflow: max_overflow}), do: :full
  defp state_name(_state), do: :overflow

end