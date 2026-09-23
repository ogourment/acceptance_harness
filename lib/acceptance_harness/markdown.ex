defmodule AcceptanceHarness.Markdown do
  @moduledoc false

  @ordered_list_pattern ~r/^\d+\.\s+/
  @code_pattern ~r/`([^`\n]+)`/
  @image_pattern ~r/!\[([^\]]*)\]\(([^)]+)\)/
  @link_pattern ~r/(?<!!)\[([^\]]+)\]\(([^)]+)\)/
  @help_pattern ~r/\{\{help:([^{}]+)\}\}/u
  @strong_pattern ~r/\*\*([^*]+)\*\*/
  @emphasis_pattern ~r/(?<!\*)\*([^*\n]+)\*(?!\*)/u

  def to_html(markdown) do
    markdown
    |> String.split("\n")
    |> render_lines([])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp render_lines([], acc), do: acc
  defp render_lines(["" | rest], acc), do: render_lines(rest, acc)

  defp render_lines([line | rest], acc) do
    cond do
      String.trim(line) == ":::" ->
        render_lines(rest, ["</div>" | acc])

      String.starts_with?(String.trim(line), "::: ") ->
        render_lines(rest, [
          ~s(<div#{attrs_html(String.trim_leading(String.trim(line), "::: "))}>) | acc
        ])

      String.starts_with?(line, "### ") ->
        render_lines(rest, ["<h3>#{inline(String.trim_leading(line, "### "))}</h3>" | acc])

      String.starts_with?(line, "## ") ->
        render_lines(rest, ["<h2>#{inline(String.trim_leading(line, "## "))}</h2>" | acc])

      String.starts_with?(line, "# ") ->
        render_lines(rest, ["<h1>#{inline(String.trim_leading(line, "# "))}</h1>" | acc])

      String.starts_with?(line, "> ") ->
        {quote_lines, rest} = Enum.split_while([line | rest], &String.starts_with?(&1, "> "))
        body = quote_lines |> Enum.map(&String.trim_leading(&1, "> ")) |> Enum.join(" ")
        render_lines(rest, ["<blockquote>#{inline(body)}</blockquote>" | acc])

      String.starts_with?(line, "```") ->
        {code_lines, rest} = fenced_code(rest)

        render_lines(rest, [
          "<pre><code>#{escape(Enum.join(code_lines, "\n"))}</code></pre>" | acc
        ])

      table_row?(line) ->
        {table_lines, rest} = Enum.split_while([line | rest], &table_row?/1)
        render_lines(rest, [table_html(table_lines) | acc])

      bullet?(line) ->
        {items, rest} = Enum.split_while([line | rest], &bullet?/1)
        html = items |> Enum.map(&bullet_item/1) |> Enum.join("")
        render_lines(rest, ["<ul>#{html}</ul>" | acc])

      ordered_list?(line) ->
        {items, rest} = Enum.split_while([line | rest], &ordered_list?/1)
        html = items |> Enum.map(&ordered_list_item/1) |> Enum.join("")
        render_lines(rest, ["<ol>#{html}</ol>" | acc])

      true ->
        {paragraph_lines, rest} = Enum.split_while([line | rest], &paragraph_line?/1)
        body = paragraph_lines |> Enum.join(" ") |> inline()
        render_lines(rest, ["<p>#{body}</p>" | acc])
    end
  end

  defp paragraph_line?(line) do
    trimmed = String.trim(line)

    line != "" and not heading?(line) and not String.starts_with?(line, "> ") and
      not String.starts_with?(trimmed, ":::") and not String.starts_with?(line, "```") and
      not table_row?(line) and not bullet?(line) and not ordered_list?(line)
  end

  defp heading?(line),
    do:
      String.starts_with?(line, "# ") or String.starts_with?(line, "## ") or
        String.starts_with?(line, "### ")

  defp table_row?(line), do: String.starts_with?(String.trim_leading(line), "|")
  defp bullet?(line), do: String.starts_with?(line, "- ")
  defp ordered_list?(line), do: Regex.match?(@ordered_list_pattern, line)

  defp table_html([header, separator | body]) do
    if table_separator?(separator) do
      """
      <table>
        <thead><tr>#{header |> table_cells() |> Enum.map_join("", &table_header_cell/1)}</tr></thead>
        <tbody>#{Enum.map_join(body, "", &table_body_row/1)}</tbody>
      </table>
      """
    else
      "<p>#{inline(Enum.join([header, separator | body], " "))}</p>"
    end
  end

  defp table_html(lines), do: "<p>#{inline(Enum.join(lines, " "))}</p>"

  defp table_separator?(line) do
    line
    |> table_cells()
    |> Enum.all?(&Regex.match?(~r/^:?-{3,}:?$/, String.trim(&1)))
  end

  defp table_cells(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp table_header_cell(text), do: "<th>#{inline(text)}</th>"

  defp table_body_row(line),
    do: "<tr>#{line |> table_cells() |> Enum.map_join("", &table_body_cell/1)}</tr>"

  defp table_body_cell(text), do: "<td>#{inline(text)}</td>"

  defp fenced_code(lines) do
    {code_lines, rest} =
      Enum.split_while(lines, fn line -> not String.starts_with?(line, "```") end)

    rest =
      case rest do
        [_closing_fence | rest] -> rest
        [] -> []
      end

    {code_lines, rest}
  end

  defp bullet_item("- " <> text), do: "<li>#{inline(text)}</li>"

  defp ordered_list_item(line) do
    text = Regex.replace(@ordered_list_pattern, line, "")
    "<li>#{inline(text)}</li>"
  end

  defp inline(text) do
    text
    |> escape()
    |> code()
    |> image()
    |> link()
    |> help()
    |> strong()
    |> emphasis()
  end

  defp code(text),
    do: Regex.replace(@code_pattern, text, fn _, value -> "<code>#{value}</code>" end)

  defp image(text) do
    Regex.replace(@image_pattern, text, fn _, alt, src ->
      ~s(<img src="#{escape_attr(src)}" alt="#{escape_attr(alt)}">)
    end)
  end

  defp link(text) do
    Regex.replace(@link_pattern, text, fn _, label, href ->
      ~s(<a href="#{escape_attr(href)}">#{label}</a>)
    end)
  end

  defp help(text) do
    Regex.replace(@help_pattern, text, fn _, title ->
      escaped_title = escape_attr(title)

      ~s(<span class="inline-help" title="#{escaped_title}" aria-label="Help: #{escaped_title}" tabindex="0">🛈</span>)
    end)
  end

  defp strong(text),
    do: Regex.replace(@strong_pattern, text, fn _, value -> "<strong>#{value}</strong>" end)

  defp emphasis(text) do
    Regex.replace(@emphasis_pattern, text, fn _, value -> "<em>#{value}</em>" end)
  end

  defp attrs_html(attrs) do
    classes =
      attrs
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.filter(&String.starts_with?(&1, "."))
      |> Enum.map(&String.trim_leading(&1, "."))

    case classes do
      [] -> ""
      classes -> ~s( class="#{classes |> Enum.join(" ") |> escape_attr()}")
    end
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attr(value) do
    value
    |> escape()
    |> String.replace("\"", "&quot;")
  end
end
