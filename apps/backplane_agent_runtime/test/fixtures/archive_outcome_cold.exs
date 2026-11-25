Code.require_file("staged_export_file_host.exs", __DIR__)

alias Backplane.AgentRuntime.Codex.MultiAgent.Archive
alias Backplane.AgentRuntime.StagedExportFileHostFixture, as: Store

[directory, result_path] = System.argv()
host_module = Backplane.AgentRuntime.Codex.ArchiveOutcomeTest.ProviderFailure
false = Code.ensure_loaded?(host_module)
{:ok, store} = Store.open(directory)
{:ok, archive} = Store.get(store, {:evidence, "cold-archive"})
{:ok, original} = Store.load(store, archive["child_identity"]["run_id"])
{:ok, %{snapshot: %{run: run}}} = Archive.restore({Store, store}, archive)
true = run == original.run
false = Code.ensure_loaded?(host_module)
:ok = Store.cleanup(store)
File.write!(result_path, "restored without host module\n")
