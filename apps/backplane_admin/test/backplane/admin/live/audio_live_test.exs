defmodule Backplane.Admin.AudioLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Admin.AudioPreview
  alias Backplane.Audio.{Binding, Config}
  alias Backplane.Audio.Media.{Admission, Runner, TempFiles}
  alias Backplane.LLM.{ModelAlias, Provider, ProviderModel}

  @moduletag :tmp_dir
  alias Backplane.Settings.Credentials

  setup do
    observer_owner = self()
    telemetry_id = "observed_preview-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:backplane, :llm_proxy, :request, :stop],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.attributes["operation"] || "", "audio.preview."),
            do: send(observer_owner, {:observed_preview, metadata.attributes})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)
    :ok = Config.set_enabled(false)
    :ok = Config.set_voices(%{})
    :ok = Config.set_policy(%{})
    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})
    :ok = Backplane.Settings.set(ModelAlias.provider_setting_key(), [])

    on_exit(fn ->
      Application.delete_env(:backplane_llama, :audio_allow_http_loopback)
    end)

    :ok
  end

  @tag :stream_response_classification
  test "preview errors explain known provider and parser failures without forwarding messages" do
    for {code, message, explanation} <- [
          {"audio_provider_error", "private-provider-body", "Provider rejected synthesis"},
          {"audio_incomplete_stream", "private-provider-body", "ended before audio completion"},
          {"audio_invalid_response", "Invalid MP3 stream", "failed MP3 validation"},
          {"audio_invalid_response", "Provider audio status is missing",
           "omitted its business status"},
          {"audio_invalid_response", "Provider audio is missing", "omitted its audio data"},
          {"audio_invalid_response", "Empty provider audio chunk",
           "contained an empty audio chunk"},
          {"audio_invalid_response", "Invalid provider audio status", "invalid audio status"},
          {"audio_invalid_response", "Invalid provider streaming response",
           "invalid non-SSE response"}
        ] do
      error = Backplane.Audio.Error.new(502, message, nil, code)
      result = preview_error_result(error)
      assert result =~ explanation
      assert result =~ code
      assert result =~ "Provider usage may have occurred"
      refute result =~ "private-provider-body"
    end
  end

  @tag :stream_response_classification
  test "unknown preview errors retain a safe fallback including forged known-code messages" do
    for code <- ["private-error-code", "audio_invalid_response"] do
      error = Backplane.Audio.Error.new(502, "<script>private-provider-body</script>", nil, code)
      result = preview_error_result(error)
      assert result =~ "Preview failed"
      refute result =~ "private"
      refute result =~ "<script>"
    end
  end

  defp preview_error_result(error) do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, tts_job: self()}}

    assert {:noreply, result} =
             Backplane.Admin.AudioLive.handle_info(
               {:audio_preview, self(), :speech, {:error, error}},
               socket
             )

    assert result.assigns.tts_job == nil
    assert result.assigns.preview_audio == nil
    result.assigns.tts_result
  end

  test "opening and cancelling ASR emits one non-dispatched preview event" do
    {:ok, job} = AudioPreview.start(self(), :transcription)
    AudioPreview.cancel(job)
    assert_receive {:audio_preview, ^job, :transcription, {:error, :cancelled}}
    assert_preview("audio.preview.transcriptions", "cancelled", "false")
    eventually(fn -> Admission.counts().operation == 0 end)
  end

  defp assert_preview(operation, outcome, dispatched) do
    assert_receive {:observed_preview, attrs}, 2000
    assert attrs["operation"] == operation
    assert attrs["outcome"] == outcome
    assert attrs["api_surface"] == "admin_audio_preview"
    assert attrs["response_bytes"] == nil
    assert attrs["metadata"]["audio"]["provider_dispatched"] == dispatched
    refute inspect(attrs) =~ "Private sample"
    refute inspect(attrs) =~ "Private transcript"
    refute inspect(attrs) =~ "offline-key"
    refute_receive {:observed_preview, _}, 20
  end

  test "audio page is discoverable and does not run paid previews on mount", %{conn: conn} do
    {:ok, view, html} = live(conn, "/llama/audio")

    assert html =~ "Audio service"
    assert html =~ ~s(href="/llama/audio")
    assert has_element?(view, "#check-audio-readiness")
    assert has_element?(view, "#audio-tts-preview")
    assert has_element?(view, "#audio-asr-preview")
    assert has_element?(view, "#audio-asr-preview input[type='file']")
    refute has_element?(view, "#open-audio-asr")
    refute has_element?(view, "#close-audio-asr")
    assert Admission.counts().upload == 0
    assert Admission.counts().operation == 0
    assert Backplane.Admin.Audit.list() == []
  end

  test "credential and region setup provisions routes without billing input or manual settings",
       %{
         conn: conn
       } do
    {:ok, _} = Credentials.store("preset-ui-key", "hidden-preset-token", "llm")
    {:ok, view, html} = live(conn, "/llama/audio")
    assert has_element?(view, "#audio-preset-form")
    assert html =~ "MiniMax API-key credential"
    assert html =~ "API region"
    assert html =~ "Save audio setup"
    refute html =~ "Advanced audio settings"
    refute html =~ "Billing label"
    refute has_element?(view, "#audio-advanced")
    refute has_element?(view, "#audio-binding-form")
    refute has_element?(view, "#audio-voices-form")
    refute has_element?(view, "#audio-policy-form")
    refute has_element?(view, "#new-audio-binding")
    refute has_element?(view, "[name='setup[billing_label]']")
    refute html =~ "save_binding"
    refute html =~ "save_voices"
    refute html =~ "save_policy"
    refute Config.enabled?()

    assert render_submit(
             form(view, "#audio-preset-form", setup: %{credential: "preset-ui-key", region: ""})
           ) =~ "Choose the region authorized"

    assert Binding.list() == []

    html =
      render_submit(
        form(view, "#audio-preset-form", setup: %{credential: "preset-ui-key", region: "global"})
      )

    assert html =~ "MiniMax audio routes saved"
    assert html =~ "minimax-audio/speech-2.8-turbo"
    assert html =~ "minimax-audio/asr-1.0"
    assert length(Binding.list()) == 2
    assert Enum.map(Binding.list(), & &1.billing_label) == [:payg, :payg]
    assert Config.voices()["minimax-audio"] == %{"aliases" => %{}, "allow_native" => true}
    refute Config.enabled?()
    refute html =~ "hidden-preset-token"
    refute html =~ "Advanced audio settings"
    assert Enum.map(Backplane.Admin.Audit.list(), & &1.action) == ["audio.preset.save"]
  end

  test "committed routes are audited when an invalid voice policy blocks its setup", %{
    conn: conn
  } do
    {:ok, _} = Credentials.store("preset-partial-key", "hidden-partial-token", "llm")
    :ok = Backplane.Settings.set("llm.audio.voices", "invalid existing policy")
    {:ok, view, _html} = live(conn, "/llama/audio")

    html =
      render_submit(
        form(view, "#audio-preset-form",
          setup: %{credential: "preset-partial-key", region: "global"}
        )
      )

    assert html =~ "Audio voice configuration needs attention"
    assert length(Binding.list()) == 2
    assert Backplane.Settings.get("llm.audio.voices") == "invalid existing policy"
    refute Config.enabled?()
    refute html =~ "hidden-partial-token"
    assert Enum.map(Backplane.Admin.Audit.list(), & &1.action) == ["audio.preset.save"]
  end

  test "enabled state is audited without configuration values", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/llama/audio")
    assert render_click(element(view, "#toggle-audio")) =~ "Audio is enabled"
    assert Config.enabled?()

    audit = Backplane.Admin.Audit.list()
    assert Enum.map(audit, & &1.action) == ["audio.config.update"]
    refute inspect(audit) =~ "enabled: true"
  end

  test "speech voice offers searchable native system-voice suggestions", %{conn: conn} do
    {:ok, view, html} = live(conn, "/llama/audio")

    assert has_element?(view, "input[name='tts[voice]'][list='audio-system-voices'][value='']")
    refute has_element?(view, "select[name='tts[voice]']")
    assert has_element?(view, "datalist#audio-system-voices option[value='female-tianmei']")
    assert html =~ ~s|value="female-tianmei"|
    assert html =~ "甜美女性音色 (中文 (普通话))"

    assert has_element?(
             view,
             "datalist#audio-system-voices option[value='Chinese (Mandarin)_Sweet_Lady']"
           )

    assert html =~ ~s|value="Chinese (Mandarin)_Sweet_Lady"|
    assert html =~ "甜美女声 (中文 (普通话))"
    assert html =~ "Search and choose a voice"
  end

  test "speech and transcription model suggestions follow their enabled bindings while audio is disabled",
       %{conn: conn} do
    {provider, speech} = model_fixture("offline-key", "speech")
    {:ok, asr} = ProviderModel.create(%{provider_id: provider.id, model: "asr", enabled: true})
    {:ok, _} = Binding.create(Map.put(binding_params(provider, speech), :capabilities, %{}))

    {:ok, _} =
      Binding.create(
        binding_params(provider, asr)
        |> Map.put(:operation, "transcription")
        |> Map.put(:capabilities, %{})
      )

    :ok = ModelAlias.add_provider(provider.name)
    {:ok, _} = ModelAlias.put("speech-public", speech.id)
    {:ok, _} = ModelAlias.put("asr-public", asr.id)
    {:ok, view, _html} = live(conn, "/llama/audio")

    refute Config.enabled?()
    assert has_element?(view, "input[name='tts[model]'][list='audio-speech-models']")

    assert has_element?(
             view,
             "datalist#audio-speech-models option[value='#{provider.name}/speech']"
           )

    assert has_element?(view, "datalist#audio-speech-models option[value='speech']")
    assert has_element?(view, "datalist#audio-speech-models option[value='speech-public']")
    refute has_element?(view, "datalist#audio-speech-models option[value='asr-public']")

    assert has_element?(view, "input[name='asr[model]'][list='audio-transcription-models']")

    assert has_element?(
             view,
             "datalist#audio-transcription-models option[value='#{provider.name}/asr']"
           )

    assert has_element?(view, "datalist#audio-transcription-models option[value='asr']")
    assert has_element?(view, "datalist#audio-transcription-models option[value='asr-public']")
    refute has_element?(view, "datalist#audio-transcription-models option[value='speech-public']")
    refute_receive {:observed_preview, _}, 50
    assert Backplane.Admin.Audit.list() == []
  end

  test "blank and forged speech voices are rejected before preview admission", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/llama/audio")

    for voice <- ["", "forged-voice-id", "甜美女生"] do
      html =
        render_submit(view, "preview_tts", %{
          "tts" => %{
            "model" => "missing",
            "voice" => voice,
            "input" => "Hello"
          }
        })

      assert html =~ "Choose a system voice"
      assert Admission.counts().operation == 0
      assert Backplane.Admin.Audit.list() == []
      refute_receive {:observed_preview, _}, 50
    end
  end

  test "credential choices filter OAuth and unrelated kinds without exposing secrets", %{
    conn: conn
  } do
    {:ok, _} =
      Credentials.store("audio-eligible-service", "hidden-api-key", "service", %{
        "auth_type" => "api_key"
      })

    {:ok, _} =
      Credentials.store("audio-ineligible-oauth", "hidden-oauth", "llm", %{
        "auth_type" => "openai_oauth"
      })

    {:ok, _} = Credentials.store("audio-ineligible-other", "hidden-other", "custom")
    {:ok, view, html} = live(conn, "/llama/audio")
    assert has_element?(view, "#audio-preset-form")
    assert html =~ "audio-eligible-service"
    refute html =~ "audio-ineligible-oauth"
    refute html =~ "audio-ineligible-other"
    refute html =~ "hidden-api-key"
    refute html =~ "hidden-oauth"
    refute html =~ "hidden-other"
    refute html =~ "Credential override"
    refute html =~ "Billing"

    html =
      render_submit(view, "save_preset", %{
        "setup" => %{"credential" => "audio-ineligible-oauth", "region" => "global"}
      })

    assert html =~ "Choose an eligible API-key credential"
    assert Binding.list() == []
  end

  @tag :asr_recovery
  test "direct upload preflight cannot write before selection admission", %{conn: conn} do
    {:ok, view, _} = live(conn, "/llama/audio")
    ref = :sys.get_state(view.pid).socket.assigns.uploads.audio.ref

    upload =
      file_input(view, "#audio-asr-preview", :audio, [
        %{name: "clip.wav", content: "unadmitted-bytes", type: "audio/wav"}
      ])

    assert {:error, _} = render_upload(upload, "clip.wav")
    eventually(fn -> :sys.get_state(view.pid).socket.assigns.uploads.audio.ref != ref end)
    assert has_element?(view, "#audio-asr-preview input[type='file']")
    assert Admission.counts().upload == 0
    assert Admission.counts().operation == 0
    assert TempFiles.usage().reserved == 0
  end

  @tag :asr_recovery
  test "disabled speech and transcription report activation without claiming dispatch", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/llama/audio")

    render_submit(
      form(view, "#audio-tts-preview",
        tts: %{
          model: "missing",
          voice: "female-tianmei",
          input: "Hello",
          response_format: "mp3"
        }
      )
    )

    eventually(fn -> has_element?(view, "#audio-tts-result", "Enable audio") end)
    refute render(view) =~ "Provider usage may have occurred"
    assert_preview("audio.preview.speech", "error", "false")
    upload = select_upload(view, "clip.wav", "unvalidated-bytes")
    render_upload(upload, "clip.wav")
    render_submit(form(view, "#audio-asr-preview", asr: %{model: "missing", ack: "true"}))
    eventually(fn -> has_element?(view, "#audio-asr-result", "Enable audio") end)
    assert_preview("audio.preview.transcriptions", "error", "false")
    assert not Config.enabled?()
    assert_rearmed(view)
  end

  test "missing acknowledgment and missing file leave the input available and release admission",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/llama/audio")
    upload = select_upload(view, "clip.wav", "bytes")
    render_upload(upload, "clip.wav")

    assert render_submit(form(view, "#audio-asr-preview", asr: %{model: "missing"})) =~
             "Acknowledge provider charges"

    assert_rearmed(view)

    assert render_submit(form(view, "#audio-asr-preview", asr: %{model: "missing", ack: "true"})) =~
             "Select a file"

    assert_rearmed(view)
  end

  test "idle form outlives request timeout without acquiring a lease", %{conn: conn} do
    :ok =
      Config.set_policy(%{
        "request_timeout_ms" => 1000,
        "conversion_timeout_ms" => 1000,
        "probe_timeout_ms" => 1000
      })

    {:ok, view, _} = live(conn, "/llama/audio")
    Process.sleep(1100)
    assert has_element?(view, "#audio-asr-preview input[type='file']")
    assert :sys.get_state(view.pid).socket.assigns.asr_session == nil
    assert Admission.counts() == %{operation: 0, upload: 0, media: 0}
    refute_receive {:observed_preview, _}, 20
  end

  test "selecting an ASR file admits once and an idle page reserves no capacity", %{conn: conn} do
    {:ok, view, _} = live(conn, "/llama/audio")
    assert Admission.counts().upload == 0
    assert Admission.counts().operation == 0

    upload =
      file_input(view, "#audio-asr-preview", :audio, [
        %{name: "clip.wav", content: :binary.copy(<<0>>, 100), type: "audio/wav"}
      ])

    render_change(form(view, "#audio-asr-preview", asr: %{model: "missing"}), upload)
    assert Admission.counts().upload == 1
    assert Admission.counts().operation == 1
    render_change(view, "validate_asr", %{"asr" => %{"language" => "en"}})
    assert Admission.counts().upload == 1

    job = :sys.get_state(view.pid).socket.assigns.asr_session
    send(job, :timeout)
    eventually(fn -> Admission.counts().upload == 0 and Admission.counts().operation == 0 end)
    eventually(fn -> has_element?(view, "#audio-asr-preview input[type='file']") end)
  end

  test "incomplete upload cancellation releases admission and rearms without opening controls", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/llama/audio")
    upload = select_upload(view, "clip.wav", :binary.copy(<<0>>, 1000))
    render_upload(upload, "clip.wav", 20)

    assert render_submit(view, "preview_asr", %{"asr" => %{"model" => "missing", "ack" => "true"}}) =~
             "Complete one upload"

    assert_rearmed(view)
    select_upload(view, "next.wav", "next")
    assert Admission.counts().upload == 1
    GenServer.stop(view.pid, :normal)
    eventually(fn -> Admission.counts().operation == 0 end)
  end

  test "invalid extension and capacity refusal release selection and rearm", %{conn: conn} do
    {:ok, view, _} = live(conn, "/llama/audio")

    upload =
      file_input(view, "#audio-asr-preview", :audio, [
        %{name: "clip.txt", content: "bad", type: "text/plain"}
      ])

    assert render_change(element(view, "#audio-asr-preview"), upload) =~ "Upload rejected"
    assert_rearmed(view)
    :ok = Config.set_policy(%{"concurrent_uploads" => 1})
    {:ok, held} = AudioPreview.start(self(), :transcription)

    upload =
      file_input(view, "#audio-asr-preview", :audio, [
        %{name: "clip.wav", content: "audio", type: "audio/wav"}
      ])

    assert render_change(element(view, "#audio-asr-preview"), upload) =~ "capacity unavailable"
    assert :sys.get_state(view.pid).socket.assigns.asr_session == nil
    assert Admission.counts().upload == 1
    AudioPreview.cancel(held)
    assert_rearmed(view)
  end

  test "real local readiness checks codecs and rejects disabled or missing-key bindings", %{
    conn: conn
  } do
    {provider, model} = model_fixture()
    {:ok, binding} = Binding.create(Map.put(binding_params(provider, model), :capabilities, %{}))
    {:ok, view, _} = live(conn, "/llama/audio")
    html = render_click(element(view, "#check-audio-readiness"))
    assert html =~ "Media ready"
    for format <- ~w(mp3 opus aac flac wav pcm), do: assert(html =~ "#{format}: ready")
    assert has_element?(view, "#audio-readiness-#{binding.id}", "speech: valid")
    {:ok, _} = Binding.update(binding, %{enabled: false})
    render_click(element(view, "#check-audio-readiness"))
    assert has_element?(view, "#audio-readiness-#{binding.id}", "speech: invalid")
    {:ok, _} = Binding.update(binding, %{enabled: true})
    Backplane.Repo.update!(Ecto.Changeset.change(Backplane.Repo.reload!(model), enabled: false))
    render_click(element(view, "#check-audio-readiness"))
    assert has_element?(view, "#audio-readiness-#{binding.id}", "speech: invalid")
    Backplane.Repo.update!(Ecto.Changeset.change(Backplane.Repo.reload!(model), enabled: true))

    Backplane.Repo.update!(
      Ecto.Changeset.change(Backplane.Repo.reload!(provider), enabled: false)
    )

    render_click(element(view, "#check-audio-readiness"))
    assert has_element?(view, "#audio-readiness-#{binding.id}", "speech: invalid")

    Backplane.Repo.update!(
      Ecto.Changeset.change(Backplane.Repo.reload!(provider),
        enabled: true,
        deleted_at: DateTime.utc_now()
      )
    )

    render_click(element(view, "#check-audio-readiness"))
    assert has_element?(view, "#audio-readiness-#{binding.id}", "speech: invalid")

    Backplane.Repo.update!(
      Ecto.Changeset.change(Backplane.Repo.reload!(provider),
        deleted_at: nil,
        credential: "audio-missing-key"
      )
    )

    render_click(element(view, "#check-audio-readiness"))
    assert has_element?(view, "#audio-readiness-#{binding.id}", "speech: invalid")
    :ok = Backplane.Settings.set("llm.audio.policy", %{"upload_bytes" => -1})
    assert render_click(element(view, "#check-audio-readiness")) =~ "Media unavailable"
    assert has_element?(view, "#audio-policy-readiness", "Policy: invalid")
  end

  test "paid TTS preview uses shared Speech and PCM is download-only", %{conn: conn, tmp_dir: dir} do
    {provider, _model, _server} = preview_fixture(dir)
    {:ok, view, _html} = live(conn, "/llama/audio")
    render_click(element(view, "#check-audio-readiness"))
    refute_receive {:provider_request, _, _, _}, 50
    refute has_element?(view, "input[name='tts[ack]']")

    render_submit(
      form(view, "#audio-tts-preview",
        tts: %{
          model: "#{provider.name}/speech",
          voice: "female-tianmei",
          input: "Private sample",
          response_format: "pcm"
        }
      )
    )

    assert_receive {:provider_request, "/v1/t2a_v2", body, ["Bearer offline-key"]}, 15_000
    assert Jason.decode!(body)["text"] == "Private sample"
    assert Jason.decode!(body)["voice_setting"]["voice_id"] == "female-tianmei"
    eventually(fn -> has_element?(view, "#audio-preview-download") end)
    assert render(view) =~ "24,000 Hz, mono"
    refute has_element?(view, "audio")
    refute render(view) =~ "offline-key"
    refute render(view) =~ dir
    refute inspect(Backplane.Admin.Audit.list()) =~ "Private sample"
    assert_preview("audio.preview.speech", "success", "true")
    eventually(fn -> TempFiles.usage().requests == 0 end)
  end

  test "preview output over 1 MB is rejected and its media is cleaned", %{
    conn: conn,
    tmp_dir: dir
  } do
    {provider, _, _} = preview_fixture(dir, duration: 26)
    {:ok, view, _} = live(conn, "/llama/audio")

    render_submit(
      form(view, "#audio-tts-preview",
        tts: %{
          model: "#{provider.name}/speech",
          voice: "female-tianmei",
          input: "Hello",
          response_format: "pcm"
        }
      )
    )

    assert_receive {:provider_request, "/v1/t2a_v2", _, _}, 15_000
    eventually(fn -> has_element?(view, "#audio-tts-result", "Preview failed") end)
    refute has_element?(view, "#audio-preview-download")
    eventually(fn -> TempFiles.usage().requests == 0 end)
  end

  test "ASR consumes repeated real uploads and preserves model and language", %{
    conn: conn,
    tmp_dir: dir
  } do
    {provider, _model, _server} = preview_fixture(dir)
    bytes = File.read!(Path.join(dir, "fixture.flac"))
    {:ok, view, _} = live(conn, "/llama/audio")

    for _ <- 1..2 do
      upload = select_upload(view, "clip.flac", bytes)
      render_upload(upload, "clip.flac")
      refute_receive {:provider_request, _, _, _}, 50

      render_submit(
        form(view, "#audio-asr-preview",
          asr: %{model: "#{provider.name}/speech", language: "en", ack: "true"}
        )
      )

      assert_receive {:provider_request, "/v1/speech_to_text", body, ["Bearer offline-key"]},
                     15_000

      assert body =~ "fLaC"
      assert body =~ ~s(name="model")
      eventually(fn -> has_element?(view, "#audio-asr-result", "Private transcript") end)
      refute inspect(Backplane.Admin.Audit.list()) =~ "Private transcript"
      assert_preview("audio.preview.transcriptions", "success", "true")
      assert_rearmed(view)
      assert has_element?(view, "input[name='asr[model]'][value='#{provider.name}/speech']")
      assert has_element?(view, "input[name='asr[language]'][value='en']")
    end
  end

  test "ASR cancellation, timeout, forced death and disconnect release active work and rearm surviving views",
       %{conn: conn, tmp_dir: dir} do
    {provider, _, _} = preview_fixture(dir, stall: true)
    bytes = File.read!(Path.join(dir, "fixture.flac"))

    for action <- [:cancel, :timeout, :kill, :disconnect] do
      {:ok, view, _} = live(conn, "/llama/audio")
      upload = select_upload(view, "clip.flac", bytes)
      render_upload(upload, "clip.flac")

      render_submit(
        form(view, "#audio-asr-preview", asr: %{model: "#{provider.name}/speech", ack: "true"})
      )

      assert_receive {:provider_request, "/v1/speech_to_text", _, _}, 15_000
      job = :sys.get_state(view.pid).socket.assigns.asr_job
      ref = Process.monitor(job)

      case action do
        :cancel -> render_click(element(view, "#cancel-audio-asr"))
        :timeout -> send(job, :timeout)
        :kill -> Process.exit(job, :kill)
        :disconnect -> GenServer.stop(view.pid, :normal)
      end

      assert_receive {:DOWN, ^ref, :process, ^job, _}, 5000
      if action != :disconnect, do: assert_rearmed(view)
      eventually(fn -> Admission.counts().operation == 0 and TempFiles.usage().requests == 0 end)
    end
  end

  @tag :asr_recovery
  test "streamed MP3 preview collects exact audio through empty progress and final completion", %{
    conn: conn,
    tmp_dir: dir
  } do
    {provider, _, _} = preview_fixture(dir, stream: true)
    expected = File.read!(Path.join(dir, "fixture.mp3"))
    {:ok, view, _} = live(conn, "/llama/audio")

    render_submit(
      form(view, "#audio-tts-preview",
        tts: %{
          model: "#{provider.name}/speech",
          voice: "female-tianmei",
          input: "Hello",
          response_format: "mp3"
        }
      )
    )

    assert_receive {:provider_request, "/v1/t2a_v2", body, _}, 15_000
    assert Jason.decode!(body)["stream"] == true
    eventually(fn -> has_element?(view, "audio[controls]") end)
    data_uri = "data:audio/mpeg;base64," <> Base.encode64(expected)
    assert has_element?(view, "#audio-preview-download[href='#{data_uri}']")
    assert_preview("audio.preview.speech", "success", "true")
    eventually(fn -> TempFiles.usage().requests == 0 and Admission.counts().operation == 0 end)
  end

  test "preview cancel and owner death terminate stalled HTTP workers and sessions", %{
    conn: conn,
    tmp_dir: dir
  } do
    {provider, _model, _server} = preview_fixture(dir, stall: true)

    for action <- [:cancel, :disconnect, :timeout] do
      {:ok, view, _} = live(conn, "/llama/audio")

      render_submit(
        form(view, "#audio-tts-preview",
          tts: %{
            model: "#{provider.name}/speech",
            voice: "female-tianmei",
            input: "Hello"
          }
        )
      )

      assert_receive {:provider_request, "/v1/t2a_v2", _, _}, 15_000
      job = :sys.get_state(view.pid).socket.assigns.tts_job
      state = :sys.get_state(job)
      refs = for pid <- [job, state.worker, state.session], do: {pid, Process.monitor(pid)}

      case action do
        :cancel -> render_click(element(view, "#cancel-audio-tts"))
        :disconnect -> GenServer.stop(view.pid, :normal)
        :timeout -> send(job, :timeout)
      end

      for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 5000)
      eventually(fn -> Admission.counts().operation == 0 and TempFiles.usage().requests == 0 end)
    end
  end

  test "oversized text is refused before starting a preview", %{conn: conn} do
    {:ok, view, _} = live(conn, "/llama/audio")

    html =
      render_submit(view, "preview_tts", %{
        "tts" => %{"input" => String.duplicate("a", 201)}
      })

    assert html =~ "limited to 200 characters"
    assert Admission.counts().operation == 0
    assert Backplane.Admin.Audit.list() == []
  end

  test "oversized upload is refused and input rearms", %{conn: conn} do
    :ok = Config.set_policy(%{"upload_bytes" => 10})
    {:ok, view, _} = live(conn, "/llama/audio")

    upload =
      file_input(view, "#audio-asr-preview", :audio, [
        %{name: "clip.wav", content: String.duplicate("a", 20), type: "audio/wav"}
      ])

    assert render_change(element(view, "#audio-asr-preview"), upload) =~ "Upload rejected"
    assert_rearmed(view)
    select_upload(view, "valid.wav", "small")
    assert Admission.counts().upload == 1
    GenServer.stop(view.pid, :normal)
    eventually(fn -> Admission.counts().operation == 0 end)
  end

  defp select_upload(view, name, bytes) do
    upload =
      file_input(view, "#audio-asr-preview", :audio, [
        %{name: name, content: bytes, type: "audio/wav"}
      ])

    render_change(element(view, "#audio-asr-preview"), upload)
    upload
  end

  defp assert_rearmed(view) do
    eventually(fn ->
      assigns = :sys.get_state(view.pid).socket.assigns

      not assigns.asr_upload_closing and assigns.uploads.audio.entries == [] and
        is_nil(assigns.asr_session) and is_nil(assigns.asr_job) and
        Admission.counts().operation == 0 and TempFiles.usage().requests == 0
    end)

    assert has_element?(view, "#audio-asr-preview input[type='file']")
    assert Admission.counts().upload == 0
    assert TempFiles.usage().reserved == 0
  end

  test "upload staging is reserved, private and removed on owner death", %{tmp_dir: dir} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, job} = AudioPreview.start(owner, :transcription)
    path = Path.join(dir, "upload.wav")
    File.write!(path, "fixture-bytes")

    assert :ok =
             AudioPreview.stage_upload(job, %Plug.Upload{
               path: path,
               filename: "../../audio.wav",
               content_type: "audio/wav"
             })

    state = :sys.get_state(job)
    assert state.staged.path != path
    assert File.stat!(state.staged.path).mode |> Bitwise.band(0o777) == 0o600
    assert TempFiles.usage().reserved == byte_size("fixture-bytes")

    assert AudioPreview.stage_upload(job, %Plug.Upload{path: path}) ==
             {:error, :upload_unavailable}

    ref = Process.monitor(job)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^job, :normal}
    eventually(fn -> not File.exists?(state.staged.path) and TempFiles.usage().reserved == 0 end)
  end

  defmodule MockProvider do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn, length: 5_000_000)

      send(
        opts[:owner],
        {:provider_request, conn.request_path, body, get_req_header(conn, "authorization")}
      )

      if opts[:stall], do: Process.sleep(30_000)

      if opts[:stream] == true and conn.request_path == "/v1/t2a_v2" do
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        events = [{1, ""}, {1, Base.encode16(opts[:audio])}, {1, ""}, {2, ""}]

        Enum.reduce(events, conn, fn {status, audio}, conn ->
          bytes =
            "data: " <>
              Jason.encode!(%{
                base_resp: %{status_code: 0},
                data: %{status: status, audio: audio}
              }) <> "\r\n\r\n"

          {:ok, conn} = chunk(conn, bytes)
          conn
        end)
      else
        payload =
          if conn.request_path == "/v1/t2a_v2" do
            %{
              "base_resp" => %{"status_code" => 0},
              "data" => %{"audio" => Base.encode16(opts[:audio])}
            }
          else
            %{"base_resp" => %{"status_code" => 0}, "text" => "Private transcript"}
          end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(payload))
      end
    end
  end

  defp preview_fixture(dir, opts \\ []) do
    Application.put_env(:backplane_llama, :audio_allow_http_loopback, true)
    path = Path.join(dir, if(opts[:stream], do: "fixture.mp3", else: "fixture.flac"))

    {_, 0} =
      System.cmd(
        Runner.executable(:convert),
        [
          "-nostdin",
          "-v",
          "error",
          "-y",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=24000:duration=#{opts[:duration] || 0.2}",
          "-c:a",
          if(opts[:stream], do: "libmp3lame", else: "flac"),
          "-ac",
          "1",
          path
        ],
        stderr_to_stdout: true
      )

    server =
      start_supervised!(
        {Bandit, plug: {MockProvider, [owner: self(), audio: File.read!(path)] ++ opts}, port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {provider, model} = model_fixture("offline-key", "speech")

    attrs =
      binding_params(provider, model)
      |> Map.put(:api_origin, "http://127.0.0.1:#{port}")
      |> Map.put(
        :capabilities,
        if(opts[:stream], do: %{}, else: %{"native_formats" => ["flac"], "streaming" => false})
      )

    {:ok, _} = Binding.create(attrs)

    {:ok, _} =
      Binding.create(attrs |> Map.put(:operation, "transcription") |> Map.put(:capabilities, %{}))

    :ok = Config.set_enabled(true)

    :ok =
      Config.set_voices(%{
        provider.name => %{"aliases" => %{}, "allow_native" => true}
      })

    {provider, model, server}
  end

  defp model_fixture(secret \\ "fixture-secret", model_name \\ "speech") do
    name = "audio-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Credentials.store(name, secret, "llm")
    {:ok, provider} = Provider.create(%{name: name, credential: name, enabled: true})

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: model_name, enabled: true})

    {provider, model}
  end

  defp binding_params(provider, model) do
    %{
      provider_id: provider.id,
      provider_model_id: model.id,
      operation: "speech",
      native_protocol: "minimax",
      api_origin: "https://audio.example.com",
      enabled: "true",
      credential_override: "",
      billing_label: "payg",
      capabilities: "{}"
    }
  end

  defp eventually(fun, attempts \\ 1500)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
