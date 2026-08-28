ExUnit.start()

defmodule Backplane.CIWorkflowTest do
  use ExUnit.Case, async: true

  @setup_beam_action "erlef/setup-beam@v1"
  @rust_action "dtolnay/rust-toolchain@stable"
  @elixir_pin "${{ env.ELIXIR_VERSION }}"
  @otp_pin "${{ env.OTP_VERSION }}"
  @rust_pin "${{ env.RUST_VERSION }}"

  @concurrency %{
    "group" => "${{ github.workflow }}-${{ github.ref }}",
    "cancel-in-progress" => true
  }

  @ci_metadata %{
    "name" => "CI",
    "on" => %{"push" => nil, "pull_request" => nil},
    "permissions" => %{"contents" => "read"},
    "concurrency" => @concurrency,
    "env" => %{
      "ELIXIR_VERSION" => "1.18.4",
      "OTP_VERSION" => "28.5.0.5",
      "RUST_VERSION" => "1.95.0",
      "MIX_ENV" => "dev"
    }
  }

  @test_metadata %{
    "name" => "Test",
    "on" => %{
      "push" => %{"branches" => ["main", "develop"]},
      "pull_request" => %{"branches" => ["main"]}
    },
    "permissions" => %{"contents" => "read"},
    "concurrency" => @concurrency,
    "env" => %{
      "ELIXIR_VERSION" => "1.18.4",
      "OTP_VERSION" => "28.5.0.5",
      "RUST_VERSION" => "1.95.0",
      "MIX_ENV" => "test",
      "PGHOST" => "/var/run/postgresql"
    }
  }

  @ci_cache_key "${{ runner.os }}-otp-${{ env.OTP_VERSION }}-elixir-${{ env.ELIXIR_VERSION }}-rust-${{ env.RUST_VERSION }}-mix-${{ env.MIX_ENV }}-job-${{ github.job }}-${{ hashFiles('**/mix.lock') }}"
  @ci_cache_prefix "${{ runner.os }}-otp-${{ env.OTP_VERSION }}-elixir-${{ env.ELIXIR_VERSION }}-rust-${{ env.RUST_VERSION }}-mix-${{ env.MIX_ENV }}-job-${{ github.job }}-"
  @test_cache_key "${{ runner.os }}-otp-${{ env.OTP_VERSION }}-elixir-${{ env.ELIXIR_VERSION }}-rust-${{ env.RUST_VERSION }}-mix-${{ env.MIX_ENV }}-job-${{ github.job }}-app-${{ matrix.app }}-${{ hashFiles('**/mix.lock') }}"
  @test_cache_prefix "${{ runner.os }}-otp-${{ env.OTP_VERSION }}-elixir-${{ env.ELIXIR_VERSION }}-rust-${{ env.RUST_VERSION }}-mix-${{ env.MIX_ENV }}-job-${{ github.job }}-app-${{ matrix.app }}-"
  @plt_cache_key "${{ runner.os }}-otp-${{ env.OTP_VERSION }}-elixir-${{ env.ELIXIR_VERSION }}-rust-${{ env.RUST_VERSION }}-mix-${{ env.MIX_ENV }}-job-${{ github.job }}-dialyzer-${{ hashFiles('**/mix.lock', 'apps/*/mix.exs', 'mix.exs') }}"
  @plt_cache_prefix "${{ runner.os }}-otp-${{ env.OTP_VERSION }}-elixir-${{ env.ELIXIR_VERSION }}-rust-${{ env.RUST_VERSION }}-mix-${{ env.MIX_ENV }}-job-${{ github.job }}-dialyzer-"

  @native_build_run "sudo apt-get update\nsudo apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev\n"

  @postgres_run ~S"""
  sudo install -d /usr/share/postgresql-common/pgdg
  sudo curl --fail --silent --show-error \
    --output /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
  . /etc/os-release
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list
  sudo apt-get update
  sudo apt-get install -y postgresql-17 postgresql-server-dev-17 build-essential
  git clone --branch v0.8.0 --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector
  make -C /tmp/pgvector with_llvm=no
  sudo make -C /tmp/pgvector with_llvm=no install
  sudo pg_ctlcluster 16 main stop || true
  sudo pg_dropcluster --stop 17 main || true
  sudo pg_createcluster 17 main --start --port 5432
  sudo -u postgres createuser --superuser "$USER" || true
  pg_isready -h "$PGHOST"
  """

  setup_all do
    {:ok,
     ci_workflow: YamlElixir.read_from_file!(".github/workflows/ci.yml"),
     test_workflow: YamlElixir.read_from_file!(".github/workflows/test.yml")}
  end

  test "CI has exact metadata, static jobs, and a dedicated workflow contract", %{
    ci_workflow: workflow
  } do
    assert Map.delete(workflow, "jobs") == @ci_metadata
    assert Map.has_key?(workflow, "on")
    refute Map.has_key?(workflow, true)

    assert workflow["jobs"] |> Map.keys() |> Enum.sort() ==
             ~w(compile credo dialyzer format workflow-contract)

    assert_standard_ci_job(
      workflow,
      "compile",
      "Compile",
      true,
      %{"name" => "Compile with warnings as errors", "run" => "mix compile --warnings-as-errors"}
    )

    assert_standard_ci_job(
      workflow,
      "format",
      "Format Check",
      false,
      %{"name" => "Check code formatting", "run" => "mix format --check-formatted"}
    )

    assert_standard_ci_job(
      workflow,
      "credo",
      "Credo",
      false,
      %{"name" => "Run Credo strict", "run" => "mix credo --strict"}
    )

    assert_dialyzer_job(workflow)
    assert_workflow_contract_job(workflow)
    assert_no_bypasses(workflow)
  end

  test "Test has the exact dynamic matrix, native services, cache, and command", %{
    test_workflow: workflow
  } do
    expected_apps = umbrella_apps()
    assert Map.delete(workflow, "jobs") == @test_metadata
    assert Map.has_key?(workflow, "on")
    refute Map.has_key?(workflow, true)
    assert Map.keys(workflow["jobs"]) == ["test"]

    job = job!(workflow, "test")
    matrix_apps = get_in(job, ["strategy", "matrix", "app"])

    assert matrix_apps != []
    assert matrix_apps == Enum.uniq(matrix_apps)
    assert matrix_apps == expected_apps

    assert Map.delete(job, "steps") == %{
             "name" => "Test (${{ matrix.app }})",
             "runs-on" => "ubuntu-24.04",
             "strategy" => %{
               "fail-fast" => false,
               "matrix" => %{"app" => expected_apps}
             }
           }

    assert_step_names(job, [
      "Checkout code",
      "Set up Elixir",
      "Set up Rust",
      "Install native build dependencies",
      "Restore dependencies cache",
      "Install dependencies",
      "Start PostgreSQL 17 with pgvector",
      "Prepare test database",
      "Run tests"
    ])

    assert_common_steps(job, true, @test_cache_key, @test_cache_prefix)

    assert_step(job, %{
      "name" => "Start PostgreSQL 17 with pgvector",
      "run" => @postgres_run
    })

    assert_step(job, %{"name" => "Prepare test database", "run" => "mix ecto.setup"})

    assert_step(job, %{
      "name" => "Run tests",
      "run" => "mix do --app ${{ matrix.app }} cmd mix test"
    })

    assert_no_bypasses(workflow)
  end

  test "CI setup-beam pins are step-local under a count-preserving mutation", %{
    ci_workflow: workflow
  } do
    job = job!(workflow, "compile")
    mutated_job = move_action_pin(job, @setup_beam_action, "elixir-version")

    assert count_value(job, @elixir_pin) == 1
    assert count_value(mutated_job, @elixir_pin) == 1

    assert_raise ExUnit.AssertionError, fn -> assert_setup_beam_step(mutated_job) end
  end

  test "Test Rust pin is step-local under a count-preserving mutation", %{
    test_workflow: workflow
  } do
    job = job!(workflow, "test")
    mutated_job = move_action_pin(job, @rust_action, "toolchain")

    assert count_value(job, @rust_pin) == 1
    assert count_value(mutated_job, @rust_pin) == 1

    assert_raise ExUnit.AssertionError, fn -> assert_rust_step(mutated_job) end
  end

  defp assert_standard_ci_job(workflow, id, name, native?, command_step) do
    job = job!(workflow, id)
    assert Map.delete(job, "steps") == %{"name" => name, "runs-on" => "ubuntu-24.04"}

    native_names =
      if native?,
        do: ["Set up Rust", "Install native build dependencies"],
        else: []

    assert_step_names(
      job,
      ["Checkout code", "Set up Elixir"] ++
        native_names ++
        ["Restore dependencies cache", "Install dependencies", command_step["name"]]
    )

    assert_common_steps(job, native?, @ci_cache_key, @ci_cache_prefix)
    assert_step(job, command_step)
  end

  defp assert_dialyzer_job(workflow) do
    job = job!(workflow, "dialyzer")
    assert Map.delete(job, "steps") == %{"name" => "Dialyzer", "runs-on" => "ubuntu-24.04"}

    assert_step_names(job, [
      "Checkout code",
      "Set up Elixir",
      "Set up Rust",
      "Install native build dependencies",
      "Restore dependencies cache",
      "Install dependencies",
      "Restore Dialyzer PLT cache",
      "Create PLT directory",
      "Build PLT if needed",
      "Run Dialyzer"
    ])

    assert_common_steps(job, true, @ci_cache_key, @ci_cache_prefix)

    assert_step(job, %{
      "name" => "Restore Dialyzer PLT cache",
      "uses" => "actions/cache@v4",
      "id" => "dialyzer-cache",
      "with" => %{
        "path" => "priv/plts",
        "key" => @plt_cache_key,
        "restore-keys" => @plt_cache_prefix
      }
    })

    assert_step(job, %{"name" => "Create PLT directory", "run" => "mkdir -p priv/plts"})

    assert_step(job, %{
      "name" => "Build PLT if needed",
      "if" => "steps.dialyzer-cache.outputs.cache-hit != 'true'",
      "run" => "mix dialyzer --plt"
    })

    assert_step(job, %{"name" => "Run Dialyzer", "run" => "mix dialyzer --format raw"})
  end

  defp assert_workflow_contract_job(workflow) do
    job = job!(workflow, "workflow-contract")

    assert Map.delete(job, "steps") == %{
             "name" => "Workflow Contract",
             "runs-on" => "ubuntu-24.04"
           }

    assert_step_names(job, [
      "Checkout code",
      "Set up Elixir",
      "Set up Rust",
      "Install native build dependencies",
      "Restore dependencies cache",
      "Install dependencies",
      "Verify CI workflow contract"
    ])

    assert_common_steps(job, true, @ci_cache_key, @ci_cache_prefix)

    assert_step(job, %{
      "name" => "Verify CI workflow contract",
      "run" => "mix run --no-start test/ci_workflow_test.exs"
    })
  end

  defp assert_common_steps(job, native?, cache_key, cache_prefix) do
    assert_step(job, %{"name" => "Checkout code", "uses" => "actions/checkout@v4"})
    assert_setup_beam_step(job)

    if native? do
      assert_rust_step(job)

      assert_step(job, %{
        "name" => "Install native build dependencies",
        "run" => @native_build_run
      })
    end

    assert_step(job, %{
      "name" => "Restore dependencies cache",
      "uses" => "actions/cache@v4",
      "with" => %{
        "path" => "deps\n_build\n",
        "key" => cache_key,
        "restore-keys" => cache_prefix
      }
    })

    assert_step(job, %{"name" => "Install dependencies", "run" => "mix deps.get"})
  end

  defp assert_setup_beam_step(job) do
    assert_step(job, %{
      "name" => "Set up Elixir",
      "uses" => @setup_beam_action,
      "with" => %{"elixir-version" => @elixir_pin, "otp-version" => @otp_pin}
    })
  end

  defp assert_rust_step(job) do
    assert_step(job, %{
      "name" => "Set up Rust",
      "uses" => @rust_action,
      "with" => %{"toolchain" => @rust_pin}
    })
  end

  defp umbrella_apps do
    mix_files = Path.wildcard("apps/*/mix.exs") |> Enum.sort()
    assert mix_files != []

    apps =
      Enum.map(mix_files, fn path ->
        matches =
          Regex.scan(~r/\bapp:\s*:([a-z][a-z0-9_]*)\b/, File.read!(path), capture: :all_but_first)

        case matches do
          [[app]] -> app
          _ -> flunk("#{path} must declare exactly one app, found #{inspect(matches)}")
        end
      end)

    assert length(apps) == length(mix_files)
    assert length(Enum.uniq(apps)) == length(mix_files)
    Enum.sort(apps)
  end

  defp job!(workflow, id) do
    assert %{"jobs" => jobs} = workflow
    assert %{^id => job} = jobs
    job
  end

  defp assert_step_names(job, expected) do
    actual = Enum.map(job["steps"], & &1["name"])

    assert length(actual) == length(expected)
    assert Enum.sort(actual) == Enum.sort(expected)
  end

  defp assert_step(job, expected) do
    matches = Enum.filter(job["steps"], &(&1["name"] == expected["name"]))
    assert [step] = matches
    assert step == expected
  end

  defp assert_no_bypasses(workflow) do
    for {_id, job} <- workflow["jobs"] do
      assert_not_bypassed(job)
      Enum.each(job["steps"], &assert_not_bypassed/1)
    end
  end

  defp assert_not_bypassed(item) do
    refute item["if"] in [false, "false", "${{ false }}", "${{false}}"]
    refute item["continue-on-error"] in [true, "true", "${{ true }}", "${{true}}"]
  end

  defp move_action_pin(job, action, pin_key) do
    source_step = action_step!(job, action)
    pin_value = get_in(source_step, ["with", pin_key])
    assert is_binary(pin_value)

    steps =
      Enum.map(job["steps"], fn step ->
        cond do
          step["uses"] == action ->
            Map.put(step, "with", Map.delete(step["with"], pin_key))

          step["name"] == "Checkout code" ->
            Map.put(step, pin_key, pin_value)

          true ->
            step
        end
      end)

    Map.put(job, "steps", steps)
  end

  defp action_step!(job, action) do
    matches = Enum.filter(job["steps"], &(&1["uses"] == action))
    assert [step] = matches
    step
  end

  defp count_value(term, target) when is_map(term) do
    term |> Map.values() |> Enum.map(&count_value(&1, target)) |> Enum.sum()
  end

  defp count_value(term, target) when is_list(term) do
    term |> Enum.map(&count_value(&1, target)) |> Enum.sum()
  end

  defp count_value(value, value), do: 1
  defp count_value(_term, _target), do: 0
end
