package contract

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"

	"os"
	"testing"

	"google.golang.org/genai"
)

type recording struct {
	Body   any    `json:"body"`
	Method string `json:"method"`
	Path   string `json:"path"`
	Query  string `json:"query"`
}

func TestWireContract(t *testing.T) {
	const model = "models/gemini-2.5-flash"
	const apiKey = "backplane-sdk-contract-key"
	response := map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{map[string]any{"text": "recording response"}}, "role": "model"}, "finishReason": "STOP", "index": 0}}, "modelVersion": "gemini-2.5-flash", "responseId": "recording-response-id", "usageMetadata": map[string]any{"candidatesTokenCount": 2, "promptTokenCount": 3, "totalTokenCount": 5}}
	var recordings []recording
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-goog-api-key") != apiKey {
			t.Errorf("api key header = %q", r.Header.Get("x-goog-api-key"))
		}
		if got := r.Header.Get("x-goog-api-client"); got == "" {
			t.Error("missing x-goog-api-client")
		}
		var body any
		if r.Body != nil {
			_ = json.NewDecoder(r.Body).Decode(&body)
		}
		recordings = append(recordings, recording{Body: body, Method: r.Method, Path: r.URL.Path, Query: func() string {
			if r.URL.RawQuery == "" {
				return ""
			}
			return "?" + r.URL.RawQuery
		}()})
		w.Header().Set("content-type", "application/json")
		switch {
		case r.URL.Query().Get("alt") == "sse":
			w.Header().Set("content-type", "text/event-stream")
			fmt.Fprintf(w, "data: %s\n\ndata: %s\n\n", mustJSON(response), mustJSON(response))
		case r.Method == http.MethodGet && r.URL.Path[len(r.URL.Path)-7:] == "/models":
			json.NewEncoder(w).Encode(map[string]any{"models": []any{map[string]any{"name": model, "displayName": "Gemini", "supportedGenerationMethods": []string{"generateContent"}}}})
		case r.Method == http.MethodGet:
			json.NewEncoder(w).Encode(map[string]any{"name": model, "displayName": "Gemini", "supportedGenerationMethods": []string{"generateContent"}})
		case r.URL.Path[len(r.URL.Path)-12:] == ":countTokens":
			json.NewEncoder(w).Encode(map[string]any{"totalTokens": 3})
		default:
			json.NewEncoder(w).Encode(response)
		}
	}))
	defer server.Close()
	client, err := genai.NewClient(context.Background(), &genai.ClientConfig{APIKey: apiKey, Backend: genai.BackendGeminiAPI, HTTPOptions: genai.HTTPOptions{BaseURL: server.URL + "/deploy", APIVersion: "v1beta"}})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err = client.Models.GenerateContent(ctx, model, genai.Text("sanitized generate prompt"), nil); err != nil {
		t.Fatal(err)
	}
	chunks := 0
	for _, streamErr := range client.Models.GenerateContentStream(ctx, model, genai.Text("sanitized stream prompt"), nil) {
		if streamErr != nil {
			t.Fatal(streamErr)
		}
		chunks++
	}
	if chunks != 2 {
		t.Fatalf("stream chunks = %d", chunks)
	}
	if counted, countErr := client.Models.CountTokens(ctx, model, genai.Text("sanitized count prompt"), nil); countErr != nil || counted.TotalTokens != 3 {
		t.Fatalf("count = %#v, err = %v", counted, countErr)
	}
	if page, listErr := client.Models.List(ctx, nil); listErr != nil || len(page.Items) != 1 || page.Items[0].Name != model {
		t.Fatalf("list = %#v, err = %v", page.Items, listErr)
	}
	if fetched, getErr := client.Models.Get(ctx, model, nil); getErr != nil || fetched.Name != model {
		t.Fatalf("get = %#v, err = %v", fetched, getErr)
	}
	if err := os.WriteFile("../../fixtures/requests/go.captured.json", []byte(mustJSON(recordings)+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	wantBytes, err := os.ReadFile("../../fixtures/requests/go.json")
	if err != nil {
		t.Fatal(err)
	}
	var want []recording
	if err = json.Unmarshal(wantBytes, &want); err != nil {
		t.Fatal(err)
	}
	if got, wantJSON := mustJSON(recordings), mustJSON(want); got != wantJSON {
		t.Fatalf("recordings\ngot  %s\nwant %s", got, wantJSON)
	}
}

func mustJSON(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return string(data)
}
