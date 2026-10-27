# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.UuidRefCastTest do
  @moduledoc """
  A bare uuid column compared with a uuid value must not be wrapped in `CAST(col AS TEXT)`:
  the cast is a no-op for the stored value, but it stops SQLite from using any index on the
  column, so primary key lookups and foreign key filters become full table scans.
  """
  use AshSqlite.RepoCase, async: false
  alias AshSqlite.Test.{Author, Comment, Post}

  require Ash.Query

  defp sql(query) do
    {:ok, data_layer_query} = Ash.Query.data_layer_query(query)
    Ecto.Adapters.SQL.to_sql(:all, AshSqlite.TestRepo, data_layer_query)
  end

  defp plan({sql, params}) do
    %{rows: rows} = AshSqlite.TestRepo.query!("EXPLAIN QUERY PLAN " <> sql, params)
    Enum.map_join(rows, "\n", &List.last/1)
  end

  defp create_post!(attrs \\ %{}) do
    Post
    |> Ash.Changeset.for_create(:create, Map.merge(%{title: "title"}, attrs))
    |> Ash.create!()
  end

  describe "generated SQL" do
    test "a primary key equality does not cast the column and uses the primary key index" do
      id = Ash.UUID.generate()
      {sql, _params} = query = sql(Ash.Query.filter(Post, id == ^id))

      refute sql =~ ~s|CAST(p0."id"|
      assert plan(query) =~ "USING INDEX"
    end

    test "a foreign key equality does not cast the column" do
      post_id = Ash.UUID.generate()
      {sql, _params} = sql(Ash.Query.filter(Comment, post_id == ^post_id))

      refute sql =~ ~s|CAST(c0."post_id"|
    end

    test "a related uuid column in a filter path does not cast the column" do
      author_id = Ash.UUID.generate()
      {sql, _params} = sql(Ash.Query.filter(Comment, post.author_id == ^author_id))

      refute sql =~ ~r/CAST\(\w+\."author_id"/
    end

    test "Ash.get by primary key uses the primary key index" do
      id = Ash.UUID.generate()

      query =
        Post
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.limit(1)
        |> sql()

      refute plan(query) =~ ~r/^SCAN p0$/m
    end
  end

  describe "results are unchanged" do
    test "equality, inequality and in on the primary key" do
      %{id: id} = create_post!()
      %{id: other_id} = create_post!()

      assert {:ok, %Post{id: ^id}} = Ash.get(Post, id)
      assert [%Post{id: ^id}] = Post |> Ash.Query.filter(id == ^id) |> Ash.read!()
      assert [%Post{id: ^other_id}] = Post |> Ash.Query.filter(id != ^id) |> Ash.read!()

      assert [_, _] = Post |> Ash.Query.filter(id in ^[id, other_id]) |> Ash.read!()
      assert [] = Post |> Ash.Query.filter(id == ^Ash.UUID.generate()) |> Ash.read!()
    end

    test "an uppercase uuid input still matches" do
      %{id: id} = create_post!()

      assert [%Post{id: ^id}] =
               Post |> Ash.Query.filter(id == ^String.upcase(id)) |> Ash.read!()
    end

    test "foreign keys, nil checks and relationship paths" do
      author =
        Author
        |> Ash.Changeset.for_create(:create, %{first_name: "a"})
        |> Ash.create!()

      %{id: post_id} = post = create_post!(%{author_id: author.id})
      %{id: lonely_id} = create_post!()

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "c"})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      assert [%Post{id: ^post_id}] =
               Post |> Ash.Query.filter(author_id == ^author.id) |> Ash.read!()

      assert [%Post{id: ^lonely_id}] =
               Post |> Ash.Query.filter(is_nil(author_id)) |> Ash.read!()

      assert [%Comment{post_id: ^post_id}] =
               Comment |> Ash.Query.filter(post.author_id == ^author.id) |> Ash.read!()

      assert [%Post{id: ^post_id}] =
               Post |> Ash.Query.filter(exists(comments, post_id == ^post_id)) |> Ash.read!()
    end

    test "comparing two uuid columns" do
      author =
        Author
        |> Ash.Changeset.for_create(:create, %{first_name: "a"})
        |> Ash.create!()

      post = create_post!(%{author_id: author.id})

      Comment
      |> Ash.Changeset.for_create(:create, %{title: "c", author_id: author.id})
      |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
      |> Ash.create!()

      assert [%Comment{}] =
               Comment |> Ash.Query.filter(author_id == post.author_id) |> Ash.read!()
    end
  end
end
