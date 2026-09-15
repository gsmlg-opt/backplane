alias Backplane.SkillProtocol.{Bundle, Client, Error, SkillRef, Wire}
alias Backplane.SkillProtocol.Source.Backplane, as: BackplaneSource

archive = System.fetch_env!("SKILL_PROTOCOL_PROBE_ARCHIVE")
destination = System.fetch_env!("SKILL_PROTOCOL_PROBE_DESTINATION")
parent = Path.dirname(destination)
prefix = ".#{Path.basename(destination)}.stage.*"
bytes = File.read!(archive)

ref = %SkillRef{
  source_id: "permission-probe",
  skill_id: "permission/probe",
  revision: "r1"
}

{:ok, bundle} = Bundle.inspect(archive, ref: ref)

permission = fn path ->
  {:ok, stat} = File.stat(path)
  stat.mode |> Bitwise.band(0o777) |> Integer.to_string(8)
end

source_glob = Path.join(System.tmp_dir!(), "backplane-skill-protocol-source.*")
inflate_glob = Path.join(System.tmp_dir!(), "backplane-skill-protocol.*")
existing_source = source_glob |> Path.wildcard() |> MapSet.new()
existing_inflate = inflate_glob |> Path.wildcard() |> MapSet.new()
{:ok, source_observed} = Agent.start_link(fn -> nil end)
{:ok, inflate_observed} = Agent.start_link(fn -> nil end)

remote_cancelled? = fn ->
  source_stage =
    source_glob
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(existing_source, &1))
    |> Enum.find(&File.exists?(Path.join(&1, "artifact.tar.gz")))

  inflate_stage =
    inflate_glob
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(existing_inflate, &1))
    |> Enum.reject(&String.contains?(&1, "-source."))
    |> Enum.find(&File.exists?(Path.join(&1, "archive.tar")))

  if source_stage do
    Agent.update(source_observed, fn _ ->
      {source_stage, permission.(source_stage),
       permission.(Path.join(source_stage, "artifact.tar.gz"))}
    end)
  end

  if inflate_stage do
    Agent.update(inflate_observed, fn _ ->
      {inflate_stage, permission.(inflate_stage),
       permission.(Path.join(inflate_stage, "archive.tar"))}
    end)
  end

  source_stage != nil and inflate_stage != nil
end

manifest_response = %{
  status: 200,
  headers: %{},
  body: JSON.encode!(Wire.manifest_map(bundle.manifest))
}

artifact_response = %{status: 200, headers: %{}, body: bytes}
{:ok, responses} = Agent.start_link(fn -> [manifest_response, artifact_response] end)

client =
  Client.new!(
    endpoint: "https://permission-probe.invalid",
    source_id: "permission-probe",
    access_context_id: "permission-probe",
    credential_supplier: fn -> nil end,
    retry_delays_ms: [],
    transport: fn _request ->
      Agent.get_and_update(responses, fn [response | rest] -> {{:ok, response}, rest} end)
    end
  )

source = BackplaneSource.new!(client)

{:error, %Error{code: :cancelled}} =
  BackplaneSource.prepare(source, "permission/probe", "r1",
    destination: destination <> "-remote",
    cancelled?: remote_cancelled?
  )

{source_stage, source_dir_mode, source_file_mode} = Agent.get(source_observed, & &1)
{inflate_stage, inflate_dir_mode, inflate_file_mode} = Agent.get(inflate_observed, & &1)
source_cleanup = if File.exists?(source_stage), do: "leaked", else: "clean"
inflate_cleanup = if File.exists?(inflate_stage), do: "leaked", else: "clean"

{:ok, checks} = Agent.start_link(fn -> 0 end)

prepare_cancelled? = fn ->
  check = Agent.get_and_update(checks, &{&1, &1 + 1})

  if check == 2 do
    [stage] = Path.wildcard(Path.join(parent, prefix), match_dot: true)
    file = Path.join(stage, "SKILL.md")
    Process.put(:permissions, {permission.(stage), permission.(file)})
    true
  else
    false
  end
end

{:error, %Error{code: :cancelled}} =
  Bundle.prepare(bundle, destination, cancelled?: prepare_cancelled?)

{directory_mode, file_mode} = Process.get(:permissions)

cleanup =
  if Path.wildcard(Path.join(parent, prefix), match_dot: true) == [],
    do: "clean",
    else: "leaked"

IO.puts(
  "source=#{source_dir_mode}/#{source_file_mode}/#{source_cleanup} " <>
    "inflate=#{inflate_dir_mode}/#{inflate_file_mode}/#{inflate_cleanup} " <>
    "prepare=#{directory_mode}/#{file_mode}/#{cleanup}"
)
