ExUnit.start()

defmodule Backplane.BuildWebAssetsScriptTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("..", __DIR__)
  @script Path.join(@repo_root, "scripts/build_web_assets.sh")

  setup do
    root =
      Path.join(System.tmp_dir!(), "backplane-asset-build-#{System.unique_integer([:positive])}")

    bin = Path.join(root, "bin")
    log = Path.join(root, "calls.log")
    File.mkdir_p!(bin)
    write_fake(Path.join(bin, "mix"), "mix")
    write_fake(Path.join(bin, "elixir"), "elixir")
    on_exit(fn -> File.rm_rf!(root) end)
    %{bin: bin, log: log}
  end

  test "runs both named profiles in separate processes from the umbrella root", context do
    {output, 0} = run_script(context)
    assert output == ""

    assert File.read!(context.log) |> String.split("\n", trim: true) == [
             "#{@repo_root}\tmix do --app backplane_api phx.digest.clean",
             "#{@repo_root}\tmix do --app backplane_admin phx.digest.clean",
             "#{@repo_root}\tmix duskmoon_bundler.build backplane_api --tailwind",
             "#{@repo_root}\tmix duskmoon_bundler.build backplane_admin --tailwind",
             "#{@repo_root}\tmix do --app backplane_api phx.digest",
             "#{@repo_root}\tmix do --app backplane_admin phx.digest",
             "#{@repo_root}\telixir -pa _build/test/lib/jason/ebin scripts/verify_web_assets.exs --source ."
           ]
  end

  test "stops immediately when the admin profile build fails", context do
    {_, status} = run_script(context, [{"FAIL_ADMIN_BUILD", "1"}])
    assert status == 23

    calls = File.read!(context.log)
    assert calls =~ "duskmoon_bundler.build backplane_api --tailwind"
    assert calls =~ "duskmoon_bundler.build backplane_admin --tailwind"
    refute calls =~ "phx.digest\n"
    refute calls =~ "\telixir "
  end

  defp run_script(context, extra_env \\ []) do
    path = context.bin <> ":" <> System.fetch_env!("PATH")
    env = [{"ASSET_BUILD_CALL_LOG", context.log}, {"MIX_ENV", "test"}, {"PATH", path} | extra_env]
    System.cmd("bash", [@script], env: env, stderr_to_stdout: true)
  end

  defp write_fake(path, command) do
    File.write!(
      path,
      """
      #!/usr/bin/env bash
      printf '%s\\t#{command} %s\\n' "$PWD" "$*" >> "$ASSET_BUILD_CALL_LOG"
      if [[ "${FAIL_ADMIN_BUILD:-}" == "1" && "$*" == "duskmoon_bundler.build backplane_admin --tailwind" ]]; then
        exit 23
      fi
      """
    )

    File.chmod!(path, 0o755)
  end
end
