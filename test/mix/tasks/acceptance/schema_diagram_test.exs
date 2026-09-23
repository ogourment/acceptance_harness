defmodule Mix.Tasks.Acceptance.SchemaDiagramTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Acceptance.SchemaDiagram

  test "keeps successful Graphviz diagnostics out of the SVG payload" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "acceptance-schema-renderer-#{System.unique_integer([:positive])}"
      )

    command = Path.join(directory, "dot")
    File.mkdir_p!(directory)

    File.write!(
      command,
      """
      #!/bin/sh
      echo "Warning: non-ASCII width fallback" >&2
      printf '<svg xmlns="http://www.w3.org/2000/svg"></svg>' > "$3"
      """
    )

    File.chmod!(command, 0o755)
    on_exit(fn -> File.rm_rf!(directory) end)

    assert SchemaDiagram.render_svg!("digraph Example {}", command: command) ==
             ~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>)
  end

  test "domain diagrams include every table column with type and nullability" do
    domain = %{id: "catalogue", title: "Catalogue", tables: ["products"]}
    tables = [%{schema: "public", name: "products"}]

    columns = [
      %{
        schema: "public",
        table: "products",
        name: "id",
        type: "uuid",
        nullable?: false,
        primary_key?: true
      },
      %{
        schema: "public",
        table: "products",
        name: "display_name",
        type: "character varying",
        nullable?: true,
        primary_key?: false
      }
    ]

    dot = SchemaDiagram.generate_domain_dot(domain, tables, columns, [])

    assert dot =~ "display_name"
    assert dot =~ "character varying"
    assert dot =~ "NULL"
    refute dot =~ "other columns"
  end
end
