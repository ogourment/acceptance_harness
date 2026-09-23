defmodule AcceptanceHarness.ReviewStore do
  @moduledoc """
  Durable review history, independent of disposable evidence runs. Import only
  authenticated, authorized receipts from the same project. Retain receipt IDs
  for idempotent synchronization; no session identifiers are persisted.
  """
  alias AcceptanceHarness.ReviewReceipt

  def install!(opts \\ []) do
    query!(
      opts,
      """
      CREATE TABLE IF NOT EXISTS acceptance_harness_review_receipts (
        project text NOT NULL,
        id text NOT NULL,
        target text NOT NULL,
        revision text NOT NULL,
        receipt jsonb NOT NULL,
        inserted_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (project, id)
      )
      """,
      []
    )

    query!(
      opts,
      "CREATE INDEX IF NOT EXISTS acceptance_harness_review_target ON acceptance_harness_review_receipts (project, target, revision)",
      []
    )

    :ok
  end

  def import!(project, receipts, opts \\ []) when is_list(receipts) do
    validated =
      Enum.map(receipts, fn receipt ->
        case ReviewReceipt.validate(receipt) do
          {:ok, %{"project" => ^project} = safe} -> safe
          _ -> raise ArgumentError, "invalid or cross-project review receipt"
        end
      end)

    repo = Keyword.get(opts, :repo, AcceptanceHarness.Config.repo())

    repo.transaction(fn ->
      Enum.reduce(validated, 0, fn receipt, count ->
        result =
          query!(
            opts,
            """
            INSERT INTO acceptance_harness_review_receipts (project, id, target, revision, receipt)
            VALUES ($1, $2, $3, $4, $5) ON CONFLICT (project, id) DO NOTHING
            """,
            [project, receipt["id"], receipt["target"], receipt["revision"], receipt]
          )

        count + result.num_rows
      end)
    end)
  end

  def export(project, opts \\ []) do
    query!(
      opts,
      "SELECT receipt FROM acceptance_harness_review_receipts WHERE project=$1 ORDER BY id",
      [project]
    ).rows
    |> Enum.map(&hd/1)
  end

  def summary(project, target, revision, opts \\ []) do
    rows =
      query!(
        opts,
        "SELECT receipt FROM acceptance_harness_review_receipts WHERE project=$1 AND target=$2",
        [project, target]
      ).rows

    ReviewReceipt.summarize(Enum.map(rows, &hd/1), project, target, revision)
  end

  defp query!(opts, sql, params),
    do:
      Ecto.Adapters.SQL.query!(
        Keyword.get(opts, :repo, AcceptanceHarness.Config.repo()),
        sql,
        params
      )
end
