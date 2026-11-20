defmodule Backplane.AiProtocol.Codec.OpenAIResponses.CodexTools do
  @moduledoc false

  alias Backplane.AiProtocol.{Error, Request}

  @message_board_names ~w(create_channel get_channels list_threads search_posts read_thread read_post subscribe unsubscribe post)
  @board_aliases Map.new(
                   @message_board_names,
                   &{"collaboration::" <> &1, "agent_message_board::" <> &1}
                 )
  @archive_operations %{
    "history" => ~w(list_windows list_items read_item search_contents),
    "notes" => ~w(list_files_by_prefix read_file search_contents append_to_file write_file)
  }
  @local_archive_aliases for {namespace, operations} <- @archive_operations,
                             operation <- operations,
                             name = namespace <> "::" <> operation,
                             into: %{},
                             do: {name, "local_" <> name}
  @archive_tools Map.keys(@local_archive_aliases)
  @local_aliases Map.merge(@board_aliases, @local_archive_aliases)

  @enforce_keys [:history_notes, :to_wire, :to_canonical, :wire_namespaces]
  defstruct @enforce_keys

  def new(%Request{} = request, mode) when mode in [:local, :remote_encrypted] do
    history =
      for %{content: blocks} <- request.input,
          %{type: :tool_call, tool_call: call} <- blocks,
          do: call.name

    names = Enum.map(request.tools || [], & &1.name) ++ history

    aliases = if mode == :local, do: @local_aliases, else: @board_aliases
    to_wire = Map.take(aliases, names)
    wire_namespaces = to_wire |> Map.values() |> MapSet.new(&namespace/1)

    if Enum.any?(names, &MapSet.member?(wire_namespaces, namespace(&1))) do
      {:error, Error.invalid!("Codex wire namespace conflicts with a canonical tool")}
    else
      {:ok,
       %__MODULE__{
         history_notes: mode,
         to_wire: to_wire,
         to_canonical: Map.new(to_wire, fn {canonical, wire} -> {wire, canonical} end),
         wire_namespaces: wire_namespaces
       }}
    end
  end

  def new(%Request{}, _mode), do: {:error, Error.invalid!("Invalid Codex History/Notes mode")}

  def validate_request(_request, nil), do: :ok

  def validate_request(request, %__MODULE__{history_notes: mode} = projection) do
    with {:ok, ^projection} <- new(request, mode) do
      :ok
    else
      {:ok, _} -> {:error, Error.invalid!("Codex tool projection does not match the request")}
      error -> error
    end
  end

  def validate_request(_request, _projection),
    do: {:error, Error.invalid!("Invalid Codex tool projection")}

  def wire_name(name, nil), do: name
  def wire_name(name, %__MODULE__{to_wire: names}), do: Map.get(names, name, name)

  def canonical_name(name, nil), do: {:ok, name}

  def canonical_name(name, %__MODULE__{} = projection) do
    cond do
      canonical = projection.to_canonical[name] ->
        {:ok, canonical}

      Map.has_key?(projection.to_wire, name) or
          MapSet.member?(projection.wire_namespaces, namespace(name)) ->
        {:error, Error.invalid!("Unexpected Codex tool identity")}

      true ->
        {:ok, name}
    end
  end

  defp namespace(name) do
    case String.split(name, "::", parts: 2) do
      [namespace, _] -> namespace
      [_] -> nil
    end
  end

  def archive?(name, %__MODULE__{}), do: name in @archive_tools
  def archive?(_name, nil), do: false

  # Match the wire schema serialized by the pinned Codex History/Notes extension.
  # Runtime validation still uses the complete, canonical schema.
  def parameters(name, %{"properties" => properties} = schema, %__MODULE__{
        history_notes: :remote_encrypted
      })
      when name in @archive_tools and is_map(properties) do
    schema = %{
      schema
      | "properties" =>
          Map.new(properties, fn
            {field, %{"type" => "integer"} = spec} -> {field, Map.delete(spec, "minimum")}
            property -> property
          end)
    }

    schema = Map.delete(schema, "additionalProperties")
    if schema["required"] == [], do: Map.delete(schema, "required"), else: schema
  end

  def parameters(_name, schema, _projection), do: schema
end
