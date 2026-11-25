defmodule Mix.Tasks.DeadCode.Public do
  @shortdoc "Find unused public functions (likely dead code)"
  @moduledoc """
  Reports public `def` functions with no callers in `lib/` or `test/`, using BEAM
  `debug_info` call graphs plus `@behaviour`, protocol, router, and `dead_code.exs`
  entry-point configuration.

  ## Usage

      mix dead_code.public
      mix dead_code.public --format md
      mix dead_code.public --module MyApp.Accounts
      mix dead_code.public --only-likely-dead
      mix dead_code.public --include-review
      mix dead_code.public --verify MyApp.Accounts.create/1
      mix dead_code.public --config dead_code.exs
      mix dead_code.check
      mix dead_code.check --max-score 25

  ## Score

  The dead code **score** is the count of `:likely_dead` public functions — actionable
  unused code. Use `mix dead_code.check` in CI with `:max_score` configured in `dead_code.exs`
  to prevent regressions.

  - `likely_dead` — no callers in BEAMs or `test/`, not matched as an entry point
  - `test_only` — callers exist only under `test/`
  - `review` — matched as `@behaviour`/protocol/router/configured entry point without BEAM callers
    (excluded from the report by default; use `--include-review` to list them)

  ## Configuration & Ignores

  Configure entry points, scanners, and suppressions in `dead_code.exs` at the host project root:

      [
        ignore: [
          {SomeModule},
          {SomeModule, :legacy_helper, 2},
          "path:lib/mix/tasks/**"
        ]
      ]

  Ignores are debt — document why each entry exists.

  ## Limitations

  - Dynamic dispatch (`apply/3` with runtime atoms, string RPC methods) needs `entry_points` or `scanners`
  - Host-only compiles may miss platform-conditional call sites
  - Private `defp` unused functions are out of scope (use the compiler)
  """

  use Mix.Task

  @switches [
    format: :string,
    module: :string,
    verify: :string,
    config: :string,
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

    unless opts[:"no-compile"] do
      Mix.Task.run("compile")
    end

    analyze_opts = analyze_opts(opts)

    if verify = opts[:verify] do
      run_verify(verify, analyze_opts)
    else
      run_report(analyze_opts, opts)
    end
  end

  defp run_verify(mfa_string, analyze_opts) do
    case DeadCode.Analyze.verify(mfa_string, analyze_opts) do
      %{} = result ->
        print_verify(result)
        :ok

      {:error, reason} ->
        Mix.raise("Invalid --verify MFA (#{inspect(reason)}). Example: MyApp.Accounts.create/1")
    end
  end

  defp print_verify(result) do
    Mix.shell().info("#{result.formatted}")
    Mix.shell().info("  category:    #{result.category}")
    Mix.shell().info("  entry_point: #{result.entry_point}")
    Mix.shell().info("  ignored:     #{result.ignored}")
    Mix.shell().info("  callers:     #{length(result.callers)}")

    for caller <- result.callers do
      Mix.shell().info("    #{caller.file}:#{Enum.join(caller.lines, ",")}")
    end
  end

  defp run_report(analyze_opts, opts) do
    analysis = DeadCode.Analyze.run(analyze_opts)
    format = parse_format(opts[:format])
    report_opts = [format: format, config: opts[:config]]
    paths = DeadCode.Report.write!(analysis, report_opts)

    for path <- paths do
      Mix.shell().info("Wrote #{path}")
    end

    maybe_fail(analysis, opts)
  end

  defp maybe_fail(%{score: %{value: value}}, opts) do
    threshold = Keyword.get(opts, :"fail-above", 0)

    if threshold > 0 and value > threshold do
      Mix.raise("Dead code score #{value} exceeds threshold #{threshold}")
    end
  end

  defp analyze_opts(opts) do
    [
      only_likely_dead: opts[:"only-likely-dead"] || false,
      include_test_only: Keyword.get(opts, :"include-test-only", true),
      include_review: opts[:"include-review"] || false,
      module: module_opt(opts[:module]),
      config: opts[:config]
    ]
  end

  defp module_opt(nil), do: nil

  defp module_opt(module_str) do
    case DeadCode.MFA.parse_module(module_str) do
      {:ok, module} -> module
      {:error, _} -> Mix.raise("Invalid --module value: #{module_str}")
    end
  end

  defp parse_format(nil), do: :both
  defp parse_format("json"), do: :json
  defp parse_format("md"), do: :md
  defp parse_format("both"), do: :both
  defp parse_format(other), do: Mix.raise("Invalid --format #{other}. Use json, md, or both.")
end
