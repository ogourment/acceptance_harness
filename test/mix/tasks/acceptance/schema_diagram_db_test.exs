defmodule Mix.Tasks.Acceptance.SchemaDiagramDbTest do
  use ExUnit.Case, async: false

  @moduletag :db

  alias AcceptanceHarness.TestRepo
  alias Mix.Tasks.Acceptance.SchemaDiagram

  test "pairs composite foreign keys backed by a standalone unique index" do
    with_schema(fn schema ->
      sql!("CREATE TABLE #{schema}.cards (id integer PRIMARY KEY, project_id integer NOT NULL)")
      sql!("CREATE UNIQUE INDEX cards_project_key ON #{schema}.cards (id, project_id)")

      sql!("""
      CREATE TABLE #{schema}.connections (
        source_item_id integer,
        project_id integer,
        FOREIGN KEY (source_item_id, project_id) REFERENCES #{schema}.cards (id, project_id)
      )
      """)

      assert SchemaDiagram.fetch_foreign_keys(TestRepo, [schema]) == [
               relationship(schema, "connections", "project_id", "cards", "project_id"),
               relationship(schema, "connections", "source_item_id", "cards", "id")
             ]
    end)
  end

  test "keeps single-column foreign keys distinct when constraint names are reused" do
    with_schema(fn schema ->
      sql!("CREATE TABLE #{schema}.users (id integer PRIMARY KEY)")
      sql!("CREATE TABLE #{schema}.projects (id integer PRIMARY KEY)")

      sql!("""
      CREATE TABLE #{schema}.members (
        user_id integer CONSTRAINT shared_reference REFERENCES #{schema}.users (id)
      )
      """)

      sql!("""
      CREATE TABLE #{schema}.cards (
        project_id integer CONSTRAINT shared_reference REFERENCES #{schema}.projects (id)
      )
      """)

      assert SchemaDiagram.fetch_foreign_keys(TestRepo, [schema]) == [
               relationship(schema, "cards", "project_id", "projects", "id"),
               relationship(schema, "members", "user_id", "users", "id")
             ]
    end)
  end

  defp with_schema(fun) do
    schema = "harness_fk_#{System.unique_integer([:positive, :monotonic])}"

    assert {:error, :verified} =
             TestRepo.transaction(fn ->
               sql!("CREATE SCHEMA #{schema}")
               fun.(schema)
               TestRepo.rollback(:verified)
             end)
  end

  defp sql!(statement), do: Ecto.Adapters.SQL.query!(TestRepo, statement, [])

  defp relationship(schema, table, column, foreign_table, foreign_column) do
    %{
      schema: schema,
      table: table,
      column: column,
      foreign_schema: schema,
      foreign_table: foreign_table,
      foreign_column: foreign_column
    }
  end
end
