defmodule Pooly.Supervisor do
  use Supervisor

  #api
  def start_link(pool_config), do: Supervisor.start_link(__MODULE__, pool_config, name: __MODULE__)

  #server
  def init(pools_config) do
    children = [
      supervisor(Pooly.PoolsSupervisor, []),
      worker(Pooly.Server, [pools_config])
    ]
    supervise(children, [strategy: :one_for_all])
  end
end
#defmodule Pooly.Supervisor do
#  use Supervisor
#  def start_link(pools_config) do
#    Supervisor.start_link(__MODULE__, pools_config,
#      name: __MODULE__)
#  end
#  def init(pools_config) do
#    children = [
#      supervisor(Pooly.PoolsSupervisor, []),
#      worker(Pooly.Server, [pools_config])
#    ]
#    opts = [strategy: :one_for_all]
#    supervise(children, opts)
#  end
#end


