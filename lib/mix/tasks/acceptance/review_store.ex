defmodule Mix.Tasks.Acceptance.ReviewStore do
  @shortdoc "Install review history or exchange project-scoped receipts"
  use Mix.Task

  def run(argv) do
    Mix.Task.run("app.start")

    case argv do
      ["install"] ->
        AcceptanceHarness.ReviewStore.install!()

      ["export", project, path] ->
        File.write!(
          path,
          Jason.encode!(AcceptanceHarness.ReviewStore.export(project), pretty: true)
        )

      ["import", project, path] ->
        {:ok, count} =
          AcceptanceHarness.ReviewStore.import!(project, Jason.decode!(File.read!(path)))

        Mix.shell().info("Imported #{count} new review receipts")

      _ ->
        Mix.raise(
          "Use acceptance.review_store install | export PROJECT FILE | import PROJECT FILE"
        )
    end
  end
end
