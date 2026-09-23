defmodule AcceptanceHarnessConsumerWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AcceptanceHarnessConsumer.Endpoint

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AcceptanceHarnessConsumer.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(AcceptanceHarnessConsumer.Repo, {:shared, self()})
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
