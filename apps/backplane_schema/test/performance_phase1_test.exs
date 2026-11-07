defmodule Backplane.Schema.PerformancePhase1.DynamicSchemas do
  import Backplane.Schema

  defschema(:invalid_dynamic, invalid_schema())

  def invalid_schema do
    %{field: {:required, {:string, {:default, "value"}}}}
  end
end

defmodule Backplane.Schema.PerformancePhase1.StaticSchemas do
  import Backplane.Schema

  defschema(:user, %{email: {:required, :string}})
  defschema(:no_spellcheck, %{email: {:required, :string}}, spellcheck: false)
end

defmodule Backplane.Schema.PerformancePhase1Test do
  use ExUnit.Case, async: true

  alias Backplane.Schema.Error
  alias Backplane.Schema.PerformancePhase1.{DynamicSchemas, StaticSchemas}

  describe "spellcheck option" do
    @schema %{email: {:required, :string}}
    @data %{emial: "ada@example.com"}

    test "disables suggestions in validation, decoding, encoding, and conforms?" do
      for validate <- [
            &Backplane.Schema.validate/3,
            &Backplane.Schema.decode/3,
            &Backplane.Schema.encode/3
          ] do
        assert {:error, [%Error{} = error]} = validate.(@schema, @data, spellcheck: false)
        assert error.message == "is required, expected type of :string"
        refute Map.has_key?(error.content, :did_you_mean)
      end

      refute Backplane.Schema.conforms?(@schema, @data, spellcheck: false)

      assert_raise ArgumentError, ~r/Invalid spellcheck option/, fn ->
        Backplane.Schema.validate(@schema, @data, spellcheck: :disabled)
      end
    end

    test "defschema accepts spellcheck as a validation option" do
      assert {:error, [%Error{} = error]} =
               StaticSchemas.no_spellcheck(@data)

      assert error.message == "is required, expected type of :string"
      refute Map.has_key?(error.content, :did_you_mean)
    end

    test "lazy lookup keeps nested map and list suggestions and ordered paths" do
      schema = %{
        accounts:
          {:list,
           %{
             profile: %{
               contact: %{email: {:required, :string}}
             }
           }}
      }

      data = %{accounts: [%{profile: %{contact: %{emial: "ada@example.com"}}}]}

      for mode <- [:strict, :permissive] do
        assert {:error, [%Error{path: [:accounts], errors: [account_error]}]} =
                 Backplane.Schema.validate(schema, data, mode: mode)

        assert %Error{path: [:accounts, 0, :profile], errors: [profile_error]} = account_error

        assert %Error{path: [:accounts, 0, :profile, :contact], errors: [contact_error]} =
                 profile_error

        assert %Error{
                 path: [:accounts, 0, :profile, :contact, :email],
                 message: "is required, expected type of :string did you mean :emial?",
                 content: %{did_you_mean: :emial}
               } = contact_error
      end
    end
  end

  describe "defschema literal validation" do
    test "returns and reuses the prevalidated literal schema" do
      schema = StaticSchemas.get_schema(:user)
      assert {:ok, ^schema} = Backplane.Schema.validate_schema(schema)

      assert {:ok, %{email: "ada@example.com"}} =
               StaticSchemas.user(%{email: "ada@example.com"})
    end

    test "dynamic schemas retain runtime validation" do
      assert {:error, [%Error{}]} =
               DynamicSchemas.invalid_dynamic(%{})
    end
  end
end
