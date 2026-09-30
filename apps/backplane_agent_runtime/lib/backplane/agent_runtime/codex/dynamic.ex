defmodule Backplane.AgentRuntime.Codex.Dynamic do
  @moduledoc """
  Host-mediated dynamic Codex catalog.

  Discovery is deliberately separate from publication.  A discovered MCP,
  connector, or host definition is only descriptive until the host publishes
  it through the strict runtime catalog.
  """

  alias Backplane.AgentRuntime.{Error, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.Contract

  defstruct entries: %{}, revision: 0, snapshots: %{}, receipts: %{}, max_results: 50

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    max_results = Keyword.get(opts, :max_results, 50)

    if is_integer(max_results) and max_results > 0,
      do: {:ok, %__MODULE__{max_results: max_results}},
      else: {:error, validation("max_results must be positive")}
  end

  @doc "Records host-authorized candidates without granting execution authority."
  @spec discover(t(), term(), [map()], keyword()) :: {:ok, t(), [map()]} | {:error, Error.t()}
  def discover(state, owner, candidates, opts \\ [])

  def discover(%__MODULE__{} = state, owner, candidates, opts)
      when is_list(candidates) do
    with :ok <- owner_valid(owner),
         :ok <- bounded(candidates, state.max_results),
         {:ok, found, entries} <- normalize_candidates(candidates, owner, opts) do
      if MapSet.disjoint?(MapSet.new(Map.keys(state.entries)), MapSet.new(Map.keys(entries))) do
        {:ok, %{state | entries: Map.merge(state.entries, entries)}, found}
      else
        {:error, validation("dynamic tool namespace collision")}
      end
    end
  end

  def discover(_state, _owner, _candidates, _opts),
    do: {:error, validation("dynamic candidates must be a list")}

  @doc "Searches only candidates owned by the requesting host and never publishes them."
  @spec search(t(), term(), String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def search(%__MODULE__{} = state, owner, query \\ "", opts \\ []) when is_binary(query) do
    with :ok <- owner_valid(owner),
         {:ok, limit} <- limit(opts, state.max_results) do
      results =
        state.entries
        |> Map.values()
        |> Enum.filter(fn entry ->
          owner_visible?(entry, owner) and entry.status == :discovered and
            (query == "" or String.contains?(entry.contract.tool_name, query))
        end)
        |> Enum.sort_by(& &1.contract.tool_name)
        |> Enum.take(limit)
        |> Enum.map(&summary/1)

      {:ok, results}
    end
  end

  @doc "Publishes one discovered definition through strict schema/authority admission."
  @spec publish(t(), term(), String.t(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def publish(%__MODULE__{} = state, owner, name, authority \\ %{})
      when is_binary(name) and is_map(authority) do
    with :ok <- owner_valid(owner),
         {:ok, entry} <- fetch_entry(state, name),
         :ok <- owner_check(entry, owner),
         :ok <- unpublished(entry),
         authority <- admission_authority(authority, owner, name, entry.contract.tool_revision),
         {:ok, admission} <-
           ToolCatalog.admit_batch([Contract.descriptor(entry.contract)], authority: authority) do
      next_revision = state.revision + 1
      published = %{entry | status: :published, publication_revision: next_revision}
      next = %{state | entries: Map.put(state.entries, name, published), revision: next_revision}
      {:ok, next, %{name: name, revision: next_revision, tools: admission.tools}}
    end
  end

  @doc "Creates an immutable view of currently published tools for one owner."
  @spec snapshot(t(), term(), keyword()) :: {:ok, t(), map()} | {:error, Error.t()}
  def snapshot(%__MODULE__{} = state, owner, opts \\ []) when is_list(opts) do
    with :ok <- owner_valid(owner),
         {:ok, limit} <- limit(opts, state.max_results) do
      entries =
        state.entries
        |> Map.values()
        |> Enum.filter(&(&1.status == :published and owner_visible?(&1, owner)))
        |> Enum.sort_by(& &1.contract.tool_name)
        |> Enum.take(limit)

      id = "dyn_" <> Integer.to_string(System.unique_integer([:positive]))

      snapshot = %{
        id: id,
        owner: owner,
        revision: state.revision,
        names: Map.new(entries, &{&1.contract.tool_name, &1.publication_revision})
      }

      {:ok, %{state | snapshots: Map.put(state.snapshots, id, snapshot)}, snapshot}
    end
  end

  @doc "Calls a published tool only when its snapshot and owner are still current."
  @spec call(t(), map(), term(), String.t(), term()) :: {:ok, t(), term()} | {:error, Error.t()}
  def call(%__MODULE__{} = state, snapshot, owner, name, arguments)
      when is_map(snapshot) and is_binary(name) do
    with :ok <- owner_valid(owner),
         :ok <- snapshot_owner(snapshot, owner),
         :ok <- snapshot_current?(state, snapshot),
         {:ok, expected_revision} <- snapshot_name(snapshot, name),
         {:ok, entry} <- fetch_entry(state, name),
         :ok <- entry_current?(entry, expected_revision),
         :ok <- validate_arguments(entry.contract, arguments) do
      case dispatch(entry.contract, arguments) do
        {:ok, result} -> {:ok, state, result}
        {:error, %Error{} = error} -> {:error, error}
        other -> {:ok, state, other}
      end
    end
  end

  @doc "Revokes a published definition and fences all older snapshots."
  @spec revoke(t(), term(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def revoke(%__MODULE__{} = state, owner, name) when is_binary(name) do
    with :ok <- owner_valid(owner),
         {:ok, entry} <- fetch_entry(state, name),
         :ok <- owner_check(entry, owner) do
      revision = state.revision + 1

      {:ok,
       %{
         state
         | revision: revision,
           entries:
             Map.put(state.entries, name, %{
               entry
               | status: :revoked,
                 publication_revision: revision
             })
       }}
    end
  end

  @doc "Records a host-mediated plugin request; completion never grants tools."
  @spec request_plugin(t(), term(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def request_plugin(%__MODULE__{} = state, owner, request) when is_map(request) do
    with :ok <- owner_valid(owner) do
      id = "plugin_" <> Integer.to_string(System.unique_integer([:positive]))
      receipt = %{id: id, owner: owner, request: request, status: :requested}
      {:ok, %{state | receipts: Map.put(state.receipts, id, receipt)}, receipt}
    end
  end

  @spec complete_plugin(t(), term(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def complete_plugin(%__MODULE__{} = state, owner, %{id: id} = result) when is_binary(id) do
    with :ok <- owner_valid(owner),
         {:ok, receipt} <- Map.fetch(state.receipts, id),
         :ok <-
           if(receipt.owner == owner,
             do: :ok,
             else: {:error, forbidden("plugin receipt belongs to another owner")}
           ) do
      completed =
        receipt |> Map.put(:status, :completed) |> Map.put(:result, Map.delete(result, :id))

      {:ok, %{state | receipts: Map.put(state.receipts, id, completed)}, completed}
    else
      :error -> {:error, Error.new(:not_found, "plugin receipt is unknown")}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp normalize_candidates(candidates, owner, opts) do
    source = Keyword.get(opts, :source, :dynamic)

    Enum.reduce_while(candidates, {:ok, [], %{}}, fn attrs, {:ok, found, entries} ->
      attrs = Map.put_new(attrs, :source, %{kind: source, owner: owner})

      case Contract.new(attrs) do
        {:ok, contract} ->
          if Map.has_key?(entries, contract.tool_name) do
            {:halt, {:error, validation("dynamic tool namespace collision")}}
          else
            entry = %{
              contract: contract,
              owner: owner,
              status: :discovered,
              publication_revision: nil
            }

            {:cont, {:ok, [summary(entry) | found], Map.put(entries, contract.tool_name, entry)}}
          end

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, found, entries} -> {:ok, Enum.reverse(found), entries}
      error -> error
    end
  end

  defp dispatch(%{backend: nil}, _arguments),
    do: {:error, Error.new(:unsupported_capability, "dynamic backend is unavailable")}

  defp dispatch(%{backend: backend}, arguments) when is_atom(backend) do
    if function_exported?(backend, :execute, 1),
      do: backend.execute(arguments),
      else: {:error, Error.new(:unsupported_capability, "dynamic backend is unavailable")}
  end

  defp validate_arguments(%{input_kind: :custom}, _), do: :ok

  defp validate_arguments(%{schema: schema}, arguments) when is_map(arguments) do
    case Backplane.AgentRuntime.InputSchema.validate(schema, arguments) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp validate_arguments(_, _), do: {:error, validation("dynamic arguments must be an object")}

  defp summary(entry),
    do: %{
      name: entry.contract.tool_name,
      description: entry.contract.description,
      revision: entry.contract.tool_revision,
      status: entry.status,
      source: entry.contract.source
    }

  defp admission_authority(authority, owner, name, revision),
    do:
      authority
      |> Map.put_new(:caller, owner)
      |> Map.put_new(:run_id, owner)
      |> Map.put(:grants, [name])
      |> Map.put(:tool_revisions, %{name => revision})

  defp owner_visible?(entry, owner), do: entry.owner == owner
  defp owner_valid(owner) when is_binary(owner) and owner != "", do: :ok
  defp owner_valid(_), do: {:error, validation("dynamic owner is required")}

  defp bounded(items, max),
    do:
      if(length(items) <= max,
        do: :ok,
        else: {:error, Error.new(:budget_exceeded, "dynamic result limit exceeded")}
      )

  defp limit(opts, max) do
    value = Keyword.get(opts, :limit, max)

    if is_integer(value) and value > 0 and value <= max,
      do: {:ok, value},
      else: {:error, validation("invalid dynamic limit")}
  end

  defp fetch_entry(state, name) do
    case Map.fetch(state.entries, name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, Error.new(:not_found, "dynamic tool is unknown")}
    end
  end

  defp owner_check(%{owner: owner}, owner), do: :ok
  defp owner_check(_, _), do: {:error, forbidden("dynamic tool belongs to another owner")}
  defp unpublished(%{status: :discovered}), do: :ok

  defp unpublished(_),
    do: {:error, Error.new(:resource_conflict, "dynamic tool is already published or revoked")}

  defp snapshot_owner(%{owner: owner}, owner), do: :ok
  defp snapshot_owner(_, _), do: {:error, forbidden("snapshot belongs to another owner")}
  defp snapshot_current?(state, %{revision: revision}) when revision == state.revision, do: :ok

  defp snapshot_current?(_, _),
    do: {:error, Error.new(:resource_conflict, "dynamic snapshot is stale")}

  defp snapshot_name(%{names: names}, name) do
    case Map.fetch(names, name) do
      {:ok, revision} -> {:ok, revision}
      :error -> {:error, Error.new(:not_found, "tool is not in snapshot")}
    end
  end

  defp entry_current?(%{status: :published, publication_revision: revision}, revision), do: :ok

  defp entry_current?(_, _),
    do: {:error, Error.new(:resource_conflict, "dynamic tool publication is stale")}

  defp validation(message), do: Error.new(:validation, message)
  defp forbidden(message), do: Error.new(:forbidden, message)
end
