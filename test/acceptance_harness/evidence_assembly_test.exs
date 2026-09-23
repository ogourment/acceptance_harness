defmodule AcceptanceHarness.EvidenceAssemblyTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.EvidenceAssembly

  test "merges phases by stable scenario id and reports missing scenarios" do
    root = Path.join(System.tmp_dir!(), "evidence-assembly-#{System.unique_integer([:positive])}")
    fast = Path.join(root, "fast")
    remaining = Path.join(root, "remaining")
    output = Path.join(root, "assembled")
    on_exit(fn -> File.rm_rf!(root) end)

    write_report(fast, "fast", [
      %{"id" => "participant", "title" => "Participant", "status" => "success", "steps" => []}
    ])

    write_report(remaining, "remaining", [
      %{"id" => "admin", "title" => "Admin", "status" => "success", "steps" => []}
    ])

    File.mkdir_p!(Path.join(fast, "screenshots"))
    File.mkdir_p!(Path.join(remaining, "screenshots"))
    File.write!(Path.join(fast, "screenshots/fast.png"), "fast")
    File.write!(Path.join(remaining, "screenshots/remaining.png"), "remaining")

    assert :ok = EvidenceAssembly.assemble!([fast, remaining], output, ["participant", "admin"])
    report = output |> Path.join("evidence.json") |> File.read!() |> Jason.decode!()
    assert Enum.map(report["scenarios"], & &1["id"]) == ["participant", "admin"]
    assert length(report["run"]["phases"]) == 2
    assert File.read!(Path.join(output, "e2e.md")) =~ "Phases assembled: **2**"
    assert File.read!(Path.join(output, "screenshots/fast.png")) == "fast"
    assert File.read!(Path.join(output, "screenshots/remaining.png")) == "remaining"

    assert {:error, {:missing_scenarios, ["public"]}} =
             EvidenceAssembly.assemble!([fast, remaining], output, [
               "participant",
               "admin",
               "public"
             ])
  end

  defp write_report(dir, phase, scenarios) do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "evidence.json"),
      Jason.encode!(%{
        "title" => "Evidence",
        "generated_at" => "2026-08-22T12:00:00Z",
        "app" => %{"version" => "1.0.0", "commit" => "abc"},
        "run" => %{"id" => phase},
        "scenarios" => scenarios,
        "pending_steps" => [],
        "pending_scenarios" => []
      })
    )
  end
end
