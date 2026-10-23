defmodule Backplane.Plugins.Git do
  @moduledoc "Fetches one pinned Git snapshot without checking out or executing its content."

  def snapshot(url, ref, opts \\ []) do
    with {:ok, commit, files, _modes} <- snapshot_with_metadata(url, ref, opts),
         do: {:ok, commit, files}
  end

  def snapshot_with_metadata(url, ref, opts \\ []) do
    with :ok <- validate_url(url, opts), {:ok, env} <- credential_env(opts) do
      temporary(fn directory ->
        with {:ok, _} <- command(["init", "--quiet", directory], env),
             {:ok, _} <-
               command(["-C", directory, "fetch", "--quiet", "--depth=1", "--", url, ref], env),
             {:ok, commit} <- command(["-C", directory, "rev-parse", "FETCH_HEAD"], env),
             commit <- String.trim(commit),
             {:ok, tree} <- command(["-C", directory, "ls-tree", "-rz", commit], env),
             {:ok, files, modes} <- read_tree(directory, tree, env) do
          {:ok, commit, files, modes}
        end
      end)
    end
  end

  def credential_env(opts) do
    base = [{"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

    case Keyword.get(opts, :credential_name) do
      nil ->
        {:ok, base}

      name ->
        with {:ok, token} <- Backplane.Settings.Credentials.fetch(name) do
          header = "Authorization: Basic " <> Base.encode64("x-access-token:" <> token)

          {:ok,
           base ++
             [
               {"GIT_CONFIG_COUNT", "1"},
               {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"},
               {"GIT_CONFIG_VALUE_0", header}
             ]}
        end
    end
  end

  def validate_url(url, opts) when is_binary(url) do
    cond do
      Keyword.get(opts, :allow_local, false) and Path.type(url) == :absolute ->
        :ok

      Regex.match?(~r/\Ahttps:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?\z/, url) ->
        :ok

      true ->
        {:error, :invalid_github_url}
    end
  end

  def validate_url(_, _), do: {:error, :invalid_github_url}

  @doc "Accept HTTPS publishing targets without embedded credentials, query or fragment."
  def validate_publish_url(url, opts \\ [])

  def validate_publish_url(url, opts) when is_binary(url) do
    if Keyword.get(opts, :allow_local, false) and Path.type(url) == :absolute do
      :ok
    else
      with false <- Regex.match?(~r/[[:space:][:cntrl:]\\]/, url),
           {:ok,
            %URI{
              scheme: "https",
              host: host,
              port: port,
              userinfo: nil,
              query: nil,
              fragment: nil
            }} <-
             URI.new(url),
           true <- valid_host?(host) and is_integer(port) and port in 1..65535 do
        :ok
      else
        _ -> {:error, :invalid_publish_url}
      end
    end
  end

  def validate_publish_url(_, _), do: {:error, :invalid_publish_url}

  @doc """
  Limit HTTP Basic token authentication to this publishing URL and disable redirects.
  Vault metadata `git_username` defaults to `x-access-token`; the token is the password.
  The target server must support this authentication contract. No credentials enter argv.
  """
  def publish_env(url, opts \\ []) do
    with :ok <- validate_publish_url(url, opts),
         {:ok, headers} <- publish_headers(url, Keyword.get(opts, :credential_name)) do
      settings = [{"http.followRedirects", "false"} | headers]

      env =
        [
          {"GIT_TERMINAL_PROMPT", "0"},
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_CONFIG_COUNT", Integer.to_string(length(settings))}
        ] ++
          Enum.flat_map(Enum.with_index(settings), fn {{key, value}, index} ->
            [{"GIT_CONFIG_KEY_#{index}", key}, {"GIT_CONFIG_VALUE_#{index}", value}]
          end)

      {:ok, env}
    end
  end

  defp publish_headers(_url, name) when name in [nil, ""], do: {:ok, []}

  defp publish_headers(url, name) do
    with {:ok, token, meta} <- Backplane.Settings.Credentials.fetch_with_meta(name),
         true <- meta.auth_type in [nil, "api_key"],
         username <- Map.get(meta.metadata, "git_username", "x-access-token"),
         true <- is_binary(username) and username != "" and not String.contains?(username, ":") do
      {:ok,
       [
         {"http.#{url}.extraheader",
          "Authorization: Basic " <> Base.encode64(username <> ":" <> token)}
       ]}
    else
      false -> {:error, :unsupported_git_credential}
      error -> error
    end
  end

  defp valid_host?(host) when is_binary(host) and host != "" do
    Regex.match?(~r/\A[A-Za-z0-9.-]+\z/, host) or
      match?({:ok, _}, :inet.parse_ipv6_address(String.to_charlist(host)))
  end

  defp valid_host?(_), do: false

  def command(args, env \\ []) do
    case System.cmd(
           "git",
           ["-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never" | args],
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:git_failed, status}}
    end
  end

  def temporary(callback) do
    path = Path.join(System.tmp_dir!(), "backplane-plugin-git-" <> Ecto.UUID.generate())
    File.mkdir_p!(path)

    try do
      callback.(path)
    after
      File.rm_rf!(path)
    end
  end

  defp read_tree(directory, tree, env) do
    tree
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce_while({:ok, %{}, %{}}, fn entry, {:ok, files, modes} ->
      [metadata, path] = String.split(entry, "\t", parts: 2)

      case String.split(metadata, " ") do
        [mode, "blob", oid] when mode in ["100644", "100755"] ->
          case command(["-C", directory, "cat-file", "blob", oid], env) do
            {:ok, bytes} ->
              {:cont,
               {:ok, Map.put(files, path, bytes),
                Map.put(modes, path, if(mode == "100755", do: 0o755, else: 0o644))}}

            error ->
              {:halt, error}
          end

        _ ->
          {:halt, {:error, :unsupported_git_entry}}
      end
    end)
  end
end
