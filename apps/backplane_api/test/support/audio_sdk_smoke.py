"""Offline SDK conformance; the ExUnit fixture supplies both localhost servers."""
import pathlib
import sys

import openai

assert openai.__version__ == "2.26.0", openai.__version__
base_url, model, sample, output = sys.argv[1:]
assert base_url.startswith("http://127.0.0.1:")
client = openai.OpenAI(base_url=base_url + "/v1", api_key="audio-loopback-client", max_retries=0, timeout=30)
response = client.audio.speech.create(model=model, input="SDK sample", voice="default", response_format="wav")
pathlib.Path(output, "sdk.wav").write_bytes(response.content)
with client.audio.speech.with_streaming_response.create(model=model, input="SDK stream", voice="default", response_format="mp3") as response:
    chunks = list(response.iter_bytes(chunk_size=128))
    assert len(chunks) > 1
    pathlib.Path(output, "sdk.mp3").write_bytes(b"".join(chunks))
with open(sample, "rb") as audio:
    response = client.audio.transcriptions.create(model=model, file=audio, language="en", response_format="json")
    assert response.text == "Offline transcript"
with open(sample, "rb") as audio:
    response = client.audio.transcriptions.create(model=model, file=audio, response_format="text")
    assert response == "Offline transcript"
print("OpenAI 2.26.0 audio SDK conformance passed")
