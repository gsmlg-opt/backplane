defmodule Backplane.Proxy.McpUpstream do
  @moduledoc "Ecto schema for the mcp_upstreams table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @headers_deny_list ~w(authorization proxy-authorization cookie x-api-key x-auth-token api-key)

  schema "mcp_upstreams" do
    field :name, :string
    field :prefix, :string
    field :transport, :string
    field :url, :string
    field :command, :string
    field :args, {:array, :string}, default: []
    field :credential, :string
    field :timeout_ms, :integer, default: 30_000
    field :refresh_interval_ms, :integer, default: 300_000
    field :enabled, :boolean, default: true
    field :headers, :map, default: %{}
    field :auth_scheme, :string, default: "none"
    field :auth_header_name, :string

    timestamps()
  end

  @required ~w(name prefix transport)a
  @optional ~w(url command args credential timeout_ms refresh_interval_ms enabled headers auth_scheme auth_header_name)a

  def changeset(upstream, attrs) do
    upstream
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:transport, ~w(http stdio))
    |> validate_inclusion(:auth_scheme, ~w(none bearer x_api_key custom_header))
    |> validate_transport_fields()
    |> validate_headers_deny_list()
    |> validate_no_url_userinfo()
    |> validate_auth_scheme()
    |> unique_constraint(:name)
    |> unique_constraint(:prefix)
  end

  defp validate_transport_fields(changeset) do
    case get_field(changeset, :transport) do
      "http" -> validate_required(changeset, [:url])
      "stdio" -> validate_required(changeset, [:command])
      _ -> changeset
    end
  end

  defp validate_headers_deny_list(changeset) do
    headers = get_field(changeset, :headers) || %{}

    denied =
      headers
      |> Map.keys()
      |> Enum.find(fn key -> String.downcase(key) in @headers_deny_list end)

    if denied do
      add_error(changeset, :headers, "contains prohibited auth header: #{denied}")
    else
      changeset
    end
  end

  defp validate_no_url_userinfo(changeset) do
    case get_field(changeset, :url) do
      nil ->
        changeset

      url ->
        uri = URI.parse(url)

        if uri.userinfo do
          add_error(changeset, :url, "must not contain embedded credentials")
        else
          changeset
        end
    end
  end

  defp validate_auth_scheme(changeset) do
    auth_scheme = get_field(changeset, :auth_scheme)
    credential = get_field(changeset, :credential)
    auth_header_name = get_field(changeset, :auth_header_name)

    changeset
    |> validate_auth_requires_credential(auth_scheme, credential)
    |> validate_custom_header(auth_scheme, auth_header_name)
  end

  defp validate_auth_requires_credential(changeset, auth_scheme, credential)
       when auth_scheme not in [nil, "none"] and (credential == nil or credential == "") do
    add_error(changeset, :credential, "is required when auth_scheme is set")
  end

  defp validate_auth_requires_credential(changeset, _auth_scheme, _credential), do: changeset

  defp validate_custom_header(changeset, "custom_header", nil) do
    add_error(changeset, :auth_header_name, "is required when auth_scheme is custom_header")
  end

  defp validate_custom_header(changeset, "custom_header", "") do
    add_error(changeset, :auth_header_name, "is required when auth_scheme is custom_header")
  end

  defp validate_custom_header(changeset, "custom_header", header_name) do
    if String.downcase(header_name) in @headers_deny_list do
      add_error(changeset, :auth_header_name, "must not be a prohibited auth header")
    else
      changeset
    end
  end

  defp validate_custom_header(changeset, _scheme, _header_name), do: changeset
end
