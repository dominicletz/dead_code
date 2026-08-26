defmodule DeadCode.Score do
  @moduledoc """
  Computes and enforces a dead code score from analysis results.

  The score is the count of public functions classified as `:likely_dead`:
  no callers in `lib/` or `test/`, and not matched by framework or entry-point
  heuristics. This is the actionable unused-code metric.
  """

  alias DeadCode.Config

  def compute(results) when is_list(results) do
    totals = Enum.frequencies_by(results, & &1.category)
    likely_dead = Map.get(totals, :likely_dead, 0)
    public_exports = length(results)

    ratio =
      if public_exports > 0 do
        Float.round(likely_dead / public_exports, 4)
      else
        0.0
      end

    %{
      value: likely_dead,
      likely_dead: likely_dead,
      public_exports: public_exports,
      ratio: ratio
    }
  end

  def check!(score, max) when is_integer(max) do
    if score.value > max do
      Mix.raise(
        "Dead code score #{score.value} exceeds maximum #{max} (#{score.value - max} over limit). " <>
          "Remove unused public functions or raise :max_score after an audit."
      )
    end

    :ok
  end

  def check!(score) do
    case Config.max_score() do
      max when is_integer(max) -> check!(score, max)
      _ -> Mix.raise("No :max_score configured for :dead_code")
    end
  end

  def format(%{value: value, public_exports: public_exports, ratio: ratio}) do
    pct = Float.round(ratio * 100, 2)
    "#{value} (#{pct}% of #{public_exports} public exports)"
  end
end
