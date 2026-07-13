defmodule BackplaneMemory.Workers.AccessWritebackWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 3

  @impl Oban.Worker
  defdelegate perform(job), to: Backplane.Memory.Workers.AccessWritebackWorker

  defdelegate enqueue(memory_ids), to: Backplane.Memory.Workers.AccessWritebackWorker
end

defmodule BackplaneMemory.Workers.EmbedWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 5

  @impl Oban.Worker
  defdelegate perform(job), to: Backplane.Memory.Workers.EmbedWorker

  defdelegate enqueue(id), to: Backplane.Memory.Workers.EmbedWorker

  defdelegate perform_with_client(job, embed_function),
    to: Backplane.Memory.Workers.EmbedWorker
end

defmodule BackplaneMemory.Workers.EpisodicWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 3

  @impl Oban.Worker
  defdelegate perform(job), to: Backplane.Memory.Workers.EpisodicWorker

  defdelegate enqueue(session_id), to: Backplane.Memory.Workers.EpisodicWorker
end

defmodule BackplaneMemory.Workers.EvictionWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 3

  @impl Oban.Worker
  defdelegate perform(job), to: Backplane.Memory.Workers.EvictionWorker
end

defmodule BackplaneMemory.Workers.FallbackSweepWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 2

  @impl Oban.Worker
  defdelegate perform(job), to: Backplane.Memory.Workers.FallbackSweepWorker
end

defmodule BackplaneMemory.Workers.GraphExtractWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 3

  @impl Oban.Worker
  defdelegate perform(job), to: Backplane.Memory.Workers.GraphExtractWorker

  defdelegate enqueue(session_id), to: Backplane.Memory.Workers.GraphExtractWorker
end

defmodule BackplaneMemory.Workers.LeaseCleanupWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 3

  @impl Oban.Worker
  defdelegate perform(job), to: Backplane.Memory.Workers.LeaseCleanupWorker
end

defmodule BackplaneMemory.Workers.ProceduralWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 2

  @impl Oban.Worker
  defdelegate perform(job), to: Backplane.Memory.Workers.ProceduralWorker
end

defmodule BackplaneMemory.Workers.ProfileBuildWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 3

  @impl Oban.Worker
  defdelegate perform(job), to: Backplane.Memory.Workers.ProfileBuildWorker

  defdelegate enqueue(project), to: Backplane.Memory.Workers.ProfileBuildWorker
end

defmodule BackplaneMemory.Workers.SummaryWorker do
  @moduledoc false
  use Oban.Worker, queue: :memory, max_attempts: 3

  @impl Oban.Worker
  defdelegate perform(job), to: Backplane.Memory.Workers.SummaryWorker

  defdelegate enqueue(session_id), to: Backplane.Memory.Workers.SummaryWorker
end
