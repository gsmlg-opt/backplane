defmodule Backplane.DiagnosticsClient.Envelope do
  @moduledoc "Validates immutable diagnostics v1 events and their transport identities."

  alias Backplane.DiagnosticsClient.Canonical

  @id {:text, 128}
  @label {:text, 128}
  @sha {:pattern, 64, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/}
  @relative_path {:pattern, 512, ~r/\A(?!\/)(?!.*(?:\A|\/)\.\.(?:\/|\z))[^\\:\x00-\x1f]+\z/}
  @u53 {:int, 0, 9_007_199_254_740_991}
  @positive_u53 {:int, 1, 9_007_199_254_740_991}
  @error_class {:enum,
                ~w(software_defect upstream_failure environment_failure configuration_or_compatibility
                   expected_control_flow agent_quality unknown)}
  @event_type {:enum,
               ~w(exception handled_error worker_exit run_started run_progress run_waiting run_finished
                  provider_attempt tool_attempt handoff process_exit service_restart resource_sample
                  log_error crash_artifact collector_health source_gap contract_check user_feedback)}
  @outcome {:enum, ~w(success failure cancelled rejected waiting unknown_outcome)}
  @certainty {:enum, ~w(observed inferred insufficient_evidence unknown)}
  @availability {:enum, ~w(available unavailable truncated redacted)}
  @trace_id {:pattern, 32, ~r/\A(?!0{32}\z)[0-9a-f]{32}\z/}
  @span_id {:pattern, 16, ~r/\A(?!0{16}\z)[0-9a-f]{16}\z/}
  @frame {:object, [],
          %{
            "module" => @label,
            "function" => @label,
            "arity" => {:int, 0, 255},
            "file" => @relative_path,
            "line" => @positive_u53
          }}
  @breadcrumb {:object, ["kind"],
               %{
                 "kind" => @label,
                 "occurred_at" => :timestamp,
                 "reference" => @id,
                 "outcome" => @outcome,
                 "summary" => {:text, 256}
               }}
  @measurement {:object, ["name", "value"],
                %{
                  "name" => @label,
                  "value" => {:decimal, 64},
                  "unit" => {:text, 32}
                }}
  @schema {:object,
           ~w(schema_version event_type event_id source_id producer_epoch source_sequence application occurred_at quality),
           %{
             "schema_version" => {:int, 1, 1},
             "event_type" => @event_type,
             "event_id" => @id,
             "source_id" => @id,
             "producer_epoch" => @id,
             "source_sequence" => @positive_u53,
             "application" => @label,
             "service_instance" => @id,
             "occurred_at" => :timestamp,
             "duration_us" => @u53,
             "version" =>
               {:object, [],
                %{
                  "repository" => {:text, 256},
                  "git_sha" => @sha,
                  "release" => @label,
                  "runtime" => @label,
                  "adapter" => @label,
                  "config_digest" => {:pattern, 64, ~r/\A[0-9a-f]{64}\z/}
                }},
             "subject" =>
               {:object, [],
                Map.new(
                  ~w(session_id run_id turn_id attempt_id tool_invocation_id parent_run_id child_run_id operation_id runtime_id runtime_instance_id),
                  &{&1, @id}
                )
                |> Map.merge(%{
                  "revision" => @u53,
                  "generation" => @u53,
                  "native_sequence" => @u53
                })},
             "correlation" =>
               {:object, [],
                %{
                  "trace_id" => @trace_id,
                  "span_id" => @span_id,
                  "parent_span_id" => @span_id,
                  "request_id" => @id,
                  "correlation_id" => @id,
                  "causation_id" => @id,
                  "occurrence_hint" => @id,
                  "process_instance" => @id,
                  "links" =>
                    {:list, 8,
                     {:object, ~w(trace_id span_id),
                      %{"trace_id" => @trace_id, "span_id" => @span_id}}}
                }},
             "result" =>
               {:object, [],
                %{
                  "phase" => @label,
                  "outcome" => @outcome,
                  "deadline_at" => :timestamp,
                  "last_progress_at" => :timestamp,
                  "wait_kind" => @label,
                  "workload" => @label,
                  "reason_code" => @label,
                  "error_class" => @error_class,
                  "retryable" => :boolean,
                  "certainty" => @certainty
                }},
             "evidence" =>
               {:object, [],
                %{
                  "exception" =>
                    {:object, [],
                     %{
                       "type" => @label,
                       "code" => @label,
                       "message" => {:text, 1024},
                       "stack" => {:list, 24, @frame}
                     }},
                  "breadcrumbs" => {:list, 16, @breadcrumb},
                  "measurements" => {:list, 16, @measurement},
                  "references" => {:list, 8, @id},
                  "contract" =>
                    {:object, ~w(rule revision expected actual),
                     %{
                       "rule" => @label,
                       "revision" => @label,
                       "expected" => {:text, 256},
                       "actual" => {:text, 256}
                     }}
                }},
             "quality" =>
               {:object, ["redaction_policy_version"],
                %{
                  "redaction_policy_version" => {:int, 1, 65_535},
                  "sampled" => :boolean,
                  "truncated" => :boolean,
                  "source_gap" => @positive_u53,
                  "stack" => @availability,
                  "origin" => {:enum, ~w(application host diagnostics)},
                  "usage_status" => {:enum, ~w(reported derived estimated unknown)}
                }}
           }}

  @spec validate(term()) :: :ok | {:error, :invalid_event | :unsupported_schema}
  def validate(%{"schema_version" => version}) when is_integer(version) and version != 1,
    do: {:error, :unsupported_schema}

  def validate(event), do: if(valid?(event, @schema), do: :ok, else: {:error, :invalid_event})

  @spec seal(map()) :: {:ok, binary(), binary()} | {:error, atom()}
  def seal(event) do
    with :ok <- validate(event),
         {:ok, bytes} <- Canonical.encode(event) do
      {:ok, bytes, Canonical.digest(bytes)}
    end
  end

  @doc "Returns the JSON Schema used for v1 compatibility fixtures."
  def schema do
    @schema
    |> json_schema()
    |> Map.merge(%{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "title" => "Backplane Diagnostics event v1"
    })
  end

  def id?(value), do: valid?(value, @id)

  @doc false
  def project(event, text_fun) do
    project_value(event, @schema, nil, text_fun)
  end

  defp project_value(value, {:object, _, properties}, _, text_fun)
       when is_map(value) and not is_struct(value) do
    Enum.reduce(properties, %{}, fn {key, spec}, acc ->
      case Map.fetch(value, key) do
        {:ok, nested} ->
          case project_value(nested, spec, key, text_fun) do
            :omit -> acc
            projected -> Map.put(acc, key, projected)
          end

        :error ->
          acc
      end
    end)
  end

  defp project_value(value, {:list, max, spec}, key, text_fun) when is_list(value) do
    value
    |> Enum.take(max)
    |> Enum.map(&project_value(&1, spec, key, text_fun))
    |> Enum.reject(&(&1 == :omit))
  end

  defp project_value(value, {:text, max}, key, text_fun) when is_binary(value),
    do: text_fun.(value, key, max)

  defp project_value(value, {:pattern, max, _}, key, text_fun) when is_binary(value),
    do: text_fun.(value, key, max)

  defp project_value(value, _, _, _), do: value

  defp valid?(value, {:object, required, properties})
       when is_map(value) and not is_struct(value) do
    map_size(value) <= map_size(properties) and Enum.all?(required, &Map.has_key?(value, &1)) and
      Enum.all?(value, fn {key, nested} -> valid?(nested, Map.get(properties, key)) end)
  end

  defp valid?(value, {:list, max, spec}) when is_list(value) do
    length(Enum.take(value, max + 1)) <= max and Enum.all?(value, &valid?(&1, spec))
  end

  defp valid?(value, {:text, max}) when is_binary(value),
    do:
      byte_size(value) in 1..max and String.valid?(value) and
        :binary.match(value, <<0>>) == :nomatch

  defp valid?(value, {:pattern, max, pattern}),
    do: valid?(value, {:text, max}) and Regex.match?(pattern, value)

  defp valid?(value, {:int, min, max}), do: is_integer(value) and value >= min and value <= max
  defp valid?(value, {:enum, allowed}), do: value in allowed
  defp valid?(value, :boolean), do: is_boolean(value)

  defp valid?(value, :timestamp),
    do: valid?(value, {:text, 32}) and match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid?(value, {:decimal, max}),
    do:
      valid?(value, {:int, -9_007_199_254_740_991, 9_007_199_254_740_991}) or
        valid?(value, {:pattern, max, ~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/})

  defp valid?(_value, _spec), do: false

  defp json_schema({:object, required, properties}) do
    %{
      "type" => "object",
      "required" => required,
      "additionalProperties" => false,
      "properties" => Map.new(properties, fn {name, spec} -> {name, json_schema(spec)} end)
    }
  end

  defp json_schema({:list, max, spec}),
    do: %{"type" => "array", "maxItems" => max, "items" => json_schema(spec)}

  defp json_schema({:text, max}),
    do: %{"type" => "string", "minLength" => 1, "maxLength" => max, "x-maxBytes" => max}

  defp json_schema({:pattern, max, pattern}) do
    Map.put(
      json_schema({:text, max}),
      "pattern",
      pattern
      |> Regex.source()
      |> String.replace("\\A", "^")
      |> String.replace("\\z", "$(?![\\s\\S])")
    )
  end

  defp json_schema({:int, min, max}),
    do: %{"type" => "integer", "minimum" => min, "maximum" => max}

  defp json_schema({:enum, values}), do: %{"enum" => values}
  defp json_schema(:boolean), do: %{"type" => "boolean"}
  defp json_schema(:timestamp), do: Map.put(json_schema({:text, 32}), "format", "date-time")

  defp json_schema({:decimal, max}) do
    %{
      "anyOf" => [
        json_schema({:int, -9_007_199_254_740_991, 9_007_199_254_740_991}),
        json_schema({:pattern, max, ~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/})
      ]
    }
  end
end
