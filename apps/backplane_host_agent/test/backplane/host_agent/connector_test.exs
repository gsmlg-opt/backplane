defmodule Backplane.HostAgent.ConnectorTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Connector

  test "rejects a missing host identity before opening a socket" do
    assert {:error, {:missing_required_config, [:host_id]}} = Connector.connect(%{})
  end
end
