defmodule Backplane.AgentRuntime.Codex.Reconciliation.Evidence do
  @moduledoc false

  alias Backplane.AgentRuntime.Error

  @max_bytes 16_777_216
  @max_nodes 262_144
  @error_classes [
    :validation,
    :forbidden,
    :approval_required,
    :not_found,
    :timeout,
    :cancelled,
    :transient_transport,
    :resource_conflict,
    :execution_failure,
    :malformed_result,
    :budget_exceeded,
    :unsupported_capability,
    :unknown_outcome,
    :overloaded
  ]
  @manifest_fields ~w(schema_version manifest_id manifest_revision subject admission_fence_ref run_refs obligations manifest_digest)
  @child_fields ~w(scope_id root_agent_id source_manager_id agent_id name parent_id parent_name attempt_id run_id run_incarnation)
  @obligation_kinds ~w(provider tool child dependency executor session registry_owner registry_resource registry_session manager host_component acknowledgement)
  @receipt_fields ~w(schema_version receipt_id revision subject manifest_digest evidence_ref evidence_digest run_fences historical_outcomes satisfied pending unresolved_effects closure retirement first_failure accepted_request_digest receipt_digest)

  def public(value) do
    with {:ok, result, _nodes} <- normalize(value, 0, 0),
         true <- byte_size(JSON.encode!(result)) <= @max_bytes do
      {:ok, result}
    else
      _ -> invalid("recovery data must be bounded unambiguous JSON without runtime handles")
    end
  rescue
    _ -> invalid("recovery data must be bounded unambiguous JSON without runtime handles")
  end

  def digest(value) do
    {:ok, value} = public(value)
    :crypto.hash(:sha256, canonical(value)) |> Base.encode16(case: :lower)
  end

  def seal(value, key), do: Map.put(value, key, digest(Map.delete(value, key)))

  def manifest(subject, run_refs, obligations, fence_ref) do
    {:ok, fields} =
      public(%{
        schema_version: 1,
        manifest_revision: 1,
        subject: subject,
        admission_fence_ref: fence_ref,
        run_refs: run_refs,
        obligations: Enum.sort_by(obligations, & &1["obligation_id"])
      })

    fields
    |> Map.put("manifest_id", "manifest_" <> digest(fields))
    |> seal("manifest_digest")
  end

  def obligation(kind, identity, provenance_ref) do
    {:ok, fields} = public(%{kind: kind, identity: identity, provenance_ref: provenance_ref})
    Map.put(fields, "obligation_id", "obligation_" <> digest(fields))
  end

  def validate_manifest(value) do
    with {:ok, value} <- public(value),
         :ok <- fields(value, @manifest_fields, @manifest_fields),
         :ok <- version(value),
         :ok <- identifier(value["manifest_id"]),
         :ok <- positive(value["manifest_revision"]),
         :ok <- subject(value["subject"]),
         :ok <- identifier(value["admission_fence_ref"]),
         :ok <- each(value["run_refs"], &run_ref/1),
         :ok <- unique(value["run_refs"], & &1["run_id"]),
         :ok <- each(value["obligations"], &obligation_shape/1),
         :ok <- unique(value["obligations"], & &1["obligation_id"]),
         :ok <- unique(value["obligations"], &{&1["kind"], &1["identity"]}),
         :ok <- subject_run(value["subject"], value["run_refs"]),
         :ok <- sealed(value, "manifest_digest") do
      {:ok, value}
    end
  end

  def validate_receipt(value) do
    with {:ok, value} <- public(value),
         :ok <- fields(value, @receipt_fields, @receipt_fields),
         :ok <- version(value),
         :ok <- identifier(value["receipt_id"]),
         :ok <- positive(value["revision"]),
         :ok <- subject(value["subject"]),
         :ok <- identifier(value["manifest_digest"]),
         :ok <- identifier(value["evidence_ref"]),
         :ok <- identifier(value["evidence_digest"]),
         :ok <- identifier(value["accepted_request_digest"]),
         true <- value["closure"] in ~w(pending confirmed),
         true <- value["retirement"] in ~w(pending confirmed),
         true <-
           Enum.all?(
             ~w(run_fences historical_outcomes satisfied pending unresolved_effects),
             &is_list(value[&1])
           ),
         :ok <-
           each(
             value["satisfied"] ++ value["pending"] ++ value["unresolved_effects"],
             &obligation_shape/1
           ),
         :ok <- unique(value["satisfied"] ++ value["pending"], & &1["obligation_id"]),
         true <-
           Enum.all?(
             value["unresolved_effects"],
             &(&1["kind"] == "tool" and &1 in (value["satisfied"] ++ value["pending"]))
           ),
         true <- value["closure"] == "confirmed" == (value["pending"] == []),
         true <-
           value["retirement"] == "confirmed" ==
             (value["pending"] == [] and value["unresolved_effects"] == []),
         :ok <- each(value["run_fences"], &receipt_fence/1),
         :ok <- each(value["historical_outcomes"], &historical_outcome/1),
         :ok <- sealed(value, "receipt_digest") do
      {:ok, value}
    else
      false -> invalid("invalid recovery receipt state")
      error -> error
    end
  end

  def subject(%{"kind" => "child", "identity" => identity} = value) do
    with :ok <- fields(value, ~w(kind identity), ~w(kind identity)),
         :ok <- fields(identity, @child_fields, @child_fields),
         :ok <- each(@child_fields -- ["run_incarnation"], &identifier(identity[&1])),
         :ok <- positive(identity["run_incarnation"]) do
      if Path.dirname(identity["name"]) == identity["parent_name"] and
           canonical_name?(identity["name"]) and canonical_name?(identity["parent_name"]),
         do: :ok,
         else: invalid("child ancestry differs from its canonical name")
    end
  end

  def subject(%{"kind" => "manager"} = value) do
    keys = ~w(kind scope_id manager_id root_agent_id)
    with :ok <- fields(value, keys, keys), do: each(keys -- ["kind"], &identifier(value[&1]))
  end

  def subject(%{"kind" => kind} = value) when kind in ~w(session registry_owner) do
    keys = ~w(kind scope_id owner_id incarnation)

    with :ok <- fields(value, keys, keys),
         :ok <- identifier(value["scope_id"]),
         :ok <- identifier(value["owner_id"]),
         do: positive(value["incarnation"])
  end

  def subject(_), do: invalid("invalid recovery subject")

  defp canonical_name?(name) do
    String.starts_with?(name, "/") and
      Enum.all?(tl(String.split(name, "/")), &(&1 not in ["", ".", ".."]))
  end

  defp subject_run(%{"kind" => "child", "identity" => identity}, refs) do
    if Enum.any?(
         refs,
         &(&1["run_id"] == identity["run_id"] and
             &1["original_incarnation"] == identity["run_incarnation"])
       ),
       do: :ok,
       else: invalid("child manifest is missing its original authoritative run reference")
  end

  defp subject_run(_, _), do: :ok

  defp receipt_fence(value) do
    keys = ~w(store_ref run_id original_incarnation current_incarnation current_revision chain)

    with :ok <- fields(value, keys, keys),
         :ok <- each(~w(store_ref run_id), &identifier(value[&1])),
         :ok <-
           each(
             ~w(original_incarnation current_incarnation current_revision),
             &positive(value[&1])
           ),
         true <-
           value["current_incarnation"] >= value["original_incarnation"] and
             is_list(value["chain"]) do
      :ok
    else
      false -> invalid("invalid receipt Store fence")
      error -> error
    end
  end

  defp historical_outcome(value) do
    keys = ~w(run_id state outcome_digest)

    with :ok <- fields(value, keys, keys),
         :ok <- identifier(value["run_id"]),
         :ok <- identifier(value["outcome_digest"]),
         true <- value["state"] in ~w(completed failed cancelled timed_out unknown_outcome) do
      :ok
    else
      false -> invalid("invalid historical outcome")
      error -> error
    end
  end

  def run_ref(value) do
    keys = ~w(store_ref run_id original_incarnation)

    with :ok <- fields(value, keys, keys),
         :ok <- identifier(value["store_ref"]),
         :ok <- identifier(value["run_id"]),
         do: positive(value["original_incarnation"])
  end

  def obligation_shape(value) do
    keys = ~w(obligation_id kind identity provenance_ref)

    with :ok <- fields(value, keys ++ ["requires"], keys),
         :ok <- identifier(value["obligation_id"]),
         :ok <- identifier(value["provenance_ref"]),
         true <- value["kind"] in @obligation_kinds,
         true <- is_map(value["identity"]) and map_size(value["identity"]) > 0,
         :ok <- each(Map.get(value, "requires", []), &identifier/1),
         :ok <- unique(Map.get(value, "requires", []), & &1) do
      :ok
    else
      false -> invalid("invalid recovery obligation")
      error -> error
    end
  end

  def fields(value, allowed, required) when is_map(value) and not is_struct(value) do
    if Enum.all?(Map.keys(value), &(&1 in allowed)) and
         Enum.all?(required, &Map.has_key?(value, &1)),
       do: :ok,
       else: invalid("recovery schema has missing or unknown fields")
  end

  def fields(_, _, _), do: invalid("recovery schema requires an object")
  def version(%{"schema_version" => 1}), do: :ok
  def version(_), do: invalid("unsupported recovery schema version")

  def identifier(value) when is_binary(value) and byte_size(value) in 1..4_096, do: :ok
  def identifier(_), do: invalid("recovery identity requires a nonempty bounded string")
  def positive(value) when is_integer(value) and value > 0, do: :ok
  def positive(_), do: invalid("recovery revision or incarnation must be positive")

  def each(values, fun) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def each(_, _), do: invalid("recovery schema requires an array")

  def unique(values, key) when is_list(values) do
    keys = Enum.map(values, key)

    if Enum.uniq(keys) == keys,
      do: :ok,
      else: invalid("duplicate recovery obligation or identity")
  end

  def unique(_, _), do: invalid("recovery schema requires an array")

  def sealed(value, key) do
    if value[key] == digest(Map.delete(value, key)),
      do: :ok,
      else: invalid("recovery data digest differs")
  end

  def invalid(message), do: {:error, Error.new(:validation, message)}

  defp normalize(_, depth, _) when depth > 32, do: :error
  defp normalize(_, _, nodes) when nodes >= @max_nodes, do: :error

  defp normalize(value, _, nodes) when is_binary(value) do
    if String.valid?(value), do: {:ok, value, nodes + 1}, else: :error
  end

  defp normalize(value, _, nodes) when is_nil(value) or is_boolean(value) or is_integer(value),
    do: {:ok, value, nodes + 1}

  defp normalize(value, _, nodes) when is_float(value), do: {:ok, value, nodes + 1}

  defp normalize(value, depth, nodes) when is_atom(value),
    do: normalize(Atom.to_string(value), depth, nodes)

  defp normalize(value, depth, nodes) when is_list(value) do
    Enum.reduce_while(value, {:ok, [], nodes + 1}, fn item, {:ok, acc, count} ->
      case normalize(item, depth + 1, count) do
        {:ok, item, next} -> {:cont, {:ok, [item | acc], next}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc, count} -> {:ok, Enum.reverse(acc), count}
      error -> error
    end
  end

  defp normalize(%Error{} = error, depth, nodes) do
    fields = Map.from_struct(error)

    if map_size(fields) == 4 and
         error.class in @error_classes and
         (is_nil(error.message) or is_binary(error.message)) and
         is_map(error.details) and not is_struct(error.details) do
      normalize(fields, depth, nodes)
    else
      :error
    end
  end

  defp normalize(value, depth, nodes) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}, nodes + 1}, fn {key, item}, {:ok, acc, count} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      with true <- is_binary(key) and String.valid?(key) and not Map.has_key?(acc, key),
           {:ok, item, next} <- normalize(item, depth + 1, count) do
        {:cont, {:ok, Map.put(acc, key, item), next}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp normalize(_, _, _), do: :error

  defp canonical(value) when is_map(value) do
    members =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [JSON.encode!(k), ":", canonical(v)] end)

    ["{", Enum.intersperse(members, ","), "}"]
  end

  defp canonical(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &canonical/1), ","), "]"]

  defp canonical(value), do: JSON.encode!(value)
end
