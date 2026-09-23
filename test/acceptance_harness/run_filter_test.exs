defmodule AcceptanceHarnessWeb.RunFilterTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarnessWeb.RunFilter

  test "parses the filter JSON query param and drops blanks and unknown keys" do
    params = %{
      "filter" =>
        Jason.encode!(%{
          "device" => "Mobile",
          "q" => " passport ",
          "tag" => "",
          "bogus" => "x",
          "status" => "todo"
        })
    }

    assert RunFilter.parse(params) == %{
             "device" => "Mobile",
             "q" => "passport"
           }
  end

  test "parse tolerates missing or malformed filter params" do
    assert RunFilter.parse(%{}) == %{}
    assert RunFilter.parse(%{"filter" => "not json"}) == %{}
    assert RunFilter.parse(%{"filter" => "[1,2]"}) == %{}
  end

  test "encode round-trips through parse and empty filters produce no param" do
    filter = %{"language" => "Français", "q" => "session"}

    assert %{"filter" => RunFilter.encode(filter)} |> RunFilter.parse() == filter
    assert RunFilter.encode(%{}) == nil
  end

  test "to_store_opts maps supported filters and ignores retired work status" do
    opts =
      RunFilter.to_store_opts(%{
        "stream" => "participants",
        "capability" => "registration",
        "status" => "todo",
        "q" => "pay",
        "user" => "alice"
      })

    assert Keyword.equal?(opts,
             value_stream: "participants",
             capability: "registration",
             search: "pay",
             user: "alice"
           )
  end
end
