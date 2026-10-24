defmodule Backplane.AgentRuntime.CodexToolSearchTest do
  use ExUnit.Case, async: true
  alias Backplane.AgentRuntime.{Error, Codex.Contract, Codex.Dynamic, Codex.ToolSearch}

  defmodule Backend do
    def execute(arguments), do: {:ok, arguments}
  end

  @fixtures Path.expand("../../fixtures/tool_search", __DIR__)
  for file <- Path.wildcard(Path.join(@fixtures, "*.json")) do
    @fixture JSON.decode!(File.read!(file))
    test "pinned oracle #{Path.basename(file)}" do
      fixture = @fixture
      documents = fixture["expected"]["documents"]

      if contracts = fixture["input"]["contracts"] do
        Enum.zip(contracts, documents)
        |> Enum.each(fn {attrs, document} ->
          attrs = Map.put(attrs, :metadata, Map.get(attrs, "metadata", %{}))

          assert {:ok, contract} =
                   Contract.new(
                     Map.put(attrs, "safety", %{
                       "read_only" => true,
                       "retry_safe" => true,
                       "parallel_safe" => true
                     })
                   )

          assert {:ok, text} = ToolSearch.text(contract)
          assert text == document["text"]
        end)
      end

      for document <- documents do
        assert ToolSearch.transliterate(document["text"]) == document["normalized"]
        actual = ToolSearch.tokens(document["text"])
        assert actual == document["tokens"], "token mismatch for #{inspect(document["text"])}"
        assert Enum.map(actual, &ToolSearch.hash/1) == document["hashes"]
      end

      corpus =
        documents
        |> Enum.with_index()
        |> Enum.map(fn {doc, id} -> {Integer.to_string(id), doc["text"]} end)

      for query <- fixture["expected"]["queries"] do
        actual = ToolSearch.rank(corpus, query["query"])
        scores = Map.new(actual)

        for %{"id" => id, "score" => expected} <- query["scores"] do
          got = Map.get(scores, Integer.to_string(id), 0.0)

          assert abs(got - expected) <= max(1.0e-7, 4 * ulp(expected)),
                 "score mismatch #{inspect(query["query"])} id=#{id}: #{got} vs #{expected}"
        end

        expected =
          query["scores"]
          |> Enum.filter(&(&1["score"] > 0))
          |> Enum.sort_by(&{-&1["score"], Integer.to_string(&1["id"])})

        assert Enum.map(actual, &elem(&1, 0)) == Enum.map(expected, &Integer.to_string(&1["id"]))
      end
    end
  end

  defp ulp(value) do
    <<bits::unsigned-32>> = <<value::float-32>>
    <<next::float-32>> = <<bits + 1::unsigned-32>>
    next - value
  end

  defp attrs(name, extra \\ %{}),
    do:
      Map.merge(
        %{
          name: name,
          description: "credential lookup",
          backend: Backend,
          schema: %{"type" => "object"},
          safety: %{read_only: true, retry_safe: true, parallel_safe: true}
        },
        extra
      )

  test "schema traversal ignores non-searchable metadata and preserves sorted recursion" do
    assert {:ok, contract} =
             Contract.new(
               attrs("read_key", %{
                 namespace: "vault",
                 metadata: %{"namespace_description" => "  Secure registry  "},
                 backend_context: %{password: "excluded_backend"},
                 output_schema: %{"description" => "excluded_output"},
                 schema: %{
                   "type" => "object",
                   "properties" => %{
                     "z" => %{"type" => "string", "enum" => ["excluded_enum"]},
                     "a" => %{"type" => "string", "description" => "first"}
                   }
                 }
               })
             )

    assert {:ok, "vault Secure registry read_key read key credential lookup a first z"} =
             ToolSearch.text(contract)
  end

  test "custom syntax supports atom keys without underscore expansion and optional absence" do
    assert {:ok, contract} =
             Contract.new(
               attrs("custom_name", %{
                 input_kind: :custom,
                 format: %{syntax: "lark", definition: "excluded"}
               })
             )

    assert {:ok, "custom_name credential lookup lark"} = ToolSearch.text(contract)

    assert {:ok, contract} =
             Contract.new(attrs("text", %{input_kind: :custom, format: %{type: "text"}}))

    assert {:ok, "text credential lookup"} = ToolSearch.text(contract)
  end

  test "atom property names sort as their canonical strings and boolean leaves add no text" do
    assert {:ok, contract} =
             Contract.new(
               attrs("inspect", %{
                 schema: %{
                   type: "object",
                   properties: %{
                     "alpha" => true,
                     zeta: false,
                     secret_key: %{type: "string"},
                     entries: %{type: "array", items: false}
                   }
                 }
               })
             )

    assert {:ok, "inspect inspect credential lookup alpha entries secret_key zeta"} =
             ToolSearch.text(contract)
  end

  test "malformed searchable text returns validation errors" do
    for extra <- [
          %{description: 42},
          %{description: <<255>>},
          %{namespace: "vault", metadata: %{namespace_description: 42}},
          %{input_kind: :custom, format: %{syntax: 42}}
        ] do
      assert {:ok, state} = Dynamic.new()

      assert {:error, %Error{class: :validation}} =
               Dynamic.discover(state, "owner", [attrs("bad", extra)])
    end

    for query <- [nil, 42, %{}, [], "", "  \n", <<255>>] do
      assert {:error, %Error{class: :validation}} = ToolSearch.query(query)
    end
  end

  test "corpus statistics exclude other owners and consumed tools" do
    assert {:ok, state} = Dynamic.new()

    assert {:ok, state, _} =
             Dynamic.discover(state, "a", [
               attrs("alpha"),
               attrs("beta", %{description: "common word"})
             ])

    assert {:ok, other, _} =
             Dynamic.discover(state, "b", [
               attrs("other", %{description: "credential credential credential"})
             ])

    assert Dynamic.search(state, "a", "credential") == Dynamic.search(other, "a", "credential")
    assert {:ok, published, _} = Dynamic.publish(other, "b", "other")

    assert Dynamic.search(state, "a", "credential") ==
             Dynamic.search(published, "a", "credential")

    assert {:ok, consumed, _} = Dynamic.publish(published, "a", "alpha")
    assert {:ok, []} = Dynamic.search(consumed, "a", "credential")
    assert {:ok, []} = Dynamic.search(state, "a", "the and is")
  end
end
