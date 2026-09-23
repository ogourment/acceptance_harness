defmodule AcceptanceHarness.MarkdownTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.Markdown

  test "renders an evidence actor marker beginning with a hash as a paragraph" do
    assert Markdown.to_html("#superadmin sees the evidence map.") ==
             "<p>#superadmin sees the evidence map.</p>"
  end
end
