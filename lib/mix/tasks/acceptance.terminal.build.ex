defmodule Mix.Tasks.Acceptance.Terminal.Build do
  @moduledoc "Builds the harness-owned PTY helper for the current host."

  use Mix.Task

  @shortdoc "Builds the native terminal PTY helper"
  @source_root Path.expand("../../..", __DIR__)

  @impl true
  def run(_arguments) do
    {output, status} =
      System.cmd(
        "cargo",
        ["build", "--release", "--locked", "--manifest-path", "native/pty_helper/Cargo.toml"],
        cd: @source_root,
        stderr_to_stdout: true
      )

    if status == 0 do
      Mix.shell().info(output)
    else
      Mix.raise("terminal PTY helper build failed:\n#{output}")
    end
  end
end
