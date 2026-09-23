defmodule AcceptanceHarness.SchemaHistoryTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.SchemaHistory

  test "captures configured overview and domain diagrams as run artifacts" do
    root = tmp_dir("capture")
    evidence_dir = Path.join(root, "evidence")
    domain_dir = Path.join(root, "schema_domains")
    overview = Path.join(root, "schema")
    domains_file = Path.join(root, "domains.exs")

    File.mkdir_p!(domain_dir)
    File.write!(overview <> ".dot", "digraph { users; }")
    File.write!(overview <> ".svg", "<svg>overview</svg>")
    File.write!(Path.join(domain_dir, "identity.dot"), "digraph { users; profiles; }")
    File.write!(Path.join(domain_dir, "identity.svg"), "<svg>identity</svg>")

    File.write!(
      domains_file,
      """
      [%{id: "identity", title: "Identity", tables: ~w(users profiles)}]
      """
    )

    artifacts =
      SchemaHistory.capture!(
        evidence_dir: evidence_dir,
        config: [
          output: overview,
          domains_file: domains_file,
          domains_output: domain_dir
        ]
      )

    assert [
             %{
               "type" => "schema_overview",
               "dot_path" => "schema/overview.dot",
               "path" => "schema/overview.svg"
             },
             %{
               "type" => "schema_domain",
               "domain_id" => "identity",
               "label" => "Identity",
               "dot_path" => "schema/domains/identity.dot",
               "path" => "schema/domains/identity.svg",
               "sha256" => hash
             }
           ] = artifacts

    assert hash == sha256("digraph { users; profiles; }")
    assert File.read!(Path.join(evidence_dir, "schema/overview.svg")) == "<svg>overview</svg>"

    assert File.read!(Path.join(evidence_dir, "schema/domains/identity.dot")) ==
             "digraph { users; profiles; }"
  end

  test "returns no artifacts when schema evidence is not configured" do
    assert SchemaHistory.capture!(config: [], evidence_dir: tmp_dir("unconfigured")) == []
  end

  test "compares only effectively changed domains" do
    previous = [
      domain("identity", "Identity", "old-identity"),
      domain("catalogue", "Catalogue", "stable"),
      domain("removed", "Removed", "old-removed")
    ]

    current = [
      domain("identity", "Identity", "new-identity"),
      domain("catalogue", "Catalogue", "stable"),
      domain("new", "New domain", "new-domain")
    ]

    assert [
             %{domain_id: "identity", label: "Identity", status: "changed"},
             %{domain_id: "new", label: "New domain", status: "new"},
             %{domain_id: "removed", label: "Removed", status: "removed"}
           ] =
             current
             |> SchemaHistory.diff(previous)
             |> Enum.map(&Map.take(&1, [:domain_id, :label, :status]))
  end

  defp domain(id, label, hash) do
    %{
      "type" => "schema_domain",
      "domain_id" => id,
      "label" => label,
      "sha256" => hash,
      "dot_path" => "schema/domains/#{id}.dot",
      "path" => "schema/domains/#{id}.svg"
    }
  end

  defp sha256(contents) do
    :sha256
    |> :crypto.hash(contents)
    |> Base.encode16(case: :lower)
  end

  defp tmp_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "acceptance-schema-history-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end
end
