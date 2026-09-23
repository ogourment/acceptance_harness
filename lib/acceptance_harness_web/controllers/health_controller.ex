defmodule AcceptanceHarnessWeb.HealthController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  alias AcceptanceHarness.Health

  def check(conn, _params), do: Phoenix.Controller.json(conn, Health.payload())
end
