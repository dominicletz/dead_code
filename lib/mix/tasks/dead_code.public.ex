defmodule Mix.Tasks.DeadCode.Public do
  @shortdoc "Find unused public functions (likely dead code)"
  @moduledoc """
  Reports public `def` functions with no callers in `lib/` or `test/`, using the
  compile xref call graph plus Phoenix/OTP entry-point heuristics.

  ## Usage

      mix dead_code.public
      mix dead_code.public --format md
      mix dead_code.public --module Model.App
      mix dead_code.public --only-likely-dead
      mix dead_code.public --include-review
      mix dead_code.public --verify Model.App.foo/2

  ## Buckets

  - `likely_dead` — no callers in lib/ or test/, not matched by entry-point scanners
  - `test_only` — callers exist only under `test/`
  - `review` — matched as framework/router/modal/RPC entry point but no direct xref callers
    (excluded from the report by default; use `--include-review` to list them)

  ## Ignore list

  Add suppressions to `.dead_code_ignore.exs`:

      {SomeModule}
      {SomeModule, :legacy_helper, 2}
      "path:lib/mix/tasks/**"

  Ignores are debt — document why each entry exists.

  ## Limitations

  - Dynamic dispatch (`apply/3`, string RPC methods, `Modals.show/2`) needs scanners or manual ignores
  - Host-only compiles may miss platform-conditional call sites
  - Colocated `.html.heex` component references are scanned but not exhaustive
  - Private `defp` unused functions are out of scope (use the compiler)
  """

  use Mix.Task

  @switches [
    format: :string,
    module: :string,
    verify: :string,
    "fail-above": :integer,
    "only-likely-dead": :boolean,
    "include-test-only": :boolean,
    "include-review": :boolean,
    "no-compile": :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {opts, _args, _} = OptionParser.parse(args, strict: @switches)

    unless opts[:no_compile] do
      Mix.Task.run("compile", ["--force"])
    end

    analyze_opts = analyze_opts(opts)

    if verify = opts[:verify] do
      run_verify(verify, analyze_opts, opts)
    else
      run_report(analyze_opts, opts)
    end
  end

  defp run_verify(mfa_string, analyze_opts, opts) do
    case DeadCode.Analyze.verify(mfa_string, analyze_opts) do
      %{} = result ->
        print_verify(result)
        maybe_fail(0, opts)

      {:error, reason} ->
        Mix.raise("Invalid --verify MFA (#{inspect(reason)}). Example: Model.App.foo/2")
    end
  end

  defp print_verify(result) do
    Mix.shell().info("#{result.formatted}")
    Mix.shell().info("  entry_point: #{result.entry_point}")
    Mix.shell().info("  framework_entry: #{result.framework_entry}")
    Mix.shell().info("  callers: #{length(result.callers)}")

    for caller <- result.callers do
      Mix.shell().info("    #{caller.file}:#{Enum.join(caller.lines, ",")}")
    end
  end

  defp run_report(analyze_opts, opts) do
    analysis = DeadCode.Analyze.run(analyze_opts)
    format = parse_format(opts[:format])
    paths = DeadCode.Report.write!(analysis, format: format)

    for path <- paths do
      Mix.shell().info("Wrote #{path}")
    end

    maybe_fail(Map.get(analysis.totals, :likely_dead, 0), opts)
  end

  defp analyze_opts(opts) do
    [
      only_likely_dead: opts[:"only-likely-dead"] || false,
      include_test_only: Keyword.get(opts, :"include-test-only", true),
      include_review: opts[:"include-review"] || false,
      module: module_opt(opts[:module])
    ]
  end

  defp module_opt(nil), do: nil

  defp module_opt(module_str) do
    case Code.string_to_quoted(module_str) do
      {:ok, module} when is_atom(module) -> module
      _ -> Mix.raise("Invalid --module value: #{module_str}")
    end
  end

  defp parse_format(nil), do: :both
  defp parse_format("json"), do: :json
  defp parse_format("md"), do: :md
  defp parse_format("both"), do: :both
  defp parse_format(other), do: Mix.raise("Invalid --format #{other}. Use json, md, or both.")

  defp maybe_fail(count, opts) do
    threshold = Keyword.get(opts, :"fail-above", 0)

    if threshold > 0 and count > threshold do
      Mix.raise("Found #{count} likely_dead public functions (threshold #{threshold})")
    end
  end
end
