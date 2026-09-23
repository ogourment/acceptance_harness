defmodule AcceptanceHarness.SchemaArtifactWriterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias AcceptanceHarness.SchemaArtifactWriter

  test "stays silent when an artifact is unchanged" do
    path = tmp_path("current.dot")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "digraph Schema { users; }\n")

    output =
      capture_io(fn ->
        assert SchemaArtifactWriter.write_if_changed!(
                 path,
                 "digraph Schema { users; }\n"
               ) == :unchanged
      end)

    assert output == ""
  end

  test "reports a compact capped DOT diff only when the artifact changes" do
    path = tmp_path("changed.dot")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(1..45, "\n", &"old_#{&1}"))
    updated = Enum.map_join(1..45, "\n", &"new_#{&1}")

    output =
      capture_io(fn ->
        assert SchemaArtifactWriter.write_if_changed!(path, updated) == :updated
      end)

    assert output =~ "Updated schema artifact: #{path} (+45/-45 lines)"
    assert output =~ "Changed schema lines (capped at 40):"
    assert output =~ "- old_1"
    assert output =~ "… 50 additional changed lines omitted"
    refute output =~ "new_45"
  end

  test "summarizes created and non-DOT artifacts without dumping their contents" do
    dot_path = tmp_path("created.dot")
    svg_path = tmp_path("changed.svg")
    File.mkdir_p!(Path.dirname(dot_path))
    File.mkdir_p!(Path.dirname(svg_path))
    File.write!(svg_path, "<svg>old</svg>")

    output =
      capture_io(fn ->
        assert SchemaArtifactWriter.write_if_changed!(dot_path, "digraph {}") == :created

        assert SchemaArtifactWriter.write_if_changed!(svg_path, "<svg>new layout</svg>") ==
                 :updated
      end)

    assert output =~ "Created schema artifact: #{dot_path}"
    assert output =~ "Updated schema artifact: #{svg_path}"
    assert output =~ "14 → 21 bytes"
    refute output =~ "<svg>new layout</svg>"
  end

  defp tmp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "acceptance-schema-output-#{System.unique_integer([:positive])}/#{name}"
    )
  end
end
