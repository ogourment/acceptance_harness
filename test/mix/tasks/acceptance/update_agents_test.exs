defmodule Mix.Tasks.Acceptance.UpdateAgentsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Acceptance.UpdateAgents

  test "adds and refreshes only its managed AGENTS.md block" do
    consumer_dir =
      Path.join(System.tmp_dir!(), "acceptance-harness-agents-#{System.unique_integer()}")

    File.mkdir_p!(consumer_dir)
    on_exit(fn -> File.rm_rf!(consumer_dir) end)
    agents_path = Path.join(consumer_dir, "AGENTS.md")
    File.write!(agents_path, "# Consumer instructions\n\nKeep this line.\n")

    UpdateAgents.run([consumer_dir])

    first = File.read!(agents_path)
    assert File.read!(Path.join(consumer_dir, ".gitignore")) == "/tmp/\n"
    assert first =~ "Keep this line."
    assert first =~ "acceptance-harness:guidance-version:#{Mix.Project.config()[:version]}"
    assert first =~ "validate with xopen's exact serving contract"
    assert first =~ "every local image and linked resource loads"
    assert first =~ "Preview-tool chrome must yield to the reviewed UI"

    # Consumers receive working pointers to the full pinned contract, not a copy
    # of hundreds of lines whose wording becomes an accidental test API.
    docs = Path.expand("../../../../docs", __DIR__)

    for document <- ["acceptance-contract.md", "approval_review_bundle_example.md"] do
      assert first =~ "deps/acceptance_harness/docs/#{document}"
      assert File.regular?(Path.join(docs, document))
    end

    refute first =~ "__HARNESS_DOCS__"
    assert length(String.split(first, "\n")) < 120

    UpdateAgents.run([consumer_dir])

    assert File.read!(agents_path) == first
    UpdateAgents.run(["--check", consumer_dir])
  end

  test "harness checkout uses its own docs without requiring a self dependency" do
    root = Path.join(System.tmp_dir!(), "harness-self-guidance-#{System.unique_integer()}")
    File.mkdir_p!(Path.join(root, "lib/mix/tasks/acceptance"))
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "lib/mix/tasks/acceptance/update_agents.ex"), "")
    File.write!(Path.join(root, "AGENTS.md"), "# Harness\n")
    UpdateAgents.run([root])
    contents = File.read!(Path.join(root, "AGENTS.md"))
    assert contents =~ "(docs/acceptance-contract.md)"
    refute contents =~ "deps/acceptance_harness/docs"
    UpdateAgents.run(["--check", root])
  end

  test "guidance version matches the package version" do
    mix = File.read!(Path.expand("../../../../mix.exs", __DIR__))
    [_, package_version] = Regex.run(~r/version: "([^"]+)"/, mix)

    source =
      File.read!(Path.expand("../../../../lib/mix/tasks/acceptance/update_agents.ex", __DIR__))

    assert source =~ ~s(@guidance_version "#{package_version}")
  end

  test "check fails when guidance is stale" do
    consumer_dir =
      Path.join(System.tmp_dir!(), "acceptance-harness-stale-agents-#{System.unique_integer()}")

    File.mkdir_p!(consumer_dir)
    File.write!(Path.join(consumer_dir, "AGENTS.md"), "# Consumer\n")
    File.write!(Path.join(consumer_dir, ".gitignore"), "/tmp/\n")

    assert_raise Mix.Error, ~r/stale AcceptanceHarness guidance/, fn ->
      UpdateAgents.run(["--check", consumer_dir])
    end
  end

  test "fails clearly when the consumer has no AGENTS.md" do
    consumer_dir =
      Path.join(System.tmp_dir!(), "acceptance-harness-no-agents-#{System.unique_integer()}")

    File.mkdir_p!(consumer_dir)

    assert_raise Mix.Error, ~r/AGENTS.md does not exist/, fn ->
      UpdateAgents.run([consumer_dir])
    end
  end

  test "check fails when tmp is not ignored" do
    consumer_dir =
      Path.join(System.tmp_dir!(), "acceptance-harness-no-tmp-ignore-#{System.unique_integer()}")

    File.mkdir_p!(consumer_dir)
    File.write!(Path.join(consumer_dir, "AGENTS.md"), "# Consumer\n")

    assert_raise Mix.Error, ~r/must ignore \/tmp\//, fn ->
      UpdateAgents.run(["--check", consumer_dir])
    end
  end

  test "fails before writing when git tracks files under tmp" do
    consumer_dir =
      Path.join(System.tmp_dir!(), "acceptance-harness-tracked-tmp-#{System.unique_integer()}")

    File.mkdir_p!(Path.join(consumer_dir, "tmp"))
    File.write!(Path.join(consumer_dir, "AGENTS.md"), "# Consumer\n")
    File.write!(Path.join(consumer_dir, ".gitignore"), "/tmp/\n")
    File.write!(Path.join(consumer_dir, "tmp/evidence.png"), "tracked evidence")
    git!(consumer_dir, ["init"])
    git!(consumer_dir, ["add", "AGENTS.md", ".gitignore"])
    git!(consumer_dir, ["add", "-f", "tmp/evidence.png"])

    assert_raise Mix.Error, ~r/tracks files under tmp.*tmp\/evidence\.png/s, fn ->
      UpdateAgents.run([consumer_dir])
    end

    assert File.read!(Path.join(consumer_dir, "AGENTS.md")) == "# Consumer\n"
  end

  defp git!(directory, arguments) do
    assert {_output, 0} = System.cmd("git", ["-C", directory | arguments], stderr_to_stdout: true)
  end
end
