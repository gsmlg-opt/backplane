defmodule Backplane.AgentRuntime.CodexReadinessFailureTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex.Control, Codex.Readiness, Error, Execution}

  defp failed(overrides \\ %{}) do
    Map.merge(
      %{
        environment_id: "actual-failed-command-startup",
        status: "failed",
        ready: false,
        authorized: true,
        error: %{class: :validation, message: "cleanup_timeout must be a finite positive timeout"}
      },
      overrides
    )
  end

  defp call(state, id \\ "actual-failed-command-startup", extra \\ %{}) do
    Control.call(%{
      tool_name: "wait_for_environment",
      arguments: %{"environment_id" => id},
      backend_context: %{
        context:
          Map.merge(
            %{environment_provider: fn _ -> state end, environment_wait_timeout: 0},
            extra
          )
      }
    })
  end

  test "initial real startup validation failure retains its reason rather than timing out" do
    assert {:error, %Error{} = actual} = Execution.validate_limits(cleanup_timeout: 0)
    state = failed(%{error: actual})

    assert {:error, %Error{class: :execution_failure} = error} =
             Readiness.await(fn -> state end, 0)

    assert error.message ==
             "Environment `actual-failed-command-startup` failed to start: #{actual.message}"

    assert error.details == %{
             "environment_id" => state.environment_id,
             "status" => "failed",
             "startup_class" => "validation",
             "reason_truncated" => false
           }

    assert error.cause == nil
  end

  test "starting then failed stops at the terminal observation" do
    key = make_ref()

    provider = fn ->
      case Process.get(key, 0) do
        0 ->
          Process.put(key, 1)
          %{status: :starting, ready: false, authorized: true}

        1 ->
          Process.put(key, 2)
          failed(%{status: :failed})

        _ ->
          flunk("terminal environment was polled again")
      end
    end

    assert {:error, %Error{class: :execution_failure}} = Readiness.await(provider, 1_000)
    assert Process.get(key) == 2
  end

  test "terminal states precede contradictory ready booleans and distinguish unavailable and closed" do
    for status <- [:failed, "failed", :unavailable, "unavailable", :closed, "closed"] do
      state = failed(%{status: status, ready: true})
      expected = if status in [:failed, "failed"], do: :execution_failure, else: :not_found

      assert {:error, %Error{class: ^expected, details: details}} =
               Readiness.await(fn -> state end, 0)

      assert details["status"] == to_string(status)
    end
  end

  test "legacy successful state is unchanged and unknown statuses retain the old gate" do
    for status <- [nil, :starting, "ready", :future_status, "future-status"] do
      state = %{ready: true, authorized: true, status: status}
      assert {:ok, ^state} = Readiness.await(fn -> state end, 0)

      assert {:ok, ^state} =
               Readiness.await(fn -> state end, 0, fn -> false end,
                 expected_environment_id: "legacy"
               )
    end

    assert {:error, %Error{class: :timeout}} =
             Readiness.await(fn -> %{ready: true, authorized: false} end, 0)

    assert {:error, %Error{class: :timeout}} = Readiness.await(fn -> %{} end, 0)
  end

  test "cancellation precedes the provider and zero timeout still observes terminal state" do
    assert {:error, %Error{class: :cancelled}} =
             Readiness.await(fn -> flunk("called provider") end, 0, fn -> true end)

    assert {:error, %Error{class: :execution_failure}} = Readiness.await(fn -> failed() end, 0)
  end

  test "expected identity is exact, logically binds a missing ID and never rewrites success" do
    state = %{ready: true, authorized: true}

    assert {:ok, ^state} =
             Readiness.await(fn -> state end, 0, fn -> false end,
               expected_environment_id: " exact "
             )

    assert {:error, %Error{class: :execution_failure, details: %{"environment_id" => "expected"}}} =
             Readiness.await(fn -> Map.delete(failed(), :environment_id) end, 0, fn -> false end,
               expected_environment_id: "expected"
             )

    assert {:ok, %{is_error: true, error: %{"class" => "malformed_result", "details" => details}}} =
             call(failed(), "different-generation")

    assert details == %{
             "environment_id" => "different-generation",
             "reason" => "environment_identity_mismatch"
           }
  end

  test "explicit invalid callback identities and missing public terminal IDs are malformed" do
    for id <- [nil, "", <<255>>, String.duplicate("x", 1_025), 1, self()] do
      assert {:error, %Error{class: :malformed_result, cause: nil}} =
               Readiness.await(fn -> failed(%{environment_id: id}) end, 0)
    end

    assert {:error, %Error{class: :malformed_result}} =
             Readiness.await(fn -> Map.delete(failed(), :environment_id) end, 0)
  end

  test "malformed options reject before either callback" do
    provider = fn -> flunk("called provider") end
    cancelled = fn -> flunk("called cancellation") end

    for options <- [
          nil,
          %{},
          [:bad],
          [unknown: "x"],
          [expected_environment_id: nil],
          [expected_environment_id: ""],
          [expected_environment_id: "x", expected_environment_id: "x"]
        ] do
      assert {:error, %Error{class: :validation}} =
               Readiness.await(provider, 0, cancelled, options)
    end
  end

  test "malformed callback shapes settle as safe errors" do
    for state <- [nil, [], self(), %{status: 7}, %{ready: "true"}, %{authorized: 1}] do
      assert {:ok,
              %{is_error: true, error: %{"class" => "malformed_result", "details" => details}}} =
               call(state)

      assert details["environment_id"] == "actual-failed-command-startup"
      refute inspect(details) =~ "#PID"
    end
  end

  test "reason truncation is a 256 byte UTF-8 prefix and never copies private fields" do
    reason = String.duplicate("界", 100)

    state =
      failed(%{
        error: %{
          class: "validation",
          message: reason,
          cause: self(),
          details: %{secret: String.duplicate("s", 100_000)}
        }
      })

    assert {:error, error} = Readiness.await(fn -> state end, 0)
    bounded = String.duplicate("界", 85)
    assert String.ends_with?(error.message, bounded)
    assert String.valid?(error.message)
    assert error.details["reason_truncated"]
    assert map_size(error.details) == 4
    assert error.cause == nil
    assert {:ok, %{is_error: true, error: value}} = call(state)
    assert value["class"] == "execution_failure"
    assert is_binary(Jason.encode!(value))
    refute Map.has_key?(value, "cause")
  end

  test "fallback reason and unknown class are bounded and not reported as truncation" do
    for {reason, fallback} <- [
          {nil, "startup reason unavailable"},
          {" \n", "startup reason unavailable"},
          {self(), "startup reason unavailable"},
          {<<255>>, "[invalid UTF-8 startup reason]"}
        ] do
      state = failed(%{error: %{class: self(), message: reason}})
      assert {:error, error} = Readiness.await(fn -> state end, 0)
      assert String.ends_with?(error.message, fallback)
      assert error.details["startup_class"] == "unknown"
      refute error.details["reason_truncated"]
    end

    for error <- [nil, self(), %{}] do
      assert {:error, result} = Readiness.await(fn -> failed(%{error: error}) end, 0)
      assert String.ends_with?(result.message, "startup reason unavailable")
    end
  end

  test "error aliases agree after class normalization and conflict rather than silently choosing" do
    assert {:error,
            %Error{class: :execution_failure, details: %{"startup_class" => "validation"}}} =
             Readiness.await(
               fn ->
                 failed(%{
                   error: %{
                     :class => :validation,
                     "class" => "validation",
                     :message => "reason",
                     "message" => "reason"
                   }
                 })
               end,
               0
             )

    for error <- [
          %{:class => :validation, "class" => "timeout"},
          %{:message => "a", "message" => "b"},
          %{:message => self(), "message" => "valid"}
        ] do
      assert {:error, %Error{class: :malformed_result}} =
               Readiness.await(fn -> failed(%{error: error}) end, 0)
    end
  end

  test "Control preserves validation, missing callback, timeout and cancellation tuples" do
    for id <- [nil, "", <<255>>, String.duplicate("x", 1_025), 1] do
      assert {:error, %Error{class: :validation}} = call(failed(), id)
    end

    assert {:error, %Error{class: :timeout}} = call(%{ready: false, authorized: true})

    assert {:error, %Error{class: :cancelled}} =
             call(failed(), "actual-failed-command-startup", %{cancelled: fn -> true end})

    assert {:error, %Error{class: :unsupported_capability}} =
             Control.call(%{
               tool_name: "wait_for_environment",
               arguments: %{"environment_id" => "x"},
               backend_context: %{context: %{}}
             })
  end

  test "message aliases require identical term types before fallback" do
    state = failed(%{error: %{:message => 1, "message" => 1.0}})

    assert {:error,
            %Error{
              class: :malformed_result,
              details: %{"reason" => "conflicting_startup_error_aliases"}
            }} = Readiness.await(fn -> state end, 0)
  end
end
