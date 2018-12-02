defmodule Pooly.Supervisor do
  use Supervisor

  #api
  def start_link(pool_config), do: Supervisor.start_link(__MODULE__, pool_config)

  #server
  def init(pool_config) do
    children = [worker(Pooly.Server), [self, pool_config]]
    supervise(children, [strategy: :one_for_all])
  end
end