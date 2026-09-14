alias Backplane.SkillProtocol.{Bundle, Client, Resource, SkillRef, Wire}
alias Backplane.SkillProtocol.Source.Backplane, as: BackplaneSource

root = System.fetch_env!("SKILL_PROTOCOL_VERIFY_ROOT")
skill_root = Path.join(root, "verifier-skill")
archive = Path.join(root, "verifier-skill.tar.gz")
File.mkdir_p!(Path.join(skill_root, "references"))

document = "---\nname: verifier-skill\ndescription: Consumer verifier\n---\nBody\n"
File.write!(Path.join(skill_root, "SKILL.md"), document)
File.write!(Path.join(skill_root, "references/guide.md"), "verified resource")

{:ok, parsed} = Backplane.SkillProtocol.Parser.parse(document)
{:ok, validated} = Backplane.SkillProtocol.Validator.validate(parsed)
"verifier-skill" = validated.name

{:ok, _packed} = Bundle.pack(skill_root, archive)

ref = %SkillRef{source_id: "verifier", skill_id: "opaque/id", revision: "r1"}
{:ok, bundle} = Bundle.inspect(archive, ref: ref)
{:ok, local} = Bundle.prepare(bundle, Path.join(root, "local-prepared"))
{:ok, "verified resource"} = Resource.read(local, "references/guide.md")

artifact = File.read!(archive)
manifest_json = bundle.manifest |> Wire.manifest_map() |> JSON.encode!()

catalog_json =
  JSON.encode!(%{
    "protocol_version" => "1",
    "data" => [
      %{
        "skill_id" => "opaque/id",
        "name" => "verifier-skill",
        "description" => "Consumer verifier",
        "revision" => "r1",
        "artifact_digest" => bundle.manifest.artifact_digest,
        "publication_status" => "ready"
      }
    ],
    "next_cursor" => nil
  })

{:ok, listener} =
  :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, ip: {127, 0, 0, 1}])

{:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

server =
  spawn_link(fn ->
    Enum.each([catalog_json, manifest_json, artifact], fn body ->
      {:ok, socket} = :gen_tcp.accept(listener, 5_000)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)

      content_type =
        if String.contains?(request, "/artifact?"),
          do: "application/x-tar+gzip",
          else: "application/json"

      response = [
        "HTTP/1.1 200 OK\r\n",
        "content-type: ",
        content_type,
        "\r\ncontent-length: ",
        Integer.to_string(byte_size(body)),
        "\r\nconnection: close\r\n\r\n",
        body
      ]

      :ok = :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    end)

    :gen_tcp.close(listener)
  end)

server_ref = Process.monitor(server)

client =
  Client.new!(
    endpoint: "http://127.0.0.1:#{port}",
    source_id: "verifier",
    access_context_id: "consumer-verifier",
    max_attempts: 1
  )

{:ok, %{data: [%{name: "verifier-skill"}], next_cursor: nil}} = Client.catalog(client)
source = BackplaneSource.new!(client)

{:ok, remote} =
  BackplaneSource.prepare(source, "opaque/id", "r1",
    destination: Path.join(root, "remote-prepared")
  )

{:ok, "verified resource"} = Resource.read(remote, "references/guide.md")

receive do
  {:DOWN, ^server_ref, :process, ^server, :normal} ->
    :ok

  {:DOWN, ^server_ref, :process, ^server, reason} ->
    raise "loopback verifier exited abnormally: #{inspect(reason)}"
after
  5_000 -> raise "loopback verifier did not terminate"
end

IO.puts("Skill Protocol public parser, bundle/resource, and loopback HTTP APIs passed")
