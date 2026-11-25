defmodule DeadCode.Analyze do
  @moduledoc false

  alias DeadCode.{
    CollectExports,
    Config,
    EntryPoints,
    Ignore,
    MFA,
    Score,
    SourceIndex,
    TestReferences,
    XrefUsed
  }

  def run(opts \\ []) do
    config = Config.load(opts)
    collected = CollectExports.collect(config, opts)

    source_index =
      SourceIndex.build(config, Keyword.put(opts, :module_to_file, collected.module_to_file))

    ignore =
      Ignore.load(source_index, config, Keyword.get(opts, :ignore_path, ".dead_code_ignore.exs"))

    beam_calls = XrefUsed.calls(collected, source_index)
    test_callers = TestReferences.callers_by_callee(config, collected, opts)

    callers_by_callee =
      beam_calls
      |> XrefUsed.callers_by_callee()
      |> TestReferences.merge_callers(test_callers)

    entry_points =
      EntryPoints.all(source_index, collected, beam_calls, config)
      |> MapSet.new()

    results =
      collected.exports
      |> Enum.reject(fn %{mfa: mfa} -> Ignore.ignored?(mfa, ignore) end)
      |> Enum.map(fn export ->
        callers = Map.get(callers_by_callee, export.mfa, [])
        category = categorize(export.mfa, callers, entry_points)

        export
        |> Map.put(:category, category)
        |> Map.put(:callers, summarize_callers(callers))
      end)

    filtered = filter_results(results, opts)

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      totals: count_by_category(filtered),
      all_totals: count_by_category(results),
      score: Score.compute(results),
      excluded: excluded_totals(results, opts),
      results: filtered
    }
  end

  def verify(mfa_string, opts \\ []) do
    with {:ok, raw_mfa} <- MFA.parse(mfa_string) do
      config = Config.load(opts)
      collected = CollectExports.collect(config, opts)

      source_index =
        SourceIndex.build(config, Keyword.put(opts, :module_to_file, collected.module_to_file))

      ignore =
        Ignore.load(
          source_index,
          config,
          Keyword.get(opts, :ignore_path, ".dead_code_ignore.exs")
        )

      canonical_mfa = Map.get(collected.default_aliases, raw_mfa, raw_mfa)
      beam_calls = XrefUsed.calls(collected, source_index)
      test_callers_map = TestReferences.callers_by_callee(config, collected, opts)

      entry_points =
        EntryPoints.all(source_index, collected, beam_calls, config)
        |> MapSet.new()

      matching_beam = Enum.filter(beam_calls, fn call -> call.callee == canonical_mfa end)
      matching_test = Map.get(test_callers_map, canonical_mfa, [])
      all_callers = matching_beam ++ matching_test

      %{
        mfa: canonical_mfa,
        formatted: MFA.format(canonical_mfa),
        entry_point: MapSet.member?(entry_points, canonical_mfa),
        ignored: Ignore.ignored?(canonical_mfa, ignore),
        category: categorize(canonical_mfa, all_callers, entry_points),
        callers: summarize_callers(all_callers)
      }
    end
  end

  defp categorize(mfa, callers, entry_points) do
    beam_callers = Enum.filter(callers, fn call -> call.source == :beam end)
    test_callers = Enum.filter(callers, fn call -> call.source == :test end)

    cond do
      beam_callers != [] -> :used
      MapSet.member?(entry_points, mfa) -> :review
      test_callers != [] -> :test_only
      true -> :likely_dead
    end
  end

  defp summarize_callers(callers) do
    callers
    |> Enum.group_by(fn call -> SourceIndex.normalize_path(call.file) end)
    |> Enum.map(fn {file, file_callers} ->
      %{
        file: file,
        lines: file_callers |> Enum.map(& &1.line) |> Enum.sort() |> Enum.uniq(),
        modules: file_callers |> Enum.map(& &1.caller_module) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(& &1.file)
  end

  defp filter_results(results, opts) do
    results
    |> Enum.reject(fn %{category: category} -> category == :used end)
    |> then(fn list ->
      if Keyword.get(opts, :only_likely_dead, false) do
        Enum.filter(list, fn %{category: category} -> category == :likely_dead end)
      else
        list
      end
    end)
    |> then(fn list ->
      if Keyword.get(opts, :include_test_only, true) do
        list
      else
        Enum.reject(list, fn %{category: category} -> category == :test_only end)
      end
    end)
    |> then(fn list ->
      if Keyword.get(opts, :include_review, false) do
        list
      else
        Enum.reject(list, fn %{category: category} -> category == :review end)
      end
    end)
  end

  defp excluded_totals(results, opts) do
    if Keyword.get(opts, :include_review, false) do
      %{}
    else
      %{review: Enum.count(results, fn %{category: c} -> c == :review end)}
    end
  end

  defp count_by_category(results) do
    Enum.frequencies_by(results, & &1.category)
  end
end
