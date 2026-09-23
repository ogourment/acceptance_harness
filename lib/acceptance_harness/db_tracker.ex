defmodule AcceptanceHarness.DbTracker do
  @moduledoc """
  Postgres row tracker for staging-backed acceptance cleanup.

  The tracker installs insert triggers on every primary-key table in a schema.
  While an ATDD run is active, inserted rows are recorded in
  `acceptance_harness_created_rows`. Cleanup deletes those exact rows in reverse
  insertion order.

  This intentionally tracks database writes globally while active. It is meant
  for staging environments where ATDD has exclusive practical use of the app.
  """

  @state_table "acceptance_harness_atdd_state"
  @rows_table "acceptance_harness_created_rows"
  @function_name "acceptance_harness_track_insert"
  @trigger_name "acceptance_harness_track_insert"
  @default_schema "public"
  @default_excluded_tables [@state_table, @rows_table, "schema_migrations"]

  @doc """
  Installs tracker tables, trigger function, and insert triggers.

  By default this instruments every table with a primary key in the `public`
  schema, excluding tracker-owned tables and `schema_migrations`.
  """
  def install!(repo, opts \\ []) do
    schema = Keyword.get(opts, :schema, @default_schema)
    excluded_tables = Keyword.get(opts, :exclude_tables, @default_excluded_tables)

    create_tracker_tables!(repo)
    create_tracker_function!(repo)

    repo
    |> tracked_tables(schema, excluded_tables)
    |> Enum.each(&install_trigger!(repo, &1))

    :ok
  end

  @doc """
  Starts globally tracking inserts for `run_id`.
  """
  def begin_run!(repo, run_id) when is_binary(run_id) and run_id != "" do
    create_tracker_tables!(repo)

    query!(
      repo,
      """
      INSERT INTO #{@state_table} (key, value)
      VALUES ('run_id', $1)
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()
      """,
      [run_id]
    )

    run_id
  end

  @doc """
  Stops global insert tracking.
  """
  def end_run!(repo) do
    create_tracker_tables!(repo)

    query!(
      repo,
      """
      INSERT INTO #{@state_table} (key, value)
      VALUES ('run_id', NULL)
      ON CONFLICT (key) DO UPDATE SET value = NULL, updated_at = now()
      """,
      []
    )

    :ok
  end

  @doc """
  Runs `fun` while global insert tracking is active.
  """
  def with_run!(repo, run_id, fun) when is_function(fun, 0) do
    begin_run!(repo, run_id)

    try do
      fun.()
    after
      end_run!(repo)
    end
  end

  @doc """
  Deletes rows created by `run_id` in reverse insertion order.

  Rows already removed by cascades or explicit cleanup count as missing, not
  failures. Pass `reset?: true` to remove tracker rows for the run after cleanup.
  """
  def cleanup!(repo, run_id, opts \\ []) when is_binary(run_id) and run_id != "" do
    rows = created_rows(repo, run_id)

    summary =
      Enum.reduce(rows, %{deleted: 0, missing: 0, failed: []}, fn row, summary ->
        case delete_created_row(repo, row) do
          {:ok, 1} -> %{summary | deleted: summary.deleted + 1}
          {:ok, 0} -> %{summary | missing: summary.missing + 1}
          {:error, error} -> %{summary | failed: [%{row: row, error: error} | summary.failed]}
        end
      end)

    if summary.failed != [] do
      raise RuntimeError, "ATDD DB cleanup failed: #{inspect(Enum.reverse(summary.failed))}"
    end

    if Keyword.get(opts, :reset?, false) do
      query!(repo, "DELETE FROM #{@rows_table} WHERE run_id = $1", [run_id])
    end

    summary
  end

  @doc """
  Returns tracked rows for `run_id` in reverse insertion order.
  """
  def created_rows(repo, run_id) do
    repo
    |> query!(
      """
      SELECT id, table_schema, table_name, primary_key
      FROM #{@rows_table}
      WHERE run_id = $1
      ORDER BY id DESC
      """,
      [run_id]
    )
    |> Map.fetch!(:rows)
    |> Enum.map(fn [id, schema, table, primary_key] ->
      %{id: id, schema: schema, table: table, primary_key: primary_key}
    end)
  end

  defp create_tracker_tables!(repo) do
    query!(
      repo,
      """
      CREATE TABLE IF NOT EXISTS #{@state_table} (
        key text PRIMARY KEY,
        value text,
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

    query!(
      repo,
      """
      CREATE TABLE IF NOT EXISTS #{@rows_table} (
        id bigserial PRIMARY KEY,
        run_id text NOT NULL,
        table_schema text NOT NULL,
        table_name text NOT NULL,
        primary_key jsonb NOT NULL,
        inserted_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

    query!(
      repo,
      "CREATE INDEX IF NOT EXISTS #{@rows_table}_run_id_id_idx ON #{@rows_table} (run_id, id DESC)",
      []
    )
  end

  defp create_tracker_function!(repo) do
    query!(
      repo,
      """
      CREATE OR REPLACE FUNCTION #{@function_name}()
      RETURNS trigger AS $$
      DECLARE
        active_run_id text;
        key_col text;
        primary_key jsonb := '{}'::jsonb;
      BEGIN
        SELECT value INTO active_run_id
        FROM #{@state_table}
        WHERE key = 'run_id';

        IF active_run_id IS NULL OR active_run_id = '' THEN
          RETURN NEW;
        END IF;

        FOREACH key_col IN ARRAY TG_ARGV LOOP
          primary_key := primary_key || jsonb_build_object(key_col, to_jsonb(NEW)->key_col);
        END LOOP;

        INSERT INTO #{@rows_table} (run_id, table_schema, table_name, primary_key)
        VALUES (active_run_id, TG_TABLE_SCHEMA, TG_TABLE_NAME, primary_key);

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """,
      []
    )
  end

  defp tracked_tables(repo, schema, excluded_tables) do
    repo
    |> query!(
      """
      SELECT table_schema, table_name, array_agg(column_name ORDER BY ordinal_position) AS columns
      FROM (
        SELECT
          table_constraints.table_schema,
          table_constraints.table_name,
          key_column_usage.column_name,
          key_column_usage.ordinal_position
        FROM information_schema.table_constraints
        JOIN information_schema.key_column_usage
          ON key_column_usage.constraint_name = table_constraints.constraint_name
         AND key_column_usage.table_schema = table_constraints.table_schema
         AND key_column_usage.table_name = table_constraints.table_name
        WHERE table_constraints.constraint_type = 'PRIMARY KEY'
          AND table_constraints.table_schema = $1
          AND table_constraints.table_name <> ALL($2)
      ) primary_keys
      GROUP BY table_schema, table_name
      ORDER BY table_schema, table_name
      """,
      [schema, excluded_tables]
    )
    |> Map.fetch!(:rows)
    |> Enum.map(fn [table_schema, table_name, columns] ->
      %{schema: table_schema, table: table_name, primary_key_columns: columns}
    end)
  end

  defp install_trigger!(repo, table) do
    qualified_table = qualified_name(table.schema, table.table)
    trigger_args = Enum.map_join(table.primary_key_columns, ", ", &quote_literal/1)

    query!(
      repo,
      "DROP TRIGGER IF EXISTS #{@trigger_name} ON #{qualified_table}",
      []
    )

    query!(
      repo,
      """
      CREATE TRIGGER #{@trigger_name}
      AFTER INSERT ON #{qualified_table}
      FOR EACH ROW
      EXECUTE FUNCTION #{@function_name}(#{trigger_args});
      """,
      []
    )
  end

  defp delete_created_row(repo, row) do
    columns = Map.keys(row.primary_key)
    values = Enum.map(columns, &Map.fetch!(row.primary_key, &1))

    where =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(" AND ", fn {column, index} -> "#{quote_ident(column)} = $#{index}" end)

    sql = "DELETE FROM #{qualified_name(row.schema, row.table)} WHERE #{where}"

    try do
      result = query!(repo, sql, values)
      {:ok, result.num_rows}
    rescue
      error -> {:error, error}
    end
  end

  defp query!(repo, sql, params) do
    apply(Ecto.Adapters.SQL, :query!, [repo, sql, params])
  end

  defp qualified_name(schema, table), do: "#{quote_ident(schema)}.#{quote_ident(table)}"

  defp quote_ident(value) do
    escaped = value |> to_string() |> String.replace("\"", "\"\"")
    ~s("#{escaped}")
  end

  defp quote_literal(value) do
    escaped = value |> to_string() |> String.replace("'", "''")
    "'#{escaped}'"
  end
end
