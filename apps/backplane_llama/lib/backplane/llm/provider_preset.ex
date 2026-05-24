defmodule Backplane.LLM.ProviderPreset do
  @moduledoc """
  Static catalog for known LLM provider creation presets.

  Presets are UI defaults only. Runtime routing uses persisted provider API and
  provider model rows.
  """

  @type api_defaults :: %{
          enabled: boolean(),
          base_url: String.t(),
          discovery_path: String.t() | nil
        }

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          default_name: String.t(),
          credential_kind: String.t(),
          default_base_url: String.t(),
          openai: api_defaults(),
          anthropic: api_defaults(),
          notes: String.t(),
          docs_urls: [String.t()]
        }

  defstruct [
    :key,
    :name,
    :default_name,
    :credential_kind,
    :default_base_url,
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
      notes:
        "Codex-oriented OpenAI preset. It uses the official OpenAI API endpoint and a Codex-friendly provider name.",
      docs_urls: [
        "https://platform.openai.com/docs/api-reference/models/list",
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
      key: "google-ai-studio",
      name: "Google AI Studio",
      default_name: "google-ai-studio",
      credential_kind: "llm",
      default_base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
      openai: %{
        enabled: true,
        base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
        discovery_path: "/models"
      },
      anthropic: %{
        enabled: false,
        base_url: "",
        discovery_path: nil
      },
      notes: "Google AI Studio provides Gemini access through an OpenAI-compatible API.",
      docs_urls: ["https://ai.google.dev/gemini-api/docs/openai"]
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
  def all, do: Enum.map(@presets, &struct!(__MODULE__, &1))

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
      preset -> struct!(__MODULE__, preset)
    end
  end

  @doc "Fetch a preset by key, raising when the key is unknown."
  @spec fetch!(String.t()) :: t()
  def fetch!(key) do
    get(key) || raise ArgumentError, "unknown LLM provider preset: #{inspect(key)}"
  end
end
