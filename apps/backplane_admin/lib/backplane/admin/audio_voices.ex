defmodule Backplane.Admin.AudioVoices do
  @moduledoc false

  defdelegate options(), to: Backplane.Audio.Voices
  defdelegate valid?(native_id), to: Backplane.Audio.Voices
end
