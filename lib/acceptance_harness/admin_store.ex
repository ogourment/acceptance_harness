defmodule AcceptanceHarness.AdminStore do
  @moduledoc """
  Database-backed storage for imported acceptance reports.

  The store expects a Postgres Ecto repo. Host applications can pass `repo: MyApp.Repo`
  to each function or configure it with:

      config :acceptance_harness, :harness, repo: MyApp.Repo
  """

  @runs_table "acceptance_harness_runs"
  @scenarios_table "acceptance_harness_scenarios"
  @steps_table "acceptance_harness_steps"
  # Raw per-step HTML is the heaviest evidence payload and the reason staging
  # snapshots grew to ~1.1GB each. A week comfortably covers the review cycle
  # and keeps run-to-run change detection intact.
  @default_html_keep_days 7
  # Full-text vector over what a reviewer can see on a step: its title,
  # description, and the captured page text. Must stay in sync with the GIN
  # expression index created by install!/1 to stay indexable.
  @steps_fts_vector "to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(description, '') || ' ' || coalesce(page_text, ''))"

  @json_columns MapSet.new([
                  :app,
                  :runner,
                  :timing,
                  :artifacts,
                  :devices,
                  :themes,
                  :languages,
                  :users,
                  :tags,
                  :failure,
                  :metadata,
                  :screenshot,
                  :surface,
                  :run_app,
                  :step_metadata,
                  :step_screenshot
                ])

  def install!(opts \\ []) do
    repo = repo!(opts)

    query!(repo, """
    CREATE TABLE IF NOT EXISTS #{@runs_table} (
      id text PRIMARY KEY,
      title text NOT NULL,
      app jsonb NOT NULL DEFAULT '{}'::jsonb,
      runner jsonb NOT NULL DEFAULT '{}'::jsonb,
      timing jsonb NOT NULL DEFAULT '{}'::jsonb,
      artifacts jsonb NOT NULL DEFAULT '[]'::jsonb,
      source_dir text,
      source_url text,
      generated_at timestamptz,
      started_at timestamptz,
      finalized_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    query!(repo, "ALTER TABLE #{@runs_table} ADD COLUMN IF NOT EXISTS source_url text")

    query!(repo, """
    CREATE TABLE IF NOT EXISTS #{@scenarios_table} (
      id bigserial PRIMARY KEY,
      run_id text NOT NULL REFERENCES #{@runs_table}(id) ON DELETE CASCADE,
      scenario_id text NOT NULL,
      title text NOT NULL,
      status text NOT NULL,
      scenario_order integer,
      duration_ms bigint,
      documented_step_ms bigint,
      undocumented_ms bigint,
      devices jsonb NOT NULL DEFAULT '[]'::jsonb,
      themes jsonb NOT NULL DEFAULT '[]'::jsonb,
      languages jsonb NOT NULL DEFAULT '[]'::jsonb,
      users jsonb NOT NULL DEFAULT '[]'::jsonb,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (run_id, scenario_id)
    )
    """)

    query!(repo, """
    CREATE TABLE IF NOT EXISTS #{@steps_table} (
      id text PRIMARY KEY,
      run_id text NOT NULL REFERENCES #{@runs_table}(id) ON DELETE CASCADE,
      scenario_id text,
      title text NOT NULL,
      description text,
      sequence bigint,
      screenshot jsonb NOT NULL DEFAULT '{}'::jsonb,
      surface jsonb NOT NULL DEFAULT '{"kind":"browser"}'::jsonb,
      artifacts jsonb NOT NULL DEFAULT '[]'::jsonb,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    query!(repo, "ALTER TABLE #{@steps_table} DROP CONSTRAINT IF EXISTS #{@steps_table}_pkey")

    query!(repo, """
    ALTER TABLE #{@steps_table}
    ADD PRIMARY KEY (run_id, id)
    """)

    query!(repo, """
    CREATE INDEX IF NOT EXISTS #{@steps_table}_run_scenario_idx
    ON #{@steps_table} (run_id, scenario_id, sequence)
    """)

    query!(repo, "DROP TABLE IF EXISTS acceptance_harness_statuses")

    query!(
      repo,
      "ALTER TABLE #{@scenarios_table} ADD COLUMN IF NOT EXISTS tags jsonb NOT NULL DEFAULT '[]'::jsonb"
    )

    query!(
      repo,
      "ALTER TABLE #{@scenarios_table} ADD COLUMN IF NOT EXISTS failure jsonb"
    )

    query!(repo, "ALTER TABLE #{@steps_table} ADD COLUMN IF NOT EXISTS page_text text")
    query!(repo, "ALTER TABLE #{@steps_table} ADD COLUMN IF NOT EXISTS page_html text")

    query!(
      repo,
      "ALTER TABLE #{@steps_table} ADD COLUMN IF NOT EXISTS surface jsonb NOT NULL DEFAULT '{\"kind\":\"browser\"}'::jsonb"
    )

    query!(
      repo,
      "ALTER TABLE #{@steps_table} ADD COLUMN IF NOT EXISTS artifacts jsonb NOT NULL DEFAULT '[]'::jsonb"
    )

    query!(repo, """
    CREATE INDEX IF NOT EXISTS #{@steps_table}_fts_idx
    ON #{@steps_table}
    USING GIN (#{@steps_fts_vector})
    """)

    normalize_json_columns!(repo)
    AcceptanceHarness.ReviewStore.install!(repo: repo)

    :ok
  end

  # Repairs jsonb columns that were written double-encoded (a jsonb string
  # holding JSON) by versions up to v0.3.4. Idempotent.
  defp normalize_json_columns!(repo) do
    [
      {@runs_table, ~w(app runner timing artifacts)},
      {@scenarios_table, ~w(devices themes languages users tags metadata)},
      {@steps_table, ~w(screenshot surface artifacts metadata)}
    ]
    |> Enum.each(fn {table, columns} ->
      Enum.each(columns, fn column ->
        query!(repo, """
        UPDATE #{table}
        SET #{column} = (#{column} #>> '{}')::jsonb
        WHERE jsonb_typeof(#{column}) = 'string'
          AND left(ltrim(#{column} #>> '{}'), 1) IN ('{', '[')
        """)
      end)
    end)
  end

  def import_evidence!(evidence_path, opts \\ []) do
    repo = repo!(opts)
    source_dir = Keyword.get(opts, :source_dir, Path.dirname(evidence_path))
    source_url = Keyword.get(opts, :source_url)

    evidence_path
    |> File.read!()
    |> Jason.decode!()
    |> import_evidence_data!(
      Keyword.put(opts, :repo, repo)
      |> Keyword.put(:source_dir, source_dir)
      |> Keyword.put(:source_url, source_url)
    )
  end

  def import_evidence_data!(evidence, opts \\ []) when is_map(evidence) do
    repo = repo!(opts)
    source_dir = Keyword.get(opts, :source_dir)
    source_url = Keyword.get(opts, :source_url)
    run = Map.fetch!(evidence, "run")
    run_id = Map.fetch!(run, "id")
    scenarios = Map.get(evidence, "scenarios", [])

    validate_scenario_aliases!(scenarios)
    install!(repo: repo)

    {:ok, ^run_id} =
      repo.transaction(fn ->
        query!(
          repo,
          """
          INSERT INTO #{@runs_table}
            (id, title, app, runner, timing, artifacts, source_dir, source_url, generated_at, started_at, finalized_at, updated_at)
          VALUES ($1, $2, $3::jsonb, $4::jsonb, $5::jsonb, $6::jsonb, $7, $8, $9, $10, $11, now())
          ON CONFLICT (id) DO UPDATE SET
            title = EXCLUDED.title,
            app = EXCLUDED.app,
            runner = EXCLUDED.runner,
            timing = EXCLUDED.timing,
            artifacts = EXCLUDED.artifacts,
            source_dir = EXCLUDED.source_dir,
            source_url = EXCLUDED.source_url,
            generated_at = EXCLUDED.generated_at,
            started_at = EXCLUDED.started_at,
            finalized_at = EXCLUDED.finalized_at,
            updated_at = now()
          """,
          [
            run_id,
            Map.get(evidence, "title", "Acceptance evidence"),
            json_param(Map.get(evidence, "app", %{})),
            json_param(Map.get(evidence, "runner", %{})),
            json_param(Map.get(evidence, "timing", %{})),
            json_param(Map.get(evidence, "artifacts", [])),
            source_dir,
            source_url,
            timestamp(Map.get(evidence, "generated_at")),
            timestamp(Map.get(run, "started_at")),
            timestamp(Map.get(run, "finalized_at"))
          ]
        )

        Enum.each(scenarios, &upsert_scenario!(repo, run_id, &1))

        scenarios
        |> Enum.flat_map(&Map.get(&1, "steps", []))
        |> Enum.each(&upsert_step!(repo, run_id, &1))

        run_id
      end)

    run_id
  end

  defp validate_scenario_aliases!(scenarios) do
    current_ids = MapSet.new(Enum.map(scenarios, &Map.fetch!(&1, "id")))

    Enum.reduce(scenarios, %{}, fn scenario, claims ->
      canonical_id = Map.fetch!(scenario, "id")

      Enum.reduce(legacy_scenario_ids!(scenario), claims, fn legacy_id, claims ->
        cond do
          legacy_id == canonical_id ->
            claims

          MapSet.member?(current_ids, legacy_id) ->
            raise ArgumentError,
                  "legacy scenario id #{inspect(legacy_id)} is also a current scenario id"

          Map.has_key?(claims, legacy_id) and claims[legacy_id] != canonical_id ->
            raise ArgumentError,
                  "legacy scenario id #{inspect(legacy_id)} is claimed by both #{inspect(claims[legacy_id])} and #{inspect(canonical_id)}"

          true ->
            Map.put(claims, legacy_id, canonical_id)
        end
      end)
    end)

    :ok
  end

  defp legacy_scenario_ids!(scenario) do
    legacy_ids =
      Map.get(scenario, "legacy_ids") || get_in(scenario, ["metadata", "legacy_ids"]) || []

    unless is_list(legacy_ids) and Enum.all?(legacy_ids, &is_binary/1) do
      raise ArgumentError,
            "scenario #{inspect(Map.get(scenario, "id"))} legacy_ids must be a list of strings"
    end

    legacy_ids
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def list_runs(opts \\ []) do
    repo = repo!(opts)

    repo
    |> query!(
      """
      SELECT
        runs.id,
        runs.title,
        runs.app,
        runs.timing,
        runs.generated_at,
        runs.finalized_at,
        count(DISTINCT scenarios.id)::int AS scenario_count,
        count(DISTINCT scenarios.id) FILTER (WHERE scenarios.status = 'failure')::int AS failure_count
      FROM #{@runs_table} runs
      LEFT JOIN #{@scenarios_table} scenarios ON scenarios.run_id = runs.id
      GROUP BY runs.id
      ORDER BY coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) DESC
      LIMIT $1
      """,
      [Keyword.get(opts, :limit, 20)]
    )
    |> rows_to_maps([
      :id,
      :title,
      :app,
      :timing,
      :generated_at,
      :finalized_at,
      :scenario_count,
      :failure_count
    ])
    |> Enum.map(&Map.merge(&1, run_change_summary(repo, &1.id)))
  end

  def latest_run(opts \\ []) do
    opts
    |> Keyword.put(:limit, 1)
    |> list_runs()
    |> List.first()
  end

  @doc "Returns imported run locations and timestamps for local evidence retention."
  def retention_runs(opts \\ []) do
    repo = repo!(opts)

    repo
    |> query!("""
    SELECT id, source_dir, generated_at, finalized_at, inserted_at
    FROM #{@runs_table}
    WHERE source_dir IS NOT NULL AND source_dir <> ''
    ORDER BY coalesce(finalized_at, generated_at, inserted_at) DESC
    """)
    |> rows_to_maps([:id, :source_dir, :generated_at, :finalized_at, :inserted_at])
  end

  @doc """
  Clears stored raw page HTML for runs older than the retention window.

  `page_html` is by far the heaviest column in the evidence schema: on Ecojeux
  staging it reached 1.63GB of a 1.84GB table, while `page_text` for the same
  47k steps was 43MB. Because the whole database is dumped hourly, that single
  column made every backup snapshot ~1.1GB and repeatedly filled the disk.

  Only `page_html` is cleared. Runs, scenarios, steps, screenshots, artifacts,
  metadata is untouched, and `page_text` is kept — it backs
  the full-text search vector, so evidence stays searchable.

  The window must comfortably exceed the review cycle: step-level change
  detection compares a run against the *previous* run's `page_html`, so a
  cleared previous run degrades that comparison to "no HTML to diff".

  Options:

    * `:keep_days` — retain HTML for runs finalized within this many days
      (default `#{@default_html_keep_days}`).
    * `:dry_run` — report what would change without writing (default `false`).
  """
  def prune_step_html!(opts \\ []) do
    repo = repo!(opts)
    keep_days = Keyword.get(opts, :keep_days, @default_html_keep_days)
    dry_run? = Keyword.get(opts, :dry_run, false)
    # Clearing one run still rewrites every TOAST chunk it owns, which is far
    # slower than an ordinary UPDATE and exceeds the default 15s query timeout
    # on a real backlog.
    batch_timeout = Keyword.get(opts, :batch_timeout, :timer.minutes(5))

    unless is_integer(keep_days) and keep_days >= 0 do
      raise ArgumentError, "keep_days must be a non-negative integer, got: #{inspect(keep_days)}"
    end

    [[runs, steps, bytes]] =
      repo
      |> query!(
        """
        SELECT
          count(DISTINCT s.run_id)::bigint,
          count(*)::bigint,
          coalesce(sum(pg_column_size(s.page_html)), 0)::bigint
        FROM #{@steps_table} s
        JOIN #{@runs_table} r ON r.id = s.run_id
        WHERE s.page_html IS NOT NULL
          AND coalesce(r.finalized_at, r.generated_at, r.inserted_at) < now() - ($1 || ' days')::interval
        """,
        [to_string(keep_days)]
      )
      |> Map.fetch!(:rows)

    unless dry_run? or steps == 0 do
      # One UPDATE over every stale row is not viable at real sizes: the first
      # production run would have touched 42k rows holding 1.4GB of TOAST, which
      # exceeds the default query timeout and holds locks and WAL for the whole
      # sweep. Clear run by run instead, so each statement stays small and an
      # interrupted sweep simply resumes on the next call.
      repo
      |> query!(
        """
        SELECT DISTINCT s.run_id
        FROM #{@steps_table} s
        JOIN #{@runs_table} r ON r.id = s.run_id
        WHERE s.page_html IS NOT NULL
          AND coalesce(r.finalized_at, r.generated_at, r.inserted_at) < now() - ($1 || ' days')::interval
        """,
        [to_string(keep_days)]
      )
      |> Map.fetch!(:rows)
      |> Enum.each(fn [run_id] ->
        apply(Ecto.Adapters.SQL, :query!, [
          repo,
          """
          UPDATE #{@steps_table}
          SET page_html = NULL, updated_at = now()
          WHERE run_id = $1 AND page_html IS NOT NULL
          """,
          [run_id],
          [timeout: batch_timeout]
        ])
      end)
    end

    %{
      keep_days: keep_days,
      dry_run?: dry_run?,
      runs: runs,
      steps: steps,
      bytes_reclaimed: bytes
    }
  end

  @doc "Returns the newest imported acceptance run corresponding to a deployment."
  def latest_run_for_deployment(deployment, opts \\ []) when is_map(deployment) do
    pipeline_id = deployment |> Map.get("pipeline_id") |> present_string()
    git_sha = deployment |> Map.get("git_sha") |> present_string()

    if is_nil(pipeline_id) and is_nil(git_sha) do
      nil
    else
      repo = repo!(opts)

      repo
      |> query!(
        """
        SELECT id, source_url, app, generated_at, finalized_at
        FROM #{@runs_table}
        WHERE ($1::text IS NOT NULL AND app->>'pipeline_id' = $1)
           OR ($2::text IS NOT NULL AND app->>'commit' = $2)
        ORDER BY
          CASE WHEN $1::text IS NOT NULL AND app->>'pipeline_id' = $1 THEN 1 ELSE 0 END DESC,
          coalesce(finalized_at, generated_at, inserted_at) DESC
        LIMIT 1
        """,
        [pipeline_id, git_sha]
      )
      |> rows_to_maps([:id, :source_url, :app, :generated_at, :finalized_at])
      |> List.first()
    end
  end

  def get_run!(run_id, opts \\ []) do
    repo = repo!(opts)

    result = query!(repo, "SELECT * FROM #{@runs_table} WHERE id = $1", [run_id])

    case result.rows do
      [row] -> row_to_map(result.columns, row)
      [] -> raise ArgumentError, "acceptance harness run not found: #{run_id}"
    end
  end

  @doc """
  Scenarios of a run.

  Filter options: `:value_stream`, `:capability`, `:device`, `:language`,
  `:user`, `:tag` (facet membership), and `:search` (search over scenario
  outcomes, titles, step titles/descriptions, captured page text, and captured
  page URLs).
  """
  def list_scenarios(run_id, opts \\ []) do
    repo = repo!(opts)

    {where, params} =
      [
        {"scenarios.run_id = $IDX", run_id},
        metadata_clause("value_stream", Keyword.get(opts, :value_stream)),
        metadata_clause("capability", Keyword.get(opts, :capability)),
        facet_clause("devices", Keyword.get(opts, :device)),
        facet_clause("languages", Keyword.get(opts, :language)),
        facet_clause("users", Keyword.get(opts, :user)),
        facet_clause("tags", Keyword.get(opts, :tag)),
        search_clause(Keyword.get(opts, :search))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {{clause, value}, index}, acc ->
        {String.replace(clause, "$IDX", "$#{index}"), acc ++ [value]}
      end)

    scenarios =
      repo
      |> query!(
        """
        SELECT
          scenarios.scenario_id,
          scenarios.title,
          scenarios.status,
          scenarios.scenario_order,
          scenarios.duration_ms,
          scenarios.documented_step_ms,
          scenarios.undocumented_ms,
          scenarios.devices,
          scenarios.themes,
          scenarios.languages,
          scenarios.users,
          scenarios.tags,
          scenarios.metadata->>'value_stream' AS value_stream,
          scenarios.metadata->>'capability' AS capability,
          scenarios.metadata->>'business_outcome' AS business_outcome,
          scenarios.metadata->>'status_reason' AS status_reason,
          (
            SELECT coalesce(
              jsonb_agg(
                jsonb_build_object(
                  'id', positioned.id,
                  'title', positioned.title,
                  'sequence', positioned.sequence,
                  'position', positioned.position,
                  'screenshot', positioned.screenshot
                )
                ORDER BY positioned.sequence, positioned.title
              ),
              '[]'::jsonb
            )
            FROM (
              SELECT
                steps.id,
                steps.title,
                steps.sequence,
                steps.screenshot,
                (row_number() OVER (ORDER BY steps.sequence, steps.title))::bigint AS position
              FROM #{@steps_table} steps
              WHERE steps.run_id = scenarios.run_id
                AND steps.scenario_id = scenarios.scenario_id
            ) positioned
          ) AS steps
        FROM #{@scenarios_table} scenarios
        WHERE #{Enum.join(where, " AND ")}
        GROUP BY scenarios.id
        ORDER BY scenarios.scenario_order NULLS LAST, scenarios.title
        """,
        params
      )
      |> rows_to_maps([
        :scenario_id,
        :title,
        :status,
        :scenario_order,
        :duration_ms,
        :documented_step_ms,
        :undocumented_ms,
        :devices,
        :themes,
        :languages,
        :users,
        :tags,
        :value_stream,
        :capability,
        :business_outcome,
        :status_reason,
        :steps
      ])

    changes = scenario_change_statuses(repo, run_id)
    change_details = scenario_change_details_by_scenario(repo, run_id)

    Enum.map(scenarios, fn scenario ->
      scenario_changes = Map.get(change_details, scenario.scenario_id, %{})

      scenario
      |> Map.put(:change_status, Map.get(changes, scenario.scenario_id))
      |> Map.put(:steps, stringified_steps(list_steps(run_id, scenario.scenario_id, repo: repo)))
      |> Map.put(:previous_title, Map.get(scenario_changes, :previous_title))
    end)
  end

  @doc """
  Recomputes retained scenario and run timing totals from step metadata.

  Historical evidence cannot recover elapsed scenario time that was never
  recorded, so this only fills documented step time and derives undocumented
  time when an elapsed duration already exists. It is idempotent and bounded
  to one run when `:run_id` is supplied.
  """
  def backfill_timing_summaries!(opts \\ []) do
    repo = repo!(opts)
    run_id = Keyword.get(opts, :run_id)
    dry_run? = Keyword.get(opts, :dry_run, false)

    where = if is_binary(run_id) and run_id != "", do: "WHERE scenarios.run_id = $1", else: ""
    params = if where == "", do: [], else: [run_id]

    counts =
      query!(
        repo,
        """
        SELECT count(*)::bigint, coalesce(sum(step_totals.documented_ms), 0)::bigint
        FROM #{@scenarios_table} scenarios
        LEFT JOIN (
          SELECT run_id, scenario_id,
                 coalesce(sum(
                   CASE WHEN metadata->>'duration_ms' ~ '^[0-9]+$'
                        THEN (metadata->>'duration_ms')::bigint ELSE 0 END
                 ), 0)::bigint AS documented_ms
          FROM #{@steps_table}
          GROUP BY run_id, scenario_id
        ) step_totals
          ON step_totals.run_id = scenarios.run_id
         AND step_totals.scenario_id = scenarios.scenario_id
        #{where}
        """,
        params
      ).rows
      |> List.first()

    unless dry_run? do
      query!(
        repo,
        """
        UPDATE #{@scenarios_table} scenarios
        SET documented_step_ms = step_totals.documented_ms,
            undocumented_ms = CASE
              WHEN scenarios.duration_ms IS NULL THEN NULL
              ELSE greatest(scenarios.duration_ms - step_totals.documented_ms, 0)
            END,
            updated_at = now()
        FROM (
          SELECT run_id, scenario_id,
                 coalesce(sum(
                   CASE WHEN metadata->>'duration_ms' ~ '^[0-9]+$'
                        THEN (metadata->>'duration_ms')::bigint ELSE 0 END
                 ), 0)::bigint AS documented_ms
          FROM #{@steps_table}
          GROUP BY run_id, scenario_id
        ) step_totals
        WHERE step_totals.run_id = scenarios.run_id
          AND step_totals.scenario_id = scenarios.scenario_id
          #{if where == "", do: "", else: "AND scenarios.run_id = $1"}
        """,
        params
      )
    end

    [scenarios, documented_ms] = counts || [0, 0]
    %{dry_run?: dry_run?, run_id: run_id, scenarios: scenarios, documented_step_ms: documented_ms}
  end

  defp scenario_change_statuses(repo, run_id) do
    repo
    |> query!(
      """
      WITH current_run AS (
        SELECT id, coalesce(finalized_at, generated_at, inserted_at) AS run_at
        FROM #{@runs_table}
        WHERE id = $1
      ),
      previous_run AS (
        -- Compare against the most recent earlier run that finished without
        -- failures. A run that aborted mid-scenario only captured part of the
        -- suite, so using it as the baseline would report every step it never
        -- reached as brand new. Falls back to the most recent earlier run when
        -- no clean one exists.
        SELECT runs.id
        FROM #{@runs_table} runs, current_run
        WHERE runs.id <> current_run.id
          AND coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) < current_run.run_at
        ORDER BY
          (NOT EXISTS (
            SELECT 1
            FROM #{@scenarios_table} failed_scenarios
            WHERE failed_scenarios.run_id = runs.id
              AND failed_scenarios.status = 'failure'
          )) DESC,
          coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) DESC
        LIMIT 1
      ),
      fingerprints AS (
        SELECT
          scenarios.run_id,
          scenarios.scenario_id,
          coalesce(scenarios.metadata->'legacy_ids', '[]'::jsonb) AS legacy_ids,
          coalesce(
            nullif(scenarios.metadata->>'source_checksum', ''),
            nullif(scenarios.metadata->>'source_sha256', ''),
            nullif(scenarios.metadata->>'checksum', ''),
            (
              SELECT string_agg(DISTINCT source.value, ',' ORDER BY source.value)
              FROM #{@steps_table} steps
              CROSS JOIN LATERAL (
                VALUES
                  (nullif(steps.metadata->>'source_checksum', '')),
                  (nullif(steps.metadata->>'source_sha256', '')),
                  (nullif(steps.metadata->>'checksum', ''))
              ) AS source(value)
              WHERE steps.run_id = scenarios.run_id
                AND steps.scenario_id = scenarios.scenario_id
                AND source.value IS NOT NULL
            )
          ) AS source_fingerprint,
          (
            SELECT md5(
              string_agg(
                coalesce(steps.title, '') || E'\\x1f' || coalesce(steps.description, ''),
                E'\\x1e' ORDER BY steps.sequence, steps.title
              )
            )
            FROM #{@steps_table} steps
            WHERE steps.run_id = scenarios.run_id
              AND steps.scenario_id = scenarios.scenario_id
          ) AS contract_fingerprint
        FROM #{@scenarios_table} scenarios
        WHERE scenarios.run_id = $1
           OR scenarios.run_id = (SELECT id FROM previous_run)
      )
      SELECT
        current.scenario_id,
        CASE
          WHEN (SELECT id FROM previous_run) IS NULL THEN NULL
          WHEN previous.scenario_id IS NULL THEN 'new'
          WHEN previous.source_fingerprint IS NOT NULL
            AND current.source_fingerprint IS NOT NULL
            AND previous.source_fingerprint <> current.source_fingerprint THEN 'delta'
          WHEN (previous.source_fingerprint IS NULL OR current.source_fingerprint IS NULL)
            AND previous.contract_fingerprint IS NOT NULL
            AND current.contract_fingerprint IS NOT NULL
            AND previous.contract_fingerprint <> current.contract_fingerprint THEN 'delta'
          ELSE NULL
        END AS change_status
      FROM fingerprints current
      LEFT JOIN LATERAL (
        SELECT previous.*
        FROM fingerprints previous
        WHERE previous.run_id = (SELECT id FROM previous_run)
          AND (
            previous.scenario_id = current.scenario_id
            OR current.legacy_ids ? previous.scenario_id
          )
        ORDER BY (previous.scenario_id = current.scenario_id) DESC
        LIMIT 1
      ) previous ON true
      WHERE current.run_id = $1
      """,
      [run_id]
    )
    |> Map.fetch!(:rows)
    |> Map.new(fn [scenario_id, change_status] -> {scenario_id, change_status} end)
  end

  defp scenario_change_details_by_scenario(repo, run_id) do
    repo
    |> query!(
      """
      WITH current_run AS (
        SELECT id, coalesce(finalized_at, generated_at, inserted_at) AS run_at
        FROM #{@runs_table}
        WHERE id = $1
      ),
      previous_run AS (
        -- See the baseline note above: a failed, partial run is a misleading
        -- comparison point.
        SELECT runs.id
        FROM #{@runs_table} runs, current_run
        WHERE runs.id <> current_run.id
          AND coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) < current_run.run_at
        ORDER BY
          (NOT EXISTS (
            SELECT 1
            FROM #{@scenarios_table} failed_scenarios
            WHERE failed_scenarios.run_id = runs.id
              AND failed_scenarios.status = 'failure'
          )) DESC,
          coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) DESC
        LIMIT 1
      )
      SELECT
        current.scenario_id,
        (SELECT id FROM previous_run) AS previous_run_id,
        previous.scenario_id AS previous_scenario_id,
        previous.title AS previous_title,
        current.metadata AS current_metadata,
        previous.metadata AS previous_metadata
      FROM #{@scenarios_table} current
      LEFT JOIN LATERAL (
        SELECT previous.*
        FROM #{@scenarios_table} previous
        WHERE previous.run_id = (SELECT id FROM previous_run)
          AND (
            previous.scenario_id = current.scenario_id
            OR coalesce(current.metadata->'legacy_ids', '[]'::jsonb) ? previous.scenario_id
          )
        ORDER BY (previous.scenario_id = current.scenario_id) DESC
        LIMIT 1
      ) previous ON true
      WHERE current.run_id = $1
      """,
      [run_id]
    )
    |> Map.fetch!(:rows)
    |> Map.new(fn [
                    scenario_id,
                    previous_run_id,
                    previous_scenario_id,
                    previous_title,
                    current_metadata,
                    previous_metadata
                  ] ->
      {scenario_id,
       %{
         previous_run_id: previous_run_id,
         previous_scenario_id: previous_scenario_id,
         previous_title: previous_title,
         source_file: map_value(current_metadata || %{}, "source_file"),
         current_source_snapshot_path: map_value(current_metadata || %{}, "source_snapshot_path"),
         previous_source_snapshot_path:
           map_value(previous_metadata || %{}, "source_snapshot_path")
       }}
    end)
  end

  defp run_change_summary(repo, run_id) do
    changes = scenario_change_statuses(repo, run_id)

    new_scenario_ids = change_scenario_ids(changes, "new")
    delta_scenario_ids = change_scenario_ids(changes, "delta")
    step_changes = step_change_summary(repo, run_id)
    schema_history = schema_history(run_id, repo: repo)

    %{
      new_scenario_count: length(new_scenario_ids),
      delta_scenario_count: length(delta_scenario_ids),
      new_step_count: step_changes.new_count,
      delta_step_count: step_changes.delta_count,
      schema_domain_change_count: length(schema_history.changes),
      changed_schema_domains: Enum.map(schema_history.changes, & &1.label),
      # Ids as well as labels, so the run index can link each domain straight to
      # its comparison instead of printing a bare list.
      changed_schema_domain_refs:
        Enum.map(schema_history.changes, &%{id: &1.domain_id, label: &1.label}),
      changed_scenarios: changed_scenarios(repo, run_id, changes),
      recovered: run_recovered?(repo, run_id)
    }
  end

  defp changed_scenarios(repo, run_id, changes) do
    repo
    |> query!(
      """
      SELECT scenario_id, title
      FROM #{@scenarios_table}
      WHERE run_id = $1
      ORDER BY scenario_order NULLS LAST, title
      """,
      [run_id]
    )
    |> Map.fetch!(:rows)
    |> Enum.flat_map(fn [scenario_id, title] ->
      case Map.get(changes, scenario_id) do
        status when status in ["new", "delta"] ->
          [%{scenario_id: scenario_id, title: title, status: status}]

        _ ->
          []
      end
    end)
  end

  @doc "Returns domain-level schema changes against the previous trustworthy run."
  def schema_history(run_id, opts \\ []) do
    repo = repo!(opts)
    current = get_run!(run_id, repo: repo)
    previous_run_id = comparison_run_id(repo, run_id)

    previous_artifacts =
      case previous_run_id do
        nil -> []
        id -> get_run!(id, repo: repo) |> map_value(:artifacts) |> List.wrap()
      end

    %{
      previous_run_id: previous_run_id,
      overview:
        current
        |> map_value(:artifacts)
        |> AcceptanceHarness.SchemaHistory.overview_artifact(),
      changes:
        AcceptanceHarness.SchemaHistory.diff(
          current |> map_value(:artifacts) |> List.wrap(),
          previous_artifacts
        )
    }
  end

  defp comparison_run_id(repo, run_id) do
    repo
    |> query!(
      """
      WITH current_run AS (
        SELECT id, coalesce(finalized_at, generated_at, inserted_at) AS run_at
        FROM #{@runs_table}
        WHERE id = $1
      )
      SELECT runs.id
      FROM #{@runs_table} runs, current_run
      WHERE runs.id <> current_run.id
        AND coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) < current_run.run_at
      ORDER BY
        (NOT EXISTS (
          SELECT 1
          FROM #{@scenarios_table} failed_scenarios
          WHERE failed_scenarios.run_id = runs.id
            AND failed_scenarios.status = 'failure'
        )) DESC,
        coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) DESC
      LIMIT 1
      """,
      [run_id]
    )
    |> Map.fetch!(:rows)
    |> case do
      [[id]] -> id
      [] -> nil
    end
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  # A run "recovered" when it passed and the run immediately before it (in
  # chronological order, whatever its content) had failures. Recovery is a
  # health event, separate from the content-change colours, so the UI shows it
  # as a small pill rather than colouring the whole card.
  defp run_recovered?(repo, run_id) do
    repo
    |> query!(
      """
      WITH current_run AS (
        SELECT id, coalesce(finalized_at, generated_at, inserted_at) AS run_at
        FROM #{@runs_table}
        WHERE id = $1
      ),
      previous_run AS (
        SELECT runs.id
        FROM #{@runs_table} runs, current_run
        WHERE runs.id <> current_run.id
          AND coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) < current_run.run_at
        ORDER BY coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) DESC
        LIMIT 1
      )
      SELECT
        (SELECT count(*) FROM #{@scenarios_table}
           WHERE run_id = $1 AND status = 'failure') = 0
        AND (SELECT id FROM previous_run) IS NOT NULL
        AND (SELECT count(*) FROM #{@scenarios_table}
           WHERE run_id = (SELECT id FROM previous_run) AND status = 'failure') > 0
      """,
      [run_id]
    )
    |> Map.fetch!(:rows)
    |> case do
      [[recovered]] -> recovered == true
      _no_rows -> false
    end
  end

  defp step_change_summary(repo, run_id) do
    repo
    |> query!(
      """
      WITH current_run AS (
        SELECT id, coalesce(finalized_at, generated_at, inserted_at) AS run_at
        FROM #{@runs_table}
        WHERE id = $1
      ),
      previous_run AS (
        -- Compare against the most recent earlier run that finished without
        -- failures. A run that aborted mid-scenario only captured part of the
        -- suite, so using it as the baseline would report every step it never
        -- reached as brand new. Falls back to the most recent earlier run when
        -- no clean one exists.
        SELECT runs.id
        FROM #{@runs_table} runs, current_run
        WHERE runs.id <> current_run.id
          AND coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) < current_run.run_at
        ORDER BY
          (NOT EXISTS (
            SELECT 1
            FROM #{@scenarios_table} failed_scenarios
            WHERE failed_scenarios.run_id = runs.id
              AND failed_scenarios.status = 'failure'
          )) DESC,
          coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) DESC
        LIMIT 1
      ),
      scenario_pairs AS (
        SELECT
          current.scenario_id AS current_scenario_id,
          previous.scenario_id AS previous_scenario_id
        FROM #{@scenarios_table} current
        LEFT JOIN LATERAL (
          SELECT candidate.scenario_id
          FROM #{@scenarios_table} candidate
          WHERE candidate.run_id = (SELECT id FROM previous_run)
            AND (
              candidate.scenario_id = current.scenario_id
              OR coalesce(current.metadata->'legacy_ids', '[]'::jsonb) ? candidate.scenario_id
            )
          ORDER BY (candidate.scenario_id = current.scenario_id) DESC
          LIMIT 1
        ) previous ON true
        WHERE current.run_id = $1
      ),
      current_steps AS (
        SELECT
          steps.scenario_id,
          steps.title,
          (row_number() OVER (
            PARTITION BY steps.scenario_id ORDER BY steps.sequence, steps.title
          ))::bigint AS position,
          count(*) OVER (PARTITION BY steps.scenario_id)::bigint AS step_count,
          coalesce(
            nullif(steps.metadata->>'source_checksum', ''),
            nullif(steps.metadata->>'source_sha256', ''),
            nullif(steps.metadata->>'checksum', ''),
            md5(coalesce(steps.title, '') || E'\\x1f' || coalesce(steps.description, ''))
          ) AS source_fingerprint
        FROM #{@steps_table} steps
        WHERE steps.run_id = $1
      ),
      previous_steps AS (
        SELECT
          steps.scenario_id,
          steps.title,
          (row_number() OVER (
            PARTITION BY steps.scenario_id ORDER BY steps.sequence, steps.title
          ))::bigint AS position,
          count(*) OVER (PARTITION BY steps.scenario_id)::bigint AS step_count,
          coalesce(
            nullif(steps.metadata->>'source_checksum', ''),
            nullif(steps.metadata->>'source_sha256', ''),
            nullif(steps.metadata->>'checksum', ''),
            md5(coalesce(steps.title, '') || E'\\x1f' || coalesce(steps.description, ''))
          ) AS source_fingerprint
        FROM #{@steps_table} steps
        WHERE steps.run_id = (SELECT id FROM previous_run)
      ),
      changes AS (
        SELECT
          CASE
            WHEN (SELECT id FROM previous_run) IS NULL THEN NULL
            WHEN scenario_pairs.previous_scenario_id IS NULL THEN 'new'
            WHEN previous.position IS NULL THEN 'new'
            WHEN current.source_fingerprint = previous.source_fingerprint THEN NULL
            WHEN current.title = previous.title THEN 'delta'
            WHEN current.step_count > previous.step_count THEN 'new'
            ELSE 'delta'
          END AS change_status
        FROM current_steps current
        JOIN scenario_pairs ON scenario_pairs.current_scenario_id = current.scenario_id
        LEFT JOIN LATERAL (
          SELECT candidate.*
          FROM previous_steps candidate
          WHERE candidate.scenario_id = scenario_pairs.previous_scenario_id
            AND (
              candidate.source_fingerprint = current.source_fingerprint
              OR candidate.title = current.title
              OR candidate.position = current.position
            )
          ORDER BY
            (candidate.source_fingerprint = current.source_fingerprint) DESC,
            (candidate.title = current.title) DESC,
            (candidate.position = current.position) DESC
          LIMIT 1
        ) previous ON true
      )
      SELECT
        count(*) FILTER (WHERE change_status = 'new')::int AS new_count,
        count(*) FILTER (WHERE change_status = 'delta')::int AS delta_count
      FROM changes
      """,
      [run_id]
    )
    |> Map.fetch!(:rows)
    |> case do
      [[new_count, delta_count]] -> %{new_count: new_count || 0, delta_count: delta_count || 0}
    end
  end

  defp change_scenario_ids(changes, status) do
    changes
    |> Enum.filter(fn {_scenario_id, change_status} -> change_status == status end)
    |> Enum.map(fn {scenario_id, _change_status} -> scenario_id end)
  end

  # jsonb-array facet membership, e.g. devices ? 'Mobile' (raw SQL, so the
  # jsonb ? operator needs no escaping).
  defp facet_clause(_column, nil), do: nil
  defp facet_clause(column, value), do: {"scenarios.#{column} ? $IDX", value}

  defp metadata_clause(_key, nil), do: nil
  defp metadata_clause(key, value), do: {"scenarios.metadata->>'#{key}' = $IDX", value}

  defp search_clause(nil), do: nil
  defp search_clause(""), do: nil

  defp search_clause(query) do
    {"""
     (scenarios.title ILIKE '%' || $IDX || '%'
       OR scenarios.metadata->>'business_outcome' ILIKE '%' || $IDX || '%'
       OR EXISTS (
       SELECT 1 FROM #{@steps_table} steps
       WHERE steps.run_id = scenarios.run_id
         AND steps.scenario_id = scenarios.scenario_id
         AND (
           #{@steps_fts_vector} @@ websearch_to_tsquery('simple', $IDX)
           OR steps.metadata->>'current_url' ILIKE '%' || $IDX || '%'
         )
     ))
     """, query}
  end

  def get_scenario!(run_id, scenario_id, opts \\ []) do
    repo = repo!(opts)

    result =
      query!(
        repo,
        "SELECT * FROM #{@scenarios_table} WHERE run_id = $1 AND scenario_id = $2",
        [run_id, scenario_id]
      )

    case result.rows do
      [row] -> row_to_map(result.columns, row)
      [] -> raise ArgumentError, "acceptance harness scenario not found: #{run_id}/#{scenario_id}"
    end
  end

  def scenario_change_status(run_id, scenario_id, opts \\ []) do
    repo = repo!(opts)

    repo
    |> query!(
      """
      WITH current_run AS (
        SELECT id, coalesce(finalized_at, generated_at, inserted_at) AS run_at
        FROM #{@runs_table}
        WHERE id = $1
      ),
      previous_run AS (
        -- Compare against the most recent earlier run that finished without
        -- failures. A run that aborted mid-scenario only captured part of the
        -- suite, so using it as the baseline would report every step it never
        -- reached as brand new. Falls back to the most recent earlier run when
        -- no clean one exists.
        SELECT runs.id
        FROM #{@runs_table} runs, current_run
        WHERE runs.id <> current_run.id
          AND coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) < current_run.run_at
        ORDER BY
          (NOT EXISTS (
            SELECT 1
            FROM #{@scenarios_table} failed_scenarios
            WHERE failed_scenarios.run_id = runs.id
              AND failed_scenarios.status = 'failure'
          )) DESC,
          coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) DESC
        LIMIT 1
      ),
      fingerprints AS (
        SELECT
          scenarios.run_id,
          scenarios.scenario_id,
          coalesce(scenarios.metadata->'legacy_ids', '[]'::jsonb) AS legacy_ids,
          coalesce(
            nullif(scenarios.metadata->>'source_checksum', ''),
            nullif(scenarios.metadata->>'source_sha256', ''),
            nullif(scenarios.metadata->>'checksum', ''),
            (
              SELECT string_agg(DISTINCT source.value, ',' ORDER BY source.value)
              FROM #{@steps_table} steps
              CROSS JOIN LATERAL (
                VALUES
                  (nullif(steps.metadata->>'source_checksum', '')),
                  (nullif(steps.metadata->>'source_sha256', '')),
                  (nullif(steps.metadata->>'checksum', ''))
              ) AS source(value)
              WHERE steps.run_id = scenarios.run_id
                AND steps.scenario_id = scenarios.scenario_id
                AND source.value IS NOT NULL
            )
          ) AS source_fingerprint,
          (
            SELECT md5(
              string_agg(
                coalesce(steps.title, '') || E'\\x1f' || coalesce(steps.description, ''),
                E'\\x1e' ORDER BY steps.sequence, steps.title
              )
            )
            FROM #{@steps_table} steps
            WHERE steps.run_id = scenarios.run_id
              AND steps.scenario_id = scenarios.scenario_id
          ) AS contract_fingerprint
        FROM #{@scenarios_table} scenarios
        WHERE scenarios.run_id = $1
           OR scenarios.run_id = (SELECT id FROM previous_run)
      )
      SELECT
        CASE
          WHEN (SELECT id FROM previous_run) IS NULL THEN NULL
          WHEN previous.scenario_id IS NULL THEN 'new'
          WHEN previous.source_fingerprint IS NOT NULL
            AND current.source_fingerprint IS NOT NULL
            AND previous.source_fingerprint <> current.source_fingerprint THEN 'delta'
          WHEN (previous.source_fingerprint IS NULL OR current.source_fingerprint IS NULL)
            AND previous.contract_fingerprint IS NOT NULL
            AND current.contract_fingerprint IS NOT NULL
            AND previous.contract_fingerprint <> current.contract_fingerprint THEN 'delta'
          ELSE NULL
        END AS change_status
      FROM fingerprints current
      LEFT JOIN LATERAL (
        SELECT previous.*
        FROM fingerprints previous
        WHERE previous.run_id = (SELECT id FROM previous_run)
          AND (
            previous.scenario_id = current.scenario_id
            OR current.legacy_ids ? previous.scenario_id
          )
        ORDER BY (previous.scenario_id = current.scenario_id) DESC
        LIMIT 1
      ) previous ON true
      WHERE current.run_id = $1
        AND current.scenario_id = $2
      """,
      [run_id, scenario_id]
    )
    |> Map.fetch!(:rows)
    |> case do
      [[status]] -> status
      _ -> nil
    end
  end

  def scenario_change_details(run_id, scenario_id, opts \\ []) do
    opts
    |> repo!()
    |> scenario_change_details_by_scenario(run_id)
    |> Map.get(scenario_id)
  end

  def scenario_source_diff(run_id, scenario_id, opts \\ []) do
    repo = repo!(opts)
    details = scenario_change_details(run_id, scenario_id, repo: repo)

    with %{previous_run_id: previous_run_id} <- details,
         previous_run_id when is_binary(previous_run_id) <- previous_run_id,
         current_path when is_binary(current_path) <- details.current_source_snapshot_path,
         previous_path when is_binary(previous_path) <- details.previous_source_snapshot_path,
         {:file, current_file} <- artifact_location(run_id, current_path, repo: repo),
         {:file, previous_file} <- artifact_location(previous_run_id, previous_path, repo: repo),
         {:ok, current_source} <- File.read(current_file),
         {:ok, previous_source} <- File.read(previous_file) do
      details
      |> Map.take([:source_file])
      |> Map.merge(AcceptanceHarness.SourceDiff.compare(previous_source, current_source))
    else
      _ -> nil
    end
  end

  def list_steps(run_id, scenario_id, opts \\ []) do
    repo = repo!(opts)

    repo
    |> query!(
      """
      WITH current_run AS (
        SELECT id, coalesce(finalized_at, generated_at, inserted_at) AS run_at
        FROM #{@runs_table}
        WHERE id = $1
      ),
      previous_run AS (
        -- Compare against the most recent earlier run that finished without
        -- failures. A run that aborted mid-scenario only captured part of the
        -- suite, so using it as the baseline would report every step it never
        -- reached as brand new. Falls back to the most recent earlier run when
        -- no clean one exists.
        SELECT runs.id
        FROM #{@runs_table} runs, current_run
        WHERE runs.id <> current_run.id
          AND coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) < current_run.run_at
        ORDER BY
          (NOT EXISTS (
            SELECT 1
            FROM #{@scenarios_table} failed_scenarios
            WHERE failed_scenarios.run_id = runs.id
              AND failed_scenarios.status = 'failure'
          )) DESC,
          coalesce(runs.finalized_at, runs.generated_at, runs.inserted_at) DESC
        LIMIT 1
      ),
      current_scenario AS (
        SELECT coalesce(metadata->'legacy_ids', '[]'::jsonb) AS legacy_ids
        FROM #{@scenarios_table}
        WHERE run_id = $1
          AND scenario_id = $2
        LIMIT 1
      ),
      previous_scenario AS (
        SELECT previous.scenario_id
        FROM #{@scenarios_table} previous, current_scenario current
        WHERE previous.run_id = (SELECT id FROM previous_run)
          AND (
            previous.scenario_id = $2
            OR current.legacy_ids ? previous.scenario_id
          )
        ORDER BY (previous.scenario_id = $2) DESC
        LIMIT 1
      ),
      current_steps AS (
        SELECT
          steps.id,
          steps.scenario_id,
          steps.title,
          steps.description,
          steps.sequence,
          steps.screenshot,
          steps.surface,
          steps.artifacts,
          steps.metadata,
          steps.page_html,
          (row_number() OVER (ORDER BY steps.sequence, steps.title))::bigint AS position,
          count(*) OVER ()::bigint AS step_count,
          coalesce(
            nullif(steps.metadata->>'source_checksum', ''),
            nullif(steps.metadata->>'source_sha256', ''),
            nullif(steps.metadata->>'checksum', ''),
            md5(coalesce(steps.title, '') || E'\\x1f' || coalesce(steps.description, ''))
          ) AS source_fingerprint
        FROM #{@steps_table} steps
        WHERE steps.run_id = $1
          AND steps.scenario_id = $2
      ),
      previous_steps AS (
        SELECT
          steps.title,
          steps.description,
          (row_number() OVER (ORDER BY steps.sequence, steps.title))::bigint AS position,
          count(*) OVER ()::bigint AS step_count,
          coalesce(
            nullif(steps.metadata->>'source_checksum', ''),
            nullif(steps.metadata->>'source_sha256', ''),
            nullif(steps.metadata->>'checksum', ''),
            md5(coalesce(steps.title, '') || E'\\x1f' || coalesce(steps.description, ''))
          ) AS source_fingerprint
        FROM #{@steps_table} steps
        JOIN previous_scenario ON steps.scenario_id = previous_scenario.scenario_id
        WHERE steps.run_id = (SELECT id FROM previous_run)
      )
      SELECT
        current_steps.id,
        current_steps.scenario_id,
        current_steps.title,
        current_steps.description,
        current_steps.sequence,
        current_steps.screenshot,
        current_steps.surface,
        current_steps.artifacts,
        current_steps.metadata,
        current_steps.page_html,
        current_steps.position,
        previous_steps.title AS previous_title,
        previous_steps.description AS previous_description,
        previous_steps.position AS previous_position,
        CASE
          WHEN (SELECT id FROM previous_run) IS NULL THEN NULL
          WHEN previous_scenario.scenario_id IS NULL THEN 'new'
          WHEN previous_steps.position IS NULL THEN 'new'
          WHEN current_steps.source_fingerprint = previous_steps.source_fingerprint THEN NULL
          WHEN current_steps.title = previous_steps.title THEN 'delta'
          WHEN current_steps.step_count > previous_steps.step_count THEN 'new'
          ELSE 'delta'
        END AS change_status
      FROM current_steps
      LEFT JOIN LATERAL (
        SELECT previous_steps.*
        FROM previous_steps
        WHERE previous_steps.source_fingerprint = current_steps.source_fingerprint
           OR previous_steps.title = current_steps.title
           OR previous_steps.position = current_steps.position
        ORDER BY
          (previous_steps.source_fingerprint = current_steps.source_fingerprint) DESC,
          (previous_steps.title = current_steps.title) DESC,
          (previous_steps.position = current_steps.position) DESC
        LIMIT 1
      ) previous_steps ON true
      LEFT JOIN previous_scenario ON true
      ORDER BY current_steps.position
      """,
      [run_id, scenario_id]
    )
    |> rows_to_maps([
      :id,
      :scenario_id,
      :title,
      :description,
      :sequence,
      :screenshot,
      :surface,
      :artifacts,
      :metadata,
      :page_html,
      :position,
      :previous_title,
      :previous_description,
      :previous_position,
      :change_status
    ])
  end

  defp stringified_steps(steps) when is_list(steps) do
    Enum.map(steps, &stringify_step_keys/1)
  end

  defp stringify_step_keys(step) when is_map(step) do
    Map.new(step, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_step_keys(step), do: step

  def screenshot_location(run_id, filename, opts \\ []) do
    repo = repo!(opts)
    variant = Keyword.get(opts, :variant, :original)

    result =
      query!(
        repo,
        "SELECT source_dir, source_url FROM #{@runs_table} WHERE id = $1",
        [run_id]
      )

    case screenshot_file_location(result.rows, filename, variant) do
      {:file, _path} = local -> local
      :error -> screenshot_url_location(result.rows, filename)
    end
  end

  def screenshot_path(run_id, filename, opts \\ []) do
    case screenshot_location(run_id, filename, opts) do
      {:file, path} -> {:ok, path}
      _ -> :error
    end
  end

  def artifact_location(run_id, relative_path, opts \\ []) do
    repo = repo!(opts)

    with {:ok, safe_path} <- safe_artifact_path(relative_path) do
      result =
        query!(
          repo,
          "SELECT source_dir, source_url FROM #{@runs_table} WHERE id = $1",
          [run_id]
        )

      case artifact_file_location(result.rows, safe_path) do
        {:file, _path} = local -> local
        :error -> artifact_url_location(result.rows, safe_path)
      end
    else
      :error -> :error
    end
  end

  defp safe_artifact_path(relative_path) when is_binary(relative_path) do
    parts = Path.split(relative_path)

    if Path.type(relative_path) == :relative and
         parts != [] and
         Enum.all?(parts, &(&1 not in ["", ".", ".."])) do
      {:ok, Path.join(parts)}
    else
      :error
    end
  end

  defp safe_artifact_path(_relative_path), do: :error

  defp artifact_file_location([[source_dir, _source_url]], relative_path)
       when is_binary(source_dir) do
    root = Path.expand(source_dir)
    path = Path.expand(Path.join(root, relative_path))

    if String.starts_with?(path, root <> "/") and File.regular?(path),
      do: {:file, path},
      else: :error
  end

  defp artifact_file_location(_rows, _relative_path), do: :error

  defp artifact_url_location([[_source_dir, source_url]], relative_path)
       when is_binary(source_url) and source_url != "" do
    encoded_path =
      relative_path
      |> Path.split()
      |> Enum.map_join("/", &URI.encode/1)

    {:url, String.trim_trailing(source_url, "/") <> "/" <> encoded_path}
  end

  defp artifact_url_location(_rows, _relative_path), do: :error

  defp screenshot_file_location([[source_dir, _source_url]], filename, variant)
       when is_binary(source_dir) do
    path = Path.expand(Path.join([source_dir, "screenshots", Path.basename(filename)]))

    thumbnail =
      Path.expand(
        Path.join([source_dir, "thumbnails", Path.rootname(Path.basename(filename)) <> ".webp"])
      )

    [primary, fallback] =
      case variant do
        :thumbnail -> [thumbnail, path]
        _ -> [path, thumbnail]
      end

    Enum.find_value([primary, fallback], :error, fn candidate ->
      if File.regular?(candidate), do: {:file, candidate}
    end)
  end

  defp screenshot_file_location(_rows, _filename, _variant), do: :error

  defp screenshot_url_location([[_source_dir, source_url]], filename)
       when is_binary(source_url) and source_url != "" do
    {:url,
     source_url
     |> String.trim_trailing("/")
     |> Kernel.<>("/screenshots/#{URI.encode(filename)}")}
  end

  defp screenshot_url_location(_rows, _filename), do: :error

  defp upsert_scenario!(repo, run_id, scenario) do
    query!(
      repo,
      """
      INSERT INTO #{@scenarios_table}
        (
          run_id, scenario_id, title, status, scenario_order, duration_ms,
          documented_step_ms, undocumented_ms, devices, themes, languages, users,
          tags, failure, metadata, updated_at
        )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10::jsonb, $11::jsonb, $12::jsonb, $13::jsonb, $14::jsonb, $15::jsonb, now())
      ON CONFLICT (run_id, scenario_id) DO UPDATE SET
        title = EXCLUDED.title,
        status = EXCLUDED.status,
        scenario_order = EXCLUDED.scenario_order,
        duration_ms = EXCLUDED.duration_ms,
        documented_step_ms = EXCLUDED.documented_step_ms,
        undocumented_ms = EXCLUDED.undocumented_ms,
        devices = EXCLUDED.devices,
        themes = EXCLUDED.themes,
        languages = EXCLUDED.languages,
        users = EXCLUDED.users,
        tags = EXCLUDED.tags,
        failure = EXCLUDED.failure,
        metadata = EXCLUDED.metadata,
        updated_at = now()
      """,
      [
        run_id,
        Map.fetch!(scenario, "id"),
        Map.get(scenario, "title", "Scenario"),
        Map.get(scenario, "status", "unknown"),
        Map.get(scenario, "order"),
        Map.get(scenario, "duration_ms"),
        Map.get(scenario, "documented_step_ms"),
        Map.get(scenario, "undocumented_ms"),
        json_param(Map.get(scenario, "devices", [])),
        json_param(Map.get(scenario, "themes", [])),
        json_param(Map.get(scenario, "languages", [])),
        json_param(Map.get(scenario, "users", [])),
        json_param(Map.get(scenario, "tags", [])),
        json_param(Map.get(scenario, "failure")),
        json_param(Map.get(scenario, "metadata", %{}))
      ]
    )
  end

  defp upsert_step!(repo, run_id, step) do
    page = Map.get(step, "page") || %{}
    metadata = Map.get(step, "metadata", %{})

    query!(
      repo,
      """
      INSERT INTO #{@steps_table}
        (id, run_id, scenario_id, title, description, sequence, screenshot, surface,
         artifacts, metadata, page_text, page_html, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8::jsonb, $9::jsonb, $10::jsonb,
              $11, $12, now())
      ON CONFLICT (run_id, id) DO UPDATE SET
        title = EXCLUDED.title,
        description = EXCLUDED.description,
        sequence = EXCLUDED.sequence,
        screenshot = EXCLUDED.screenshot,
        surface = EXCLUDED.surface,
        artifacts = EXCLUDED.artifacts,
        metadata = EXCLUDED.metadata,
        page_text = EXCLUDED.page_text,
        page_html = EXCLUDED.page_html,
        updated_at = now()
      """,
      [
        Map.fetch!(step, "id"),
        run_id,
        Map.get(step, "scenario_id"),
        Map.get(step, "title", "Step"),
        Map.get(step, "description", ""),
        Map.get(step, "sequence"),
        json_param(Map.get(step, "screenshot") || %{}),
        json_param(Map.get(step, "surface", %{"kind" => "browser"})),
        json_param(Map.get(step, "artifacts", [])),
        json_param(metadata),
        surface_search_text(Map.get(step, "surface", %{})) || Map.get(page, "text") ||
          Map.get(metadata, "page_text"),
        Map.get(page, "html") || Map.get(metadata, "page_html")
      ]
    )
  end

  defp surface_search_text(%{"text" => text}) when is_binary(text), do: text

  defp surface_search_text(%{"kind" => "message_timeline", "frames" => frames})
       when is_list(frames) do
    frames
    |> Enum.map(&Map.get(&1, "text"))
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp surface_search_text(_surface), do: nil

  defp repo!(opts) when is_atom(opts) do
    opts
  end

  defp repo!(opts) do
    Keyword.get(opts, :repo) || AcceptanceHarness.Config.repo() ||
      raise ArgumentError,
            "configure :acceptance_harness, :harness, repo: MyApp.Repo or pass repo: repo"
  end

  defp query!(repo, sql, params \\ []) do
    apply(Ecto.Adapters.SQL, :query!, [repo, sql, params])
  end

  # Postgrex encodes Elixir maps/lists natively as jsonb. Encoding to a JSON
  # string here would store a jsonb *string* (double encoding), which breaks
  # jsonb operators like `?` — install!/1 repairs rows written that way.
  defp json_param(value), do: value

  defp timestamp(nil), do: nil
  defp timestamp(""), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp rows_to_maps(result, keys) do
    Enum.map(result.rows, &row_to_map(keys, &1))
  end

  defp row_to_map(keys, row) do
    keys
    |> Enum.zip(row)
    |> Map.new(fn {key, value} -> {key, decode_json_column(key, value)} end)
  end

  defp decode_json_column(key, value) when is_binary(value) do
    if json_column?(key) do
      case Jason.decode(value) do
        {:ok, decoded} -> decoded
        {:error, _error} -> value
      end
    else
      value
    end
  end

  defp decode_json_column(_key, value), do: value

  defp json_column?(key) when is_atom(key), do: MapSet.member?(@json_columns, key)

  defp json_column?(key) when is_binary(key) do
    key
    |> String.to_existing_atom()
    |> json_column?()
  rescue
    ArgumentError -> false
  end

  defp json_column?(_key), do: false

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end

  defp present_string(_value), do: nil
end
