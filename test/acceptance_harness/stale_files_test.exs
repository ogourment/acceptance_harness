defmodule AcceptanceHarness.StaleFilesTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.StaleFiles

  setup do
    root = Path.join(System.tmp_dir!(), "acceptance-stale-#{System.unique_integer([:positive])}")
    directory = Path.join(root, "test/atdd")
    evidence = Path.join(root, "tmp/atdd/evidence.json")
    manifest = Path.join(root, "tmp/atdd-stale-files.json")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(root) end)
    %{directory: directory, evidence: evidence, manifest: manifest}
  end

  test "missing manifest explicitly falls back to the full suite", context do
    write_scenario(context.directory, "one", "v1")
    write_evidence(context.evidence, [{"one", "success"}])

    assert {:full, reason} = select(context)
    assert reason =~ "manifest is missing"
  end

  test "selects the union of non-success, new, and modified files", context do
    failed = write_scenario(context.directory, "failed", "v1")
    changed = write_scenario(context.directory, "changed", "v1")
    _stable = write_scenario(context.directory, "stable", "v1")
    StaleFiles.record_all!(context.directory, context.manifest)

    write_scenario(context.directory, "changed", "v2")
    new = write_scenario(context.directory, "new", "v1")

    write_evidence(context.evidence, [
      {"failed", "failure"},
      {"changed", "success"},
      {"stable", "success"}
    ])

    assert {:selected, selected} = select(context)
    assert selected == Enum.sort([failed, changed, new])
  end

  test "record-selected advances only successful selected files", context do
    one = write_scenario(context.directory, "one", "v1")
    two = write_scenario(context.directory, "two", "v1")
    StaleFiles.record_all!(context.directory, context.manifest)

    write_scenario(context.directory, "one", "v2")
    write_scenario(context.directory, "two", "v2")
    write_evidence(context.evidence, [{"one", "success"}, {"two", "success"}])

    StaleFiles.record_selected!(context.directory, context.manifest, [one])

    assert {:selected, [^two]} = select(context)
  end

  test "corrupt evidence and unmapped failed IDs fall back to full", context do
    write_scenario(context.directory, "one", "v1")
    StaleFiles.record_all!(context.directory, context.manifest)
    File.mkdir_p!(Path.dirname(context.evidence))
    File.write!(context.evidence, "not-json")
    assert {:full, reason} = select(context)
    assert reason =~ "evidence is corrupt"

    write_evidence(context.evidence, [{"missing", "failure"}])
    assert {:full, reason} = select(context)
    assert reason =~ "could not be mapped"
  end

  test "scanner supports scenario and scenario! calls", context do
    ordinary = write_scenario(context.directory, "ordinary", "v1")
    bang = Path.join(context.directory, "bang_atdd_test.exs")
    File.write!(bang, ~S|@scenario Suite.scenario!("bang")| <> "\n")

    files = StaleFiles.scan(context.directory)

    assert files[ordinary].scenario_ids == ["ordinary"]
    assert files[bang].scenario_ids == ["bang"]
  end

  defp select(context) do
    StaleFiles.select(
      directory: context.directory,
      evidence_path: context.evidence,
      manifest_path: context.manifest
    )
  end

  defp write_scenario(directory, id, suffix) do
    path = Path.join(directory, "#{id}_atdd_test.exs")
    File.write!(path, ~s|@scenario Suite.scenario("#{id}")\n# #{suffix}\n|)
    Path.expand(path)
  end

  defp write_evidence(path, scenarios) do
    payload = %{
      "timing" => %{"finalized" => true},
      "run" => %{"finalized_at" => "2026-07-20T20:00:00Z"},
      "scenarios" => Enum.map(scenarios, fn {id, status} -> %{"id" => id, "status" => status} end)
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(payload))
  end
end
