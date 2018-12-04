#defmodule Pooly.Server do
#  use GenServer
#  import Supervisor.Spec
#
#  #api
#  def start_link(pools_config), do: GenServer.start_link(__MODULE__, pools_config, name: __MODULE__)
#  def checkout(pool_name), do: GenServer.call(:"#{pool_name}Server", :checkout)
#  def checkin(pool_name, worker_pid), do: GenServer.call(:"#{pool_name}Server", {:checkin, worker_pid})
#  def status(pool_name), do: GenServer.call(:"#{pool_name}Server", :status)
#
#  #server
#  def init(pools_config) do
#    pools_config
#    |> Enum.each(fn(pool_config) ->
#      send(self(), {:start_pool, pool_config})
#    end)
#
#    {:ok, pools_config}
#  end
#
#  def handle_info({:start_pool, pool_config}, state) do
#    what_is_this = Supervisor.start_child(Pooly.PoolsSupervisor, supervisor_spec(pool_config))
#    IO.inspect(what_is_this)
#    {:noreply, state}
#  end
#
#  defp supervisor_spec(pool_config) do
#    opts = [id: :"#{pool_config[:name]}Supervisor"]
#    supervisor(Pooly.PoolSupervisor, [pool_config], opts)
#  end
#end

defmodule Pooly.Server do
  use GenServer
  import Supervisor.Spec

  #api
  def start_link(pools_config), do: GenServer.start_link(__MODULE__, pools_config, name: __MODULE__)
  def checkout(pool_name), do: GenServer.call(:"#{pool_name}Server", :checkout)
  def checkin(pool_name, worker_pid), do: GenServer.cast(:"#{pool_name}Server", {:checkin, worker_pid})
  def status(pool_name), do: GenServer.call(:"#{pool_name}Server", :status)

  #server
  def init(pools_config) do
    pools_config |> Enum.each(fn(pool_config) ->
      send(self(), {:start_pool, pool_config})
    end)
    {:ok, pools_config}
  end

  def handle_info({:start_pool, pool_config}, state) do
    {:ok, _pool_sup} = Supervisor.start_child(Pooly.PoolsSupervisor, supervisor_spec(pool_config))
    {:noreply, state}
  end

  defp supervisor_spec(pool_config) do
    opts = [id: :"#{pool_config[:name]}Supervisor"]
    supervisor(Pooly.PoolSupervisor, [pool_config], opts)
  end
end


