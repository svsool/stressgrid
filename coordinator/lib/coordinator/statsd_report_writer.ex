defmodule Stressgrid.Coordinator.StatsdReportWriter do
  @moduledoc false

  alias Stressgrid.Coordinator.{ReportWriter, StatsdReportWriter}

  @behaviour ReportWriter

  require Logger

  defstruct []

  def init(_opts) do
    %StatsdReportWriter{}
  end

  def start(writer) do
    writer
  end

  def write(id, _clock, %StatsdReportWriter{} = writer, hist_stats, scalars) do
    tags = [run: id]

    hist_stats
    |> Enum.each(fn {key, stats} ->
      if not is_nil(stats) do
        metric_name = key |> normalize_metric_name()

        Statsd.gauge("#{metric_name}.mean", stats.mean, tags)
        Statsd.gauge("#{metric_name}.min", stats.min, tags)
        Statsd.gauge("#{metric_name}.p50", stats.p50, tags)
        Statsd.gauge("#{metric_name}.p75", stats.p75, tags)
        Statsd.gauge("#{metric_name}.p95", stats.p95, tags)
        Statsd.gauge("#{metric_name}.p99", stats.p99, tags)
        Statsd.gauge("#{metric_name}.max", stats.max, tags)

        Statsd.counter("#{metric_name}.sample_count", stats.count, tags)
      end
    end)

    scalars
    |> Enum.each(fn {key, value} ->
      metric_name = key |> normalize_metric_name()
      Statsd.gauge(metric_name, value, tags)
    end)

    writer
  rescue
    error ->
      Logger.error("StatsD write error: #{inspect(error)}")

      writer
  end

  def finish(result_info, _id, %StatsdReportWriter{}) do
    result_info
  end

  defp normalize_metric_name(metric_name) do
    metric_name
    |> Atom.to_string()
    |> String.replace("_", ".")
  end
end
