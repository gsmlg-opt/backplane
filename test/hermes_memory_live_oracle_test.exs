ExUnit.start()
Code.require_file("support/hermes_semantic_oracle.exs", __DIR__)

defmodule Backplane.HermesMemoryLiveOracleTest do
  use ExUnit.Case, async: true
  import Ecto.Query

  alias Backplane.HermesSemanticOracle, as: Oracle

  @historical "The agent initially guessed cobalt as the deployment status color but was mistaken."
  @conditional "Cobalt is an incorrect assumption for deployment status color if amber is specified."
  @possibility "Deployment status colors can include amber and cobalt, but user preference should be confirmed."

  for {content, index} <-
        Enum.with_index([
          @possibility,
          "Deployment status colours may include cobalt and amber, but the user's preference must be confirmed.",
          "Deployment status colors could include cobalt, but user preference should be confirmed.",
          "Deployment status colors might include amber and cobalt, but user preference must be confirmed.",
          @possibility <> " Amber is the correct durable deployment status color for the user.",
          @historical <> " " <> @possibility
        ]) do
    test "generic qualified candidate #{index}" do
      assert Oracle.check(unquote(content), "candidate_inference") == :ok

      for trust <- ["established_fact", nil, "user_confirmed"] do
        assert Oracle.check(unquote(content), trust) ==
                 {:error, "assistant_guess_promoted_to_established_fact"}
      end
    end
  end

  for {content, index} <-
        Enum.with_index([
          "The user's deployment status colors can include amber and cobalt, but user preference should be confirmed.",
          "Deployment status colors include amber and cobalt, but user preference should be confirmed.",
          "Deployment status colors can include amber and cobalt, but user preference is confirmed.",
          "Deployment status colors can include amber and cobalt, but user preference should not be confirmed.",
          "Deployment status colors can include amber and cobalt unless user preference is confirmed.",
          "Deployment status colors can include amber and cobalt, but cobalt is confirmed.",
          "Deployment status colors can include amber and cobalt, but the user's current preference is cobalt.",
          "Deployment status colors can include amber and cobalt, but user preference is unconfirmed.",
          "Deployment status colors can include amber and cobalt, but user preference should be confirmed as cobalt.",
          @possibility <> " The user's current preference is cobalt.",
          @possibility <> " It is the confirmed preference.",
          @possibility <> " The latter is currently preferred.",
          String.trim_trailing(@possibility, ".") <> " and cobalt is correct.",
          "The user may prefer cobalt, but user preference should be confirmed.",
          "The user confirmed cobalt. " <> @possibility,
          "Amber is not correct. " <> @possibility
        ]) do
    test "possibility rejects unsupported claim #{index}" do
      assert Oracle.check(unquote(content), "candidate_inference") ==
               {:error, "derived_current_assistant_guess_not_rejected"}
    end
  end

  for content <- [
        @historical,
        "The assistant previously suggested cobalt, which the user explicitly rejected in favor of amber.",
        "The assistant incorrectly guessed cobalt.",
        "Cobalt was your mistake, not my preference.",
        "The user prefers amber, not cobalt.",
        "Amber is correct, not cobalt. Cobalt was an assistant mistake."
      ] do
    test "qualified history remains a candidate: #{content}" do
      assert Oracle.check(unquote(content), "candidate_inference") == :ok
    end
  end

  for content <- [
        "The user currently prefers cobalt.",
        "Not cobalt was mentioned earlier. The user currently prefers cobalt.",
        "The assistant incorrectly guessed cobalt, but the user currently prefers cobalt.",
        "Cobalt was a mistake and the user currently prefers cobalt.",
        "The user prefers cobalt, not amber.",
        "The user does not prefer amber, but cobalt.",
        "The user does not reject cobalt.",
        "Cobalt was not a mistake.",
        "The assistant did not incorrectly guess cobalt.",
        "The agent initially guessed cobalt as the deployment status color but was not mistaken.",
        "Not not cobalt.",
        @historical <> " The user currently prefers cobalt.",
        "The user prefers amber, not cobalt, and currently prefers cobalt."
      ] do
    test "unqualified or contradictory cobalt is rejected: #{content}" do
      assert Oracle.check(unquote(content), "candidate_inference") ==
               {:error, "derived_current_assistant_guess_not_rejected"}
    end
  end

  test "historical assistant mistake cannot be promoted to an established fact" do
    assert Oracle.check(@historical, "established_fact") ==
             {:error, "assistant_guess_promoted_to_established_fact"}
  end

  for content <- [
        @conditional,
        "Cobalt is an incorrect assumption for deployment status color.",
        "Cobalt was an incorrect assumption for deployment status color.",
        "Cobalt is incorrect for deployment status color if amber is specified.",
        "If amber is specified, cobalt is an incorrect assumption for deployment status color.",
        "When amber is specified, cobalt is an incorrect assumption for deployment status color.",
        @conditional <> " Amber is the correct deployment status color."
      ] do
    test "direct or conditional refutation remains a candidate: #{content}" do
      assert Oracle.check(unquote(content), "candidate_inference") == :ok
    end

    test "direct or conditional refutation cannot establish a fact: #{content}" do
      assert Oracle.check(unquote(content), "established_fact") ==
               {:error, "assistant_guess_promoted_to_established_fact"}
    end
  end

  for content <- [
        "Cobalt is an incorrect assumption for deployment status color and cobalt is the current color.",
        String.trim_trailing(@conditional, ".") <> " and cobalt is the current color.",
        @conditional <> " The user currently prefers cobalt.",
        "Cobalt is an incorrect assumption for deployment status color if amber is not specified.",
        "Cobalt is an incorrect assumption for deployment status color only if amber is not specified.",
        "Cobalt is not an incorrect assumption for deployment status color if amber is specified.",
        "If amber is specified, cobalt is a correct assumption for deployment status color.",
        "If amber is specified, cobalt is an incorrect assumption, but cobalt is the user's current preference.",
        "Cobalt is an incorrect assumption for deployment status color unless amber is specified.",
        "Cobalt is incorrect if amber is specified and cobalt is the current color.",
        @conditional <> " It is the user's current preference.",
        @conditional <> " That color is the user's current preference.",
        "The assistant incorrectly guessed cobalt. It is now the correct color."
      ] do
    test "conditional contradictions, inversions and unresolved pronouns are rejected: #{content}" do
      assert Oracle.check(unquote(content), "candidate_inference") ==
               {:error, "derived_current_assistant_guess_not_rejected"}
    end
  end

  test "amber and unrelated content continue to the existing support and confirmation checks" do
    assert Oracle.check(
             "Amber is the user's durable deployment status color.",
             "candidate_inference"
           ) ==
             :ok

    assert Oracle.check("The weather today is cloudy.", "candidate_inference") == :ok
  end

  test "only a direct amber correction satisfies the separate correction requirement" do
    for content <- [
          "Amber is the correct durable deployment status color for the user.",
          "The user's durable deployment status color is amber.",
          "The user prefers amber, not cobalt.",
          @conditional <> " Amber is the correct deployment status color.",
          @possibility <> " Amber is the correct deployment status color."
        ] do
      assert Oracle.corrected_preference?(content), content
    end

    for content <- [
          @possibility,
          @historical,
          @conditional,
          "Amber may be the user's deployment status color.",
          "Amber is not the user's deployment status color.",
          "The user prefers amber. The user currently prefers cobalt.",
          "Amber is correct. It is not the user's preference."
        ] do
      refute Oracle.corrected_preference?(content), content
    end
  end

  test "normal lineage capture requires an owned new database, host, scope and session" do
    source_path = Path.join(__DIR__, "hermes_memory_live_acceptance.exs")

    {:__block__, _, [{:defmodule, meta, [_name, body]}, _main]} =
      Code.string_to_quoted!(File.read!(source_path))

    runner = Backplane.HermesLiveOracleGuardFixture
    definition = {:defmodule, meta, [runner, body]}

    definition =
      Macro.prewalk(definition, fn
        {:defp, meta, [{name, _, _} = head, body]}
        when name in [:semantic_diagnostic_allowed?, :capture_synthetic_semantic_diagnostic] ->
          {:def, meta, [head, body]}

        node ->
          node
      end)

    Code.eval_quoted(definition, [], file: source_path)
    marker = "0123456789abcdef"
    host = "owned-synthetic-host"
    session = "hermes-live-#{marker}-a"

    memory = %{
      id: "owned-memory",
      host_id: host,
      scope: "hermes_live_#{marker}",
      namespace: "private"
    }

    resources = %{
      marker: marker,
      database_created: true,
      database: "backplane_test_hermeslive_#{marker}",
      host_id: host
    }

    key = {runner, :resources}
    Process.put(key, resources)

    # No diagnostics flag or database is needed to establish this ownership check.
    assert apply(runner, :semantic_diagnostic_allowed?, [memory, host, session])

    for invalid <- [
          Map.put(resources, :database_created, false),
          Map.put(resources, :database, "backplane_dev"),
          Map.put(resources, :host_id, "foreign"),
          Map.delete(resources, :marker)
        ] do
      Process.put(key, invalid)
      refute apply(runner, :semantic_diagnostic_allowed?, [memory, host, session])
      apply(runner, :capture_synthetic_semantic_diagnostic, [memory, host, session])
      assert Process.get({runner, :synthetic_semantic_diagnostics}, []) == []
    end

    Process.put(key, resources)

    for {record, actor, conversation} <- [
          {Map.put(memory, :host_id, "foreign"), host, session},
          {Map.put(memory, :scope, "operator"), host, session},
          {Map.put(memory, :namespace, "team"), host, session},
          {memory, "foreign", session},
          {memory, host, session <> "-other"}
        ] do
      refute apply(runner, :semantic_diagnostic_allowed?, [record, actor, conversation])
      apply(runner, :capture_synthetic_semantic_diagnostic, [record, actor, conversation])
      assert Process.get({runner, :synthetic_semantic_diagnostics}, []) == []
    end
  end

  test "an actual gate query error returns false and prevents prerequisite continuation" do
    source_path = Path.join(__DIR__, "hermes_memory_live_acceptance.exs")
    {:__block__, _, [definition, _main]} = Code.string_to_quoted!(File.read!(source_path))

    # Compile the real runner without its main call. Expose only gate/2 for this
    # isolated error-path check; no application, database or provider is started.
    definition =
      Macro.prewalk(definition, fn
        {:defp, meta, [{:gate, _, _} = head, body]} -> {:def, meta, [head, body]}
        node -> node
      end)

    Code.eval_quoted(definition, [], file: source_path)
    result_key = {Backplane.HermesLiveAcceptance, :results}
    Process.put(result_key, [])

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        result =
          apply(Backplane.HermesLiveAcceptance, :gate, [
            "synthetic_query_error",
            fn -> raise %Ecto.QueryError{message: "synthetic planner failure"} end
          ])

        if result, do: flunk("failed query allowed prerequisite continuation")
        assert result == false
      end)

    assert [%{gate: "synthetic_query_error", status: "failed", details: details}] =
             Process.get(result_key)

    assert details == %{
             code: "exception:Ecto.QueryError",
             message: "synthetic planner failure"
           }

    assert Jason.decode!(String.trim(output))["status"] == "failed"
  end

  test "both exact live provenance queries plan without a database or provider" do
    ast =
      Code.string_to_quoted!(File.read!(Path.join(__DIR__, "hermes_memory_live_acceptance.exs")))

    {_, queries} =
      Macro.prewalk(ast, [], fn node, found ->
        if match?({:from, _, _}, node) and
             Regex.match?(~r/\b(?:e|evidence)\.support_score >/, Macro.to_string(node)) do
          {node, [node | found]}
        else
          {node, found}
        end
      end)

    assert length(queries) == 2

    partition = %{
      memory_space_id: "11111111-1111-1111-1111-111111111111",
      scope: "synthetic",
      namespace: "private"
    }

    for query_ast <- queries do
      aliases = %{
        Event: Backplane.Memory.Events.Event,
        Evidence: Backplane.Memory.Memories.Evidence,
        RememberRequest: Backplane.Memory.Memories.RememberRequest,
        ProjectedSession: Backplane.Memory.Projections.ProjectedSession,
        RequestEvidence: Backplane.Memory.Sources.RequestEvidence,
        SourceEvent: Backplane.Memory.Summaries.SourceEvent,
        Summary: Backplane.Memory.Summaries.Summary
      }

      query_ast =
        Macro.prewalk(query_ast, fn
          {:__aliases__, _, [name]} = node -> Map.get(aliases, name, node)
          node -> node
        end)

      {query, _} =
        Code.eval_quoted(
          query_ast,
          [
            memory: %{id: "22222222-2222-2222-2222-222222222222"},
            partition: partition,
            host_id: "synthetic-host",
            session_id: "synthetic-session"
          ],
          __ENV__
        )

      query =
        query
        |> exclude(:select)
        |> exclude(:preload)
        |> exclude(:distinct)
        |> select(1)
        |> limit(1)

      {planned, _, _} = Ecto.Query.Planner.plan(query, :all, Ecto.Adapters.Postgres)

      assert {%Ecto.Query{}, _} =
               Ecto.Query.Planner.normalize(planned, :all, Ecto.Adapters.Postgres, 0)
    end
  end
end
