defmodule Backplane.Skills.Hosts do
  @moduledoc """
  Public context for host agents that sync assigned skills.
  """

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.Skills.Host

  @doc "List host agents ordered by name."
  @spec list_hosts() :: [Host.t()]
  def list_hosts do
    Host |> order_by(:name) |> Repo.all()
  end

  @doc "Fetch a host agent by ID."
  @spec get_host(Ecto.UUID.t()) :: Host.t() | nil
  def get_host(id), do: Repo.get(Host, id)

  @doc "Create a host agent and return the plaintext token once."
  @spec create_host(map()) :: {:ok, Host.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_host(attrs) when is_map(attrs) do
    token = "bha_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    params =
      attrs
      |> stringify_keys()
      |> Map.put("token_hash", Bcrypt.hash_pwd_salt(token))
      |> normalize_targets()

    case %Host{} |> Host.changeset(params) |> Repo.insert() do
      {:ok, host} -> {:ok, host, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Verify an active host token."
  @spec verify_token(term()) :: {:ok, Host.t()} | :error
  def verify_token(token) when is_binary(token) do
    hosts = Host |> where(active: true) |> Repo.all()

    case Enum.find(hosts, &Bcrypt.verify_pass(token, &1.token_hash)) do
      nil ->
        Bcrypt.no_user_verify()
        :error

      host ->
        {:ok, touch_last_seen(host)}
    end
  end

  def verify_token(_), do: :error

  @doc "Record a host heartbeat."
  @spec heartbeat(Host.t(), map()) :: {:ok, Host.t()} | {:error, Ecto.Changeset.t()}
  def heartbeat(%Host{} = host, attrs) when is_map(attrs) do
    params =
      attrs
      |> stringify_keys()
      |> normalize_targets()
      |> Map.put("status", "online")
      |> Map.put("last_seen_at", DateTime.utc_now())

    host
    |> Host.changeset(params)
    |> Repo.update()
  end

  defp touch_last_seen(host) do
    {:ok, host} =
      host
      |> Host.changeset(%{"last_seen_at" => DateTime.utc_now()})
      |> Repo.update()

    host
  end

  defp normalize_targets(%{"targets" => targets} = attrs) when is_list(targets) do
    targets =
      Map.new(targets, fn target ->
        target = stringify_keys(target)
        {target["name"], target}
      end)

    Map.put(attrs, "targets", targets)
  end

  defp normalize_targets(attrs), do: attrs

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
