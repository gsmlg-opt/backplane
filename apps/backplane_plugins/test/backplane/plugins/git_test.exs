defmodule Backplane.Plugins.GitTest do
  use BackplanePlugins.DataCase, async: false
  alias Backplane.Plugins.Git
  alias Backplane.Settings.{Credential, Encryption}
  alias Backplane.Settings.Credentials.Vault

  test "publishing accepts HTTPS Git hosts while synchronization stays GitHub-only" do
    for url <- [
          "https://github.com/team/plugins.git",
          "https://gitea.example.test/team/plugins.git",
          "https://git.example.test:8443/team/plugins",
          "https://[::1]:8443/plugins.git"
        ] do
      assert :ok = Git.validate_publish_url(url)
    end

    assert :ok = Git.validate_url("https://github.com/team/plugins.git", [])

    assert {:error, :invalid_github_url} =
             Git.validate_url("https://gitea.example.test/team/plugins.git", [])
  end

  test "publishing rejects credentials, query, fragment and non-HTTPS targets" do
    for url <- [
          nil,
          "https://user:token@gitea.example.test/team/plugins.git",
          "https://user@gitea.example.test/team/plugins.git",
          "https://gitea.example.test/team/plugins.git?token=secret",
          "https://gitea.example.test/team/plugins.git#main",
          "http://gitea.example.test/team/plugins.git",
          "ssh://git@gitea.example.test/team/plugins.git",
          "git@gitea.example.test:team/plugins.git",
          "file:///tmp/plugins.git",
          "/tmp/plugins.git",
          "https://*.example.test/team/plugins.git",
          "https://gitea.example.test:0/team/plugins.git",
          "https://gitea.example.test:65536/team/plugins.git",
          "https://gitea.example.test/team/\nplugins.git",
          "https://gitea.example.test/team\\plugins.git"
        ] do
      assert {:error, :invalid_publish_url} = Git.validate_publish_url(url)
    end

    assert :ok = Git.validate_publish_url("/tmp/plugins.git", allow_local: true)
  end

  test "publishing credentials match only the selected HTTPS target and redirects are disabled" do
    name = "plugin-gitea-" <> Ecto.UUID.generate()
    token = "fixture-token"
    url = "https://gitea.example.test:8443/team/plugins.git"
    put_credential(name, token, %{"git_username" => "operator"})
    assert {:ok, env} = Git.publish_env(url, credential_name: name)
    expected = "Authorization: Basic " <> Base.encode64("operator:" <> token)

    assert {"false\n", 0} = git_config(env, ["--get", "http.followRedirects"])
    assert {expected <> "\n", 0} == git_config(env, ["--get-urlmatch", "http.extraheader", url])

    assert {expected <> "\n", 0} ==
             git_config(env, ["--get-urlmatch", "http.extraheader", url <> "/info/refs"])

    for other <- [
          "https://other.example.test:8443/team/plugins.git",
          "https://gitea.example.test/team/plugins.git",
          "http://gitea.example.test:8443/team/plugins.git",
          "https://gitea.example.test:8443/other/plugins.git"
        ] do
      assert {"", 1} = git_config(env, ["--get-urlmatch", "http.extraheader", other])
    end

    assert Enum.any?(env, fn {key, value} ->
             String.starts_with?(key, "GIT_CONFIG_KEY_") and
               value == "http.#{url}.extraheader"
           end)
  end

  test "publishing defaults to the token username and also disables unauthenticated redirects" do
    name = "plugin-github-" <> Ecto.UUID.generate()
    url = "https://github.com/team/plugins.git"
    put_credential(name, "fixture-token")
    assert {:ok, env} = Git.publish_env(url, credential_name: name)
    expected = "Authorization: Basic " <> Base.encode64("x-access-token:fixture-token")
    assert {expected <> "\n", 0} == git_config(env, ["--get-urlmatch", "http.extraheader", url])
    assert {:ok, public_env} = Git.publish_env(url)
    assert {"false\n", 0} = git_config(public_env, ["--get", "http.followRedirects"])
    assert {"", 1} = git_config(public_env, ["--get-urlmatch", "http.extraheader", url])
    assert {:ok, ^public_env} = Git.publish_env(url, credential_name: "")
  end

  test "publishing rejects unsupported credential contracts" do
    name = "plugin-invalid-" <> Ecto.UUID.generate()
    url = "https://gitea.example.test/team/plugins.git"

    put_credential(name, "fixture-token", %{"git_username" => "user:other"})

    assert {:error, :unsupported_git_credential} = Git.publish_env(url, credential_name: name)

    put_credential(name, "fixture-token", %{"auth_type" => "unsupported"})

    assert {:error, :unsupported_git_credential} = Git.publish_env(url, credential_name: name)
  end

  @tag :tmp_dir
  test "credential queries exclude the enclosing checkout's local header", %{tmp_dir: tmp_dir} do
    checkout = Path.join(tmp_dir, "checkout")
    url = "https://github.com/team/plugins.git"
    sentinel = "Authorization: fixture-checkout-only"
    assert {_, 0} = System.cmd("git", ["init", "--quiet", checkout])

    assert {_, 0} =
             System.cmd("git", [
               "-C",
               checkout,
               "config",
               "http.https://github.com/.extraheader",
               sentinel
             ])

    assert {:ok, public_env} = Git.publish_env(url)

    assert {sentinel <> "\n", 0} ==
             System.cmd("git", ["config", "--get-urlmatch", "http.extraheader", url],
               cd: checkout,
               env: [{"GIT_CONFIG_GLOBAL", "/dev/null"} | public_env]
             )

    assert {"", 1} = git_config(public_env, ["--get-urlmatch", "http.extraheader", url], checkout)

    name = "plugin-isolated-" <> Ecto.UUID.generate()
    put_credential(name, "fixture-token")
    assert {:ok, authenticated_env} = Git.publish_env(url, credential_name: name)
    expected = "Authorization: Basic " <> Base.encode64("x-access-token:fixture-token")

    assert {expected <> "\n", 0} ==
             git_config(authenticated_env, ["--get-urlmatch", "http.extraheader", url], checkout)
  end

  defp put_credential(name, token, metadata \\ %{}) do
    Vault.put(%Credential{
      name: name,
      kind: "service",
      encrypted_value: Encryption.encrypt(token),
      metadata: metadata
    })

    on_exit(fn -> Vault.remove(name) end)
  end

  defp git_config(env, args, directory \\ File.cwd!()) do
    isolated =
      Path.join(System.tmp_dir!(), "plugin-git-config-#{System.unique_integer([:positive])}")

    try do
      assert {_, 0} = System.cmd("git", ["init", "--quiet", isolated])

      System.cmd("git", ["-C", isolated, "config" | args],
        cd: directory,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"} | env],
        stderr_to_stdout: true
      )
    after
      File.rm_rf!(isolated)
    end
  end
end
