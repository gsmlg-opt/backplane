defmodule Backplane.SkillProtocol.Cache.NativeLock do
  @moduledoc false

  @spec load_nif() :: :ok
  def load_nif do
    _ = try_load_nif()
    :ok
  end

  @spec acquire(binary()) :: {:ok, reference()} | {:error, :busy | :unavailable | :invalid_path}
  def acquire(path) when is_binary(path) do
    case try_load_nif() do
      :ok -> acquire(path)
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  def acquire(_path), do: {:error, :invalid_path}

  @spec release(reference()) :: :ok
  def release(_handle), do: :ok

  defp try_load_nif do
    path = :filename.join(:code.priv_dir(:backplane_skill_protocol), ~c"cache_native_lock")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
