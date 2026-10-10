defmodule Backplane.Admin.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Backplane.Admin.BuildInfo

  @compiled %{
    environment: "prod",
    git_ref: "main",
    git_sha: "local-commit",
    built_at: "2026-10-10T01:00:00Z"
  }

  test "current version comes from the running application specification" do
    info = BuildInfo.current()

    assert info.version == to_string(Application.spec(:backplane_admin, :vsn))

    assert Map.keys(info) |> Enum.sort() ==
             Enum.sort([:version, :environment, :git_ref, :git_sha, :built_at, :released_at])

    assert Enum.all?(Map.values(info), &is_binary/1)
  end

  test "only the development compilation environment adds the dev suffix" do
    for environment <- ["dev", "prod", "test"] do
      info = BuildInfo.normalize_metadata("1.2.3", %{@compiled | environment: environment}, %{})
      expected = if environment == "dev", do: "v1.2.3-dev", else: "v1.2.3"

      assert BuildInfo.label(info) == expected
    end
  end

  test "deployment metadata overrides compiled metadata" do
    env = %{
      "BACKPLANE_GIT_REF" => " v1.2.3 ",
      "BACKPLANE_GIT_SHA" => "deployed-commit",
      "VCS_REF" => "alternate-commit",
      "BACKPLANE_BUILD_DATE" => "2026-10-10T02:00:00Z",
      "BACKPLANE_RELEASE_DATE" => "2026-10-10T03:00:00Z"
    }

    assert BuildInfo.normalize_metadata(~c"1.2.3", @compiled, env) == %{
             version: "1.2.3",
             environment: "prod",
             git_ref: "v1.2.3",
             git_sha: "deployed-commit",
             built_at: "2026-10-10T02:00:00Z",
             released_at: "2026-10-10T03:00:00Z"
           }
  end

  test "VCS_REF supplies the commit when the primary deployment SHA is missing" do
    info =
      BuildInfo.normalize_metadata("1.2.3", @compiled, %{
        "BACKPLANE_GIT_SHA" => "unknown",
        "VCS_REF" => "alternate-commit"
      })

    assert info.git_sha == "alternate-commit"
  end

  test "empty and unknown deployment values fall back without inventing a release time" do
    for value <- [nil, "", "  ", "unknown", " UNKNOWN ", "Not provided"] do
      env =
        Map.new(
          ~w(BACKPLANE_GIT_REF BACKPLANE_GIT_SHA VCS_REF BACKPLANE_BUILD_DATE BACKPLANE_RELEASE_DATE),
          &{&1, value}
        )

      info = BuildInfo.normalize_metadata("1.2.3", @compiled, env)

      assert info.git_ref == @compiled.git_ref
      assert info.git_sha == @compiled.git_sha
      assert info.built_at == @compiled.built_at
      assert info.released_at == "Not provided"
    end
  end

  test "missing compiled and deployment metadata is explicitly unavailable" do
    info = BuildInfo.normalize_metadata("1.2.3", %{environment: "prod"}, %{})

    assert info.git_ref == "Not provided"
    assert info.git_sha == "Not provided"
    assert info.built_at == "Not provided"
    assert info.released_at == "Not provided"
  end

  test "tooltip distinguishes build time from release time" do
    info = BuildInfo.normalize_metadata("1.2.3", @compiled, %{})

    assert BuildInfo.tooltip(info) == """
           Version: 1.2.3
           Environment: prod
           Git ref: main
           Commit: local-commit
           Build time: 2026-10-10T01:00:00Z
           Release time: Not provided\
           """
  end
end
