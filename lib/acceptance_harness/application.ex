defmodule AcceptanceHarness.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [AcceptanceHarness.Terminal.Supervisor]
    Supervisor.start_link(children, strategy: :one_for_one, name: AcceptanceHarness.Supervisor)
  end
end
