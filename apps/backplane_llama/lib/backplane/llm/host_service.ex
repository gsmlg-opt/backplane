defmodule Backplane.LLM.HostService do
  @moduledoc "A platform-managed host-local service with explicitly declared API endpoints."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  @protocols ~w(openai_embeddings openai_chat_completions openai_responses anthropic_messages)

  schema "host_api_services" do
    field(:host_id, :binary_id)
    field(:name, :string)
    field(:enabled, :boolean, default: true)
    field(:endpoints, :map, default: %{})
    field(:revision, :integer, default: 1)
    timestamps()
  end

  def protocols, do: @protocols

  def changeset(service, attrs) do
    service
    |> cast(attrs, [:host_id, :name, :enabled, :endpoints])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:host_id, :name, :enabled])
    |> validate_length(:name, max: 128)
    |> validate_endpoint_configuration()
    |> foreign_key_constraint(:host_id)
    |> unique_constraint([:host_id, :name])
  end

  defp validate_endpoint_configuration(changeset) do
    Enum.reduce(
      validate_endpoints(:endpoints, get_field(changeset, :endpoints)),
      changeset,
      fn {field, message}, changeset -> add_error(changeset, field, message) end
    )
  end

  defp validate_endpoints(:endpoints, endpoints) when map_size(endpoints) in 1..4 do
    if Enum.all?(endpoints, fn {api, url} -> api in @protocols and valid_url?(url) end),
      do: [],
      else: [
        endpoints:
          "must map supported APIs to exact HTTP(S) endpoint URLs without embedded credentials or fragments"
      ]
  end

  defp validate_endpoints(:endpoints, _),
    do: [endpoints: "must declare at least one supported API endpoint"]

  defp valid_url?(url) when is_binary(url) and byte_size(url) <= 2048 do
    case URI.new(url) do
      {:ok, %{scheme: scheme, host: host, userinfo: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        not String.contains?(url, ["\"", "\\"]) and not Regex.match?(~r/[\x00-\x20\x7f]/, url)

      _ ->
        false
    end
  end

  defp valid_url?(_), do: false
end
