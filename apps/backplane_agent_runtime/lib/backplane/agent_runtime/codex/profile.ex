defmodule Backplane.AgentRuntime.Codex.Profile do
  @moduledoc "Builds explicit host-authored Codex profiles through strict catalog admission."

  alias Backplane.AgentRuntime.{
    Codex.Catalog,
    Codex.CodeMode,
    Codex.Control,
    Codex.DynamicRuntime,
    Codex.ExtensionRuntime,
    Codex.Hosted,
    Codex.MultiAgent,
    Codex.Services,
    Codex.Tools,
    Error
  }

  @spec build(
          :pinned_local
          | :interactive
          | :collaboration_v1
          | :collaboration_v2
          | :code_mode
          | :code_mode_only
          | :mixed
          | :dynamic
          | :extensions
          | :configured
          | :service_compat,
          map(),
          map(),
          keyword()
        ) ::
          {:ok, map()} | {:error, Error.t()}
  def build(profile, context, authority, opts \\ [])

  def build(:pinned_local, context, authority, opts)
      when is_map(context) and is_map(authority) and is_list(opts) do
    admit_selected(Tools.contracts(context), authority, opts)
  end

  def build(:service_compat, context, authority, opts)
      when is_map(context) and is_map(authority) and is_list(opts) do
    contracts = Services.contracts(context)

    if contracts == [] do
      {:error, Error.new(:unsupported_capability, "service profile has no configured backends")}
    else
      admit_selected(contracts, authority, opts)
    end
  end

  def build(:interactive, context, authority, opts)
      when is_map(context) and is_map(authority) and is_list(opts) do
    admit_selected(Control.contracts(context), authority, opts)
  end

  def build(:collaboration_v1, %{collaboration_runtime: runtime}, authority, opts)
      when is_pid(runtime) and is_map(authority) and is_list(opts) do
    admit_selected(MultiAgent.contracts(:v1, runtime, opts), authority, opts)
  end

  def build(:collaboration_v2, %{collaboration_runtime: runtime}, authority, opts)
      when is_pid(runtime) and is_map(authority) and is_list(opts) do
    admit_selected(MultiAgent.contracts(:v2, runtime, opts), authority, opts)
  end

  def build(:code_mode, context, authority, opts)
      when is_map(context) and is_map(authority) and is_list(opts) do
    case CodeMode.contracts(context) do
      [] -> {:error, Error.new(:unsupported_capability, "Code Mode backend is unavailable")}
      contracts -> admit_selected(contracts, authority, opts)
    end
  end

  def build(:code_mode_only, context, authority, opts)
      when is_map(context) and is_map(authority) and is_list(opts) do
    code_mode_profile(context, authority, opts, :code_mode_only)
  end

  def build(:mixed, context, authority, opts)
      when is_map(context) and is_map(authority) and is_list(opts) do
    code_mode_profile(context, authority, opts, :direct)
  end

  def build(:dynamic, context, authority, opts)
      when is_map(context) and is_map(authority) and is_list(opts) do
    case DynamicRuntime.contracts(context) do
      [] -> {:error, Error.new(:unsupported_capability, "dynamic backends are unavailable")}
      contracts -> admit_selected(contracts, authority, opts)
    end
  end

  def build(:extensions, context, authority, opts)
      when is_map(context) and is_map(authority) and is_list(opts) do
    case ExtensionRuntime.contracts(context) do
      [] -> {:error, Error.new(:unsupported_capability, "extension runtime is unavailable")}
      contracts -> admit_selected(contracts, authority, opts)
    end
  end

  def build(:configured, context, authority, opts)
      when is_map(context) and is_map(authority) and is_list(opts) do
    with {:ok, families} <- configured_families(opts),
         {:ok, contracts} <- collect_families(families, context, opts),
         :ok <- unique_contract_names(contracts),
         {:ok, profile} <- admit_selected(contracts, authority, opts),
         {:ok, hosted_tools} <- Hosted.declarations(context) do
      {:ok, Map.put(profile, :hosted_tools, hosted_tools)}
    end
  end

  def build(_, _, _, _), do: {:error, Error.new(:validation, "invalid Codex profile request")}

  defp admit_selected(contracts, authority, opts) do
    selected = Keyword.get(opts, :tools, Enum.map(contracts, &canonical_name/1))
    available = Map.new(contracts, &{canonical_name(&1), &1})

    with true <-
           is_list(selected) or {:error, Error.new(:validation, "profile tools must be a list")},
         :ok <- ensure_available(selected, available) do
      Catalog.admit(Enum.map(selected, &Map.fetch!(available, &1)), authority)
    end
  end

  defp configured_families(opts) do
    case Keyword.get(opts, :families) do
      families when is_list(families) and families != [] -> {:ok, families}
      _ -> {:error, Error.new(:validation, "configured profile families must be a nonempty list")}
    end
  end

  defp collect_families(families, context, opts) do
    Enum.reduce_while(families, {:ok, []}, fn family, {:ok, contracts} ->
      case family_contracts(family, context, opts) do
        {:ok, selected} -> {:cont, {:ok, contracts ++ selected}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp family_contracts(:local, context, _opts), do: {:ok, Tools.contracts(context)}
  defp family_contracts(:interactive, context, _opts), do: {:ok, Control.contracts(context)}

  defp family_contracts(family, %{collaboration_runtime: runtime}, opts)
       when family in [:collaboration_v1, :collaboration_v2] and is_pid(runtime) do
    version = if family == :collaboration_v1, do: :v1, else: :v2
    {:ok, MultiAgent.contracts(version, runtime, opts)}
  end

  defp family_contracts(family, _context, _opts)
       when family in [:collaboration_v1, :collaboration_v2],
       do: unavailable_family(family)

  defp family_contracts(:extensions, context, _opts),
    do: available_family(:extensions, ExtensionRuntime.contracts(context))

  defp family_contracts(:dynamic, context, _opts),
    do: available_family(:dynamic, DynamicRuntime.contracts(context))

  defp family_contracts(:code_mode, context, _opts),
    do: available_family(:code_mode, CodeMode.contracts(context))

  defp family_contracts(:services, context, _opts),
    do: available_family(:services, Services.contracts(context))

  defp family_contracts(family, _context, _opts),
    do:
      {:error,
       Error.new(:validation, "unknown configured profile family", details: %{family: family})}

  defp available_family(family, []), do: unavailable_family(family)
  defp available_family(_family, contracts), do: {:ok, contracts}

  defp unavailable_family(family),
    do:
      {:error,
       Error.new(:unsupported_capability, "configured profile family is unavailable",
         details: %{family: family}
       )}

  defp unique_contract_names(contracts) do
    names = Enum.map(contracts, &canonical_name/1)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      duplicates ->
        {:error,
         Error.new(:resource_conflict, "configured profile tool names collide",
           details: %{tools: Enum.uniq(duplicates)}
         )}
    end
  end

  defp code_mode_profile(context, authority, opts, target_exposure) do
    exec = CodeMode.contracts(context)
    targets = Map.get(context, :code_mode_contracts, [])

    cond do
      exec == [] ->
        {:error, Error.new(:unsupported_capability, "Code Mode backend is unavailable")}

      not is_list(targets) ->
        {:error, Error.new(:validation, "Code Mode contracts must be a list")}

      true ->
        targets = Enum.map(targets, &Map.put(&1, :exposure, target_exposure))
        admit_selected(exec ++ targets, authority, opts)
    end
  end

  defp ensure_available(selected, available) do
    case Enum.reject(selected, &Map.has_key?(available, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         Error.new(:unsupported_capability, "requested Codex tools are unavailable",
           details: %{tools: missing}
         )}
    end
  end

  defp canonical_name(%{name: name, namespace: nil}), do: name
  defp canonical_name(%{name: name, namespace: namespace}), do: namespace <> "::" <> name
  defp canonical_name(%{name: name}), do: name
end
