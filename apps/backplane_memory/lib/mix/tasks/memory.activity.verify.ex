defmodule Mix.Tasks.Memory.Activity.Verify do
  @shortdoc "Verify or repair durable daily memory activity"

  @moduledoc """
  Compares durable daily activity with authoritative canonical events.

      mix memory.activity.verify --client ID --scope SCOPE --namespace NAMESPACE
      mix memory.activity.verify --client ID --scope SCOPE --namespace NAMESPACE \
        --from YYYY-MM-DD --to YYYY-MM-DD [--repair]
  """

  use Mix.Task

  alias Backplane.Memory.Projections.ActivityVerifier

  @usage "Usage: mix memory.activity.verify --client ID --scope SCOPE --namespace NAMESPACE [--from YYYY-MM-DD --to YYYY-MM-DD] [--repair]"

  @impl Mix.Task
  def run(args) do
    {mode, opts} = parse_args(args)
    Mix.Task.run("app.start")

    case mode do
      :verify ->
        opts |> ActivityVerifier.verify() |> print_verification()

      :repair ->
        case ActivityVerifier.repair(opts) do
          {:ok, result} ->
            repaired = result.repaired_subjects
            verification = result.verification
            Mix.shell().info("repaired_subjects=#{repaired}")

            Mix.shell().info(
              "orphan_contributions_removed=#{result.orphan_contributions_removed}"
            )

            Mix.shell().info("orphan_daily_removed=#{result.orphan_daily_removed}")
            print_verification({:ok, verification})

          {:error, reason} ->
            Mix.raise("activity repair failed: #{inspect(reason)}")
        end
    end
  end

  defp parse_args(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          client: :string,
          scope: :string,
          namespace: :string,
          from: :string,
          to: :string,
          repair: :boolean
        ]
      )

    duplicate? =
      Enum.any?(~w(--client --scope --namespace --from --to --repair), fn switch ->
        Enum.count(args, &(&1 == switch or String.starts_with?(&1, switch <> "="))) > 1
      end)

    required? = Enum.all?([:client, :scope, :namespace], &non_empty?(Keyword.get(opts, &1)))

    dates? =
      (Keyword.has_key?(opts, :from) and Keyword.has_key?(opts, :to)) or
        (not Keyword.has_key?(opts, :from) and not Keyword.has_key?(opts, :to))

    if positional == [] and invalid == [] and not duplicate? and required? and dates? do
      mode = if Keyword.get(opts, :repair, false), do: :repair, else: :verify

      verifier_opts =
        [
          client_id: Keyword.fetch!(opts, :client),
          scope: Keyword.fetch!(opts, :scope),
          namespace: Keyword.fetch!(opts, :namespace)
        ]
        |> maybe_dates(opts)

      {mode, verifier_opts}
    else
      Mix.raise(@usage)
    end
  end

  defp maybe_dates(opts, parsed) do
    if Keyword.has_key?(parsed, :from) do
      opts ++ [date_from: Keyword.fetch!(parsed, :from), date_to: Keyword.fetch!(parsed, :to)]
    else
      opts
    end
  end

  defp print_verification({:ok, verification}) do
    Mix.shell().info("status=#{verification.status}")
    Mix.shell().info("drift_count=#{verification.drift_count}")

    Enum.each(verification.drift, fn drift ->
      Mix.shell().info("drift=#{inspect(drift, limit: :infinity, printable_limit: :infinity)}")
    end)

    if verification.status == :drift do
      Mix.raise("activity aggregate drift detected")
    end
  end

  defp print_verification({:error, reason}),
    do: Mix.raise("activity verification failed: #{inspect(reason)}")

  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""
end
