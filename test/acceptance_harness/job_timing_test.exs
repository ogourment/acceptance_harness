defmodule AcceptanceHarness.JobTimingTest do
  use ExUnit.Case, async: true
  alias AcceptanceHarness.{JobTiming, Timing}

  test "captures this job's timestamp interval separately from runner queue" do
    job = %{
      "id" => 42,
      "created_at" => "2026-09-20T12:00:00.000Z",
      "started_at" => "2026-09-20T12:02:05.250Z",
      "queued_duration" => 1.125,
      "user" => %{"email" => "private@example.test"}
    }

    timing = JobTiming.capture(%{"CI_JOB_ID" => "42"}, fn _ -> {:ok, job} end)
    assert timing.job_wait_ms == 125_250
    assert timing.runner_queue_ms == 1125
    refute inspect(timing) =~ "private@example.test"
    roundtrip = Jason.decode!(Jason.encode!(%{timing: timing}))

    assert Enum.find(Timing.run_metrics(roundtrip), &(&1.label == "Evidence job pending")).value ==
             "2 min 5 s"
  end

  test "does not attribute a different job attempt to this evidence" do
    result = JobTiming.capture(%{"CI_JOB_ID" => "42"}, fn _ -> {:ok, %{"id" => 41}} end)
    assert result.job_wait_ms == nil
    assert result.job_timing.status == "invalid"
  end

  test "preserves fractional fallback and real zero, rejects malformed and negative durations" do
    for {input, expected} <- [{"125.25", 125_250}, {"0", 0}, {"-1", nil}, {"bad", nil}] do
      assert JobTiming.capture(%{"ATDD_JOB_WAIT_SECONDS" => input}).job_wait_ms == expected
    end
  end

  test "missing or reversed timestamps stay unknown, not a fabricated zero" do
    for job <- [
          %{},
          %{"created_at" => "2026-09-20T12:01:00Z", "started_at" => "2026-09-20T12:00:00Z"}
        ] do
      assert JobTiming.from_job(job).job_wait_ms == nil
    end

    assert JobTiming.capture(%{}).job_timing.status == "not_applicable"

    assert JobTiming.capture(%{"CI_JOB_ID" => "42"}, fn _ -> {:error, :denied} end).job_timing.status ==
             "unavailable"
  end
end
