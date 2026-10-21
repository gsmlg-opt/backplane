defmodule Backplane.Memory.LLMTest do
  use ExUnit.Case, async: false

  alias Backplane.Memory.LLM

  setup do
    setting = :ets.lookup(:backplane_settings, "memory.llm_model")
    req_options = Application.get_env(:backplane_memory, :llm_req_options)

    :ets.insert(:backplane_settings, {"memory.llm_model", "test-model"})
    Application.put_env(:backplane_memory, :llm_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      :ets.delete(:backplane_settings, "memory.llm_model")
      if setting != [], do: :ets.insert(:backplane_settings, setting)

      if req_options do
        Application.put_env(:backplane_memory, :llm_req_options, req_options)
      else
        Application.delete_env(:backplane_memory, :llm_req_options)
      end
    end)

    :ok
  end

  @tag :graph_schema
  test "graph extraction requests bounded filtered source text and validates entity references" do
    response = %{
      "nodes" => [
        %{"key" => "gateway", "type" => "Module", "name" => "Backplane"},
        %{"key" => "database", "type" => "Library", "name" => "PostgreSQL"}
      ],
      "edges" => [%{"source" => "gateway", "target" => "database", "relation" => "uses"}]
    }

    Req.Test.stub(__MODULE__, fn conn ->
      assert LLM.capture_suppressed?()
      assert Plug.Conn.get_req_header(conn, "x-backplane-memory-origin") == ["graph"]
      assert Plug.Conn.get_req_header(conn, "x-backplane-memory-capture") == ["skip"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["model"] == "test-model"

      assert request["response_format"] == %{
               "type" => "json_schema",
               "json_schema" => %{
                 "name" => "memory_graph",
                 "strict" => true,
                 "schema" => %{
                   "type" => "object",
                   "required" => ["nodes", "edges"],
                   "additionalProperties" => false,
                   "properties" => %{
                     "nodes" => %{
                       "type" => "array",
                       "items" => %{
                         "type" => "object",
                         "required" => ["key", "type", "name"],
                         "additionalProperties" => false,
                         "properties" => %{
                           "key" => %{"type" => "string"},
                           "type" => %{
                             "type" => "string",
                             "enum" =>
                               ~w(File Function Module Library Concept Decision Bug Pattern Person)
                           },
                           "name" => %{"type" => "string"}
                         }
                       }
                     },
                     "edges" => %{
                       "type" => "array",
                       "items" => %{
                         "type" => "object",
                         "required" => ["source", "target", "relation"],
                         "additionalProperties" => false,
                         "properties" => %{
                           "source" => %{"type" => "string"},
                           "target" => %{"type" => "string"},
                           "relation" => %{
                             "type" => "string",
                             "enum" =>
                               ~w(uses imports calls depends_on tests documents caused_by supersedes relates_to)
                           }
                         }
                       }
                     }
                   }
                 }
               }
             }

      assert [%{"content" => prompt}] = request["messages"]
      assert prompt =~ "Backplane uses PostgreSQL"
      refute prompt =~ "private-secret"
      assert byte_size(prompt) <= 80_000

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(response)}}]
      })
    end)

    assert {:ok, %{nodes: [gateway, database], edges: [edge]}} =
             LLM.extract_graph(["Backplane uses PostgreSQL <private>private-secret</private>"])

    assert gateway == %{key: "gateway", type: "Module", name: "Backplane"}
    assert database == %{key: "database", type: "Library", name: "PostgreSQL"}
    assert edge == %{source: "gateway", target: "database", relation: "uses"}
    refute LLM.capture_suppressed?()
  end

  test "graph extraction rejects invalid shapes, unsupported types and unknown references" do
    node = %{"key" => "a", "type" => "Concept", "name" => "Gateway"}

    for {response, reason} <- [
          {%{"nodes" => [], "edges" => []}, :nodes_count},
          {%{"nodes" => [Map.put(node, "type", "private-model-value")], "edges" => []},
           :node_type},
          {%{"nodes" => [node, node], "edges" => []}, :node_key_duplicate},
          {%{
             "nodes" => [node],
             "edges" => [
               %{"source" => "a", "target" => "private-model-value", "relation" => "uses"}
             ]
           }, :edge_target_reference},
          {%{"nodes" => [node], "edges" => [], "unexpected" => "private-model-value"},
           :graph_fields},
          {%{"nodes" => [Map.put(node, "key", "")], "edges" => []}, :node_key},
          {%{"nodes" => [Map.put(node, "name", "")], "edges" => []}, :node_name},
          {%{"nodes" => [%{"private-model-value" => true}], "edges" => []}, :node_fields},
          {%{"nodes" => [node], "edges" => [%{"private-model-value" => true}]}, :edge_fields},
          {%{
             "nodes" => [node],
             "edges" => [
               %{"source" => "private-model-value", "target" => "a", "relation" => "uses"}
             ]
           }, :edge_source_reference},
          {%{
             "nodes" => [node],
             "edges" => [%{"source" => "a", "target" => "a", "relation" => "private-model-value"}]
           }, :edge_relation},
          {%{"nodes" => [node], "edges" => List.duplicate(%{}, 101)}, :edges_count}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => Jason.encode!(response)}}]
        })
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_graph_response} = LLM.extract_graph(["Gateway"])
        end)

      assert log =~ "Memory graph response rejected: #{reason}"
      refute log =~ "private-model-value"
    end

    assert {:error, :invalid_graph_input} = LLM.extract_graph([%{content: "invalid"}])
    assert {:error, :invalid_graph_input} = LLM.extract_graph(List.duplicate("source", 51))
  end

  test "query expansion makes a real request and retains useful unique alternatives" do
    :ets.insert(:backplane_settings, {"memory.llm_model", " test-model "})

    Req.Test.stub(__MODULE__, fn conn ->
      assert LLM.capture_suppressed?()
      assert Plug.Conn.get_req_header(conn, "x-backplane-memory-origin") == ["query-expansion"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["model"] == "test-model"
      assert request["response_format"] == %{"type" => "json_object"}

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" =>
                Jason.encode!(%{
                  "queries" => [
                    " gateway routing ",
                    "proxy routing",
                    "model dispatch",
                    "proxy routing"
                  ]
                })
            }
          }
        ]
      })
    end)

    assert {:ok, ["gateway routing", "proxy routing", "model dispatch"]} =
             LLM.expand_query("gateway routing")
  end

  test "graph schema rejection surfaces once without an unconstrained fallback" do
    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :graph_schema_request)
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "private provider detail"})
    end)

    assert {:error, {:llm_status, 400}} = LLM.extract_graph(["gateway uses database"])
    assert_received :graph_schema_request
    refute_received :graph_schema_request
  end

  test "graph and expansion surface provider failures and reject malformed or oversized responses" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "private provider detail"})
    end)

    assert {:error, {:llm_status, 503}} = LLM.extract_graph(["gateway uses database"])
    assert {:error, {:llm_status, 503}} = LLM.expand_query("routing")

    for response <- ["not json", ~s({"queries":["routing"]}), ~s({"queries":[1,2,3]})] do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => response}}]})
      end)

      assert {:error, :invalid_query_expansion_response} = LLM.expand_query("routing")
    end

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => String.duplicate("x", 100_001)}}]
      })
    end)

    assert {:error, :graph_response_too_large} = LLM.extract_graph(["source"])
    assert {:error, :query_expansion_response_too_large} = LLM.expand_query("routing")

    assert {:error, :invalid_query_expansion_input} =
             LLM.expand_query(String.duplicate("q", 2_001))
  end

  test "blank and invalid model settings skip all enrichment" do
    for invalid <- [nil, "", " ", 123] do
      :ets.insert(:backplane_settings, {"memory.llm_model", invalid})
      assert {:skip, :no_llm} = LLM.extract_graph(["source"])
      assert {:skip, :no_llm} = LLM.expand_query("routing")
    end
  end

  test "graph and expansion classify transport timeouts without returning provider content" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, {:llm_transport, :timeout}} = LLM.extract_graph(["source"])
    assert {:error, {:llm_transport, :timeout}} = LLM.expand_query("routing")
  end

  test "classify_relation uses the proxy chat completion and parses a strict JSON object" do
    secret = "sk-abcdefghijklmnopqrstuvwxyz"
    stable_id = "11111111-2222-3333-4444-555555555555"
    straddling_secret = String.duplicate("x", 85) <> secret
    private_secret_prefix = "boundary-secret-prefix"

    private_secret_body =
      private_secret_prefix <>
        String.duplicate("z", 500 - String.length(private_secret_prefix))

    straddling_private =
      String.duplicate("x", 85) <> "<private>" <> private_secret_body <> "</private>"

    Req.Test.stub(__MODULE__, fn conn ->
      assert LLM.capture_suppressed?()
      assert Plug.Conn.get_req_header(conn, "x-backplane-memory-origin") == ["relation"]
      assert Plug.Conn.get_req_header(conn, "x-backplane-memory-capture") == ["skip"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["response_format"] == %{
               "type" => "json_schema",
               "json_schema" => %{
                 "name" => "memory_relation",
                 "strict" => true,
                 "schema" => %{
                   "type" => "object",
                   "required" => ["classification", "confidence"],
                   "additionalProperties" => false,
                   "properties" => %{
                     "classification" => %{
                       "type" => "string",
                       "enum" =>
                         ~w(duplicate extension temporal_replacement contradiction unrelated)
                     },
                     "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
                   }
                 }
               }
             }

      assert request["model"] == "test-model"
      assert [%{"content" => prompt, "role" => "user"}] = request["messages"]
      assert byte_size(prompt) <= 12_000
      assert prompt =~ ~s("content":"filtered source memory")
      assert prompt =~ ~s("evidence_kind":"supports")
      assert prompt =~ "[REDACTED]"
      refute prompt =~ "sk-"
      refute prompt =~ "<private>"
      refute prompt =~ String.slice(private_secret_prefix, 0, 6)
      refute prompt =~ secret
      refute prompt =~ stable_id
      refute prompt =~ "agent-private-123"
      refute prompt =~ "host-private-123"
      refute prompt =~ "session-private-123"
      refute prompt =~ "11111111-1111-1111-1111-111111111111"

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" => Jason.encode!(%{"classification" => "extension", "confidence" => 0.75})
            }
          }
        ]
      })
    end)

    assert {:ok, %{"classification" => "extension", "confidence" => 0.75}} =
             LLM.classify_relation(
               %{
                 "id" => stable_id,
                 "content" => "filtered source memory",
                 "claim" => %{
                   "subject" => "backplane #{secret}",
                   "predicate" => "uses",
                   "value" => "api_key=#{secret}",
                   "cardinality" => "single"
                 },
                 "entities" => [
                   straddling_secret,
                   straddling_private,
                   "backplane #{secret}"
                 ],
                 "valid_from" => "token=#{secret}",
                 "evidence" => [
                   %{
                     "evidence_kind" => "supports",
                     "agent_id" => "agent-private-123",
                     "host_id" => "host-private-123",
                     "session_id" => "session-private-123",
                     "source_event_id" => "11111111-1111-1111-1111-111111111111"
                   }
                 ]
               },
               %{
                 "content" => "filtered target memory",
                 "claim" => nil,
                 "entities" => ["backplane"],
                 "evidence" => []
               }
             )
  end

  test "relation classification retains strict response validation and provider errors" do
    invalid = [
      "not json",
      "```json\n{\"classification\":\"duplicate\",\"confidence\":1}\n```",
      ~s({"classification":"duplicate","confidence":1,"extra":true}),
      ~s({"classification":"duplicate"}),
      ~s({"classification":"unknown","confidence":1}),
      ~s({"classification":"duplicate","confidence":"1"}),
      ~s({"classification":"duplicate","confidence":-0.1}),
      ~s({"classification":"duplicate","confidence":1.1}),
      ~s([{"classification":"duplicate","confidence":1}])
    ]

    for content <- invalid do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => content}}]})
      end)

      assert {:error, :invalid_classifier_response} = LLM.classify_relation(%{}, %{})
    end

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"choices" => []}) end)
    assert {:error, :invalid_classifier_response} = LLM.classify_relation(%{}, %{})

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 503, "private provider error")
    end)

    assert {:error, {:llm_status, 503}} = LLM.classify_relation(%{}, %{})

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, %Req.TransportError{reason: :timeout}} = LLM.classify_relation(%{}, %{})
    refute LLM.capture_suppressed?()
  end

  test "relation classification accepts every supported enum and confidence endpoints" do
    for classification <- ~w(duplicate extension temporal_replacement contradiction unrelated),
        confidence <- [0, 1] do
      expected = %{"classification" => classification, "confidence" => confidence}

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => Jason.encode!(expected)}}]
        })
      end)

      assert {:ok, ^expected} = LLM.classify_relation(%{}, %{})
    end
  end

  test "crystallize accepts only the strict bounded structured object" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert LLM.capture_suppressed?()
      assert Plug.Conn.get_req_header(conn, "x-backplane-memory-origin") == ["crystal"]
      assert Plug.Conn.get_req_header(conn, "x-backplane-memory-capture") == ["skip"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["response_format"] == %{"type" => "json_object"}
      [%{"content" => prompt}] = request["messages"]
      assert prompt =~ "verified outcomes and explicitly accepted decisions"
      assert prompt =~ "historical error alone"
      assert prompt =~ "Use empty arrays"
      assert byte_size(prompt) <= 80_000
      refute prompt =~ "<private>"

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(crystal_payload())}}]
      })
    end)

    assert {:ok, %{"title" => "Crystal"}, "test-model"} =
             LLM.crystallize(crystal_input())

    refute LLM.capture_suppressed?()
  end

  test "crystallize restores recursive capture suppression when the provider raises" do
    Req.Test.stub(__MODULE__, fn _conn ->
      assert LLM.capture_suppressed?()
      raise "provider exploded"
    end)

    assert_raise RuntimeError, "provider exploded", fn -> LLM.crystallize(crystal_input()) end
    refute LLM.capture_suppressed?()
  end

  test "crystallize classifies non-200, malformed, missing, wrong, and oversized responses" do
    for {response, expected} <- [
          {{503, %{"error" => "private"}}, {:error, {:llm_status, 503}}},
          {{200, %{"choices" => [%{"message" => %{"content" => "{"}}]}},
           {:error, :invalid_crystal_response}},
          {{200,
            %{
              "choices" => [
                %{
                  "message" => %{
                    "content" => Jason.encode!(Map.delete(crystal_payload(), "title"))
                  }
                }
              ]
            }}, {:error, :invalid_crystal_response}},
          {{200,
            %{
              "choices" => [
                %{
                  "message" => %{
                    "content" => Jason.encode!(Map.put(crystal_payload(), "decisions", "wrong"))
                  }
                }
              ]
            }}, {:error, :invalid_crystal_response}},
          {{200,
            %{"choices" => [%{"message" => %{"content" => String.duplicate("x", 100_001)}}]}},
           {:error, :crystal_response_too_large}}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        {status, body} = response
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end)

      assert LLM.crystallize(crystal_input()) == expected
    end
  end

  defp crystal_input do
    %{
      summary: %{content: "safe <private>secret</private>"},
      fallback: %{
        title: "Fallback",
        narrative: "Fallback narrative",
        key_outcomes: [],
        decisions: [],
        files_affected: [],
        unresolved_items: []
      }
    }
  end

  defp crystal_payload do
    %{
      "title" => "Crystal",
      "narrative" => "Narrative",
      "key_outcomes" => [],
      "decisions" => [],
      "files_affected" => [],
      "unresolved_items" => []
    }
  end

  test "descriptor fields are bounded before encoding and remain valid JSON" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [%{"content" => prompt}] = Jason.decode!(body)["messages"]
      [_, source_json, target_json] = Regex.run(~r/Source: (.*)\nTarget: (.*)\n/s, prompt)
      source = Jason.decode!(source_json)
      target = Jason.decode!(target_json)

      assert String.length(source["content"]) == 2_000
      assert length(source["entities"]) == 20
      assert Enum.all?(source["entities"], &(String.length(&1) <= 100))
      assert length(source["evidence"]) == 10
      assert String.length(target["content"]) == 2_000

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" => Jason.encode!(%{"classification" => "unrelated", "confidence" => 1.0})
            }
          }
        ]
      })
    end)

    descriptor = %{
      "content" => String.duplicate("x", 10_000),
      "entities" => for(index <- 1..100, do: "#{index}-#{String.duplicate("e", 500)}"),
      "evidence" =>
        for index <- 1..30 do
          %{
            "evidence_kind" => "supports",
            "source_session_id" => "#{index}-#{String.duplicate("s", 500)}"
          }
        end
    }

    assert {:ok, %{"classification" => "unrelated"}} =
             LLM.classify_relation(descriptor, descriptor)
  end

  test "entity and evidence preprocessing inspects only a bounded raw prefix" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [%{"content" => prompt}] = Jason.decode!(body)["messages"]
      [_, source_json, _target_json] = Regex.run(~r/Source: (.*)\nTarget: (.*)\n/s, prompt)
      source = Jason.decode!(source_json)

      assert source["entities"] == Enum.map(1..10, &"entity-#{&1}")

      assert Enum.map(source["evidence"], & &1["support_score"]) ==
               Enum.map(1..5, &(&1 / 100))

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" => Jason.encode!(%{"classification" => "unrelated", "confidence" => 1.0})
            }
          }
        ]
      })
    end)

    descriptor = %{
      "entities" => List.duplicate(nil, 90) ++ Enum.map(1..20, &"entity-#{&1}"),
      "evidence" =>
        List.duplicate(:invalid, 95) ++
          Enum.map(
            1..10,
            &%{"evidence_kind" => "supports", "support_score" => &1 / 100}
          )
    }

    assert {:ok, %{"classification" => "unrelated"}} =
             LLM.classify_relation(descriptor, descriptor)
  end

  test "rerank uses the proxy and parses strict complete token scores" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert LLM.capture_suppressed?()
      assert Plug.Conn.get_req_header(conn, "x-backplane-memory-origin") == ["rerank"]
      assert Plug.Conn.get_req_header(conn, "x-backplane-memory-capture") == ["skip"]
      assert conn.request_path == "/v1/chat/completions"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["model"] == "test-model"
      [%{"content" => prompt}] = request["messages"]
      assert byte_size(prompt) <= 40_000
      assert prompt =~ ~s("memory_type":"semantic")
      refute prompt =~ "host-private"

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{
              "content" =>
                Jason.encode!(%{
                  "rankings" => [
                    %{"token" => 1, "score" => 0.9},
                    %{"token" => 0, "score" => 0.4}
                  ]
                })
            }
          }
        ]
      })
    end)

    descriptors = [
      %{token: 0, kind: "memory", memory_type: "semantic", content: "first"},
      %{token: 1, kind: "lesson", memory_type: "semantic", content: "second"}
    ]

    assert {:ok, [%{token: 1, score: 0.9}, %{token: 0, score: 0.4}]} =
             LLM.rerank("query", descriptors)
  end

  test "fact and procedure extraction suppress recursive capture and restore the guard" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      assert LLM.capture_suppressed?()
      assert Plug.Conn.get_req_header(conn, "x-backplane-memory-capture") == ["skip"]
      [origin] = Plug.Conn.get_req_header(conn, "x-backplane-memory-origin")
      send(parent, {:provider_origin, origin})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => "- first\n2. second"}}]
      })
    end)

    assert {:ok, ["first", "second"]} = LLM.extract_facts("bounded summary")
    assert_receive {:provider_origin, "fact"}
    refute LLM.capture_suppressed?()

    assert {:ok, ["first", "second"]} = LLM.extract_procedures("bounded memories")
    assert_receive {:provider_origin, "procedure"}
    refute LLM.capture_suppressed?()
  end

  test "all provider calls restore recursive capture suppression when the provider raises" do
    Req.Test.stub(__MODULE__, fn _conn ->
      assert LLM.capture_suppressed?()
      raise "provider exploded"
    end)

    assert_raise RuntimeError, "provider exploded", fn ->
      LLM.rerank("query", [%{token: 0, content: "bounded"}])
    end

    refute LLM.capture_suppressed?()
  end

  test "rerank rejects malformed or incomplete proxy responses" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"content" => ~s({"rankings":[{"token":0,"score":2}]})}}
        ]
      })
    end)

    assert {:error, :invalid_reranker_response} =
             LLM.rerank("query", [
               %{token: 0, kind: "memory", memory_type: "semantic", content: "first"}
             ])
  end

  test "rerank surfaces non-200 and enforces candidate and prompt caps" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "private"})
    end)

    descriptor = %{token: 0, kind: "memory", memory_type: "semantic", content: "first"}
    assert {:error, {:llm_status, 503}} = LLM.rerank("query", [descriptor])

    assert {:error, :too_many_reranker_candidates} =
             LLM.rerank("query", List.duplicate(descriptor, 501))

    assert {:error, :reranker_payload_too_large} =
             LLM.rerank(String.duplicate("q", 40_001), [descriptor])
  end
end
