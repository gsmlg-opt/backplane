defmodule Backplane.WebOrigins do
  @moduledoc """
  Runtime origins for links crossing the API/admin endpoint boundary.
  """

  @default_api_url "http://localhost:4220"
  @default_admin_url "http://localhost:4221"

  @spec api_base_url() :: String.t()
  def api_base_url, do: base_url(:api_url, @default_api_url)

  @spec admin_base_url() :: String.t()
  def admin_base_url, do: base_url(:admin_url, @default_admin_url)

  @spec api_url(String.t()) :: String.t()
  def api_url(path \\ "/"), do: join(api_base_url(), path)

  @spec admin_url(String.t()) :: String.t()
  def admin_url(path \\ "/admin"), do: join(admin_base_url(), path)

  defp base_url(key, default) do
    :backplane
    |> Application.get_env(key, default)
    |> String.trim_trailing("/")
  end

  defp join(base_url, path) when is_binary(path) do
    normalized_path = "/" <> String.trim_leading(path, "/")
    base_url <> normalized_path
  end
end
