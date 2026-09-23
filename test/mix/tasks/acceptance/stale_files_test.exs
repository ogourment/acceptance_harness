defmodule Mix.Tasks.Acceptance.StaleFilesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "select prints an explicit full fallback and can write machine-readable output" do
    root =
      Path.join(System.tmp_dir!(), "acceptance-stale-task-#{System.unique_integer([:positive])}")

    directory = Path.join(root, "test/atdd")
    evidence = Path.join(root, "evidence.json")
    manifest = Path.join(root, "missing.json")
    output = Path.join(root, "selection.txt")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "one_atdd_test.exs"), ~S|Suite.scenario("one")|)

    on_exit(fn -> File.rm_rf!(root) end)

    assert capture_io(fn ->
             Mix.Tasks.Acceptance.StaleFiles.run([
               "select",
               "--directory",
               directory,
               "--evidence",
               evidence,
               "--manifest",
               manifest
             ])
           end) =~ "__FULL__\tATDD stale manifest is missing"

    Mix.Tasks.Acceptance.StaleFiles.run([
      "select",
      "--directory",
      directory,
      "--evidence",
      evidence,
      "--manifest",
      manifest,
      "--output",
      output
    ])

    assert File.read!(output) =~ "__FULL__\tATDD stale manifest is missing"
  end
end
