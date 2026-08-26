defmodule DeadCode.Analyze do
  @moduledoc false

  alias DeadCode.{
    CollectExports,
    EntryPoints,
    Ignore,
    MFA,
    Score,
    SourceIndex,
    TestReferences,
    XrefUsed
  }

  def run(opts \\ []) do
    source_index = SourceIndex.build()
    ignore = Ignore.load(source_index, Keyword.get(opts, :ignore_path, ".dead_code_ignore.exs"))

    exports = CollectExports.all(Keyword.put(opts, :source_index, source_index))
    calls = XrefUsed.calls()

    callers_by_callee =
      calls
      |> XrefUsed.callers_by_callee()
      |> TestReferences.merge_callers(TestReferences.callers_by_callee(exports))

    entry_points = EntryPoints.all(source_index, exports) |> MapSet.new()

    results =
      exports
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
    with {:ok, mfa} <- MFA.parse(mfa_string) do
      source_index = SourceIndex.build()
      calls = XrefUsed.calls()
      exports = CollectExports.all(Keyword.put(opts, :source_index, source_index))

      callers =
        calls
        |> Enum.filter(fn call -> call.callee == mfa end)
        |> summarize_callers()

      test_callers =
        TestReferences.callers_by_callee(exports)
        |> Map.get(mfa, [])
        |> summarize_callers()

      entry_points = EntryPoints.all(source_index, exports) |> MapSet.new()

      %{
        mfa: mfa,
        formatted: MFA.format(mfa),
        entry_point: MapSet.member?(entry_points, mfa),
        framework_entry: EntryPoints.framework_entry?(mfa),
        callers: callers ++ test_callers
      }
    end
  end

  defp categorize(mfa, callers, entry_points) do
    lib_callers = Enum.filter(callers, fn call -> SourceIndex.lib_file?(call.file) end)
    test_callers = Enum.filter(callers, fn call -> SourceIndex.test_file?(call.file) end)

    cond do
      lib_callers != [] -> :used
      test_callers != [] -> :test_only
      MapSet.member?(entry_points, mfa) -> :review
      EntryPoints.framework_entry?(mfa) -> :review
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
