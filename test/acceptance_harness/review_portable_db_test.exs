defmodule AcceptanceHarness.ReviewPortableDbTest do
  use ExUnit.Case, async: false
  @moduletag :db
  alias AcceptanceHarness.{AdminStore, ReviewStore, ReviewTarget, TestRepo}

  @tag :tmp_dir
  test "portable SQLite receipts retain coverage after PostgreSQL import", %{tmp_dir: dir} do
    old = Application.fetch_env!(:acceptance_harness, :harness)
    Application.put_env(:acceptance_harness, :harness, Keyword.put(old, :repo, TestRepo))
    AdminStore.install!(repo: TestRepo)
    id = "portable-#{System.unique_integer([:positive])}"
    project = "project-#{id}"

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "DELETE FROM acceptance_harness_review_receipts WHERE project=$1",
        [project]
      )

      Ecto.Adapters.SQL.query!(TestRepo, "DELETE FROM acceptance_harness_runs WHERE id=$1", [id])
      Application.put_env(:acceptance_harness, :harness, old)
    end)

    data = %{
      "run" => %{"id" => id},
      "app" => %{"name" => project},
      "title" => "Portable evidence",
      "scenarios" => [
        %{
          "id" => "inspect",
          "title" => "Inspect",
          "steps" => [
            %{
              "id" => "first",
              "scenario_id" => "inspect",
              "sequence" => 1,
              "title" => "Outcome",
              "description" => "Visible result",
              "surface" => %{"kind" => "terminal", "text" => "é result"}
            }
          ]
        }
      ]
    }

    evidence = Path.join(dir, "evidence")
    File.mkdir_p!(evidence)
    manifest = Path.join(evidence, "evidence.json")
    File.write!(manifest, Jason.encode!(data))
    AdminStore.import_evidence_data!(data, repo: TestRepo)

    script = """
    import runpy, sys, json
    m = runpy.run_path('priv/preview/review_server.py', run_name='portable_test')
    r = m['Review'](sys.argv[1], sys.argv[2], 'dev')
    p = dict(run_id=sys.argv[3], scenario_id='inspect', step_id='first', session='portable-test-session', source='human')
    r.record(p)
    print(json.dumps(dict(target=r.resolve(p), receipts=r.export())))
    """

    {json, 0} =
      System.cmd("python3", ["-c", script, manifest, Path.join(dir, "reviews.sqlite3"), id])

    portable = Jason.decode!(json)
    target = ReviewTarget.resolve(id, "inspect", "first")
    assert portable["target"]["revision"] == target.revision
    assert portable["target"]["target"] == target.target
    assert {:ok, 1} = ReviewStore.import!(project, portable["receipts"], repo: TestRepo)
    assert {:ok, 0} = ReviewStore.import!(project, portable["receipts"], repo: TestRepo)

    assert ReviewStore.summary(project, target.target, target.revision, repo: TestRepo).environments ==
             %{"dev" => 1}
  end
end
