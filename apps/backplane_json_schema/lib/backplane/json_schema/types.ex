defmodule Backplane.JsonSchema.Types do
  @moduledoc """
  Defines the core data structures used by Backplane.JsonSchema.
  """

  defmodule Schema do
    @moduledoc """
    A compiled JSON Schema containing executable rules and reference metadata.
    """
    @type t :: %__MODULE__{
            rules: list(Backplane.JsonSchema.Types.Rule.t()),
            defs: map() | nil,
            local_refs: map(),
            dynamic_anchor: String.t() | nil,
            source_id: String.t() | nil,
            raw: map() | boolean() | nil,
            loader:
              (String.t() ->
                 {:ok, map() | boolean()}
                 | {:ok, %{required(:document) => map() | boolean(), optional(:base_uri) => String.t()}}
                 | {:error, term()})
              | nil,
            format_assertion: boolean(),
            content_assertion: boolean(),
            draft: String.t()
          }
    defstruct [
      :rules,
      :defs,
      :source_id,
      :raw,
      :dynamic_anchor,
      :loader,
      local_refs: %{},
      format_assertion: false,
      content_assertion: false,
      draft: "draft2020_12"
    ]
  end

  defmodule ValidationContext do
    @moduledoc """
    Lightweight runtime context threaded through validation.
    """
    @type t :: %__MODULE__{
            root_schema: Backplane.JsonSchema.Types.Schema.t(),
            scope_stack: list(String.t()),
            source_id: String.t() | nil,
            raw: map() | nil,
            local_refs: map()
          }
    defstruct [
      :root_schema,
      :source_id,
      :raw,
      local_refs: %{},
      scope_stack: []
    ]
  end

  defmodule Rule do
    @moduledoc """
    A single compiled validation step.
    """
    @type t :: %__MODULE__{
            name: atom(),
            params: term()
          }
    defstruct [:name, :params]
  end

  defmodule Error do
    @moduledoc """
    An error encountered during validation or schema compilation.
    """
    @type t :: %__MODULE__{
            path: list(),
            rule: atom(),
            context: Backplane.JsonSchema.Types.ErrorContext.t() | nil,
            value: term() | nil
          }
    defstruct [:path, :rule, :context, :value]

    defimpl String.Chars do
      def to_string(t) do
        Backplane.JsonSchema.ErrorFormatter.format(t)
      end
    end
  end

  defmodule ErrorContext do
    @moduledoc """
    Structured detail carried by `Backplane.JsonSchema.Types.Error`.
    """
    @type t :: %__MODULE__{
            contrast: term() | nil,
            input: term() | nil,
            error_detail: term() | nil
          }
    defstruct [:contrast, :input, :error_detail]
  end

  @non_neg_int_keywords ~w(minLength maxLength minProperties maxProperties minItems maxItems)
  @numeric_keywords ~w(minimum maximum exclusiveMinimum exclusiveMaximum)
  @valid_types ~w(string integer number boolean object array null)

  @doc false
  defguard is_non_neg_int_keywords?(value) when value in @non_neg_int_keywords

  @doc false
  defguard is_numeric_keywords?(value) when value in @numeric_keywords

  @doc false
  def valid_types, do: @valid_types

  @doc false
  defguard is_valid_types?(value) when value in @valid_types
end
