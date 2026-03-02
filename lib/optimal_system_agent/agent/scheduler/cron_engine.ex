defmodule OptimalSystemAgent.Agent.Scheduler.CronEngine do
  @moduledoc """
  Pure cron expression parser and matcher.

  Supports standard 5-field cron expressions:
    {minute} {hour} {day_of_month} {month} {day_of_week}

  Field syntax:
    - `*`       any value
    - `*/n`     every n-th value
    - `n`       exact value
    - `n,m,...` comma-separated list
    - `n-m`     range (inclusive)

  Ranges: minute 0-59, hour 0-23, dom 1-31, month 1-12, dow 0-6 (0=Sunday)
  """

  @doc """
  Parse a 5-field cron expression into a map of field -> MapSet of allowed values.

  Returns `{:ok, %{minute: MapSet, hour: MapSet, dom: MapSet, month: MapSet, dow: MapSet}}`
  or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(expr) when is_binary(expr) do
    parts = String.split(expr, ~r/\s+/, trim: true)

    case parts do
      [min, hour, dom, month, dow] ->
        with {:ok, min_set} <- parse_field(min, 0, 59),
             {:ok, hour_set} <- parse_field(hour, 0, 23),
             {:ok, dom_set} <- parse_field(dom, 1, 31),
             {:ok, month_set} <- parse_field(month, 1, 12),
             {:ok, dow_set} <- parse_field(dow, 0, 6) do
          {:ok, %{minute: min_set, hour: hour_set, dom: dom_set, month: month_set, dow: dow_set}}
        end

      _ ->
        {:error, "expected 5 fields, got #{length(parts)}"}
    end
  end

  def parse(_), do: {:error, "schedule must be a string"}

  @doc """
  Check whether a parsed cron fields map matches the given DateTime.
  """
  @spec matches?(map(), DateTime.t()) :: boolean()
  def matches?(%{minute: min_s, hour: hr_s, dom: dom_s, month: mo_s, dow: dow_s}, dt) do
    # Date.day_of_week/1 returns 1 (Mon) through 7 (Sun).
    # Cron convention: 0 = Sunday, 1 = Monday ... 6 = Saturday.
    dow =
      case Date.day_of_week(dt) do
        7 -> 0
        n -> n
      end

    MapSet.member?(min_s, dt.minute) and
      MapSet.member?(hr_s, dt.hour) and
      MapSet.member?(dom_s, dt.day) and
      MapSet.member?(mo_s, dt.month) and
      MapSet.member?(dow_s, dow)
  end

  # ── Field parsing (private) ──────────────────────────────────────────

  defp parse_field("*", min, max), do: {:ok, MapSet.new(min..max)}

  defp parse_field("*/" <> step_str, min, max) do
    case Integer.parse(step_str) do
      {step, ""} when step > 0 ->
        values = Enum.filter(min..max, &(rem(&1 - min, step) == 0))
        {:ok, MapSet.new(values)}

      _ ->
        {:error, "invalid step value: #{step_str}"}
    end
  end

  defp parse_field(field, min, max) do
    parts = String.split(field, ",")

    Enum.reduce_while(parts, {:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case parse_single(part, min, max) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_single(part, min, max) do
    cond do
      String.contains?(part, "-") ->
        case String.split(part, "-", parts: 2) do
          [lo_str, hi_str] ->
            with {lo, ""} <- Integer.parse(lo_str),
                 {hi, ""} <- Integer.parse(hi_str),
                 true <- lo >= min and hi <= max and lo <= hi do
              {:ok, MapSet.new(lo..hi)}
            else
              _ -> {:error, "invalid range: #{part}"}
            end

          _ ->
            {:error, "invalid range: #{part}"}
        end

      true ->
        case Integer.parse(part) do
          {n, ""} when n >= min and n <= max ->
            {:ok, MapSet.new([n])}

          {n, ""} ->
            {:error, "value #{n} out of range #{min}-#{max}"}

          _ ->
            {:error, "invalid cron value: #{part}"}
        end
    end
  end
end
