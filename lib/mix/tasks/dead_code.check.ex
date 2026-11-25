defmodule Mix.Tasks.DeadCode.Check do
  @shortdoc "Fail when dead code score exceeds configured maximum"
  @moduledoc """
  Runs dead code analysis and fails when the score exceeds `:max_score` in `dead_code.exs`
  (or `--max-score`).

  The score counts public functions classified as `:likely_dead` (actionable dead code).

  ## Usage

      mix dead_code.check
      mix dead_code.check --max-score 25
      mix dead_code.check --config dead_code.exs

  Configure the limit in `dead_code.exs`:

      [max_score: 25]
  """

  use Mix.Task

  @switches [max_score: :integer, "no-compile": :boolean, config: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {opts, _args, _} = OptionParser.parse(args, strict: @switches)

    unless opts[:"no-compile"] do
      Mix.Task.run("compile")
    end

    analyze_opts = [config: opts[:config]]
    analysis = DeadCode.Analyze.run(analyze_opts)
    score = analysis.score
    max = opts[:max_score] || DeadCode.Config.max_score(analyze_opts)

    if is_integer(max) do
      DeadCode.Score.check!(score, max)
      Mix.shell().info("Dead code #{DeadCode.Score.format(score)} — within max #{max}")
    else
      Mix.shell().info("Dead code #{DeadCode.Score.format(score)} — no max configured")
    end
  end
end
