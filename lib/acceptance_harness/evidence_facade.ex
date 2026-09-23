defmodule AcceptanceHarness.EvidenceFacade do
  @moduledoc """
  Generates a small, app-local façade for acceptance evidence.

  Consumer applications can keep their own namespace while avoiding a repeated
  list of `defdelegate` declarations:

      defmodule MyApp.AtddEvidence do
        use AcceptanceHarness.EvidenceFacade
      end

  The delegate list is deliberately explicit. New functions added to
  `AcceptanceHarness.Evidence` do not become part of the consumer façade until
  they are intentionally added here.
  """

  @delegates [
    {:start_scenario_runtime!, [0]},
    {:record_current_scenario_runtime, [1]},
    {:reset!, [1, 2, 3]},
    {:record_step, [3, 4]},
    {:record_pending_step, [3, 4]},
    {:record_pending_scenario, [1, 2]},
    {:mark_scenario_success!, [1]},
    {:mark_scenario_ignored_failure!, [2, 3]},
    {:record_scenario_runtime, [2]},
    {:finalize!, [0]},
    {:report_path, [0]},
    {:evidence_json_path, [0]},
    {:report_json_path, [0]}
  ]

  defmacro __using__(_opts) do
    delegates =
      for {name, arities} <- @delegates,
          arity <- arities do
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          defdelegate unquote(name)(unquote_splicing(args)),
            to: AcceptanceHarness.Evidence
        end
      end

    quote do
      (unquote_splicing(delegates))
    end
  end
end
