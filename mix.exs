defmodule DeadCode.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dominicletz/dead_code"

  def project do
    [
      app: :dead_code,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Find unused public functions via compile xref and entry-point heuristics",
      package: package(),
      source_url: @source_url
    ]
  end

  defp deps do
    [{:jason, "~> 1.3"}]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
