defmodule Backplane.Memory.Config do
  @moduledoc false

  alias Backplane.Memory.Audit
  alias Backplane.Settings

  @event_gap_grace_seconds "memory.event_gap_grace_seconds"
  @host_batch_max_events "memory.host_batch_max_events"
  @host_batch_max_bytes "memory.host_batch_max_bytes"
  @host_spool_max_bytes "memory.host_spool_max_bytes"
  @host_spool_max_age_days "memory.host_spool_max_age_days"
  @session_stale_after_seconds "memory.session_stale_after_seconds"
  @fallback_sweep_batch_size "memory.fallback_sweep_batch_size"

  @distill_delay_seconds "memory.distill_delay_seconds"
  @distill_max_concurrency "memory.distill_max_concurrency"

  @default_event_gap_grace_seconds 60
  @default_host_spool_max_bytes 64 * 1024 * 1024
  @default_session_stale_after_seconds 10_800
  @default_fallback_sweep_batch_size 100

  @editable_settings [
    {"services.memory.enabled", "Memory service", :boolean, nil, nil, :service_enabled?},
    {"memory.llm_model", "Processing model", :model, nil, nil, :llm_model},
    {"memory.embed_model", "Embedding model (2560 dimensions)", :model, nil, nil, :embed_model},
    {"memory.proxy_credential", "Gateway resource credential", :credential, nil, nil,
     :proxy_credential},
    {@session_stale_after_seconds, "Stale session seconds", :integer, 60, 10_800,
     :session_stale_after_seconds},
    {@fallback_sweep_batch_size, "Fallback sweep batch", :integer, 1, 500,
     :fallback_sweep_batch_size},
    {@host_batch_max_events, "Host batch maximum events", :integer, 1, 100,
     :host_batch_max_events},
    {@host_batch_max_bytes, "Host batch maximum bytes", :integer, 1, 524_288,
     :host_batch_max_bytes},
    {@host_spool_max_bytes, "Host spool maximum bytes", :integer, 1, 1_073_741_824,
     :host_spool_max_bytes},
    {@host_spool_max_age_days, "Host spool maximum age days", :integer, 1, 3_660,
     :host_spool_max_age_days},
    {@event_gap_grace_seconds, "Event gap grace seconds", :integer, 1, 3_600,
     :event_gap_grace_seconds},
    {@distill_delay_seconds, "Distillation delay seconds", :integer, 0, 86_400,
     :distill_delay_seconds},
    {@distill_max_concurrency, "Distillation concurrency", :integer, 1, 8,
     :distill_max_concurrency}
  ]

  @doc "Returns the finite typed operator-editable Memory setting inventory."
  def editable_settings do
    Enum.map(@editable_settings, fn {key, label, type, minimum, maximum, accessor} ->
      %{
        key: key,
        label: label,
        type: type,
        minimum: minimum,
        maximum: maximum,
        configured: Settings.get(key),
        effective: apply(__MODULE__, accessor, []),
        apply_mode: apply_mode(key),
        reason: setting_reason(key)
      }
    end)
  end

  @doc "Validates, persists, and content-safely audits a trusted operator setting change."
  def update_setting(key, raw_value, %{
        actor: actor,
        request_id: request_id,
        correlation_id: correlation_id
      })
      when is_binary(key) and is_binary(actor) and is_binary(request_id) and
             is_binary(correlation_id) do
    with {:ok, spec} <- fetch_setting_spec(key),
         {:ok, value} <- parse_setting(raw_value, spec),
         previous = Settings.get(key),
         :ok <- persist_setting(key, value),
         :ok <-
           Audit.log("memory.config.set", actor, %{setting: key}, %{
             request_id: request_id,
             correlation_id: correlation_id,
             setting: key,
             old_class: value_class(previous),
             new_class: value_class(value),
             changed: previous !== value,
             content_exposed: false
           }) do
      {:ok, value}
    end
  end

  def update_setting(_key, _raw_value, _context), do: {:error, :unauthorized}

  defp persist_setting(key, value), do: Settings.set(key, value)

  defp fetch_setting_spec(key) do
    case Enum.find(@editable_settings, fn {candidate, _, _, _, _, _} -> candidate == key end) do
      nil -> {:error, :unknown_setting}
      {_, _, type, minimum, maximum, _} -> {:ok, {type, minimum, maximum}}
    end
  end

  defp parse_setting(value, {:boolean, nil, nil}) when value in [true, "true"], do: {:ok, true}
  defp parse_setting(value, {:boolean, nil, nil}) when value in [false, "false"], do: {:ok, false}

  defp parse_setting(value, {:integer, minimum, maximum}) do
    with {:ok, integer} <- parse_integer(value),
         true <- integer >= minimum and integer <= maximum do
      {:ok, integer}
    else
      _ -> {:error, :invalid_value}
    end
  end

  defp parse_setting(value, {:model, nil, nil}) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, nil}
      byte_size(value) <= 256 and not Regex.match?(~r/\s|[\x00-\x1F]/u, value) -> {:ok, value}
      true -> {:error, :invalid_value}
    end
  end

  defp parse_setting("", {:credential, nil, nil}), do: {:ok, nil}

  defp parse_setting(value, {:credential, nil, nil}) when is_binary(value) do
    case Backplane.Settings.Credentials.Vault.get(value) do
      %{kind: "service", metadata: metadata} ->
        auth_type = (metadata || %{})["auth_type"]

        if auth_type in [nil, "api_key"],
          do: {:ok, value},
          else: {:error, :invalid_value}

      _ ->
        {:error, :invalid_value}
    end
  end

  defp parse_setting(_value, _spec), do: {:error, :invalid_value}

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp parse_integer(_value), do: :error
  defp value_class(true), do: "boolean:true"
  defp value_class(false), do: "boolean:false"
  defp value_class(value) when is_integer(value), do: "integer"
  defp value_class(value) when is_float(value), do: "float"
  defp value_class(nil), do: "unset"
  defp value_class(_value), do: "other"

  def service_enabled?, do: enabled?("services.memory.enabled")
  def llm_model, do: normalized_setting("memory.llm_model")
  def embed_model, do: normalized_setting("memory.embed_model")
  def proxy_credential, do: normalized_setting("memory.proxy_credential")

  defp normalized_setting(key) do
    case Settings.get(key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: String.trim(value)

      _ ->
        nil
    end
  end

  defp apply_mode("memory.host_" <> _),
    do: "Central live policy; host applies on next negotiation/report"

  defp apply_mode("services.memory.enabled"),
    do: "Live; updates tool and prompt discovery"

  defp apply_mode(_), do: "Live; persisted across restart"

  defp setting_reason(key) when key in ["memory.llm_model", "memory.embed_model"] do
    if normalized_setting(key),
      do: "Selected route; provider resolution and last request status shown below",
      else: "No model selected"
  end

  defp setting_reason("memory.proxy_credential") do
    if proxy_credential(),
      do: "Named service credential; secret never displayed",
      else: "No resource bearer; requests require an open development resource"
  end

  defp setting_reason(_key), do: "Effective policy shown"

  @doc "Returns the final-processing gap grace in seconds (inclusive range 1..3600; default 60)."
  def event_gap_grace_seconds do
    bounded_integer(@event_gap_grace_seconds, @default_event_gap_grace_seconds, 1, 3_600)
  end

  def distill_delay_seconds, do: bounded_integer(@distill_delay_seconds, 600, 0, 86_400)

  def distill_max_concurrency, do: bounded_integer(@distill_max_concurrency, 2, 1, 8)

  def host_batch_max_events, do: bounded_integer(@host_batch_max_events, 100, 1, 100)

  def host_batch_max_bytes, do: bounded_integer(@host_batch_max_bytes, 524_288, 1, 524_288)

  def host_spool_max_bytes,
    do: bounded_integer(@host_spool_max_bytes, @default_host_spool_max_bytes, 1, 1_073_741_824)

  def host_spool_max_age_days, do: bounded_integer(@host_spool_max_age_days, 30, 1, 3_660)

  @doc "Returns the stale-session threshold in seconds (inclusive range 60..10800; default 10800)."
  def session_stale_after_seconds do
    bounded_integer(
      @session_stale_after_seconds,
      @default_session_stale_after_seconds,
      60,
      10_800
    )
  end

  @doc "Returns the fallback sweep candidate limit (inclusive range 1..500; default 100)."
  def fallback_sweep_batch_size do
    bounded_integer(
      @fallback_sweep_batch_size,
      @default_fallback_sweep_batch_size,
      1,
      500
    )
  end

  defp enabled?(key), do: Backplane.Settings.get(key) == true

  defp bounded_integer(key, default, minimum, maximum) do
    case Backplane.Settings.get(key) do
      value when is_integer(value) and value >= minimum and value <= maximum -> value
      _invalid -> default
    end
  end
end
