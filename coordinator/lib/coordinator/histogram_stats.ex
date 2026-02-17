defmodule Stressgrid.Coordinator.HistogramStats do
  @moduledoc """
  Pre-computed histogram statistics to eliminate redundant percentile calculations.

  This module provides a single computation point for all histogram statistics needed
  by report writers, reducing CPU load by computing each statistic once instead of
  multiple times across different writers.
  """

  @type t :: %__MODULE__{
          mean: float() | nil,
          min: non_neg_integer() | nil,
          max: non_neg_integer() | nil,
          median: float() | nil,
          stddev: float() | nil,
          p1: float() | nil,
          p10: float() | nil,
          p25: float() | nil,
          p50: float() | nil,
          p75: float() | nil,
          p90: float() | nil,
          p95: float() | nil,
          p99: float() | nil,
          count: non_neg_integer(),
          sum: non_neg_integer() | nil
        }

  defstruct [
    :mean,
    :min,
    :max,
    :median,
    :stddev,
    :p1,
    :p10,
    :p25,
    :p50,
    :p75,
    :p90,
    :p95,
    :p99,
    :count,
    :sum
  ]

  @doc """
  Computes all statistics for a single histogram.

  Returns nil if the histogram is empty (count == 0), otherwise returns
  a HistogramStats struct with all percentiles and aggregate values.

  ## Examples

      iex> hist = :hdr_histogram.open(3600 * 1000 * 1000, 3)
      iex> :hdr_histogram.record(hist, 100)
      iex> stats = HistogramStats.compute(hist)
      iex> stats.mean
      100.0
  """
  @spec compute(:hdr_histogram.histogram()) :: t() | nil
  def compute(hist) do
    count = :hdr_histogram.get_total_count(hist)

    if count == 0 do
      nil
    else
      %__MODULE__{
        count: count,
        mean: :hdr_histogram.mean(hist),
        min: :hdr_histogram.min(hist),
        max: :hdr_histogram.max(hist),
        median: :hdr_histogram.median(hist),
        stddev: :hdr_histogram.stddev(hist),
        sum: round(:hdr_histogram.mean(hist) * count),
        p1: :hdr_histogram.percentile(hist, 1.0),
        p10: :hdr_histogram.percentile(hist, 10.0),
        p25: :hdr_histogram.percentile(hist, 25.0),
        p50: :hdr_histogram.percentile(hist, 50.0),
        p75: :hdr_histogram.percentile(hist, 75.0),
        p90: :hdr_histogram.percentile(hist, 90.0),
        p95: :hdr_histogram.percentile(hist, 95.0),
        p99: :hdr_histogram.percentile(hist, 99.0)
      }
    end
  end

  @doc """
  Computes statistics for all histograms in a map.

  Takes a map where keys are histogram identifiers and values are histograms,
  returns a map with the same keys but values are HistogramStats structs (or nil).

  ## Examples

      iex> hists = %{"metric1" => hist1, "metric2" => hist2}
      iex> stats = HistogramStats.compute_all(hists)
      iex> stats["metric1"].mean
      150.0
  """
  @spec compute_all(map()) :: %{any() => t() | nil}
  def compute_all(hists) when is_map(hists) do
    hists
    |> Enum.map(fn {key, hist} -> {key, compute(hist)} end)
    |> Map.new()
  end
end
