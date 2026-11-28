defmodule Backplane.CDP.ConfigTest do
  use ExUnit.Case, async: false

  alias Backplane.CDP
  alias Backplane.CDP.Config
  alias Backplane.CDP.MCP.{Artifacts, Script, Upload}

  @moduletag :tmp_dir
  @environment ~w(BACKPLANE_CDP_PORT BACKPLANE_CDP_ARTIFACT_DIR BACKPLANE_CDP_UPLOAD_DIR)

  setup do
    previous_config = Application.fetch_env(:backplane_cdp, :config)
    previous_environment = Map.new(@environment, &{&1, System.get_env(&1)})
    Application.delete_env(:backplane_cdp, :config)
    Enum.each(@environment, &System.delete_env/1)

    on_exit(fn ->
      case previous_config do
        {:ok, config} -> Application.put_env(:backplane_cdp, :config, config)
        :error -> Application.delete_env(:backplane_cdp, :config)
      end

      Enum.each(previous_environment, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "unconfigured CDP is disabled and explains host config and environment options" do
    refute CDP.enabled?()
    assert {:error, message} = CDP.port()
    assert message =~ "cdp.enabled"
    assert message =~ "cdp.port"
    assert message =~ "BACKPLANE_CDP_PORT"
  end

  test "explicit enablement defaults to Chrome port 9222 when no port is supplied" do
    Application.put_env(:backplane_cdp, :config, %{enabled: true})
    assert {:ok, 9222} = CDP.port()
    assert CDP.enabled?()
    System.put_env("BACKPLANE_CDP_PORT", "")
    assert {:ok, 9222} = CDP.port()
  end

  test "the file port overrides the environment port and explicit false overrides both" do
    System.put_env("BACKPLANE_CDP_PORT", "9223")
    Application.put_env(:backplane_cdp, :config, %{port: 9444})
    assert {:ok, 9444} = CDP.port()
    assert CDP.enabled?()

    Application.put_env(:backplane_cdp, :config, %{enabled: false, port: 9444})
    assert {:error, "Chrome DevTools is disabled by cdp.enabled in the host config"} = CDP.port()
    refute CDP.enabled?()
  end

  test "missing file port preserves the standalone environment setup" do
    System.put_env("BACKPLANE_CDP_PORT", "9333")
    assert {:ok, 9333} = CDP.port()
    Application.put_env(:backplane_cdp, :config, %{enabled: true})
    assert {:ok, 9333} = CDP.port()
  end

  test "invalid configured values are reported without falling back to environment values" do
    System.put_env("BACKPLANE_CDP_PORT", "9222")

    for port <- [0, 65_536, nil, "9444", false] do
      Application.put_env(:backplane_cdp, :config, %{enabled: true, port: port})
      assert {:error, message} = CDP.port()
      assert message =~ "cdp.port"
      refute CDP.enabled?()
    end

    for enabled <- [nil, "true", 1] do
      Application.put_env(:backplane_cdp, :config, %{enabled: enabled, port: 9222})
      assert {:error, message} = CDP.port()
      assert message =~ "cdp.enabled"
    end

    Application.put_env(:backplane_cdp, :config, [])
    assert {:error, message} = CDP.port()
    assert message =~ "must be a map"
  end

  test "invalid environment ports retain an error instead of using the enabled default" do
    Application.put_env(:backplane_cdp, :config, %{enabled: true})

    for port <- ["0", "65536", "9222trailing", " 9222"] do
      System.put_env("BACKPLANE_CDP_PORT", port)
      assert {:error, message} = CDP.port()
      assert message =~ "BACKPLANE_CDP_PORT"
      assert message =~ "cdp.port"
    end
  end

  test "directory settings override environment fields independently", %{tmp_dir: directory} do
    artifact = Path.join(directory, "artifacts")
    upload = Path.join(directory, "uploads")
    environment = Path.join(directory, "environment")
    Enum.each([artifact, upload, environment], &File.mkdir!/1)
    System.put_env("BACKPLANE_CDP_ARTIFACT_DIR", environment)
    System.put_env("BACKPLANE_CDP_UPLOAD_DIR", environment)
    Application.put_env(:backplane_cdp, :config, %{artifact_dir: artifact, upload_dir: upload})
    assert {:ok, ^artifact} = Config.artifact_dir()
    assert {:ok, ^upload} = Config.upload_dir()

    Application.put_env(:backplane_cdp, :config, %{upload_dir: upload})
    assert {:ok, ^environment} = Config.artifact_dir()
    assert {:ok, ^upload} = Config.upload_dir()
  end

  test "explicit empty directory fields suppress environment fallback", %{tmp_dir: directory} do
    System.put_env("BACKPLANE_CDP_ARTIFACT_DIR", directory)
    System.put_env("BACKPLANE_CDP_UPLOAD_DIR", directory)

    for empty <- [nil, ""] do
      Application.put_env(:backplane_cdp, :config, %{artifact_dir: empty, upload_dir: empty})
      assert {:error, artifact_message} = Config.artifact_dir()
      assert artifact_message =~ "cdp.artifact_dir"
      assert artifact_message =~ "BACKPLANE_CDP_ARTIFACT_DIR"
      assert {:error, upload_message} = Config.upload_dir()
      assert upload_message =~ "cdp.upload_dir"
      assert upload_message =~ "BACKPLANE_CDP_UPLOAD_DIR"
    end
  end

  test "directory settings require existing directories", %{tmp_dir: directory} do
    Application.put_env(:backplane_cdp, :config, %{
      artifact_dir: Path.join(directory, "missing"),
      upload_dir: 123
    })

    assert {:error, _} = Config.artifact_dir()
    assert {:error, _} = Config.upload_dir()
  end

  test "artifact paths use the configured directory through the normal writer", %{
    tmp_dir: directory
  } do
    configured = Path.join(directory, "configured")
    environment = Path.join(directory, "environment")
    File.mkdir!(configured)
    File.mkdir!(environment)
    System.put_env("BACKPLANE_CDP_ARTIFACT_DIR", environment)
    Application.put_env(:backplane_cdp, :config, %{artifact_dir: configured})
    path = Path.join(configured, "snapshot.txt")
    assert {:ok, ^path} = Artifacts.write("snapshot.txt", "snapshot")
    assert File.read!(path) == "snapshot"
    assert File.ls!(environment) == []
    assert {:error, message} = Artifacts.destination("../outside", "")
    assert message =~ "cdp.artifact_dir"
    assert message =~ "BACKPLANE_CDP_ARTIFACT_DIR"
  end

  test "upload paths use the configured directory before validating individual files", %{
    tmp_dir: directory
  } do
    Application.put_env(:backplane_cdp, :config, %{upload_dir: directory})
    System.put_env("BACKPLANE_CDP_UPLOAD_DIR", Path.join(directory, "missing"))

    assert {:error, message, %{}} =
             Upload.call("upload_file", %{"filePaths" => ["../outside"]}, %{})

    assert message ==
             "Choose regular files directly inside cdp.upload_dir (host config) or BACKPLANE_CDP_UPLOAD_DIR"
  end

  test "script source paths read the configured upload directory", %{tmp_dir: directory} do
    File.write!(Path.join(directory, "inspect.js"), "document.title")
    Application.put_env(:backplane_cdp, :config, %{upload_dir: directory})
    System.put_env("BACKPLANE_CDP_UPLOAD_DIR", Path.join(directory, "missing"))
    args = %{"sourcePath" => "inspect.js", "format" => "script", "args" => ["uid"]}

    assert {:error, ~s(args cannot be used when format is "script".), %{}} =
             Script.call("evaluate_script", args, %{})
  end

  test "legacy directory environment variables still support artifact creation", %{
    tmp_dir: directory
  } do
    System.put_env("BACKPLANE_CDP_ARTIFACT_DIR", directory)
    System.put_env("BACKPLANE_CDP_UPLOAD_DIR", directory)
    path = Path.join(directory, "legacy.txt")
    assert {:ok, ^path} = Artifacts.write("legacy.txt", "legacy")
    assert {:ok, ^directory} = Config.upload_dir()
  end
end
