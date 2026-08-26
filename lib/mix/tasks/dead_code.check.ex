defmodule Mix.Tasks.DeadCode.Check do
  @shortdoc "Fail when dead code score exceeds configured maximum"
  @moduledoc """
  Runs dead code analysis and fails when the score exceeds `:max_score` in config.

  The score counts public functions classified as `:likely_dead` (actionable dead code).

  ## Usage

      mix dead_code.check
      mix dead_code.check --max-score 950

  Configure the limit in the host project:

      config :dead_code, max_score: 950
  """

  use Mix.Task

  @switches [max_score: :integer, "no-compile": :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {opts, _args, _} = OptionParser.parse(args, strict: @switches)

    unless opts[:"no-compile"] do
      Mix.Task.run("compile", ["--force"])
    end

    analysis = DeadCode.Analyze.run([])
    score = analysis.score
    max = opts[:max_score] || DeadCode.Config.max_score()

    if is_integer(max) do
      DeadCode.Score.check!(score, max)
      Mix.shell().info("Dead code #{DeadCode.Score.format(score)} — within max #{max}")
    else
      Mix.shell().info("Dead code #{DeadCode.Score.format(score)} — no max configured")
    end
  end
end
