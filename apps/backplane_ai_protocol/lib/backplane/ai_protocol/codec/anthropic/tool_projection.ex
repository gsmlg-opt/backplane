defmodule Backplane.AiProtocol.Codec.Anthropic.ToolProjection do
  @moduledoc false

  alias Backplane.AiProtocol.{Error, Request, ToolDefinition}

  @enforce_keys [:by_name, :by_wire]
  defstruct [:by_name, :by_wire, version: 1]

  @option :anthropic_tool_projection
  @legal_name ~r/\A[a-zA-Z0-9_-]{1,64}\z/
  @metadata_prefix "\n\n[Backplane Anthropic tool metadata v1; format and output schemas are advisory]\n"

  def new(%Request{} = request) do
    declarations = Enum.map(request.tools || [], &{&1.name, &1.input_kind})

    history =
      for %{content: blocks} <- request.input,
          %{type: :tool_call, tool_call: call} <- blocks do
        {call.name, if(match?({:custom, _}, call.raw_arguments), do: :custom, else: :function)}
      end

    build(declarations ++ history)
  end

  def options(opts, projection), do: Keyword.put(opts, @option, projection)

  def from_options(opts) do
    case Keyword.fetch(opts, @option) do
      :error -> {:ok, nil}
      {:ok, projection} -> validate(projection)
    end
  end

  def for_request(request, opts) do
    with {:ok, projection} <- from_options(opts) do
      if projection do
        with {:ok, expected} <- new(request),
             true <- expected == projection do
          {:ok, projection}
        else
          false -> incompatible("Anthropic tool projection does not match the request")
          error -> error
        end
      else
        {:ok, nil}
      end
    end
  end

  def validate(%__MODULE__{version: 1, by_name: by_name, by_wire: by_wire} = projection)
      when is_map(by_name) and is_map(by_wire) do
    identities =
      Enum.map(by_name, fn
        {name, %{input_kind: kind}} -> {name, kind}
        _ -> :invalid
      end)

    case build(identities) do
      {:ok, ^projection} -> {:ok, projection}
      _ -> incompatible("Anthropic tool projection context is invalid")
    end
  end

  def validate(_), do: incompatible("Anthropic tool projection context is invalid")

  def legal_name?(name) when is_binary(name), do: String.match?(name, @legal_name)
  def legal_name?(_), do: false

  def encode_name(name, nil) do
    if legal_name?(name),
      do: {:ok, %{name: name, wire_name: name, input_kind: :function}},
      else: incompatible("Anthropic tool names must match [a-zA-Z0-9_-]{1,64}")
  end

  def encode_name(name, %__MODULE__{by_name: names}) do
    case Map.fetch(names, name) do
      {:ok, identity} -> {:ok, identity}
      :error -> incompatible("Anthropic tool is missing from its projection")
    end
  end

  def decode_name(name, nil), do: encode_name(name, nil)

  def decode_name(name, %__MODULE__{by_wire: names}) do
    case Map.fetch(names, name) do
      {:ok, identity} -> {:ok, identity}
      :error -> incompatible("Anthropic response tool is missing from its projection")
    end
  end

  def encode_arguments({:custom, text}, %{input_kind: :custom}) when is_binary(text),
    do: {:ok, %{"input" => text}}

  def encode_arguments({:custom, _}, _),
    do: incompatible("Anthropic custom tool arguments require the matching projection")

  def encode_arguments(_arguments, %{input_kind: :custom}),
    do: incompatible("Anthropic custom tool replay requires raw custom text")

  def encode_arguments(arguments, _identity),
    do: Backplane.AiProtocol.Codec.Common.json_arguments(arguments)

  def decode_arguments(%{"input" => text} = input, %{input_kind: :custom})
      when is_binary(text) and map_size(input) == 1,
      do: {:ok, {:custom, text}}

  def decode_arguments(_input, %{input_kind: :custom}),
    do: incompatible("Anthropic custom tool input must contain exactly one string input field")

  def decode_arguments(input, _identity) when is_map(input), do: {:ok, {:structured, input}}
  def decode_arguments(_, _), do: incompatible("Anthropic tool input must be an object")

  def encode_tool(%ToolDefinition{} = tool, nil) do
    with {:ok, identity} <- encode_name(tool.name, nil) do
      {:ok, wire_tool(tool, identity, tool.description || "")}
    end
  end

  def encode_tool(%ToolDefinition{} = tool, projection) do
    with {:ok, identity} <- encode_name(tool.name, projection),
         true <- identity.input_kind == tool.input_kind,
         {:ok, metadata} <-
           Jason.encode(%{
             "canonical_name" => tool.name,
             "input_kind" => Atom.to_string(tool.input_kind),
             "format" => tool.format,
             "extensions" => tool.extensions
           }) do
      {:ok, wire_tool(tool, identity, (tool.description || "") <> @metadata_prefix <> metadata)}
    else
      false -> incompatible("Anthropic tool definition kind conflicts with its projection")
      {:error, %Error{}} = error -> error
      _ -> incompatible("Anthropic tool metadata cannot be encoded as JSON")
    end
  end

  defp wire_tool(tool, identity, description) do
    schema =
      if identity.input_kind == :custom do
        %{
          "type" => "object",
          "properties" => %{"input" => %{"type" => "string"}},
          "required" => ["input"],
          "additionalProperties" => false
        }
      else
        tool.input_schema || %{"type" => "object"}
      end

    %{"name" => identity.wire_name, "description" => description, "input_schema" => schema}
  end

  def project_choice(wire, projection) do
    case wire["tool_choice"] do
      %{} = choice ->
        with {:ok, name_key} <- choice_name_key(choice),
             {:ok, projected} <-
               project_choice_name(choice, name_key, projection, wire["tools"] || []) do
          {:ok, Map.put(wire, "tool_choice", projected)}
        end

      _ ->
        {:ok, wire}
    end
  end

  defp choice_name_key(%{"name" => _name, name: _atom_name}),
    do: incompatible("Anthropic tool choice has ambiguous name keys")

  defp choice_name_key(%{"name" => _name}), do: {:ok, "name"}
  defp choice_name_key(%{name: _name}), do: {:ok, :name}
  defp choice_name_key(_choice), do: {:ok, nil}

  defp project_choice_name(choice, nil, _projection, _tools), do: {:ok, choice}

  defp project_choice_name(choice, name_key, projection, tools) do
    with {:ok, identity} <- encode_name(Map.fetch!(choice, name_key), projection),
         :ok <- active_choice(identity, projection, tools),
         do: {:ok, Map.put(choice, name_key, identity.wire_name)}
  end

  defp active_choice(identity, _projection, tools) do
    if Enum.any?(tools, &(&1["name"] == identity.wire_name)),
      do: :ok,
      else: incompatible("Anthropic forced tool choice must name an active declaration")
  end

  defp build(identities) do
    Enum.reduce_while(identities, {:ok, %__MODULE__{by_name: %{}, by_wire: %{}}}, fn
      {name, kind}, {:ok, projection} when kind in [:function, :custom] ->
        with {:ok, _} <- ToolDefinition.new(%{name: name}),
             {:ok, updated} <- add(projection, name, kind) do
          {:cont, {:ok, updated}}
        else
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, incompatible("Anthropic tool projection identity is invalid")}
    end)
  end

  defp add(projection, name, kind) do
    wire = wire_name(name)
    identity = %{name: name, wire_name: wire, input_kind: kind}

    case {Map.get(projection.by_name, name), Map.get(projection.by_wire, wire)} do
      {nil, nil} ->
        {:ok,
         %{
           projection
           | by_name: Map.put(projection.by_name, name, identity),
             by_wire: Map.put(projection.by_wire, wire, identity)
         }}

      {^identity, ^identity} ->
        {:ok, projection}

      {%{input_kind: other}, _} when other != kind ->
        incompatible("Anthropic tool history and definition disagree on input kind")

      _ ->
        incompatible("Anthropic projected tool names collide")
    end
  end

  defp wire_name(name) do
    if legal_name?(name) do
      name
    else
      digest = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower)
      "bp_" <> binary_part(digest, 0, 60)
    end
  end

  defp incompatible(message), do: {:error, Error.incompatible!(message)}
end
