defmodule DeadCode.Report do
  @moduledoc false

  alias DeadCode.{Config, MFA}

  @json_name "unused_public_functions.json"
  @md_name "unused_public_functions.md"

  def write!(analysis, opts \\ []) do
    report_dir = Config.report_dir()
    File.mkdir_p!(report_dir)

    formats = Keyword.get(opts, :format, :both)
    encoded = encode_analysis(analysis)

    paths =
      []
      |> then(fn acc -> acc ++ maybe_write_json(encoded, formats, report_dir) end)
      |> then(fn acc -> acc ++ maybe_write_md(analysis, formats, report_dir) end)

    print_summary(analysis)
    paths
  end

  defp encode_analysis(%{generated_at: generated_at, totals: totals, results: results} = analysis) do
    base = %{
      generated_at: generated_at,
      totals: totals,
      results: Enum.map(results, &encode_result/1)
    }

    case Map.get(analysis, :excluded) do
      nil -> base
      excluded -> Map.put(base, :excluded, excluded)
    end
  end

  defp encode_result(%{mfa: mfa, file: file, category: category, callers: callers}) do
    %{
      mfa: MFA.format(mfa),
      file: file,
      category: category,
      callers: callers
    }
  end

  defp maybe_write_json(analysis, formats, report_dir) do
    if formats in [:json, :both] do
      path = Path.join(report_dir, @json_name)
      File.write!(path, Jason.encode!(analysis, pretty: true))
      [path]
    else
      []
    end
  end

  defp maybe_write_md(analysis, formats, report_dir) do
    if formats in [:md, :both] do
      path = Path.join(report_dir, @md_name)
      File.write!(path, markdown(analysis))
      [path]
    else
      []
    end
  end

  defp print_summary(%{totals: totals, results: results, excluded: excluded}) do
    Mix.shell().info("Unused public function report")
    Mix.shell().info("  likely_dead: #{Map.get(totals, :likely_dead, 0)}")
    Mix.shell().info("  test_only:   #{Map.get(totals, :test_only, 0)}")
    Mix.shell().info("  review:      #{Map.get(totals, :review, 0)}")

    if count = Map.get(excluded, :review) do
      Mix.shell().info("  review excluded: #{count} (use --include-review)")
    end

    Mix.shell().info("  total:       #{length(results)}")
  end

  defp print_summary(%{totals: totals, results: results}) do
    print_summary(%{totals: totals, results: results, excluded: %{}})
  end

  defp markdown(%{generated_at: generated_at, totals: totals, results: results} = analysis) do
    excluded = Map.get(analysis, :excluded, %{})
    review_excluded = Map.get(excluded, :review, 0)

    review_note =
      if review_excluded > 0 do
        "\nReview entries excluded from this report: #{review_excluded} (use `--include-review`)\n"
      else
        ""
      end

    sections =
      [:likely_dead, :test_only, :review]
      |> Enum.filter(fn category ->
        category != :review or review_excluded == 0
      end)
      |> Enum.map(fn category ->
        section =
          results
          |> Enum.filter(fn item -> item.category == category end)
          |> Enum.sort_by(fn item -> MFA.format(item.mfa) end)
          |> Enum.map_join("\n", &markdown_item/1)

        """
        ## #{category}

        #{if section == "", do: "_None_", else: section}
        """
      end)
      |> Enum.join("\n")

    """
    # Unused public functions

    Generated: #{generated_at}

    | Category | Count |
    |----------|------:|
    | likely_dead | #{Map.get(totals, :likely_dead, 0)} |
    | test_only | #{Map.get(totals, :test_only, 0)} |
    | review | #{Map.get(totals, :review, 0)} |
    #{review_note}
    #{sections}
    """
  end

  defp markdown_item(%{mfa: mfa, file: file, callers: callers}) do
    file = file || "unknown"

    caller_summary =
      Enum.map_join(callers, "; ", fn c -> "#{c.file}:#{Enum.join(c.lines, ",")}" end)

    caller_summary = if caller_summary == "", do: "none", else: caller_summary
    "- `#{MFA.format(mfa)}` (#{file}) — callers: #{caller_summary}"
  end

  def report_paths do
    report_dir = Config.report_dir()

    [
      Path.join(report_dir, @json_name),
      Path.join(report_dir, @md_name)
    ]
  end
end
