defmodule Backplane.LLM.ProviderPreset do
  @moduledoc """
  Static catalog for known LLM provider creation presets.

  Presets provide creation defaults and optional credential auth constraints.
  Runtime routing uses persisted provider API and provider model rows.
  """

  @type api_defaults :: %{
          optional(:native_protocols) => [atom()],
          optional(:backend_config) => map(),
          enabled: boolean(),
          base_url: String.t(),
          discovery_path: String.t() | nil
        }

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          default_name: String.t(),
          default_credential: String.t() | nil,
          credential_kind: String.t(),
          credential_auth_type: String.t() | nil,
          default_base_url: String.t(),
          surfaces: %{atom() => api_defaults()},
          openai: api_defaults(),
          anthropic: api_defaults(),
          notes: String.t(),
          docs_urls: [String.t()]
        }

  defstruct [
    :key,
    :name,
    :default_name,
    :default_credential,
    :credential_kind,
    :credential_auth_type,
    :default_base_url,
    :surfaces,
    :openai,
    :anthropic,
    :notes,
    docs_urls: []
  ]

  @presets [
    %{
      key: "deepseek",
      name: "DeepSeek",
      default_name: "deepseek",
      credential_kind: "llm",
      default_base_url: "https://api.deepseek.com",
      openai: %{
        enabled: true,
        base_url: "https://api.deepseek.com",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: true,
        base_url: "https://api.deepseek.com/anthropic",
        discovery_path: "/v1/models"
      },
      notes: "DeepSeek supports OpenAI-compatible and Anthropic-compatible API formats.",
      docs_urls: [
        "https://api-docs.deepseek.com/",
        "https://api-docs.deepseek.com/guides/anthropic_api",
        "https://api-docs.deepseek.com/api/list-models"
      ]
    },
    %{
      key: "z-ai",
      name: "Z.ai",
      default_name: "z-ai",
      credential_kind: "llm",
      default_base_url: "https://open.bigmodel.cn/api",
      openai: %{
        enabled: true,
        base_url: "https://open.bigmodel.cn/api/paas/v4",
        discovery_path: nil
      },
      anthropic: %{
        enabled: false,
        base_url: "https://api.z.ai/api/anthropic",
        discovery_path: nil
      },
      notes:
        "Z.ai general API is OpenAI-compatible. Its Anthropic-compatible endpoint is documented for GLM Coding Plan tooling, so it is disabled by default.",
      docs_urls: [
        "https://docs.bigmodel.cn/cn/guide/develop/openai/introduction",
        "https://docs.z.ai/api-reference/llm/chat-completion",
        "https://docs.z.ai/devpack/tool/claude"
      ]
    },
    %{
      key: "minimax",
      name: "MiniMax",
      default_name: "minimax",
      credential_kind: "llm",
      default_base_url: "https://api.minimaxi.com",
      openai: %{
        enabled: true,
        base_url: "https://api.minimaxi.com/v1",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: true,
        base_url: "https://api.minimaxi.com/anthropic",
        discovery_path: "/v1/models"
      },
      notes:
        "MiniMax supports OpenAI-compatible and Anthropic-compatible protocols. The preset uses the China base URL and can be overridden.",
      docs_urls: [
        "https://platform.minimax.io/docs/token-plan/other-tools",
        "https://platform.minimax.io/docs/api-reference/models/openai/list-models",
        "https://platform.minimax.io/docs/api-reference/models/anthropic/list-models",
        "https://platform.minimax.io/docs/solutions/mini-agent"
      ]
    },
    %{
      key: "opencode",
      name: "OpenCode Go",
      default_name: "opencode",
      credential_kind: "llm",
      default_base_url: "https://opencode.ai/zen/go/v1",
      openai: %{
        enabled: true,
        base_url: "https://opencode.ai/zen/go/v1",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: false,
        base_url: "",
        discovery_path: nil
      },
      notes: "OpenCode Go exposes an OpenAI-compatible API surface.",
      docs_urls: ["https://dev.opencode.ai/docs/go/"]
    },
    %{
      key: "openrouter",
      name: "OpenRouter",
      default_name: "openrouter",
      credential_kind: "llm",
      default_base_url: "https://openrouter.ai/api/v1",
      openai: %{
        enabled: true,
        base_url: "https://openrouter.ai/api/v1",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: false,
        base_url: "",
        discovery_path: nil
      },
      notes: "OpenRouter provides an OpenAI-compatible API for routed models.",
      docs_urls: ["https://openrouter.ai/docs/quickstart"]
    },
    %{
      key: "ollama",
      name: "Ollama",
      default_name: "ollama",
      credential_kind: "llm",
      default_base_url: "http://localhost:11434",
      openai: %{
        enabled: true,
        base_url: "http://localhost:11434/v1",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: true,
        base_url: "http://localhost:11434",
        discovery_path: "/v1/models"
      },
      notes: "Ollama exposes local OpenAI-compatible and Anthropic-compatible endpoints.",
      docs_urls: [
        "https://docs.ollama.com/api/openai-compatibility",
        "https://docs.ollama.com/api/anthropic-compatibility"
      ]
    },
    %{
      key: "ollama-cloud",
      name: "Ollama Cloud",
      default_name: "ollama-cloud",
      credential_kind: "llm",
      credential_auth_type: "api_key",
      default_base_url: "https://ollama.com",
      openai: %{
        enabled: true,
        base_url: "https://ollama.com/v1",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: true,
        base_url: "https://ollama.com",
        discovery_path: "/v1/models"
      },
      notes:
        "Ollama Cloud exposes hosted OpenAI-compatible and Anthropic-compatible endpoints using an Ollama API key.",
      docs_urls: [
        "https://docs.ollama.com/cloud",
        "https://docs.ollama.com/api/authentication",
        "https://docs.ollama.com/api/openai-compatibility",
        "https://docs.ollama.com/api/anthropic-compatibility"
      ]
    },
    %{
      key: "vllm",
      name: "vLLM",
      default_name: "vllm",
      credential_kind: "llm",
      credential_auth_type: "api_key",
      default_base_url: "http://localhost:8000",
      openai: %{
        enabled: true,
        base_url: "http://localhost:8000/v1",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: true,
        base_url: "http://localhost:8000",
        discovery_path: nil
      },
      notes:
        "vLLM serves native OpenAI Chat Completions, Responses, and Anthropic Messages APIs. Model discovery uses the OpenAI /v1/models endpoint. API keys are optional unless server authentication is configured.",
      docs_urls: [
        "https://docs.vllm.ai/en/latest/serving/online_serving/",
        "https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/",
        "https://docs.vllm.ai/en/latest/cli/serve/"
      ]
    },
    %{
      key: "sglang",
      name: "SGLang",
      default_name: "sglang",
      credential_kind: "llm",
      credential_auth_type: "api_key",
      default_base_url: "http://localhost:30000",
      openai: %{
        enabled: true,
        base_url: "http://localhost:30000/v1",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: true,
        base_url: "http://localhost:30000",
        discovery_path: nil
      },
      notes:
        "SGLang serves native OpenAI Chat Completions, Responses, and Anthropic Messages APIs. Responses availability depends on server initialization and model support. Model discovery uses the OpenAI /v1/models endpoint. API keys are optional unless server authentication is configured.",
      docs_urls: [
        "https://docs.sglang.io/docs/basic_usage/openai_api_completions",
        "https://docs.sglang.io/docs/basic_usage/anthropic_api",
        "https://docs.sglang.io/docs/advanced_features/server_arguments",
        "https://github.com/sgl-project/sglang/blob/main/python/sglang/srt/entrypoints/http_server.py"
      ]
    },
    %{
      key: "custom",
      name: "Custom",
      default_name: "custom",
      credential_kind: "llm",
      default_base_url: "",
      openai: %{
        enabled: true,
        base_url: "",
        discovery_path: nil
      },
      anthropic: %{
        enabled: false,
        base_url: "",
        discovery_path: nil
      },
      notes: "Custom provider preset for manually configured OpenAI-compatible endpoints.",
      docs_urls: []
    },
    %{
      key: "openai",
      name: "OpenAI",
      default_name: "openai",
      credential_kind: "llm",
      default_base_url: "https://api.openai.com/v1",
      openai: %{
        enabled: true,
        base_url: "https://api.openai.com/v1",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: false,
        base_url: "",
        discovery_path: nil
      },
      notes: "OpenAI provider preset for the official OpenAI API.",
      docs_urls: ["https://platform.openai.com/docs/api-reference/models/list"]
    },
    %{
      key: "openai-codex",
      name: "OpenAI Codex",
      default_name: "openai-codex",
      default_credential: "openai-codex",
      credential_kind: "llm",
      credential_auth_type: "openai_oauth",
      default_base_url: Backplane.LLM.OpenAICodex.default_backend_base_url(),
      openai: %{
        enabled: true,
        base_url: Backplane.LLM.OpenAICodex.default_backend_base_url(),
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: false,
        base_url: "",
        discovery_path: nil
      },
      notes:
        "Codex-oriented OpenAI preset. It uses the ChatGPT Codex backend with an OpenAI OAuth credential.",
      docs_urls: [
        "https://developers.openai.com/codex/config-reference"
      ]
    },
    %{
      key: "anthropic",
      name: "Anthropic",
      default_name: "anthropic",
      credential_kind: "llm",
      default_base_url: "https://api.anthropic.com",
      openai: %{
        enabled: false,
        base_url: "",
        discovery_path: nil
      },
      anthropic: %{
        enabled: true,
        base_url: "https://api.anthropic.com",
        discovery_path: "/v1/models"
      },
      notes: "Anthropic provider preset for the official Messages API.",
      docs_urls: ["https://platform.claude.com/docs/en/api/overview"]
    },
    %{
      key: "x-ai",
      name: "x.ai",
      default_name: "x-ai",
      credential_kind: "llm",
      default_base_url: "https://api.x.ai/v1",
      openai: %{
        enabled: true,
        base_url: "https://api.x.ai/v1",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: false,
        base_url: "",
        discovery_path: nil
      },
      notes: "x.ai exposes an OpenAI-compatible chat completions API.",
      docs_urls: ["https://docs.x.ai/docs/guides/chat-completions"]
    },
    %{
      key: "google-gemini-developer",
      name: "Google Gemini Developer API",
      default_name: "google-gemini-developer",
      credential_kind: "llm",
      credential_auth_type: "api_key",
      default_base_url: "https://generativelanguage.googleapis.com/v1beta",
      surfaces: %{
        google: %{
          enabled: true,
          base_url: "https://generativelanguage.googleapis.com/v1beta",
          discovery_path: "/models",
          native_protocols: [:google_generate_content]
        }
      },
      notes:
        "Official Gemini Developer API using native GenerateContent and an API-key credential.",
      docs_urls: ["https://ai.google.dev/api"]
    },
    %{
      key: "google-antigravity",
      name: "Google Antigravity",
      default_name: "google-antigravity",
      default_credential: "google-antigravity",
      credential_kind: "llm",
      credential_auth_type: "google_oauth",
      default_base_url: "https://cloudcode-pa.googleapis.com",
      surfaces: %{
        antigravity: %{
          enabled: true,
          base_url: "https://cloudcode-pa.googleapis.com",
          discovery_path: "/v1internal:fetchAvailableModels",
          native_protocols: [:google_antigravity],
          backend_config: %{}
        }
      },
      notes: "Google Antigravity subscription API using its native Cloud Code protocol.",
      docs_urls: []
    },
    %{
      key: "moonshot-cn",
      name: "Moonshot.cn",
      default_name: "moonshot-cn",
      credential_kind: "llm",
      default_base_url: "https://api.moonshot.cn/v1",
      openai: %{
        enabled: true,
        base_url: "https://api.moonshot.cn/v1",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: false,
        base_url: "",
        discovery_path: nil
      },
      notes: "Moonshot.cn provides Kimi models through an OpenAI-compatible API.",
      docs_urls: ["https://platform.kimi.com/docs/api/overview"]
    }
  ]

  @doc "List all built-in provider presets."
  @spec all() :: [t()]
  def all, do: Enum.map(@presets, &normalize/1)

  @doc "Return all preset keys."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@presets, & &1.key)

  @doc "Fetch a preset by key."
  @spec get(String.t()) :: t() | nil
  def get(key) when is_binary(key) do
    @presets
    |> Enum.find(&(&1.key == key))
    |> case do
      nil -> nil
      preset -> normalize(preset)
    end
  end

  def get(_key), do: nil

  @doc "Fetch a preset by key, raising when the key is unknown."
  @spec fetch!(String.t()) :: t()
  def fetch!(key) do
    get(key) || raise ArgumentError, "unknown LLM provider preset: #{inspect(key)}"
  end

  @doc "Normalized API surfaces configured by a preset."
  @spec surfaces(t()) :: %{atom() => api_defaults()}
  def surfaces(%__MODULE__{surfaces: surfaces}), do: surfaces

  @doc "Fetch one normalized API surface configured by a preset."
  @spec surface(t(), atom()) :: api_defaults() | nil
  def surface(%__MODULE__{} = preset, api_surface) do
    Map.get(preset.surfaces, api_surface)
  end

  @doc "Default wire protocols enabled for a preset's API surface."
  @spec native_protocols(t(), atom()) :: [atom()]
  def native_protocols(%__MODULE__{} = preset, api_surface) do
    case surface(preset, api_surface) do
      %{native_protocols: protocols} -> protocols
      _ -> []
    end
  end

  defp normalize(preset) do
    surfaces = Map.get(preset, :surfaces) || legacy_surfaces(preset)

    preset
    |> Map.put(:surfaces, surfaces)
    |> Map.put(:openai, compatibility_slot(surfaces, :openai))
    |> Map.put(:anthropic, compatibility_slot(surfaces, :anthropic))
    |> then(&struct!(__MODULE__, &1))
  end

  defp legacy_surfaces(preset) do
    [:openai, :anthropic]
    |> Map.new(fn api_surface ->
      defaults = Map.fetch!(preset, api_surface)

      {api_surface,
       Map.put(defaults, :native_protocols, legacy_native_protocols(preset.key, api_surface))}
    end)
  end

  defp compatibility_slot(surfaces, api_surface) do
    surfaces
    |> Map.get(api_surface, %{enabled: false, base_url: "", discovery_path: nil})
    |> Map.drop([:native_protocols])
  end

  defp legacy_native_protocols("openai-codex", :openai), do: [:openai_responses]

  defp legacy_native_protocols(_preset_key, :openai),
    do: [:openai_chat_completions, :openai_responses]

  defp legacy_native_protocols(_preset_key, :anthropic), do: [:anthropic_messages]
end
