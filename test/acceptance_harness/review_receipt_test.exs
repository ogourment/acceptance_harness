defmodule AcceptanceHarness.ReviewReceiptTest do
  use ExUnit.Case, async: true
  alias AcceptanceHarness.ReviewReceipt

  defp receipt(session, extra \\ %{}) do
    {:ok, receipt} =
      ReviewReceipt.new(
        Map.merge(
          %{
            "project" => "ecojeux",
            "target" => "scenario/invite",
            "revision" => "r1",
            "environment" => "dev",
            "run_id" => "run1",
            "source" => "human",
            "viewed_at" => "2026-09-20T12:00:00Z"
          },
          extra
        ),
        session
      )

    receipt
  end

  test "promotion and duplicate import preserve origin without inflating counts" do
    dev = receipt("one")
    staging = receipt("two", %{"environment" => "staging"})
    summary = ReviewReceipt.summarize([dev, dev, staging], "ecojeux", "scenario/invite", "r1")
    assert summary.reads == 2
    assert summary.environments == %{"dev" => 1, "staging" => 1}

    assert ReviewReceipt.summarize([dev], "ecojeux", "scenario/invite", "r2").state ==
             "changed_unreviewed"

    assert ReviewReceipt.summarize([dev], "other", "scenario/invite", "r1").reads == 0
  end

  test "automation does not become human review and sessions are not retained" do
    automated = receipt("secret-session", %{"source" => "automated"})
    summary = ReviewReceipt.summarize([automated], "ecojeux", "scenario/invite", "r1")
    assert summary.reads == 0
    assert summary.automated == 1
    refute inspect(automated) =~ "secret-session"
  end

  test "fingerprints match the portable JSON contract" do
    assert ReviewReceipt.fingerprint(["é", %{"z" => 1, "a" => ["x", nil]}]) ==
             "3e5d097d75cd30b5e6ce88d19622fa8ea150ed2805e4fbf80a60d7d9581c5c6c"
  end
end
