defmodule AcceptanceHarness.SchemaDiff do
  @moduledoc """
  Structural comparison of two generated schema diagrams.

  Reviewers could previously only be shown the previous and current diagrams
  side by side. When a release adds a column to an existing table the two
  pictures are nearly identical and the difference is a few characters buried in
  a large diagram, which is not reviewable.

  This compares the DOT sources — the structured form Graphviz was rendered
  from — and marks the result **on the current diagram**, so one picture shows
  what changed. Marking is done by rewriting the existing SVG rather than
  re-rendering, because Graphviz is not installed where the review UI runs.

  Removals cannot be drawn onto a diagram that no longer contains them; they are
  returned separately so the UI can list them explicitly rather than imply the
  picture is complete.
  """

  @added_class "ah-schema-added"
  @changed_class "ah-schema-changed"

  @type column :: {String.t(), String.t()}
  @type t :: %{
          tables: %{
            optional(String.t()) => %{added: [column], removed: [column], changed: list()}
          },
          added_tables: [String.t()],
          removed_tables: [String.t()]
        }

  @doc """
  Parses a schema diagram into `%{table_id => %{label:, columns:}}`.

  Accepts either the DOT source or the SVG rendered from it. Runs captured
  before the DOT was archived alongside the picture left only an SVG behind, and
  a comparison that cannot read those is a comparison that cannot look back past
  the day the feature shipped.
  """
  @spec parse(String.t() | nil) :: map()
  def parse(nil), do: %{}

  def parse(source) when is_binary(source) do
    if svg?(source), do: parse_svg(source), else: parse_dot(source)
  end

  defp svg?(source), do: source =~ ~r/<svg[\s>]/

  # The overview diagram puts `label=` and the closing `];` on their own lines,
  # while the per-domain ones write both inline. Neither layout is meaningful to
  # Graphviz, so whitespace is allowed around both.
  defp parse_dot(dot) do
    ~r/"(?<id>[^"]+)"\s*\[\s*label=<(?<body>.*?)>\s*\];/s
    |> Regex.scan(dot, capture: :all_names)
    |> Enum.reduce(%{}, fn [body, id], acc ->
      Map.put(acc, id, %{label: table_label(body, id), columns: columns(body)})
    end)
  end

  # Graphviz renders each table as a <g class="node"> whose <title> is the node
  # id, then one <text> per cell in row order: the bold header, then name/type
  # pairs. Edges are their own groups and carry labels that are not columns, so
  # only node groups are read.
  defp parse_svg(svg) do
    ~r/<g[^>]*class="node"[^>]*>(?<body>.*?)<\/g>/s
    |> Regex.scan(svg, capture: :all_names)
    |> Enum.reduce(%{}, fn [body], acc ->
      case Regex.run(~r/<title>(.*?)<\/title>/s, body, capture: :all_but_first) do
        [id] ->
          id = unescape(String.trim(id))
          {label, columns} = svg_cells(body, id)
          Map.put(acc, id, %{label: label, columns: columns})

        _ ->
          acc
      end
    end)
  end

  defp svg_cells(body, id) do
    cells =
      ~r/<text[^>]*>(.*?)<\/text>/s
      |> Regex.scan(body, capture: :all_but_first)
      |> Enum.map(fn [text] -> clean(text) end)

    case cells do
      [header | rest] -> {header, pair_cells(rest)}
      [] -> {id, []}
    end
  end

  # A trailing unpaired cell means the diagram was truncated; drop it rather
  # than inventing a column with an empty type.
  defp pair_cells([name, type | rest]), do: [{name, type} | pair_cells(rest)]
  defp pair_cells(_), do: []

  defp table_label(body, id) do
    case Regex.run(~r/<B>(.*?)<\/B>/s, body) do
      [_, label] -> label |> String.trim() |> unescape()
      _ -> id
    end
  end

  # The header row carries COLSPAN; every other row is a column and its type.
  defp columns(body) do
    ~r/<TR>(?!<TD BGCOLOR)(.*?)<\/TR>/s
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.flat_map(fn [row] ->
      case Regex.scan(~r/<TD[^>]*>(.*?)<\/TD>/s, row, capture: :all_but_first) do
        [[name], [type] | _] -> [{clean(name), clean(type)}]
        _ -> []
      end
    end)
  end

  defp clean(value) do
    value
    |> String.replace(~r/<[^>]*>/, "")
    |> String.trim()
    |> unescape()
  end

  defp unescape(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  @doc """
  Compares two DOT sources. A nil previous source means everything is new.
  """
  @spec diff(String.t() | nil, String.t() | nil) :: t()
  def diff(previous_dot, current_dot) do
    previous = parse(previous_dot)
    current = parse(current_dot)

    added_tables =
      current |> Map.keys() |> Enum.reject(&Map.has_key?(previous, &1)) |> Enum.sort()

    removed_tables =
      previous |> Map.keys() |> Enum.reject(&Map.has_key?(current, &1)) |> Enum.sort()

    tables =
      current
      |> Enum.filter(fn {id, _} -> Map.has_key?(previous, id) end)
      |> Enum.reduce(%{}, fn {id, table}, acc ->
        change = compare_columns(previous[id].columns, table.columns)
        if empty?(change), do: acc, else: Map.put(acc, id, change)
      end)

    %{tables: tables, added_tables: added_tables, removed_tables: removed_tables}
  end

  defp compare_columns(previous, current) do
    previous_by_name = Map.new(previous)
    current_by_name = Map.new(current)

    added = Enum.reject(current, fn {name, _} -> Map.has_key?(previous_by_name, name) end)
    removed = Enum.reject(previous, fn {name, _} -> Map.has_key?(current_by_name, name) end)

    changed =
      current
      |> Enum.filter(fn {name, type} ->
        case Map.fetch(previous_by_name, name) do
          {:ok, previous_type} -> previous_type != type
          :error -> false
        end
      end)
      |> Enum.map(fn {name, type} -> {name, previous_by_name[name], type} end)

    %{added: added, removed: removed, changed: changed}
  end

  defp empty?(%{added: [], removed: [], changed: []}), do: true
  defp empty?(_), do: false

  @doc """
  Whether the comparison found anything at all.
  """
  @spec any?(t()) :: boolean()
  def any?(diff) do
    diff.tables != %{} or diff.added_tables != [] or diff.removed_tables != []
  end

  @doc """
  Marks added and type-changed columns on the current diagram.

  Matching is scoped to the Graphviz node whose `<title>` names the table, so a
  column name that also exists in another table is not marked there.
  """
  @spec annotate_svg(String.t(), t()) :: String.t()
  def annotate_svg(svg, diff) when is_binary(svg) do
    marks =
      diff.tables
      |> Enum.flat_map(fn {table, change} ->
        Enum.map(change.added, fn {name, _} -> {table, name, @added_class} end) ++
          Enum.map(change.changed, fn {name, _, _} -> {table, name, @changed_class} end)
      end)

    case marks do
      [] -> svg
      marks -> svg |> apply_marks(marks) |> inject_styles()
    end
  end

  defp apply_marks(svg, marks) do
    Enum.reduce(marks, svg, fn {table, column, class}, acc ->
      mark_within_node(acc, table, column, class)
    end)
  end

  # Rewrites only inside the <g> whose <title> is this table.
  defp mark_within_node(svg, table, column, class) do
    pattern = ~r/(<g[^>]*class="node">\s*<title>#{Regex.escape(table)}<\/title>.*?<\/g>)/s

    Regex.replace(pattern, svg, fn _full, node ->
      Regex.replace(
        ~r/<text([^>]*)>#{Regex.escape(column)}<\/text>/,
        node,
        fn _m, attrs -> ~s(<text#{attrs} class="#{class}">#{column}</text>) end,
        global: false
      )
    end)
  end

  defp inject_styles(svg) do
    style = """
    <style>
    .#{@added_class} { fill: #15803d; font-weight: bold; }
    .#{@changed_class} { fill: #b45309; font-weight: bold; }
    </style>
    """

    String.replace(svg, ~r/(<svg[^>]*>)/, "\\1\n#{style}", global: false)
  end

  @added_colour "#15803d"
  @removed_colour "#b91c1c"
  @changed_colour "#b45309"
  @added_fill "#dcfce7"
  @removed_fill "#fee2e2"
  @changed_fill "#fef3c7"

  @doc """
  Builds a single DOT source showing both versions at once.

  Unchanged columns render as they always did. Added columns are green and
  prefixed `+`. **Removed columns are carried forward in red and prefixed `-`**,
  which is the whole point: a diagram rendered only from the current schema can
  never show what was deleted. Type changes are amber and show both types.
  """
  @spec union_dot(String.t() | nil, String.t() | nil) :: String.t()
  def union_dot(previous_dot, current_dot) do
    previous = parse(previous_dot)
    current = parse(current_dot)

    ids = (Map.keys(current) ++ Map.keys(previous)) |> Enum.uniq() |> Enum.sort()
    base = current_dot || previous_dot || "digraph schema_diff {\n}\n"

    {base, removed_nodes} =
      Enum.reduce(ids, {base, []}, fn id, {dot, removed_nodes} ->
        before = Map.get(previous, id)
        after_ = Map.get(current, id)

        cond do
          is_nil(after_) ->
            {dot, [node_dot(id, before, nil) | removed_nodes]}

          before == after_ ->
            {dot, removed_nodes}

          true ->
            {replace_node(dot, id, node_dot(id, before, after_)), removed_nodes}
        end
      end)

    additions =
      removed_nodes
      |> Enum.reverse()
      |> Kernel.++(removed_edges(previous_dot, current_dot))
      |> Enum.join("\n")

    append_to_graph(base, additions)
  end

  defp replace_node(dot, id, replacement) do
    pattern = ~r/^\s*"#{Regex.escape(id)}"\s*\[\s*label=<.*?^\s*>\s*\];\s*$/ms
    Regex.replace(pattern, dot, fn _ -> replacement end, global: false)
  end

  defp removed_edges(nil, _current_dot), do: []

  defp removed_edges(previous_dot, current_dot) do
    current_dot = current_dot || ""

    ~r/^\s*"[^"]+"\s*->\s*"[^"]+"\s*\[[^\n]+\];\s*$/m
    |> Regex.scan(previous_dot)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&String.contains?(current_dot, &1))
    |> Enum.map(&mark_removed_edge/1)
  end

  defp mark_removed_edge(edge) do
    String.replace(edge, ~r/\];\s*$/, ~s(, color="#{@removed_colour}", style="dashed"];))
  end

  defp append_to_graph(dot, ""), do: dot

  defp append_to_graph(dot, additions) do
    case Regex.run(~r/}\s*$/, dot, return: :index) do
      [{index, _length}] -> String.slice(dot, 0, index) <> "\n#{additions}\n}\n"
      nil -> dot <> "\n#{additions}\n"
    end
  end

  defp node_dot(id, previous, current) do
    {label, border} =
      cond do
        is_nil(previous) -> {(current && current.label) || id, @added_colour}
        is_nil(current) -> {previous.label, @removed_colour}
        true -> {current.label, "#2563eb"}
      end

    rows = rows_dot(previous, current)

    ~s(  "#{id}" [label=<\n) <>
      ~s(    <TABLE BORDER="1" CELLBORDER="1" CELLSPACING="0" CELLPADDING="5" COLOR="#{border}">\n) <>
      ~s(      <TR><TD BGCOLOR="#dbeafe" COLSPAN="2"><B>#{escape(label)}</B></TD></TR>#{rows}\n) <>
      ~s(    </TABLE>\n  >];)
  end

  # Current columns keep their order; removed ones are appended so the reader
  # sees the live shape first and what left it after.
  defp rows_dot(previous, current) do
    previous_columns = if previous, do: previous.columns, else: []
    current_columns = if current, do: current.columns, else: []
    previous_by_name = Map.new(previous_columns)
    current_names = MapSet.new(current_columns, &elem(&1, 0))

    kept =
      Enum.map_join(current_columns, "", fn {name, type} ->
        case Map.fetch(previous_by_name, name) do
          :error when previous == nil -> row(name, type, nil, nil)
          :error -> row("+ " <> name, type, @added_colour, @added_fill)
          {:ok, ^type} -> row(name, type, nil, nil)
          {:ok, was} -> row("~ " <> name, "#{was} -> #{type}", @changed_colour, @changed_fill)
        end
      end)

    dropped =
      previous_columns
      |> Enum.reject(fn {name, _} -> MapSet.member?(current_names, name) end)
      |> Enum.map_join("", fn {name, type} ->
        row("- " <> name, type, @removed_colour, @removed_fill)
      end)

    kept <> dropped
  end

  defp row(name, type, nil, nil) do
    ~s(<TR><TD ALIGN="LEFT">#{escape(name)}</TD><TD ALIGN="LEFT">#{escape(type)}</TD></TR>)
  end

  defp row(name, type, colour, fill) do
    cell = fn value ->
      ~s(<TD ALIGN="LEFT" BGCOLOR="#{fill}"><FONT COLOR="#{colour}">#{escape(value)}</FONT></TD>)
    end

    "<TR>" <> cell.(name) <> cell.(type) <> "</TR>"
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc """
  Renders a DOT source to SVG with Graphviz.

  Returns `{:error, :graphviz_unavailable}` rather than raising when `dot` is
  missing, so a host without Graphviz degrades to the textual comparison instead
  of failing the page.
  """
  @spec render_svg(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def render_svg(dot_source, opts \\ []) do
    dot_path = Keyword.get(opts, :dot_path) || System.find_executable("dot")

    cond do
      is_nil(dot_path) ->
        {:error, :graphviz_unavailable}

      not File.exists?(dot_path) ->
        {:error, :graphviz_unavailable}

      true ->
        run_dot(dot_path, dot_source)
    end
  end

  # System.cmd/3 cannot write to stdin, so the source goes through a temp file.
  # Only ErlangError (a missing or non-executable binary) means "unavailable";
  # anything else is a real failure and must not be disguised as one.
  defp run_dot(dot_path, dot_source) do
    source_path =
      Path.join(System.tmp_dir!(), "ah-schema-diff-#{System.unique_integer([:positive])}.dot")

    output_path = Path.rootname(source_path) <> ".svg"

    try do
      File.write!(source_path, dot_source)

      case System.cmd(
             dot_path,
             ["-Tsvg", "-o", output_path, source_path],
             stderr_to_stdout: true
           ) do
        {_diagnostics, 0} -> {:ok, File.read!(output_path)}
        {_output, _code} -> {:error, :graphviz_failed}
      end
    rescue
      ErlangError -> {:error, :graphviz_unavailable}
    after
      File.rm(source_path)
      File.rm(output_path)
    end
  end

  @doc """
  Builds and renders the union diagram in one step.
  """
  @spec union_svg(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def union_svg(previous_dot, current_dot, opts \\ []) do
    previous_dot
    |> union_dot(current_dot)
    |> render_svg(opts)
  end
end
