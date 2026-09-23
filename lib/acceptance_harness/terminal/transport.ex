defmodule AcceptanceHarness.Terminal.Transport do
  @moduledoc """
  Transport contract for one terminal process owned by one acceptance scenario.

  Output events contain raw bytes. Screen emulation, ANSI normalization, and
  scenario assertions intentionally live above this boundary.
  """

  @type session :: pid()
  @type start_option ::
          {:command, [String.t()]}
          | {:cwd, String.t()}
          | {:env, %{optional(String.t()) => String.t()}}
          | {:rows, pos_integer()}
          | {:cols, pos_integer()}
          | {:owner, pid()}
          | {:event_target, pid()}
          | {:helper_path, String.t()}
          | {:start_timeout, pos_integer()}

  @callback start([start_option()]) :: {:ok, session()} | {:error, term()}
  @callback input(session(), iodata()) :: :ok | {:error, term()}
  @callback resize(session(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  @callback snapshot(session()) :: {:ok, map()} | {:error, term()}
  @callback stop(session(), term()) :: :ok | {:error, term()}
end
