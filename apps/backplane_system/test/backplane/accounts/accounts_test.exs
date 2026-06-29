defmodule Backplane.AccountsTest do
  use Backplane.DataCase, async: false

  alias Backplane.Accounts
  alias Backplane.Accounts.{User, UserIdentity}

  describe "provision_federated_user/2" do
    test "creates a user and identity from stable provider subject claims" do
      {:ok, provider} = auth_provider("google")

      assert {:ok, %{user: %User{} = user, identity: %UserIdentity{} = identity}} =
               Accounts.provision_federated_user(provider, %{
                 "sub" => "google-sub-1",
                 "email" => "alice@example.com",
                 "name" => "Alice Example"
               })

      assert user.email == "alice@example.com"
      assert user.name == "Alice Example"
      assert user.active
      assert identity.provider_id == provider.id
      assert identity.subject == "google-sub-1"
      assert identity.user_id == user.id
      assert identity.raw_claims["sub"] == "google-sub-1"
    end

    test "reuses identity by provider subject and updates claim snapshots" do
      {:ok, provider} = auth_provider("google")

      {:ok, %{user: first_user, identity: first_identity}} =
        Accounts.provision_federated_user(provider, %{
          "sub" => "google-sub-1",
          "email" => "alice@example.com",
          "name" => "Alice"
        })

      assert {:ok, %{user: second_user, identity: second_identity}} =
               Accounts.provision_federated_user(provider, %{
                 "sub" => "google-sub-1",
                 "email" => "alice-renamed@example.com",
                 "name" => "Alice Renamed"
               })

      assert second_user.id == first_user.id
      assert second_identity.id == first_identity.id
      assert second_identity.email == "alice-renamed@example.com"
      assert second_identity.name == "Alice Renamed"
      assert second_identity.raw_claims["name"] == "Alice Renamed"
    end

    test "does not merge users by email across provider subjects" do
      {:ok, google} = auth_provider("google")
      {:ok, github} = auth_provider("github")

      {:ok, %{user: google_user}} =
        Accounts.provision_federated_user(google, %{
          "sub" => "google-sub",
          "email" => "same@example.com",
          "name" => "Google User"
        })

      {:ok, %{user: github_user}} =
        Accounts.provision_federated_user(github, %{
          "sub" => "github-sub",
          "email" => "same@example.com",
          "name" => "GitHub User"
        })

      refute github_user.id == google_user.id
      assert github_user.email == "same@example.com"
      assert google_user.email == "same@example.com"
    end

    test "returns changeset errors without partial identity writes when required claims are missing" do
      {:ok, provider} = auth_provider("google")

      assert {:error, changeset} =
               Accounts.provision_federated_user(provider, %{
                 "sub" => "google-sub-without-email",
                 "name" => "No Email"
               })

      assert %{email: ["can't be blank"]} = errors_on(changeset)
      assert Accounts.get_user_by_identity(provider.id, "google-sub-without-email") == nil
    end

    test "converges concurrent first-time provisioning for the same provider subject" do
      {:ok, provider} = auth_provider("google")

      claims = %{
        "sub" => "shared-google-sub",
        "email" => "alice@example.com",
        "name" => "Alice Example"
      }

      results =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn -> Accounts.provision_federated_user(provider, claims) end)
        end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert Enum.all?(results, &match?({:ok, %{user: %User{}, identity: %UserIdentity{}}}, &1))

      user_ids =
        Enum.map(results, fn {:ok, %{user: user}} -> user.id end)
        |> Enum.uniq()

      assert [_single_user_id] = user_ids

      assert [%UserIdentity{subject: "shared-google-sub"}] =
               Repo.all(
                 from identity in UserIdentity,
                   where:
                     identity.provider_id == ^provider.id and
                       identity.subject == "shared-google-sub"
               )
    end
  end

  describe "bootstrap_admin?/1" do
    setup do
      old_emails = Application.get_env(:backplane, :bootstrap_admin_emails)

      on_exit(fn ->
        if is_nil(old_emails) do
          Application.delete_env(:backplane, :bootstrap_admin_emails)
        else
          Application.put_env(:backplane, :bootstrap_admin_emails, old_emails)
        end
      end)

      :ok
    end

    test "matches configured emails case-insensitively" do
      Application.put_env(:backplane, :bootstrap_admin_emails, [
        "Admin@Example.COM",
        " ops@example.com "
      ])

      assert Accounts.bootstrap_admin?("admin@example.com")
      assert Accounts.bootstrap_admin?(%User{email: "OPS@example.com"})
      refute Accounts.bootstrap_admin?("member@example.com")
    end

    test "ignores blank and nil configured emails" do
      Application.put_env(:backplane, :bootstrap_admin_emails, ["", nil, "root@example.com"])

      assert Accounts.bootstrap_admin?("ROOT@example.com")
      refute Accounts.bootstrap_admin?("")
      refute Accounts.bootstrap_admin?(nil)
    end
  end

  defp auth_provider(slug) do
    Accounts.create_auth_provider(%{
      slug: slug,
      name: String.capitalize(slug),
      kind: "oidc",
      issuer: "https://#{slug}.example.com",
      client_id: "#{slug}-client",
      client_secret: "#{slug}-secret",
      scopes: ["openid", "email", "profile"]
    })
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
