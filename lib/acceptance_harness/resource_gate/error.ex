defmodule AcceptanceHarness.ResourceGate.Error do
  @moduledoc false
  defexception [:message, :status, reasons: []]
end
