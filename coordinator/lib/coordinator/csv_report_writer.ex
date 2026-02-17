defmodule Stressgrid.Coordinator.CsvReportWriter do
  @moduledoc false

  alias Stressgrid.Coordinator.{ReportWriter, CsvReportWriter}

  @behaviour ReportWriter

  @management_base_priv "priv/static/management"
  @management_base_public "management"

  defstruct table: %{}

  def init(_) do
    nil
  end

  def start(nil) do
    %CsvReportWriter{}
  end

  def write(_, clock, %CsvReportWriter{table: table} = writer, hist_stats, scalars) do
    row =
      hist_stats
      |> Enum.reject(fn {_, stats} ->
        is_nil(stats)
      end)
      |> Enum.map(fn {key, stats} ->
        [
          {key, stats.mean},
          {:"#{key}_min", stats.min},
          {:"#{key}_pc1", stats.p1},
          {:"#{key}_pc10", stats.p10},
          {:"#{key}_pc25", stats.p25},
          {:"#{key}_median", stats.median},
          {:"#{key}_pc75", stats.p75},
          {:"#{key}_pc90", stats.p90},
          {:"#{key}_pc99", stats.p99},
          {:"#{key}_max", stats.max},
          {:"#{key}_stddev", stats.stddev}
        ]
      end)
      |> Enum.concat()
      |> Enum.concat(scalars)
      |> Map.new()
      |> Map.merge(table |> Map.get(clock, %{}))

    %{writer | table: table |> Map.put(clock, row)}
  end

  def finish(result_info, id, %CsvReportWriter{
        table: table
      }) do
    tmp_directory = Path.join([System.tmp_dir(), id])
    File.mkdir_p!(tmp_directory)

    write_csv(table, Path.join([tmp_directory, "results.csv"]))

    filename = "#{id}.tar.gz"
    directory = Path.join([Application.app_dir(:coordinator), @management_base_priv])
    File.mkdir_p!(directory)

    result_info =
      case System.cmd("tar", ["czf", Path.join(directory, filename), "-C", System.tmp_dir(), id]) do
        {_, 0} ->
          result_info |> Map.merge(%{"csv_url" => Path.join([@management_base_public, filename])})

        _ ->
          result_info
      end

    File.rm_rf!(Path.join([System.tmp_dir(), id]))

    result_info
  end

  defp write_csv(table, file_name) do
    keys =
      table
      |> Enum.reduce([], fn {_, row}, keys ->
        row
        |> Enum.reduce(keys, fn {key, _}, keys -> [key | keys] end)
        |> Enum.uniq()
      end)
      |> Enum.sort()

    keys_string =
      keys
      |> Enum.map(&"#{&1}")
      |> Enum.join(",")

    io_data =
      ["clock,#{keys_string}\r\n"] ++
        (table
         |> Enum.sort_by(fn {clock, _} -> clock end)
         |> Enum.map(fn {clock, row} ->
           values_string =
             keys
             |> Enum.map(fn key ->
               case row |> Map.get(key) do
                 nil ->
                   ""

                 value ->
                   "#{value}"
               end
             end)
             |> Enum.join(",")

           "#{clock},#{values_string}\r\n"
         end)
         |> Enum.to_list())

    File.write!(file_name, io_data)
  end
end
