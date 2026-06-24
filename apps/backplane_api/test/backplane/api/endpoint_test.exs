defmodule Backplane.Api.EndpointTest do
  use ExUnit.Case, async: true

  test "disables origin checks" do
    endpoint_config = Application.fetch_env!(:backplane_api, Backplane.Api.Endpoint)

    assert Keyword.fetch!(endpoint_config, :check_origin) == false
  end
end
