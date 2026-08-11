defmodule Backplane.McpProtocol.Client.Authorization do
  @moduledoc """
  HTTP client authorization helpers for the modern MCP protocol.

  These helpers model authorization-server binding and client registration
  decisions. They do not add OAuth behavior to stdio transports.
  """

  @issuer_support_key "authorization_response_iss_parameter_supported"
  @cimd_support_key "client_id_metadata_document_supported"
  @registration_endpoint_key "registration_endpoint"

  @type registration_selection ::
          {:pre_registered, term()}
          | {:client_id_metadata_document, String.t()}
          | {:dynamic_client_registration, String.t()}

  @doc """
  Validates a present RFC 9207 authorization-response issuer byte for byte.

  When the response omits `iss`, use `validate_issuer/3` with the
  authorization-server metadata so the advertised support flag can be
  honored. The two-argument form returns `:issuer_metadata_required` for an
  omitted issuer instead of guessing whether the parameter was required.
  """
  @spec validate_issuer(String.t(), String.t() | nil) ::
          :ok | {:error, :issuer_mismatch | :issuer_metadata_required}
  def validate_issuer(expected, returned) when is_binary(expected) and is_binary(returned) do
    compare_issuer(expected, returned)
  end

  def validate_issuer(expected, nil) when is_binary(expected) do
    {:error, :issuer_metadata_required}
  end

  @doc """
  Validates an RFC 9207 authorization-response issuer using authorization-server metadata.

  A present `iss` always has to match the expected issuer exactly. A missing
  `iss` is rejected only when the server advertises
  `authorization_response_iss_parameter_supported`.
  """
  @spec validate_issuer(String.t(), String.t() | nil, map()) ::
          :ok | {:error, :issuer_mismatch | :missing_issuer}
  def validate_issuer(expected, returned, metadata)
      when is_binary(expected) and is_binary(returned) and is_map(metadata) do
    compare_issuer(expected, returned)
  end

  def validate_issuer(expected, nil, metadata) when is_binary(expected) and is_map(metadata) do
    if metadata_value(metadata, @issuer_support_key) == true do
      {:error, :missing_issuer}
    else
      :ok
    end
  end

  @doc """
  Selects the highest-priority registration mechanism supported by both peers.

  Options are considered in MCP's required priority order:

    * `:pre_registered` — existing authorization-server-specific client data
    * `:client_id_metadata_document` — the client's HTTPS metadata document ID
    * `:dynamic_client_registration` — whether deprecated DCR is enabled
  """
  @spec select_registration(map(), keyword()) ::
          {:ok, registration_selection()} | {:error, :registration_unavailable}
  def select_registration(metadata, opts) when is_map(metadata) and is_list(opts) do
    with :error <- select_pre_registered(opts),
         :error <- select_cimd(metadata, opts),
         :error <- select_dynamic_registration(metadata, opts) do
      {:error, :registration_unavailable}
    end
  end

  @doc """
  Adds the OIDC Dynamic Client Registration `application_type` field.

  Native desktop, mobile, CLI, and localhost clients should pass `:native`;
  remotely hosted browser applications should pass `:web`.
  """
  @spec registration_metadata(map(), :native | :web | String.t()) :: map()
  def registration_metadata(metadata, application_type)
      when is_map(metadata) and application_type in [:native, :web, "native", "web"] do
    application_type = to_string(application_type)

    metadata
    |> Map.delete(:application_type)
    |> Map.put("application_type", application_type)
  end

  @doc """
  Returns the exact authorization-server/client identifier credential key.

  Neither component is URI-normalized or case-folded. The issuer should be the
  value already validated by `validate_issuer/2` or `validate_issuer/3`.
  """
  @spec credential_key(String.t(), String.t()) :: {String.t(), String.t()}
  def credential_key(issuer, client_id) when is_binary(issuer) and is_binary(client_id) do
    {issuer, client_id}
  end

  defp compare_issuer(expected, returned) do
    if expected == returned, do: :ok, else: {:error, :issuer_mismatch}
  end

  defp select_pre_registered(opts) do
    case Keyword.fetch(opts, :pre_registered) do
      {:ok, value} when value not in [nil, false] -> {:ok, {:pre_registered, value}}
      _missing -> :error
    end
  end

  defp select_cimd(metadata, opts) do
    client_id = Keyword.get(opts, :client_id_metadata_document)

    if metadata_value(metadata, @cimd_support_key) == true and is_binary(client_id) do
      {:ok, {:client_id_metadata_document, client_id}}
    else
      :error
    end
  end

  defp select_dynamic_registration(metadata, opts) do
    endpoint = metadata_value(metadata, @registration_endpoint_key)
    enabled? = Keyword.get(opts, :dynamic_client_registration, false)

    if enabled? == true and is_binary(endpoint) do
      {:ok, {:dynamic_client_registration, endpoint}}
    else
      :error
    end
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key, Map.get(metadata, metadata_atom_key(key)))
  end

  defp metadata_atom_key(@issuer_support_key), do: :authorization_response_iss_parameter_supported
  defp metadata_atom_key(@cimd_support_key), do: :client_id_metadata_document_supported
  defp metadata_atom_key(@registration_endpoint_key), do: :registration_endpoint
end
