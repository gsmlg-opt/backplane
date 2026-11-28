defmodule Backplane.CDP.MCP.Upload do
  @moduledoc false
  alias Backplane.CDP.{Client, Config}
  alias Backplane.CDP.MCP.{Pages, Snapshot}

  def call("upload_file", args, state) do
    with {:ok, paths} <- files(args["filePaths"]),
         {:ok, target, state} <- Pages.selected(args, state) do
      result =
        Client.with_connection(state.port, target, fn conn ->
          with {:ok, backend} <- Snapshot.backend(target, state, args["uid"]),
               :ok <- Snapshot.current_document(conn, target, state),
               {:ok, _} <-
                 Client.send_command(conn, "DOM.setFileInputFiles", %{
                   "backendNodeId" => backend,
                   "files" => paths
                 }) do
            message = "File uploaded from #{Enum.join(args["filePaths"], ", ")}."

            if args["includeSnapshot"] do
              with {:ok, tree, state} <- Snapshot.capture(conn, target, state),
                   do: success(message <> "\n" <> tree, state)
            else
              success(message, state)
            end
          end
        end)

      case result do
        {:error, reason} -> {:error, reason, state}
        reply -> reply
      end
    else
      {:error, reason} -> {:error, reason, state}
      other -> other
    end
  end

  defp files(paths) do
    with {:ok, root} <- Config.upload_dir(),
         expanded = Enum.map(paths, &Path.expand(&1, root)),
         true <-
           Enum.all?(
             expanded,
             &(Path.dirname(&1) == root and match?({:ok, %{type: :regular}}, File.lstat(&1)))
           ) do
      {:ok, expanded}
    else
      {:error, _message} = error ->
        error

      false ->
        {:error,
         "Choose regular files directly inside cdp.upload_dir (host config) or BACKPLANE_CDP_UPLOAD_DIR"}
    end
  end

  defp success(message, state), do: {:ok, [%{"type" => "text", "text" => message}], state}
end
