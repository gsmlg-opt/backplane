defmodule Backplane.Memory.Operations.ParamsTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.Operations.Params

  describe "timeline/1" do
    test "accepts atom and string keys, trims strings, and omits blank values" do
      assert {:ok, %{values: values, query: query}} =
               Params.timeline(%{
                 "agent" => " agent-1 ",
                 "tool" => nil,
                 "limit" => "50",
                 project: "  alpha  ",
                 status: "   "
               })

      assert values == %{project: "alpha", agent: "agent-1", limit: 50}
      assert query == %{"project" => "alpha", "agent" => "agent-1"}

      assert {:ok, %{values: %{project: "beta", limit: 50}}} =
               Params.timeline(project: " beta ")
    end

    test "rejects unknown nonblank keys while retaining valid canonical filters" do
      assert {:error, {:invalid_param, "unknown", %{"project" => "alpha"}}} =
               Params.timeline(%{"unknown" => "value", "project" => " alpha "})

      assert {:error, {:invalid_param, :unknown, %{"project" => "alpha"}}} =
               Params.timeline(project: "alpha", unknown: "value")
    end

    test "normalizes numeric limits with default 50 and cap 100" do
      assert {:ok, %{values: %{limit: 50}, query: %{}}} = Params.timeline(%{})

      assert {:ok, %{values: %{limit: 50}, query: %{}}} =
               Params.timeline(%{"limit" => "50"})

      for limit <- [101, 500, "101", "500"] do
        assert {:ok, %{values: %{limit: 100}, query: %{"limit" => "100"}}} =
                 Params.timeline(%{"limit" => limit})
      end

      for invalid <- [0, -1, "0", "-1", "1.5", 1.5] do
        assert {:error, {:invalid_param, :limit, %{"project" => "alpha"}}} =
                 Params.timeline(%{"project" => "alpha", "limit" => invalid})
      end
    end

    test "normalizes full ISO-8601 and datetime-local timestamps to canonical UTC" do
      cases = [
        {"2026-07-17T18:11:12+08:00", ~U[2026-07-17 10:11:12Z], "2026-07-17T10:11:12Z"},
        {"2026-07-17T10:11", ~U[2026-07-17 10:11:00Z], "2026-07-17T10:11:00Z"},
        {"2026-07-17T10:11:12", ~U[2026-07-17 10:11:12Z], "2026-07-17T10:11:12Z"},
        {"2026-07-17T10:11:12.123456", ~U[2026-07-17 10:11:12.123456Z],
         "2026-07-17T10:11:12.123456Z"}
      ]

      for {input, expected, canonical} <- cases do
        assert {:ok, %{values: %{from: ^expected}, query: %{"from" => ^canonical}}} =
                 Params.timeline(%{"from" => input})
      end
    end

    test "rejects invalid timestamps and keeps other canonical values" do
      for key <- ["from", "to"] do
        expected_key = String.to_atom(key)

        assert {:error, {:invalid_param, ^expected_key, %{"project" => "alpha"}}} =
                 Params.timeline(%{key => "not-a-time", "project" => "alpha"})
      end
    end

    test "rejects non-map and non-keyword input" do
      for invalid <- [nil, "filters", [1, 2], [{:project, "alpha"}, "bad"]] do
        assert {:error, {:invalid_param, :filters, %{}}} = Params.timeline(invalid)
      end
    end
  end

  describe "streams/1" do
    test "restricts state to open or closed" do
      for state <- ["open", "closed"] do
        assert {:ok,
                %{
                  values: %{state: ^state, limit: 50},
                  query: %{"state" => ^state}
                }} = Params.streams(%{"state" => state})
      end

      assert {:error, {:invalid_param, :state, %{"project" => "alpha"}}} =
               Params.streams(%{"state" => "all", "project" => "alpha"})
    end

    test "canonical query uses string keys and omits blanks and the default limit" do
      assert {:ok,
              %{
                values: %{host: "host-1", limit: 50},
                query: %{"host" => "host-1"}
              }} =
               Params.streams(%{
                 "agent" => " ",
                 "cursor" => nil,
                 "limit" => "50",
                 host: " host-1 "
               })
    end
  end

  describe "sequence/1" do
    test "accepts positive before or after anchors and caps limits at 100" do
      assert {:ok,
              %{
                values: %{before: 10, limit: 100},
                query: %{"before" => "10"}
              }} = Params.sequence(%{"before" => "10", "limit" => "500"})

      assert {:ok,
              %{
                values: %{after: 4, limit: 25},
                query: %{"after" => "4", "limit" => "25"}
              }} = Params.sequence(after: 4, limit: 25)

      for invalid <- [0, -1, "0", "-1", "1.5", 1.5] do
        assert {:error, {:invalid_param, :before, %{}}} =
                 Params.sequence(%{"before" => invalid})
      end
    end

    test "before and after are mutually exclusive with a canonical before query" do
      assert {:error, {:invalid_param, :after, %{"before" => "10"}}} =
               Params.sequence(%{"before" => "10", "after" => "20"})
    end
  end
end
