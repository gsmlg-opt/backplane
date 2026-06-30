defmodule Backplane.AuthTest do
  use ExUnit.Case, async: true

  test "auth app exposes the stable facade" do
    assert Code.ensure_loaded?(Backplane.Auth)
    assert Backplane.Auth.module_info(:module) == Backplane.Auth
  end

  test "auth application starts its supervisor" do
    assert Application.spec(:backplane_auth, :mod) == {BackplaneAuth.Application, []}
    assert Process.whereis(BackplaneAuth.Supervisor)
  end
end
