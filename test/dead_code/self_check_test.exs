defmodule DeadCode.SelfCheckTest do
  use ExUnit.Case, async: true

  alias DeadCode.Analyze

  test "dead_code has no internal false positives on its own library modules" do
    {:ok, all_mods} = :application.get_key(:dead_code, :modules)

    lib_mods =
      Enum.reject(all_mods, fn mod ->
        mod |> Atom.to_string() |> String.starts_with?("Elixir.DeadCode.Fixtures")
      end)

    analysis = Analyze.run(modules: lib_mods, test_files: [], ignore_path: nil)

    likely_dead_mfas =
      analysis.results
      |> Enum.filter(&(&1.category == :likely_dead))
      |> Enum.map(& &1.mfa)
      |> MapSet.new()

    # None of dead_code's internal helpers or default-arg entry points should be falsely flagged
    refute MapSet.member?(likely_dead_mfas, {DeadCode.Config, :max_score, 1})
    refute MapSet.member?(likely_dead_mfas, {DeadCode.Config, :report_dir, 1})
    refute MapSet.member?(likely_dead_mfas, {DeadCode.Ignore, :load, 3})
    refute MapSet.member?(likely_dead_mfas, {DeadCode.Analyze, :run, 1})
    refute MapSet.member?(likely_dead_mfas, {DeadCode.Analyze, :verify, 2})
    refute MapSet.member?(likely_dead_mfas, {DeadCode.Report, :write!, 2})
    refute MapSet.member?(likely_dead_mfas, {DeadCode.Score, :check!, 2})
  end
end
