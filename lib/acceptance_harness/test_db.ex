defmodule AcceptanceHarness.TestDb do
  @moduledoc false

  @default_user "postgres"
  @default_password "postgres"

  @doc false
  def setup_test_db do
    case find_db_config() do
      {:ok, db_config} ->
        Application.put_env(:acceptance_harness, AcceptanceHarness.TestRepo, db_config)
        ensure_repo_started!()
        install_schema!()
        {:ok, db_config}

      :error ->
        :error
    end
  end

  def find_db_config do
    base = base_db_config()

    explicit_user = System.get_env("ACCEPTANCE_HARNESS_TEST_DB_USER")
    explicit_password = System.get_env("ACCEPTANCE_HARNESS_TEST_DB_PASSWORD")

    candidates =
      if explicit_user || explicit_password do
        [
          [
            username: explicit_user || @default_user,
            password: explicit_password || @default_password
          ]
        ]
      else
        [
          [username: @default_user, password: @default_password],
          [
            username:
              System.get_env(
                "POSTGRES_USER",
                System.get_env("PGUSER", System.get_env("USER", "postgres"))
              ),
            password: System.get_env("POSTGRES_PASSWORD", System.get_env("PGPASSWORD", ""))
          ],
          [username: System.get_env("USER"), password: System.get_env("PGPASSWORD", "")]
        ]
      end
      |> Enum.uniq()
      |> Enum.reject(&is_nil(Keyword.get(&1, :username)))

    Enum.find_value(candidates, fn candidate ->
      merged = Keyword.merge(base, candidate)

      case check_db_exists(merged) do
        :ok -> {:ok, merged}
        {:error, :already_up} -> {:ok, merged}
        _ -> nil
      end
    end) || :error
  end

  defp base_db_config do
    [
      hostname: System.get_env("ACCEPTANCE_HARNESS_TEST_DB_HOST", "localhost"),
      database: System.get_env("ACCEPTANCE_HARNESS_TEST_DB_NAME", "acceptance_harness_test"),
      pool_size: 2,
      log: false
    ]
  end

  defp check_db_exists(config) do
    original_level = Logger.level()
    Logger.configure(level: :critical)

    try do
      apply(Ecto.Adapters.Postgres, :storage_up, [config])
    rescue
      _ -> :error
    after
      Logger.configure(level: original_level)
    end
  end

  defp ensure_repo_started! do
    case apply(AcceptanceHarness.TestRepo, :start_link, []) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise reason
    end
  end

  defp install_schema! do
    AcceptanceHarness.AdminStore.install!(repo: AcceptanceHarness.TestRepo)
  end
end
