defmodule Backplane.Admin.HostServicesLiveTest do
  use Backplane.Admin.LiveCase, async: false
  import Phoenix.LiveViewTest

  alias Backplane.Embedding
  alias Backplane.LLM.{HostServices, Provider, ProviderApi}
  alias Backplane.Repo
  alias Backplane.Skills.Hosts

  setup do
    {:ok, host} =
      Hosts.create_agent(%{
        name: "api-services-#{System.unique_integer([:positive])}"
      })

    %{host: host}
  end

  test "configures explicit APIs on a host and edits and deletes the service", %{
    conn: conn,
    host: host
  } do
    {:ok, view, html} = live(conn, "/system/host-agents/#{host.id}/services")
    assert html =~ "API Services"
    refute html =~ "vLLM"

    view
    |> form("#host-api-service-form", %{
      "service" => %{
        "name" => "my-local-api",
        "enabled" => "true",
        "openai_responses" => "http://127.0.0.1:8000/native/responses",
        "anthropic_messages" => "http://127.0.0.1:8000/native/messages"
      }
    })
    |> render_submit()

    assert [service] = HostServices.list_for_host(host.id)

    assert service.endpoints == %{
             "openai_responses" => "http://127.0.0.1:8000/native/responses",
             "anthropic_messages" => "http://127.0.0.1:8000/native/messages"
           }

    assert has_element?(view, "#host-api-service-#{service.id}", "my-local-api")

    view |> element("#edit-host-api-service-#{service.id}") |> render_click()

    view
    |> form("#host-api-service-form", %{"service" => %{"name" => "renamed", "enabled" => "false"}})
    |> render_submit()

    assert %{name: "renamed", enabled: false} = HostServices.get(service.id)
    view |> element("#delete-host-api-service-#{service.id}") |> render_click()
    assert [] = HostServices.list_for_host(host.id)
  end

  test "shows endpoint errors and excludes another host's service from edit actions", %{
    conn: conn,
    host: host
  } do
    {:ok, view, _} = live(conn, "/system/host-agents/#{host.id}/services")

    html =
      view
      |> form("#host-api-service-form", %{
        "service" => %{"name" => "missing", "enabled" => "true"}
      })
      |> render_submit()

    assert html =~ "must declare at least one supported API endpoint"
    assert [] = HostServices.list_for_host(host.id)

    {:ok, other_host} =
      Hosts.create_agent(%{
        name: "other-api-host-#{System.unique_integer([:positive])}"
      })

    {:ok, service} =
      HostServices.create(%{
        host_id: other_host.id,
        name: "other-api",
        endpoints: %{
          "openai_responses" => "http://127.0.0.1:8000/v1/responses"
        }
      })

    assert render_click(view, "edit_service", %{"id" => service.id}) =~ "API service not found"
    assert render_click(view, "delete_service", %{"id" => service.id}) =~ "API service not found"
    assert HostServices.get(service.id)
  end

  test "selects a host service for an LLM provider without a credential", %{
    conn: conn,
    host: host
  } do
    {:ok, service} =
      HostServices.create(%{
        host_id: host.id,
        name: "local-inference",
        endpoints: %{
          "openai_responses" => "http://127.0.0.1:8000/native/responses",
          "openai_chat_completions" => "http://127.0.0.1:8000/native/chat"
        }
      })

    {:ok, view, _} = live(conn, "/llama/providers/new?preset=custom")
    assert has_element?(view, "#provider-host-service option[value='#{service.id}']")

    view
    |> form("form[phx-submit=save]", %{
      "provider" => %{
        "name" => "host-inference",
        "host_service_id" => service.id,
        "credential" => "",
        "openai_enabled" => "true",
        "openai_chat_completions_enabled" => "true",
        "openai_responses_enabled" => "true"
      }
    })
    |> render_submit()

    assert_redirect(view, "/llama/providers")
    provider = Repo.get_by!(Provider, name: "host-inference")
    assert provider.host_service_id == service.id
    assert is_nil(provider.credential)

    assert [%{native_protocols: protocols, model_discovery_enabled: false}] =
             ProviderApi.list_for_provider(provider.id)

    assert Enum.sort(protocols) == [:openai_chat_completions, :openai_responses]
    {:ok, edit, _} = live(conn, "/llama/providers/#{provider.id}")
    assert has_element?(edit, "#provider-host-service option[value='#{service.id}'][selected]")
    assert {:error, changeset} = Hosts.delete_agent(host)
    assert changeset.errors[:id]
    assert Hosts.get_host(host.id)
    assert Provider.get(provider.id)
    assert HostServices.get(service.id)
  end

  test "selects an embedding host service and configures its model", %{conn: conn, host: host} do
    {:ok, service} =
      HostServices.create(%{
        host_id: host.id,
        name: "local-vector",
        endpoints: %{
          "openai_embeddings" => "http://127.0.0.1:8001/vector"
        }
      })

    {:ok, view, _} = live(conn, "/llama/embedding")
    view |> element("#open-embedding-provider-modal") |> render_click()
    assert has_element?(view, "#embedding-provider-host-service option[value='#{service.id}']")

    view
    |> form("#embedding-provider-form", %{
      "provider" => %{
        "name" => "host-embedding",
        "host_service_id" => service.id,
        "credential" => "",
        "enabled" => "true",
        "model" => "local-vector-model",
        "model_enabled" => "true"
      }
    })
    |> render_submit()

    assert [model] = Embedding.list_enabled_models()
    assert model.provider.host_service_id == service.id
    assert model.provider.base_url == "http://127.0.0.1:8001/vector"
    assert model.model == "local-vector-model"
  end
end
