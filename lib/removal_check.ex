defmodule Bonfire.WordPress.RemovalCheck do
  @moduledoc """
  Run hourly by `Oban.Plugins.Cron`: queues a check for posts gone from the configured WordPress site when one is due, every `[:bonfire_wordpress, :removal_check_every]` (a duration, a day by default), see `Bonfire.WordPress.Sync.check_removals/0`. Running more often than any interval it can be set to is what lets that interval be configured, at an hour's precision; a run that isn't due only reads two settings.
  """
  use Oban.Worker, queue: :scheduled, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    Bonfire.WordPress.Sync.check_removals()
    :ok
  end
end
