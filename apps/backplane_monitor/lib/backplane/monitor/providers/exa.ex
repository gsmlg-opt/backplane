defmodule Backplane.Monitor.Providers.Exa do
  @moduledoc "Reports when Exa team usage analytics are unavailable."

  @spec fetch() :: {:ok, map()}
  def fetch do
    {:ok,
     %{
       balances: [],
       usage: [],
       limit: nil,
       is_available: nil,
       warnings: [{:usage_unavailable, :team_management_key_required}]
     }}
  end
end
