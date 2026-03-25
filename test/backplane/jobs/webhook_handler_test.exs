defmodule Backplane.Jobs.WebhookHandlerTest do
  use Backplane.DataCase, async: true

  alias Backplane.Jobs.WebhookHandler

  describe "enqueue/2 for GitHub" do
    test "enqueues job from GitHub push event" do
      params = %{
        "ref" => "refs/heads/main",
        "repository" => %{
          "clone_url" => "https://github.com/test/repo.git"
        }
      }

      assert {:ok, _job} = WebhookHandler.enqueue(:github, params)
    end

    test "ignores non-push GitHub events" do
      assert {:ok, :ignored} = WebhookHandler.enqueue(:github, %{"action" => "opened"})
    end

    test "handles html_url fallback" do
      params = %{
        "ref" => "refs/heads/main",
        "repository" => %{
          "html_url" => "https://github.com/test/repo"
        }
      }

      assert {:ok, _job} = WebhookHandler.enqueue(:github, params)
    end
  end

  describe "enqueue/2 for GitLab" do
    test "enqueues job from GitLab push event" do
      params = %{
        "ref" => "refs/heads/main",
        "project" => %{
          "git_http_url" => "https://gitlab.com/test/repo.git"
        }
      }

      assert {:ok, _job} = WebhookHandler.enqueue(:gitlab, params)
    end

    test "ignores non-push GitLab events" do
      assert {:ok, :ignored} =
               WebhookHandler.enqueue(:gitlab, %{"object_kind" => "merge_request"})
    end
  end

  describe "validate_github_signature/3" do
    test "validates correct signature" do
      payload = ~s({"test": true})
      secret = "webhook-secret"

      expected =
        "sha256=" <>
          (:crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower))

      assert WebhookHandler.validate_github_signature(payload, expected, secret)
    end

    test "rejects incorrect signature" do
      payload = ~s({"test": true})
      secret = "webhook-secret"

      refute WebhookHandler.validate_github_signature(payload, "sha256=wrong", secret)
    end

    test "rejects signature with wrong prefix" do
      payload = ~s({"test": true})
      secret = "webhook-secret"

      hmac = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
      refute WebhookHandler.validate_github_signature(payload, "sha1=#{hmac}", secret)
    end
  end

  describe "validate_gitlab_token/2" do
    test "validates matching token" do
      assert WebhookHandler.validate_gitlab_token("my-secret", "my-secret")
    end

    test "rejects non-matching token" do
      refute WebhookHandler.validate_gitlab_token("wrong", "my-secret")
    end
  end
end
