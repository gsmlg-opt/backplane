defmodule Backplane.AgentRuntime.Codex.Contract do
  alias Backplane.AgentRuntime.{Error, InputSchema}

  @moduledoc """
  Provider-neutral representation of a Codex callable tool.

  A contract is descriptive only. Execution authority remains in the existing
  registry and `Conversation` admission path; importing a contract never grants
  access to its backend.
  """

  @type input_kind :: :function | :custom

  @type t :: %{
          namespace: String.t() | nil,
          name: String.t(),
          tool_name: String.t(),
          description: String.t(),
          input_kind: input_kind(),
          schema: map() | nil,
          output_schema: map() | nil,
          format: map() | nil,
          tool_revision: pos_integer(),
          exposure: :direct | :code_mode_only | :deferred | :hidden,
          backend: module() | nil,
          backend_context: map(),
          safety: map(),
          source: map(),
          metadata: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, namespace} <- optional_name(attrs, :namespace),
         {:ok, name} <- required_name(attrs, :name),
         {:ok, input_kind} <- input_kind(attrs),
         {:ok, schema} <- function_schema(attrs, input_kind),
         {:ok, format} <- custom_format(attrs, input_kind),
         {:ok, revision} <- revision(attrs),
         {:ok, exposure} <- exposure(attrs),
         {:ok, safety} <- safety(attrs),
         {:ok, backend} <- backend(attrs),
         {:ok, backend_context} <- backend_context(attrs) do
      tool_name = canonical_name(namespace, name)

      {:ok,
       %{
         namespace: namespace,
         name: name,
         tool_name: tool_name,
         description: Map.get(attrs, :description, Map.get(attrs, "description", "")),
         input_kind: input_kind,
         schema: schema,
         output_schema: Map.get(attrs, :output_schema, Map.get(attrs, "output_schema")),
         format: format,
         tool_revision: revision,
         exposure: exposure,
         backend: backend,
         backend_context: backend_context,
         safety: safety,
         source: Map.get(attrs, :source, %{}),
         metadata: Map.get(attrs, :metadata, %{})
       }}
    end
  end

  def new(_attrs), do: {:error, Error.new(:validation, "Codex contract must be a map")}

  @spec canonical_name(String.t() | nil, String.t()) :: String.t()
  def canonical_name(nil, name), do: name
  def canonical_name(namespace, name), do: namespace <> "::" <> name

  @spec split_name(String.t()) :: {:ok, {String.t() | nil, String.t()}} | {:error, Error.t()}
  def split_name(name) when is_binary(name) do
    case String.split(name, "::", parts: 2) do
      [tool] when tool != "" -> {:ok, {nil, tool}}
      [namespace, tool] when namespace != "" and tool != "" -> {:ok, {namespace, tool}}
      _ -> {:error, Error.new(:validation, "Codex tool name must not be empty")}
    end
  end

  def split_name(_), do: {:error, Error.new(:validation, "Codex tool name must be a string")}

  @spec descriptor(t()) :: map()
  def descriptor(%{tool_name: name} = contract) do
    %{
      tool_name: name,
      tool_revision: contract.tool_revision,
      backend: contract.backend,
      backend_context: contract.backend_context,
      description: contract.description,
      schema: contract.schema || %{"type" => "object"},
      safety: contract.safety,
      codex_input_kind: contract.input_kind,
      codex_format: contract.format,
      codex_exposure: contract.exposure,
      codex_output_schema: contract.output_schema,
      codex_source: contract.source
    }
  end

  @spec provider_definition(t()) :: map()
  def provider_definition(%{input_kind: :function} = contract) do
    %{
      type: "function",
      name: contract.tool_name,
      description: contract.description,
      parameters: json_value(contract.schema)
    }
    |> maybe_put_output_schema(contract.output_schema)
  end

  def provider_definition(%{input_kind: :custom} = contract) do
    %{
      type: "custom",
      name: contract.tool_name,
      description: contract.description,
      format: contract.format
    }
  end

  defp optional_name(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    cond do
      is_nil(value) -> {:ok, nil}
      is_binary(value) and valid_name?(value) -> {:ok, value}
      true -> {:error, Error.new(:validation, "#{key} must be a non-empty name")}
    end
  end

  defp required_name(attrs, key) do
    with {:ok, value} <- optional_name(attrs, key) do
      if is_binary(value),
        do: {:ok, value},
        else: {:error, Error.new(:validation, "#{key} is required")}
    end
  end

  defp valid_name?(value), do: value != "" and not String.contains?(value, "::")

  defp input_kind(attrs) do
    value = Map.get(attrs, :input_kind, Map.get(attrs, "input_kind", :function))

    case value do
      :function -> {:ok, :function}
      "function" -> {:ok, :function}
      :custom -> {:ok, :custom}
      "custom" -> {:ok, :custom}
      _ -> {:error, Error.new(:validation, "input_kind must be :function or :custom")}
    end
  end

  defp function_schema(_attrs, :custom), do: {:ok, nil}

  defp function_schema(attrs, :function) do
    schema = Map.get(attrs, :schema, Map.get(attrs, "schema", %{"type" => "object"}))

    case InputSchema.validate_schema(schema) do
      :ok -> {:ok, schema}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp custom_format(_attrs, :function), do: {:ok, nil}

  defp custom_format(attrs, :custom) do
    format = Map.get(attrs, :format, Map.get(attrs, "format"))

    if is_map(format),
      do: {:ok, format},
      else: {:error, Error.new(:validation, "custom format is required")}
  end

  defp revision(attrs) do
    value = Map.get(attrs, :tool_revision, Map.get(attrs, "tool_revision", 1))

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, Error.new(:validation, "tool_revision must be positive")}
  end

  defp exposure(attrs) do
    value = Map.get(attrs, :exposure, Map.get(attrs, "exposure", :direct))

    case value do
      value when value in [:direct, :code_mode_only, :deferred, :hidden] -> {:ok, value}
      "direct" -> {:ok, :direct}
      "code_mode_only" -> {:ok, :code_mode_only}
      "deferred" -> {:ok, :deferred}
      "hidden" -> {:ok, :hidden}
      _ -> {:error, Error.new(:validation, "invalid Codex tool exposure")}
    end
  end

  defp safety(attrs) do
    raw = Map.get(attrs, :safety, Map.get(attrs, "safety", %{}))

    value =
      if is_map(raw) do
        [:read_only, :retry_safe, :parallel_safe, :requires_approval]
        |> Enum.reduce(%{}, fn key, acc ->
          case Map.fetch(raw, key) do
            {:ok, child} ->
              Map.put(acc, key, child)

            :error ->
              case Map.fetch(raw, Atom.to_string(key)) do
                {:ok, child} -> Map.put(acc, key, child)
                :error -> acc
              end
          end
        end)
      else
        raw
      end

    if is_map(value) and
         Enum.all?([:read_only, :retry_safe, :parallel_safe], &Map.has_key?(value, &1)) do
      {:ok, value}
    else
      {:error, Error.new(:validation, "safety requires read_only, retry_safe, and parallel_safe")}
    end
  end

  defp backend(attrs) do
    value = Map.get(attrs, :backend, Map.get(attrs, "backend"))

    if is_nil(value) or is_atom(value),
      do: {:ok, value},
      else: {:error, Error.new(:validation, "backend must be a module")}
  end

  defp backend_context(attrs) do
    value = Map.get(attrs, :backend_context, Map.get(attrs, "backend_context", %{}))

    if is_map(value),
      do: {:ok, value},
      else: {:error, Error.new(:validation, "backend_context must be a map")}
  end

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, child} ->
      {if(is_atom(key), do: Atom.to_string(key), else: key), json_value(child)}
    end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value), do: value

  defp maybe_put_output_schema(definition, nil), do: definition

  defp maybe_put_output_schema(definition, schema),
    do: Map.put(definition, :output_schema, json_value(schema))
end
