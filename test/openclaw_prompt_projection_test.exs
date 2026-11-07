ExUnit.start()
Code.require_file("support/openclaw_prompt_projection.exs", __DIR__)

defmodule Backplane.OpenClawPromptProjectionTest do
  use ExUnit.Case, async: true
  alias Backplane.OpenClawPromptProjection

  test "recall is inspected on the submitted input before appended host runtime context" do
    prompt = "What is the qualification fruit?"
    projection = "Backplane memory reference data: pear\n\n" <> prompt

    for content <- [projection, [%{"type" => "text", "text" => projection}]] do
      turn = %{
        "prompt" => prompt,
        "finalPrompt" => [
          %{"role" => "user", "content" => projection},
          %{"role" => "assistant", "content" => "Previous reply."},
          %{"role" => "user", "content" => content},
          %{"role" => "user", "content" => "Host runtime context update."}
        ]
      }

      assert OpenClawPromptProjection.current_user_text(turn) == projection
    end
  end

  test "historical recall cannot satisfy an unrelated current query" do
    prompt = "Unrelated neutrino question."

    turn = %{
      "prompt" => prompt,
      "finalPrompt" => [
        %{"role" => "user", "content" => "Backplane memory reference data: pear"},
        %{"role" => "user", "content" => prompt},
        %{"role" => "user", "content" => "Host runtime context update."}
      ]
    }

    assert OpenClawPromptProjection.current_user_text(turn) == prompt
    assert OpenClawPromptProjection.current_user_text(%{turn | "prompt" => "Absent input"}) == ""
    assert OpenClawPromptProjection.current_user_text(%{turn | "prompt" => ""}) == ""
    assert OpenClawPromptProjection.current_user_text(%{}) == ""
  end
end
