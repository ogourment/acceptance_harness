defmodule AcceptanceHarness.ResourceGate.Collector do
  @moduledoc """
  Platform adapter contract for scenario-level process resource evidence.

  A collector starts after application warm-up, returns updated state for each
  sample, and emits one normalized result after the scenario settles.
  """

  @type state :: term()
  @type options :: keyword()
  @type result :: map()

  @callback start(options()) :: {:ok, state()} | {:skip, String.t()} | {:error, term()}
  @callback sample(state()) :: {:ok, state()} | {:error, term()}
  @callback finish(state()) :: {:ok, result()} | {:skip, String.t()} | {:error, term()}
end
