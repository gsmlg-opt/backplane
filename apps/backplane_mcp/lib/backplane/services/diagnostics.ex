defmodule Backplane.Services.Diagnostics do
  @moduledoc "Read-only access to Diagnostics through an explicitly scoped main MCP client."

  @behaviour Backplane.Services.ManagedService

  alias Backplane.Diagnostics.Queries

  @scope "diagnostics::read"
  @text %{"type" => "string", "maxLength" => 128}
  @id %{"type" => "integer", "minimum" => 1}

  @impl true
  def prefix, do: "diagnostics"

  @impl true
  def enabled?, do: true

  def tool?("diagnostics::" <> _), do: true
  def tool?(_), do: false

  @doc "Diagnostic evidence uses an exact read scope on the authenticated main resource."
  def allowed?(%{kind: kind, resource: :mcp, scopes: scopes})
      when kind in [:client_token, :oauth] and is_list(scopes),
      do: @scope in scopes

  def allowed?(_), do: false

  @impl true
  def tools do
    [
      tool(
        "search_issues",
        "Find a bounded page of diagnostic issues.",
        [],
        %{
          "status" => @text,
          "severity" => @text,
          "category" => @text,
          "cursor" => @text,
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
        },
        &Queries.search_issues/1
      ),
      tool(
        "get_issue",
        "Read the issue status, counts, and recent observations.",
        ["issue_id"],
        %{"issue_id" => @id},
        &Queries.get_issue(&1["issue_id"])
      ),
      tool(
        "get_run",
        "Read a source-scoped execution and its observation gaps.",
        ~w(source_id run_id),
        %{"source_id" => @text, "run_id" => @text},
        &Queries.get_run(&1["source_id"], &1["run_id"])
      ),
      tool(
        "get_evidence",
        "Read one redacted reference inside the specified evidence bundle.",
        ~w(bundle_id reference),
        %{"bundle_id" => @id, "reference" => @text},
        &Queries.get_evidence(&1["bundle_id"], &1["reference"])
      ),
      tool(
        "get_report",
        "Read the latest diagnostics report and available repair material.",
        ["issue_id"],
        %{"issue_id" => @id},
        &Queries.get_report(&1["issue_id"])
      )
    ]
  end

  defp tool(name, description, required, props, read) do
    %{
      name: "diagnostics::" <> name,
      description: description,
      input_schema: %{
        "type" => "object",
        "required" => required,
        "properties" => props,
        "additionalProperties" => false
      },
      handler: fn args, auth ->
        if allowed?(auth), do: read.(args), else: {:error, :insufficient_scope}
      end
    }
  end
end
