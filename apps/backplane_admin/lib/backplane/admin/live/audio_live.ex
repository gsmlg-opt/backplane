defmodule Backplane.Admin.AudioLive do
  use Backplane.Admin, :live_view

  alias Backplane.Admin.{Audit, AudioPreview, AudioUploadWriter, AudioVoices}
  alias Backplane.Audio.{Binding, Config, Error, PresetSetup, Resolver}
  alias Backplane.Audio.Media.Capabilities
  alias Backplane.Settings.Credentials

  @upload_extensions ~w(.flac .mp3 .mp4 .mpeg .mpga .m4a .ogg .wav .webm)

  @impl true
  def mount(_params, _session, socket) do
    preset = PresetSetup.current()

    {:ok,
     socket
     |> assign(
       current_path: "/llama/audio",
       setup_form:
         to_form(
           %{
             "credential" => preset.credential || "",
             "region" => preset.region || ""
           },
           as: :setup
         ),
       setup_error: nil,
       readiness: nil,
       tts_result: nil,
       asr_result: nil,
       preview_audio: nil,
       preview_format: nil,
       tts_job: nil,
       asr_job: nil,
       tts_form:
         to_form(
           %{
             "model" => "",
             "voice" => "",
             "input" => "",
             "response_format" => "mp3"
           },
           as: :tts
         ),
       asr_form: to_form(%{"model" => "", "language" => "", "ack" => "false"}, as: :asr),
       asr_session: nil,
       asr_upload_deadline: nil,
       asr_upload_closing: false
     )
     |> load()
     |> configure_upload()}
  end

  @impl true
  def handle_event("enable", %{"enabled" => value}, socket) when value in ["true", "false"] do
    :ok = Config.set_enabled(value == "true")
    Audit.record("audio.config.update", "audio_config")
    {:noreply, load(socket)}
  end

  def handle_event("check_readiness", _, socket) do
    result = Capabilities.probe()
    Audit.record("audio.readiness.requested", "audio_config")
    {:noreply, socket |> load() |> assign(readiness: result)}
  end

  def handle_event("save_preset", %{"setup" => params}, socket) do
    case PresetSetup.save(params["credential"], params["region"]) do
      {:ok, _} ->
        Audit.record("audio.preset.save", "audio_config")

        socket =
          socket
          |> assign(setup_form: to_form(params, as: :setup), setup_error: nil)
          |> load()
          |> put_flash(:info, "MiniMax audio routes saved. Enable audio separately when ready.")

        {:noreply, prefill_preview_models(socket)}

      {:error, {:voice_policy_not_saved, _}} ->
        Audit.record("audio.preset.save", "audio_config")

        {:noreply,
         socket
         |> load()
         |> assign(
           setup_form: to_form(params, as: :setup),
           setup_error:
             "Routes were saved, but native voice IDs could not be enabled. Audio voice configuration needs attention."
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           setup_form: to_form(params, as: :setup),
           setup_error: preset_error(reason)
         )}
    end
  end

  def handle_event("cancel_tts", _, socket) do
    if socket.assigns.tts_job, do: AudioPreview.cancel(socket.assigns.tts_job)
    {:noreply, socket}
  end

  def handle_event("cancel_asr", _, socket) do
    if socket.assigns.asr_job, do: AudioPreview.cancel(socket.assigns.asr_job)
    {:noreply, socket}
  end

  def handle_event("preview_tts", _, %{assigns: %{tts_job: job}} = socket)
      when not is_nil(job),
      do: {:noreply, socket}

  def handle_event("preview_tts", %{"tts" => params}, socket) do
    cond do
      String.length(params["input"] || "") > 200 ->
        {:noreply,
         assign(socket,
           tts_result: "Speech preview is limited to 200 characters",
           preview_audio: nil
         )}

      not AudioVoices.valid?(params["voice"]) ->
        {:noreply,
         assign(socket,
           tts_result: "Choose a system voice before running speech preview",
           preview_audio: nil
         )}

      true ->
        case AudioPreview.start(self(), :speech) do
          {:ok, job} ->
            Process.monitor(job)
            Audit.record("audio.speech.preview_requested", "audio_preview")
            AudioPreview.run(job, params)

            {:noreply,
             assign(socket,
               tts_job: job,
               tts_result: "Speech preview running",
               preview_audio: nil
             )}

          _ ->
            {:noreply,
             assign(socket, tts_result: "Audio capacity unavailable", preview_audio: nil)}
        end
    end
  end

  def handle_event("validate_asr", _, %{assigns: %{asr_upload_closing: true}} = socket),
    do: {:noreply, socket}

  def handle_event("validate_asr", payload, socket) do
    params = Map.merge(socket.assigns.asr_form.params, Map.get(payload, "asr", %{}))
    socket = assign(socket, asr_form: to_form(Map.put(params, "ack", "false"), as: :asr))
    upload = socket.assigns.uploads.audio

    cond do
      upload_errors(upload) != [] or
          Enum.any?(upload.entries, &(upload_errors(upload, &1) != [] or not allowed_upload?(&1))) ->
        {:noreply,
         socket |> close_upload() |> assign(asr_result: "Upload rejected; select a file again")}

      upload.entries == [] or not is_nil(socket.assigns.asr_job) or
          not is_nil(socket.assigns.asr_session) ->
        {:noreply, socket}

      true ->
        deadline =
          System.monotonic_time(:millisecond) +
            min(Config.policy()["request_timeout_ms"], 120_000)

        case AudioPreview.start(self(), :transcription) do
          {:ok, job} ->
            Process.monitor(job)

            {:noreply,
             assign(socket, asr_session: job, asr_upload_deadline: deadline, asr_result: nil)}

          _ ->
            {:noreply,
             socket
             |> close_upload()
             |> assign(asr_result: "Audio upload capacity unavailable; select a file again")}
        end
    end
  end

  def handle_event("preview_asr", _, %{assigns: %{asr_job: job}} = socket) when is_pid(job),
    do: {:noreply, socket}

  def handle_event("preview_asr", %{"asr" => params}, socket) do
    values = Map.merge(socket.assigns.asr_form.params, params) |> Map.put("ack", "false")
    socket = assign(socket, asr_form: to_form(values, as: :asr))

    cond do
      params["ack"] != "true" ->
        {:noreply,
         socket
         |> close_upload()
         |> assign(asr_result: "Acknowledge provider charges for transcription")}

      not is_pid(socket.assigns.asr_session) or not Process.alive?(socket.assigns.asr_session) ->
        {:noreply, socket |> close_upload() |> assign(asr_result: "Select a file again")}

      true ->
        case uploaded_entries(socket, :audio) do
          {[entry], []} ->
            if allowed_upload?(entry) do
              start_asr(socket, params)
            else
              {:noreply,
               socket |> close_upload() |> assign(asr_result: "Unsupported upload format")}
            end

          _ ->
            {:noreply,
             socket
             |> close_upload()
             |> assign(asr_result: "Complete one upload before running transcription")}
        end
    end
  end

  @impl true
  def handle_info({:audio_preview, job, :speech, result}, %{assigns: %{tts_job: job}} = socket) do
    case result do
      {:ok, %{bytes: bytes, format: format}} ->
        {:noreply,
         assign(socket,
           tts_job: nil,
           tts_result: "Speech preview ready",
           preview_format: format,
           preview_audio: "data:#{mime(format)};base64,#{Base.encode64(bytes)}"
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, tts_job: nil, tts_result: preview_error(reason), preview_audio: nil)}
    end
  end

  def handle_info({:audio_preview, job, :transcription, result}, socket) do
    if job in [socket.assigns.asr_job, socket.assigns.asr_session] do
      message =
        case result do
          {:ok, text} -> text
          {:error, reason} -> preview_error(reason)
        end

      message =
        if job == socket.assigns.asr_session and result == {:error, :timeout},
          do: "Selected file expired; select a file again",
          else: message

      {:noreply, socket |> close_upload() |> assign(asr_job: nil, asr_result: message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, _ref, :process, job, _reason}, socket) do
    cond do
      socket.assigns.tts_job == job ->
        {:noreply,
         assign(socket,
           tts_job: nil,
           tts_result: "Preview stopped; provider usage may have occurred",
           preview_audio: nil
         )}

      job in [socket.assigns.asr_job, socket.assigns.asr_session] ->
        message =
          if job == socket.assigns.asr_session,
            do: "Upload stopped; select a file again",
            else: "Preview stopped; provider usage may have occurred"

        {:noreply,
         socket
         |> close_upload()
         |> assign(asr_job: nil, asr_result: message)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:audio_preview, _, _, _}, socket), do: {:noreply, socket}

  def handle_info(:close_audio_upload, %{assigns: %{asr_upload_closing: true}} = socket),
    do: {:noreply, retire_upload(socket)}

  def handle_info(:close_audio_upload, socket), do: {:noreply, socket}

  # MIME and filename are hints; the shared domain probes/decodes actual bytes.
  # Use an explicit extension check because MIME registries vary by deployment.
  defp allowed_upload?(entry),
    do: String.downcase(Path.extname(entry.client_name)) in @upload_extensions

  defp start_asr(socket, params) do
    job = socket.assigns.asr_session

    results =
      consume_uploaded_entries(socket, :audio, fn %{path: path}, entry ->
        upload = %Plug.Upload{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        {:ok, AudioPreview.stage_upload(job, upload)}
      end)

    if results == [:ok] do
      Audit.record("audio.transcription.preview_requested", "audio_preview")
      AudioPreview.run(job, params)

      {:noreply,
       socket
       |> retire_upload()
       |> assign(
         asr_session: nil,
         asr_job: job,
         asr_result: "Transcription preview running"
       )}
    else
      {:noreply, socket |> close_upload() |> assign(asr_result: "Upload could not be prepared")}
    end
  end

  defp close_upload(socket) do
    if socket.assigns.asr_session, do: AudioPreview.cancel(socket.assigns.asr_session)

    socket =
      Enum.reduce(socket.assigns.uploads.audio.entries, socket, fn entry, acc ->
        cancel_upload(acc, :audio, entry.ref)
      end)

    socket |> assign(asr_session: nil, asr_upload_deadline: nil) |> retire_upload()
  end

  # LiveView removes consumed/cancelled channel entries asynchronously. Retire the
  # configuration only after that cleanup, before admitting another upload.
  defp retire_upload(socket) do
    case uploaded_entries(socket, :audio) do
      {[], []} ->
        socket
        |> disallow_upload(:audio)
        |> configure_upload()
        |> assign(asr_upload_closing: false)

      _ ->
        Process.send_after(self(), :close_audio_upload, 10)
        assign(socket, asr_upload_closing: true)
    end
  end

  defp configure_upload(socket) do
    allow_upload(socket, :audio,
      accept: :any,
      max_entries: 1,
      max_file_size: Config.policy()["upload_bytes"],
      writer: fn _, entry, socket ->
        session =
          if allowed_upload?(entry) and not socket.assigns.asr_upload_closing,
            do: socket.assigns.asr_session

        {AudioUploadWriter, session: session, deadline: socket.assigns.asr_upload_deadline}
      end,
      progress: &upload_progress/3
    )
  end

  defp upload_progress(:audio, entry, socket) do
    if upload_errors(socket.assigns.uploads.audio, entry) == [] do
      {:noreply, socket}
    else
      {:noreply,
       socket |> close_upload() |> assign(asr_result: "Upload rejected; select a file again")}
    end
  end

  defp preview_error(%Error{code: "audio_disabled"}),
    do:
      "Audio is disabled (audio_disabled). Select Enable audio in Audio service before previewing."

  defp preview_error(:cancelled),
    do:
      "Preview cancelled; provider usage may have occurred. Cancellation does not guarantee a refund."

  defp preview_error(:timeout),
    do: "Preview timed out; provider execution is uncertain. No automatic retry was made."

  defp preview_error(%Error{code: "audio_provider_error"}),
    do:
      "Provider rejected synthesis (audio_provider_error). Check the selected account, region and model access. Provider usage may have occurred."

  defp preview_error(%Error{code: "audio_incomplete_stream"}),
    do:
      "Provider response ended before audio completion (audio_incomplete_stream). Provider usage may have occurred."

  defp preview_error(%Error{code: "audio_invalid_response", message: "Invalid MP3 stream"}),
    do:
      "Provider audio failed MP3 validation (audio_invalid_response). Provider usage may have occurred."

  defp preview_error(%Error{
         code: "audio_invalid_response",
         message: "Provider audio status is missing"
       }),
       do:
         "Provider stream omitted its business status (audio_invalid_response). Provider usage may have occurred."

  defp preview_error(%Error{code: "audio_invalid_response", message: "Provider audio is missing"}),
    do:
      "Provider stream omitted its audio data (audio_invalid_response). Provider usage may have occurred."

  defp preview_error(%Error{
         code: "audio_invalid_response",
         message: "Empty provider audio chunk"
       }),
       do:
         "Provider stream contained an empty audio chunk (audio_invalid_response). Provider usage may have occurred."

  defp preview_error(%Error{
         code: "audio_invalid_response",
         message: "Invalid provider audio status"
       }),
       do:
         "Provider stream contained an invalid audio status (audio_invalid_response). Provider usage may have occurred."

  defp preview_error(%Error{
         code: "audio_invalid_response",
         message: "Invalid provider streaming response"
       }),
       do:
         "Provider returned an invalid non-SSE response (audio_invalid_response). Provider usage may have occurred."

  defp preview_error(_),
    do:
      "Preview failed; check bindings, voices, media readiness and limits. Provider usage may have occurred."

  defp mime("wav"), do: "audio/wav"
  defp mime("flac"), do: "audio/flac"
  defp mime("opus"), do: "audio/ogg"
  defp mime("aac"), do: "audio/aac"
  defp mime("pcm"), do: "application/octet-stream"
  defp mime(_), do: "audio/mpeg"

  defp preset_error(:ineligible_credential), do: "Choose an eligible API-key credential."
  defp preset_error(:invalid_region), do: "Choose the region authorized for this key."

  defp preset_error(:provider_conflict),
    do: "The minimax-audio provider already exists and is not owned by audio setup."

  defp preset_error(:route_conflict),
    do:
      "Existing audio models or bindings differ from the preset. Audio route configuration needs operator attention."

  defp preset_error(_), do: "Audio routes could not be saved."

  defp prefill_preview_models(socket) do
    tts = socket.assigns.tts_form.params
    asr = socket.assigns.asr_form.params

    socket
    |> assign(
      tts_form:
        to_form(
          if(tts["model"] in [nil, ""],
            do: Map.put(tts, "model", PresetSetup.model_name(:speech)),
            else: tts
          ),
          as: :tts
        ),
      asr_form:
        to_form(
          if(asr["model"] in [nil, ""],
            do: Map.put(asr, "model", PresetSetup.model_name(:transcription)),
            else: asr
          ),
          as: :asr
        )
    )
  end

  defp load(socket) do
    assign(socket,
      preset: PresetSetup.current(),
      enabled: Config.enabled?(),
      bindings: Binding.list(),
      speech_models: Resolver.available_models(:speech),
      transcription_models: Resolver.available_models(:transcription),
      credentials: eligible_credentials(),
      voice_options: AudioVoices.options(),
      policy_valid: Config.policy_valid?()
    )
  end

  defp eligible_credentials do
    Credentials.list()
    |> Enum.filter(
      &(&1.kind in ["llm", "service"] and (&1.metadata || %{})["auth_type"] in [nil, "api_key"])
    )
  end

  defp binding_valid?(binding, credentials) do
    binding.enabled and binding.provider.enabled and is_nil(binding.provider.deleted_at) and
      binding.provider_model.enabled and
      Enum.any?(
        credentials,
        &(&1.name == (binding.credential_override || binding.provider.credential))
      ) and
      Binding.changeset(binding, %{}).valid?
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <header><h1 class="text-2xl font-bold">Audio</h1><p class="text-sm text-on-surface-variant">Configure speech and transcription. Preview requests may incur provider charges.</p></header>
      <.dm_card variant="bordered"><:title>Audio service</:title>
        <p>Audio is {if @enabled, do: "enabled", else: "disabled"}.</p>
        <p class="text-sm text-warning">Previews may incur provider charges, including credit use with a Subscription Key.</p>
        <.dm_btn id="toggle-audio" phx-click="enable" phx-value-enabled={to_string(!@enabled)}>{if @enabled, do: "Disable audio", else: "Enable audio"}</.dm_btn>
      </.dm_card>
      <.dm_card variant="bordered"><:title>MiniMax audio setup</:title>
        <p>Store your MiniMax API token in <a href="/system/credentials" class="text-primary underline">System → Credentials</a>, then select its credential name and authorized region here. This saves speech and transcription routes without contacting MiniMax.</p>
        <.form for={@setup_form} id="audio-preset-form" phx-submit="save_preset" class="grid gap-3 md:grid-cols-2">
          <.dm_select field={@setup_form[:credential]} label="MiniMax API-key credential" options={Enum.map(@credentials, &{&1.name, &1.name})} prompt="Choose credential" />
          <.dm_select field={@setup_form[:region]} label="API region" options={[{"global", "Global (api.minimax.io)"}, {"china", "China (api.minimaxi.com)"}]} prompt="Choose region" />
          <p :if={@setup_error} id="audio-setup-error" class="text-error md:col-span-2">{@setup_error}</p>
          <.dm_btn id="save-audio-preset" type="submit" variant="primary">Save audio setup</.dm_btn>
        </.form>
        <p :if={@preset.configured?}>Models: {PresetSetup.model_name(:speech)} and {PresetSetup.model_name(:transcription)}. Speech requests must supply a native MiniMax voice ID.</p>
      </.dm_card>
      <.dm_card variant="bordered"><:title>Readiness</:title>
        <p>Run a local codec, ffprobe, FFmpeg, sandbox and temporary storage check. No provider request is made.</p>
        <.dm_btn id="check-audio-readiness" phx-click="check_readiness">Check readiness</.dm_btn>
        <div :if={@readiness} id="audio-readiness">
          <p id="audio-policy-readiness">Policy: {if @policy_valid, do: "valid", else: "invalid"}</p>
          <p>{if @readiness.ready?, do: "Media ready", else: "Media unavailable"} · sandbox: {@readiness.sandbox}</p>
          <p :for={{format, ready?} <- @readiness.asr_formats}>ASR {format}: {if ready?, do: "ready", else: "missing"}</p>
          <p :for={{format, ready?} <- @readiness.formats}>{format}: {if ready?, do: "ready", else: "missing"}</p>
          <p :for={binding <- @bindings} id={"audio-readiness-#{binding.id}"}>{binding.provider.name}/{binding.provider_model.model} {binding.operation}: {if binding_valid?(binding, @credentials), do: "valid", else: "invalid"}</p>
        </div>
      </.dm_card>
      <.dm_card variant="bordered"><:title>Speech preview</:title>
        <p>Explicit preview sends text to the selected provider and may incur charges. Text is limited to 200 characters and output to 1 MB in this browser session. Previews expire after at most two minutes.</p>
        <.form for={@tts_form} id="audio-tts-preview" phx-submit="preview_tts">
          <.dm_input field={@tts_form[:model]} label="Public model or provider/model" list="audio-speech-models" placeholder="Search or enter a model" autocomplete="off" />
          <datalist id="audio-speech-models">
            <option :for={name <- @speech_models} value={name}>{name}</option>
          </datalist>
          <.dm_input field={@tts_form[:voice]} label="Voice" list="audio-system-voices" placeholder="Search and choose a voice" autocomplete="off" />
          <datalist id="audio-system-voices">
            <option :for={{native_id, label} <- @voice_options} value={native_id} label={label}>{label}</option>
          </datalist>
          <.dm_textarea field={@tts_form[:input]} label="Text (maximum 200 characters)" maxlength={200} />
          <.dm_select field={@tts_form[:response_format]} label="Format" options={Enum.map(~w(mp3 opus aac flac wav pcm), &{&1, &1})} />
          <.dm_btn type="submit" disabled={not is_nil(@tts_job)}>Run speech preview</.dm_btn>
        </.form>
        <.dm_btn :if={@tts_job} id="cancel-audio-tts" phx-click="cancel_tts">Cancel speech preview</.dm_btn>
        <p :if={@tts_result} id="audio-tts-result">{@tts_result}</p>
        <audio :if={@preview_audio && @preview_format != "pcm"} controls src={@preview_audio}></audio>
        <a :if={@preview_audio} id="audio-preview-download" href={@preview_audio} download={"preview.#{@preview_format}"}>Download preview</a>
        <p :if={@preview_audio && @preview_format == "pcm"}>Raw PCM: signed 16-bit little-endian, 24,000 Hz, mono. Download and open with these parameters; browser playback is unavailable.</p>
      </.dm_card>
      <.dm_card variant="bordered"><:title>Transcription preview</:title>
        <p>Accepted files: FLAC, MP3, MP4, MPEG, MPGA, M4A, OGG, WAV and WebM. Submitting a file may incur provider charges. A selected file expires after two minutes.</p>
        <.form for={@asr_form} id="audio-asr-preview" phx-submit="preview_asr" phx-change="validate_asr">
          <.dm_input field={@asr_form[:model]} label="Public model or provider/model" list="audio-transcription-models" placeholder="Search or enter a model" autocomplete="off" />
          <datalist id="audio-transcription-models">
            <option :for={name <- @transcription_models} value={name}>{name}</option>
          </datalist>
          <.dm_input field={@asr_form[:language]} label="Language (optional)" />
          <.live_file_input upload={@uploads.audio} disabled={not is_nil(@asr_job) or @asr_upload_closing} />
          <p :for={entry <- @uploads.audio.entries}>{entry.client_name}</p>
          <label><input type="checkbox" name="asr[ack]" value="true" /> I acknowledge provider charges for this transcription preview</label>
          <.dm_btn type="submit" disabled={not is_nil(@asr_job) or @asr_upload_closing}>Run transcription preview</.dm_btn>
        </.form>
        <.dm_btn :if={@asr_job} id="cancel-audio-asr" phx-click="cancel_asr">Cancel transcription preview</.dm_btn>
        <p :if={@asr_result} id="audio-asr-result">{@asr_result}</p>
      </.dm_card>
    </div>
    """
  end
end
