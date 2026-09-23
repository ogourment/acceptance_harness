defmodule Mix.Tasks.Acceptance.SchemaCompareTest do
  use ExUnit.Case, async: false

  @moduletag :graphviz

  defp dot(columns) do
    rows =
      Enum.map_join(columns, "", fn {name, type} ->
        ~s(<TR><TD ALIGN="LEFT">#{name}</TD><TD ALIGN="LEFT">#{type}</TD></TR>)
      end)

    """
    digraph d {
      "players" [label=<
        <TABLE BORDER="1">
          <TR><TD BGCOLOR="#dbeafe" COLSPAN="2"><B>public.players</B></TD></TR>#{rows}
        </TABLE>
      >];
    }
    """
  end

  defp git!(args, dir), do: {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  # A throwaway repository with the diagram committed twice, which is the shape
  # the task reads: the checked-in DOT at two revisions.
  defp repo_with_history(columns_before, columns_after) do
    dir = Path.join(System.tmp_dir!(), "ah-compare-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "docs/schema/app_domains"))

    git!(["init", "--initial-branch=main"], dir)
    git!(["config", "user.email", "test@example.com"], dir)
    git!(["config", "user.name", "Test"], dir)

    path = Path.join(dir, "docs/schema/app_domains/multiplayer.dot")

    File.write!(path, dot(columns_before))
    git!(["add", "."], dir)
    git!(["commit", "-m", "before"], dir)

    File.write!(path, dot(columns_after))
    git!(["add", "."], dir)
    # --allow-empty so an unchanged schema still produces a second revision
    git!(["commit", "--allow-empty", "-m", "after"], dir)

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp compare(dir, args) do
    out = Path.join(dir, "tmp/compare")

    File.cd!(dir, fn ->
      Mix.Tasks.Acceptance.SchemaCompare.run(
        ["--out", out, "--domains-output", "docs/schema/app_domains"] ++ args
      )
    end)

    out
  end

  setup do
    if System.find_executable("dot") == nil, do: :ok
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "renders a comparison for a domain that changed between two revisions" do
    if System.find_executable("dot") do
      dir =
        repo_with_history(
          [{"id PK", "uuid NOT NULL"}],
          [{"id PK", "uuid NOT NULL"}, {"revoked_at", "timestamp NULL"}]
        )

      out = compare(dir, ["--from", "HEAD~1", "--to", "HEAD"])

      svg = File.read!(Path.join(out, "multiplayer.svg"))
      assert svg =~ "<svg"
      # the added column is carried in green and signed
      assert svg =~ "revoked_at"
      assert svg =~ "#15803d"
    end
  end

  test "writes nothing when the two revisions share a schema" do
    if System.find_executable("dot") do
      columns = [{"id PK", "uuid NOT NULL"}]
      dir = repo_with_history(columns, columns)

      out = compare(dir, ["--from", "HEAD~1", "--to", "HEAD"])

      assert File.ls!(out) == []
      assert_received {:mix_shell, :info, [message]}
      assert message =~ "No schema changes"
    end
  end
end
