defmodule AcceptanceHarness.SchemaDiffTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.SchemaDiff

  defp dot(tables) do
    nodes =
      Enum.map_join(tables, "\n", fn {name, columns} ->
        rows =
          Enum.map_join(columns, "", fn {column, type} ->
            ~s(<TR><TD ALIGN="LEFT">#{column}</TD><TD ALIGN="LEFT">#{type}</TD></TR>)
          end)

        """
          "#{name}" [label=<
            <TABLE BORDER="1">
              <TR><TD BGCOLOR="#dbeafe" COLSPAN="2"><B>public.#{name}</B></TD></TR>#{rows}
            </TABLE>
          >];
        """
      end)

    "digraph d {\n#{nodes}\n}"
  end

  describe "parse/1" do
    test "reads tables and their columns" do
      parsed =
        SchemaDiff.parse(dot(%{"users" => [{"id PK", "bigint NOT NULL"}, {"email", "citext"}]}))

      assert %{"users" => table} = parsed
      assert table.label == "public.users"
      assert table.columns == [{"id PK", "bigint NOT NULL"}, {"email", "citext"}]
    end

    test "returns an empty map for a graph with no tables" do
      assert SchemaDiff.parse("digraph d {\n}") == %{}
    end

    # The overview diagram puts label= and the closing ]; on their own lines,
    # which silently made it unparseable and so never comparable.
    test "reads a node whose label opens and closes on separate lines" do
      dot = """
      digraph Schema {
        "users" [
          label=<
            <TABLE BORDER="1">
      <TR><TD BGCOLOR="#dbeafe" COLSPAN="2"><B>public.users</B></TD></TR>
      <TR><TD ALIGN="LEFT"><FONT POINT-SIZE="12">id PK</FONT></TD><TD ALIGN="LEFT"><FONT POINT-SIZE="12">bigint NOT NULL</FONT></TD></TR>
            </TABLE>
          >
        ];
      }
      """

      assert %{"users" => table} = SchemaDiff.parse(dot)
      assert table.label == "public.users"
      assert table.columns == [{"id PK", "bigint NOT NULL"}]
    end
  end

  describe "parse/1 on a rendered SVG" do
    # Runs captured before the DOT source was archived alongside the diagram
    # only left an SVG behind. Graphviz emits one <text> per table cell in row
    # order, so the columns can be recovered from the picture itself.
    @rendered_svg """
    <svg xmlns="http://www.w3.org/2000/svg">
    <g id="node1" class="node">
    <title>players</title>
    <polygon fill="#dbeafe" stroke="none" points="0,0 1,1"/>
    <text text-anchor="start" x="1" y="-1" font-weight="bold" font-size="14.00">public.players</text>
    <polygon fill="none" stroke="#2563eb" points="0,0 1,1"/>
    <text text-anchor="start" x="1" y="-2" font-size="14.00">id PK</text>
    <polygon fill="none" stroke="#2563eb" points="0,0 1,1"/>
    <text text-anchor="start" x="2" y="-2" font-size="14.00">uuid NOT NULL</text>
    <polygon fill="none" stroke="#2563eb" points="0,0 1,1"/>
    <text text-anchor="start" x="1" y="-3" font-size="14.00">seat_index</text>
    <polygon fill="none" stroke="#2563eb" points="0,0 1,1"/>
    <text text-anchor="start" x="2" y="-3" font-size="14.00">integer NOT NULL</text>
    </g>
    <g id="edge1" class="edge">
    <title>players&#45;&gt;games</title>
    <text text-anchor="middle" x="5" y="-5" font-size="10.00">game_id</text>
    </g>
    </svg>
    """

    test "recovers tables and columns from a rendered diagram" do
      parsed = SchemaDiff.parse(@rendered_svg)

      assert %{"players" => table} = parsed
      assert table.label == "public.players"
      assert table.columns == [{"id PK", "uuid NOT NULL"}, {"seat_index", "integer NOT NULL"}]
    end

    test "ignores edge labels, which are not columns" do
      assert SchemaDiff.parse(@rendered_svg) |> Map.keys() == ["players"]
    end

    test "an SVG and the DOT it was rendered from compare as identical" do
      from_dot =
        dot(%{"players" => [{"id PK", "uuid NOT NULL"}, {"seat_index", "integer NOT NULL"}]})

      refute SchemaDiff.any?(SchemaDiff.diff(from_dot, @rendered_svg))
    end

    test "an added column is found when only the previous run left an SVG" do
      current =
        dot(%{
          "players" => [
            {"id PK", "uuid NOT NULL"},
            {"seat_index", "integer NOT NULL"},
            {"revoked_at", "timestamp without time zone NULL"}
          ]
        })

      diff = SchemaDiff.diff(@rendered_svg, current)

      assert diff.tables["players"].added == [
               {"revoked_at", "timestamp without time zone NULL"}
             ]
    end

    test "unescapes entities the renderer wrote" do
      svg = """
      <svg><g class="node"><title>t</title>
      <text font-weight="bold">public.t</text>
      <text>a&amp;b</text><text>text NULL</text>
      </g></svg>
      """

      assert SchemaDiff.parse(svg)["t"].columns == [{"a&b", "text NULL"}]
    end
  end

  describe "diff/2" do
    test "reports an added column against the table that gained it" do
      before_dot = dot(%{"users" => [{"id PK", "bigint"}]})
      after_dot = dot(%{"users" => [{"id PK", "bigint"}, {"timezone", "character varying"}]})

      diff = SchemaDiff.diff(before_dot, after_dot)

      assert diff.tables["users"].added == [{"timezone", "character varying"}]
      assert diff.tables["users"].removed == []
      assert diff.added_tables == []
      assert diff.removed_tables == []
      assert SchemaDiff.any?(diff)
    end

    test "reports a removed column" do
      before_dot = dot(%{"users" => [{"id PK", "bigint"}, {"legacy", "text"}]})
      after_dot = dot(%{"users" => [{"id PK", "bigint"}]})

      diff = SchemaDiff.diff(before_dot, after_dot)

      assert diff.tables["users"].removed == [{"legacy", "text"}]
      assert diff.tables["users"].added == []
    end

    test "reports a changed column type as both sides so the change is visible" do
      before_dot = dot(%{"users" => [{"age", "integer"}]})
      after_dot = dot(%{"users" => [{"age", "bigint"}]})

      diff = SchemaDiff.diff(before_dot, after_dot)

      assert diff.tables["users"].changed == [{"age", "integer", "bigint"}]
    end

    test "reports whole tables added and removed" do
      before_dot = dot(%{"users" => [{"id PK", "bigint"}]})
      after_dot = dot(%{"users" => [{"id PK", "bigint"}], "players" => [{"id PK", "bigint"}]})

      diff = SchemaDiff.diff(before_dot, after_dot)

      assert diff.added_tables == ["players"]
      assert SchemaDiff.diff(after_dot, before_dot).removed_tables == ["players"]
    end

    test "an identical schema produces no change" do
      same = dot(%{"users" => [{"id PK", "bigint"}]})
      diff = SchemaDiff.diff(same, same)

      assert diff.tables == %{}
      refute SchemaDiff.any?(diff)
    end

    test "treats a missing previous schema as everything being new" do
      after_dot = dot(%{"users" => [{"id PK", "bigint"}]})
      diff = SchemaDiff.diff(nil, after_dot)

      assert diff.added_tables == ["users"]
      assert SchemaDiff.any?(diff)
    end
  end

  describe "annotate_svg/2" do
    @svg """
    <svg xmlns="http://www.w3.org/2000/svg">
    <g id="node1" class="node"><title>users</title>
    <text x="1" y="1">id PK</text>
    <text x="1" y="2">timezone</text>
    </g>
    <g id="node2" class="node"><title>games</title>
    <text x="1" y="3">timezone</text>
    </g>
    </svg>
    """

    test "marks only the added column, and only inside the table that gained it" do
      diff = %{
        tables: %{
          "users" => %{added: [{"timezone", "character varying"}], removed: [], changed: []}
        },
        added_tables: [],
        removed_tables: []
      }

      annotated = SchemaDiff.annotate_svg(@svg, diff)

      # The users row is marked...
      assert annotated =~ ~r/<text[^>]*class="ah-schema-added"[^>]*>timezone<\/text>/
      # ...and the identically named column in another table is not.
      assert Regex.scan(~r/class="ah-schema-added"/, annotated) |> length() == 1
    end

    test "injects the legend styles once" do
      diff = %{
        tables: %{"users" => %{added: [{"timezone", "x"}], removed: [], changed: []}},
        added_tables: [],
        removed_tables: []
      }

      annotated = SchemaDiff.annotate_svg(@svg, diff)
      assert annotated =~ "ah-schema-added"
      assert Regex.scan(~r/<style/, annotated) |> length() == 1
    end

    test "returns the diagram unchanged when nothing was added" do
      diff = %{tables: %{}, added_tables: [], removed_tables: []}
      assert SchemaDiff.annotate_svg(@svg, diff) == @svg
    end
  end

  describe "union_dot/2" do
    test "preserves the domain diagram layout, clusters, and relationship edges" do
      before_dot = domain_dot([{"id PK", "uuid NOT NULL"}])
      after_dot = domain_dot([{"id PK", "uuid NOT NULL"}, {"payer_email", "text NULL"}])

      union = SchemaDiff.union_dot(before_dot, after_dot)

      assert union =~ "digraph registrations_and_passport"
      assert union =~ "subgraph cluster_local"
      assert union =~ "subgraph cluster_external"

      assert union =~
               ~s("registration_checkouts" -> "registrations" [label="registration_id -> id", color="#64748b"])

      assert union =~ "+ payer_email"
    end

    test "keeps unchanged columns plain and marks added ones green" do
      before_dot = dot(%{"users" => [{"id PK", "bigint"}]})
      after_dot = dot(%{"users" => [{"id PK", "bigint"}, {"timezone", "character varying"}]})

      union = SchemaDiff.union_dot(before_dot, after_dot)

      assert union =~ ~r/digraph/
      # the unchanged column carries no colour
      assert union =~ ~r/<TD ALIGN="LEFT">id PK<\/TD>/
      # the added one is green and signed
      assert union =~ "#15803d"
      assert union =~ "+ timezone"
    end

    test "marks generated overview nodes whose closing bracket is on its own line" do
      before_dot = dot(%{"users" => [{"id PK", "bigint"}]})

      after_dot =
        String.replace(
          dot(%{"users" => [{"id PK", "bigint"}, {"timezone", "character varying"}]}),
          ">];",
          ">\n  ];"
        )

      union = SchemaDiff.union_dot(before_dot, after_dot)

      assert union =~ "#15803d"
      assert union =~ "+ timezone"
    end

    test "carries removed columns forward in red so they appear on the same diagram" do
      before_dot = dot(%{"users" => [{"id PK", "bigint"}, {"legacy", "text"}]})
      after_dot = dot(%{"users" => [{"id PK", "bigint"}]})

      union = SchemaDiff.union_dot(before_dot, after_dot)

      assert union =~ "#b91c1c"
      assert union =~ "- legacy"
    end

    test "includes a table that no longer exists, marked as removed" do
      before_dot = dot(%{"users" => [{"id PK", "bigint"}], "legacy" => [{"id PK", "bigint"}]})
      after_dot = dot(%{"users" => [{"id PK", "bigint"}]})

      union = SchemaDiff.union_dot(before_dot, after_dot)

      assert union =~ "legacy"
      assert union =~ "#b91c1c"
    end

    test "shows a changed type as old and new" do
      before_dot = dot(%{"users" => [{"age", "integer"}]})
      after_dot = dot(%{"users" => [{"age", "bigint"}]})

      union = SchemaDiff.union_dot(before_dot, after_dot)

      assert union =~ "integer"
      assert union =~ "bigint"
      assert union =~ "#b45309"
    end
  end

  describe "render_svg/1" do
    test "keeps successful Graphviz warnings out of a valid SVG document" do
      directory =
        Path.join(System.tmp_dir!(), "schema-diff-renderer-#{System.unique_integer([:positive])}")

      command = Path.join(directory, "dot")
      File.mkdir_p!(directory)

      File.write!(
        command,
        """
        #!/bin/sh
        echo "Warning: no value for width of non-ASCII character" >&2
        printf '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"></svg>' > "$3"
        """
      )

      File.chmod!(command, 0o755)
      on_exit(fn -> File.rm_rf!(directory) end)

      assert {:ok, svg} = SchemaDiff.render_svg("digraph Example {}", dot_path: command)
      refute svg =~ "Warning:"
      assert String.starts_with?(svg, "<?xml")
      assert svg =~ ~r/^<\?xml[^>]*\?>\s*<svg\b/s
      assert String.ends_with?(svg, "</svg>")
    end

    @tag :graphviz
    test "renders the union diagram when Graphviz is available" do
      if System.find_executable("dot") do
        before_dot = dot(%{"users" => [{"id PK", "bigint"}]})
        after_dot = dot(%{"users" => [{"id PK", "bigint"}, {"timezone", "text"}]})

        assert {:ok, svg} = SchemaDiff.render_svg(SchemaDiff.union_dot(before_dot, after_dot))
        assert svg =~ "<svg"
        assert svg =~ "timezone"
      end
    end

    @tag :graphviz
    test "renders relationship links in the unified SVG" do
      if System.find_executable("dot") do
        before_dot = domain_dot([{"id PK", "uuid NOT NULL"}])
        after_dot = domain_dot([{"id PK", "uuid NOT NULL"}, {"payer_email", "text NULL"}])

        assert {:ok, svg} = SchemaDiff.union_svg(before_dot, after_dot)
        assert svg =~ ~s(class="edge")
        assert svg =~ "registration_checkouts&#45;&gt;registrations"
        assert svg =~ "registration_id &#45;&gt; id"
      end
    end

    test "reports a clear error rather than crashing when Graphviz is missing" do
      assert {:error, :graphviz_unavailable} =
               SchemaDiff.render_svg("digraph g { a }", dot_path: "/nonexistent/dot")
    end
  end

  defp domain_dot(checkout_columns) do
    checkout_rows =
      Enum.map_join(checkout_columns, "", fn {column, type} ->
        ~s(<TR><TD ALIGN="LEFT">#{column}</TD><TD ALIGN="LEFT">#{type}</TD></TR>)
      end)

    """
    digraph registrations_and_passport {
      graph [rankdir=TB, bgcolor="white", pad=0.35, nodesep=0.6, ranksep=0.9, fontname="Helvetica"];
      node [shape=plain, fontname="Helvetica"];
      edge [fontname="Helvetica", fontsize=10, arrowsize=0.7];
      labelloc="t";
      label=< <B>Registrations &amp; passport</B><BR/><FONT POINT-SIZE="12">Local tables show every column. Amber dashed arrows cross a domain boundary.</FONT> >;

      subgraph cluster_local {
        label="Registrations & passport";
        color="#94a3b8";
        "registration_checkouts" [label=<
          <TABLE BORDER="1" CELLBORDER="1" CELLSPACING="0" CELLPADDING="5" COLOR="#2563eb">
            <TR><TD BGCOLOR="#dbeafe" COLSPAN="2"><B>public.registration_checkouts</B></TD></TR>
            #{checkout_rows}
          </TABLE>
        >];
        "registrations" [label=<
          <TABLE BORDER="1" CELLBORDER="1" CELLSPACING="0" CELLPADDING="5" COLOR="#2563eb">
            <TR><TD BGCOLOR="#dbeafe" COLSPAN="2"><B>public.registrations</B></TD></TR>
            <TR><TD ALIGN="LEFT">id PK</TD><TD ALIGN="LEFT">uuid NOT NULL</TD></TR>
          </TABLE>
        >];
      }

      subgraph cluster_external {
        label="External-domain references — other relationships are intentionally omitted";
        color="#cbd5e1";
        "workshop_sessions" [label=<
          <TABLE BORDER="1" CELLBORDER="1" CELLSPACING="0" CELLPADDING="5" COLOR="#d97706">
            <TR><TD BGCOLOR="#fef3c7"><B>external: workshop_sessions</B></TD></TR>
            <TR><TD><FONT POINT-SIZE="10">other fields and relationships omitted</FONT></TD></TR>
          </TABLE>
        >];
      }

      "registration_checkouts" -> "registrations" [label="registration_id -> id", color="#64748b"];
      "registrations" -> "workshop_sessions" [label="workshop_session_id -> id", color="#d97706", style="dashed", penwidth=1.5];
    }
    """
  end
end
