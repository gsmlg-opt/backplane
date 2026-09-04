defmodule Backplane.LLM.ProxyRequest do
  @moduledoc """
  Logical schema for LLM proxy access records.

  Maps to the physical `llm_logs` table. New observability v2 code uses this
  module; `Backplane.LLM.UsageLog` remains a compatibility facade.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "llm_logs" do
    field(:event_id, :string)
    field(:request_id, :string)
    field(:trace_id, :string)
    field(:client_id, :binary_id)
    field(:client_ip, :string)

    field(:operation, :string)
    field(:api_surface, :string)
    field(:http_method, :string)
    field(:path, :string)

    belongs_to(:provider, Backplane.LLM.Provider, type: :binary_id)
    field(:provider_name, :string)
    belongs_to(:provider_api, Backplane.LLM.ProviderApi, type: :binary_id)
    belongs_to(:provider_model, Backplane.LLM.ProviderModel, type: :binary_id)

    belongs_to(:provider_model_surface, Backplane.LLM.ProviderModelSurface, type: :binary_id)

    field(:requested_model, :string)
    field(:resolved_model, :string)
    field(:model, :string, virtual: true)

    field(:status, :integer)
    field(:outcome, :string)
    field(:error_kind, :string)
    field(:error_code, :string)
    field(:error_reason, :string)

    field(:stream, :boolean, default: false)
    field(:duration_ms, :integer)
    field(:upstream_duration_ms, :integer)
    field(:ttft_ms, :integer)
    field(:stream_duration_ms, :integer)
    field(:stream_chunks, :integer)

    field(:request_bytes, :integer)
    field(:response_bytes, :integer)
    field(:input_tokens, :integer)
    field(:output_tokens, :integer)
    field(:total_tokens, :integer)
    field(:cached_tokens, :integer)
    field(:reasoning_tokens, :integer)

    field(:finish_reason, :string)
    field(:provider_request_id, :string)
    field(:attempt_count, :integer, default: 1)

    field(:metadata, :map, default: %{})

    field(:raw_request, :string)
    field(:raw_response, :string)

    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  @persist_fields ~w(
    event_id request_id trace_id client_id client_ip operation api_surface
    http_method path provider_id provider_name provider_api_id provider_model_id
    provider_model_surface_id requested_model resolved_model status outcome
    error_kind error_code error_reason stream duration_ms upstream_duration_ms
    ttft_ms stream_duration_ms stream_chunks request_bytes response_bytes
    input_tokens output_tokens total_tokens cached_tokens reasoning_tokens
    finish_reason provider_request_id attempt_count metadata
  )a

  @doc "Changeset for inserting a proxy access record."
  def insert_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, @persist_fields)
    |> validate_required([:event_id, :operation, :outcome])
    |> unique_constraint(:event_id)
  end

  @doc "Maps a virtual `model` field to `requested_model` for legacy callers."
  def legacy_attrs(attrs) when is_map(attrs) do
    case Map.pop(attrs, :model) do
      {nil, rest} -> rest
      {model, rest} -> Map.put_new(rest, :requested_model, model)
    end
  end
end
