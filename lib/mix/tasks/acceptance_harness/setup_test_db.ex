defmodule Mix.Tasks.AcceptanceHarness.SetupTestDb do
  @moduledoc "Prepares the local acceptance-harness test database for DB-backed tests."
  use Mix.Task

  @shortdoc "Prepares the acceptance-harness test DB for :db tests"

  @impl Mix.Task
  def run(_args) do
    if Mix.env() != :test do
      Mix.raise("Run with MIX_ENV=test (for example: MIX_ENV=test mix ecto.setup)")
    end

    Application.ensure_all_started(:acceptance_harness)

    case AcceptanceHarness.TestDb.setup_test_db() do
      {:ok, config} ->
        db_name = Keyword.fetch!(config, :database)
        Mix.shell().info("Prepared acceptance-harness test DB: #{db_name}")

      :error ->
        Mix.raise(
          "Unable to prepare acceptance-harness test DB. Set ACCEPTANCE_HARNESS_TEST_DB_USER and ACCEPTANCE_HARNESS_TEST_DB_PASSWORD."
        )
    end
  end
end
