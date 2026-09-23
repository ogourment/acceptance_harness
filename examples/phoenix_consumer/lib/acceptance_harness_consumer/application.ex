defmodule AcceptanceHarnessConsumer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: AcceptanceHarnessConsumer.PubSub},
        AcceptanceHarnessConsumer.Endpoint
      ] ++ repo_child()

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: AcceptanceHarnessConsumer.Supervisor
    )
  end

  defp repo_child do
    if Mix.env() == :test, do: [], else: [AcceptanceHarnessConsumer.Repo]
  end
end
