defmodule AcceptanceHarness.ReviewStoreDbTest do
  use ExUnit.Case, async: false
  @moduletag :db
  alias AcceptanceHarness.{ReviewReceipt, ReviewStore, TestRepo}

  test "durable cross-environment import is idempotent and project scoped" do
    ReviewStore.install!(repo: TestRepo)
    project = "receipt-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "DELETE FROM acceptance_harness_review_receipts WHERE project=$1",
        [project]
      )
    end)

    {:ok, receipt} =
      ReviewReceipt.new(
        %{
          "project" => project,
          "target" => "step/invite/send",
          "revision" => "v1",
          "run_id" => "dev-run",
          "environment" => "dev",
          "source" => "human",
          "viewed_at" => "2026-09-20T12:00:00Z"
        },
        "first-session"
      )

    assert {:ok, 1} = ReviewStore.import!(project, [receipt], repo: TestRepo)
    assert {:ok, 0} = ReviewStore.import!(project, [receipt], repo: TestRepo)

    assert ReviewStore.summary(project, receipt["target"], "v1", repo: TestRepo).environments ==
             %{"dev" => 1}

    assert ReviewStore.export(project, repo: TestRepo) == [receipt]

    assert_raise ArgumentError, fn ->
      ReviewStore.import!("other-project", [receipt], repo: TestRepo)
    end

    assert ReviewStore.summary(project, receipt["target"], "v2", repo: TestRepo).state ==
             "changed_unreviewed"
  end
end
