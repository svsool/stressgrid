defmodule Stressgrid.Coordinator.HistogramStatsTest do
  use ExUnit.Case, async: true

  alias Stressgrid.Coordinator.HistogramStats

  describe "compute/1" do
    test "returns nil for empty histogram" do
      {:ok, hist} = :hdr_histogram.open(3600 * 1000 * 1000, 3)
      assert HistogramStats.compute(hist) == nil
      :hdr_histogram.close(hist)
    end

    test "computes all statistics for histogram with data" do
      {:ok, hist} = :hdr_histogram.open(3600 * 1000 * 1000, 3)
      :hdr_histogram.record(hist, 100)
      :hdr_histogram.record(hist, 200)
      :hdr_histogram.record(hist, 300)

      stats = HistogramStats.compute(hist)

      assert stats.count == 3
      assert stats.mean == 200.0
      assert stats.min == 100
      assert stats.max == 300
      assert stats.median == 200.0
      assert stats.sum == 600

      # Verify percentiles are present
      assert is_float(stats.p1)
      assert is_float(stats.p10)
      assert is_float(stats.p25)
      assert is_float(stats.p50)
      assert is_float(stats.p75)
      assert is_float(stats.p90)
      assert is_float(stats.p95)
      assert is_float(stats.p99)
      assert is_float(stats.stddev)

      :hdr_histogram.close(hist)
    end

    test "computes correct percentiles" do
      {:ok, hist} = :hdr_histogram.open(3600 * 1000 * 1000, 3)

      # Record values from 1 to 100
      Enum.each(1..100, fn value ->
        :hdr_histogram.record(hist, value)
      end)

      stats = HistogramStats.compute(hist)

      assert stats.count == 100
      # Percentiles should be in ascending order
      assert stats.p1 <= stats.p10
      assert stats.p10 <= stats.p25
      assert stats.p25 <= stats.p50
      assert stats.p50 <= stats.p75
      assert stats.p75 <= stats.p90
      assert stats.p90 <= stats.p95
      assert stats.p95 <= stats.p99

      :hdr_histogram.close(hist)
    end
  end

  describe "compute_all/1" do
    test "processes empty map" do
      assert HistogramStats.compute_all(%{}) == %{}
    end

    test "computes statistics for all histograms in map" do
      {:ok, hist1} = :hdr_histogram.open(3600 * 1000 * 1000, 3)
      {:ok, hist2} = :hdr_histogram.open(3600 * 1000 * 1000, 3)
      {:ok, hist3} = :hdr_histogram.open(3600 * 1000 * 1000, 3)

      :hdr_histogram.record(hist1, 100)
      :hdr_histogram.record(hist2, 200)
      # hist3 remains empty

      hists = %{
        metric1: hist1,
        metric2: hist2,
        metric3: hist3
      }

      stats = HistogramStats.compute_all(hists)

      assert Map.keys(stats) == [:metric1, :metric2, :metric3]
      assert stats.metric1.mean == 100.0
      assert stats.metric2.mean == 200.0
      assert stats.metric3 == nil

      :hdr_histogram.close(hist1)
      :hdr_histogram.close(hist2)
      :hdr_histogram.close(hist3)
    end

    test "preserves original map keys" do
      {:ok, hist1} = :hdr_histogram.open(3600 * 1000 * 1000, 3)
      {:ok, hist2} = :hdr_histogram.open(3600 * 1000 * 1000, 3)

      :hdr_histogram.record(hist1, 100)
      :hdr_histogram.record(hist2, 200)

      hists = %{
        "string_key" => hist1,
        {:tuple, :key} => hist2
      }

      stats = HistogramStats.compute_all(hists)

      assert Map.has_key?(stats, "string_key")
      assert Map.has_key?(stats, {:tuple, :key})
      assert stats["string_key"].mean == 100.0
      assert stats[{:tuple, :key}].mean == 200.0

      :hdr_histogram.close(hist1)
      :hdr_histogram.close(hist2)
    end
  end
end
