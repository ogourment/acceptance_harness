defmodule Mix.Tasks.Acceptance.Site do
  @moduledoc "Builds a static acceptance evidence site."
  use Mix.Task

  @shortdoc "Builds a static acceptance evidence site"

  @impl Mix.Task
  def run([source_dir, output_dir]) do
    AcceptanceHarness.Site.build!(source_dir, output_dir)
  end

  def run(_args) do
    Mix.raise("usage: mix acceptance.site SOURCE_DIR OUTPUT_DIR")
  end
end
