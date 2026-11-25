defmodule DeadCode.Config do
  @moduledoc false

  @default_files ["dead_code.exs", ".dead_code.exs"]

  @defaults %{
    otp_app: nil,
    lib_glob: "lib/**/*.{ex,heex}",
    test_glob: "test/**/*.{ex,exs}",
    report_dir: "priv/reports",
    routers: [],
    entry_points: [],
    module_callbacks: [],
    scanners: [],
    ignore: [],
    max_score: nil
  }

  def load(opts \\ []) do
    env_config =
      Application.get_all_env(:dead_code)
      |> Map.new()

    file_config =
      case config_path(opts[:config]) do
        nil -> %{}
        path -> eval_config_file(path)
      end

    opt_overrides =
      opts
      |> Enum.reject(fn {k, v} ->
        is_nil(v) and k in [:otp_app, :config, :module, :max_score]
      end)
      |> Map.new()

    @defaults
    |> Map.merge(env_config)
    |> Map.merge(file_config)
    |> Map.merge(opt_overrides)
    |> normalize()
  end

  def report_dir(opts \\ []), do: load(opts).report_dir
  def max_score(opts \\ []), do: load(opts).max_score

  defp config_path(nil) do
    Enum.find(@default_files, &File.exists?/1)
  end

  defp config_path(path) when is_binary(path) do
    if File.exists?(path) do
      path
    else
      Mix.raise("dead_code config file not found: #{path}")
    end
  end

  defp eval_config_file(path) do
    {term, _} = Code.eval_file(path)

    cond do
      is_map(term) -> term
      Keyword.keyword?(term) -> Map.new(term)
      true -> Mix.raise("dead_code config in #{path} must return a keyword list or map")
    end
  end

  defp normalize(config) do
    otp_app = config.otp_app || Mix.Project.config()[:app]

    %{
      otp_app: otp_app,
      lib_glob: config.lib_glob,
      test_glob: config.test_glob,
      report_dir: config.report_dir,
      routers: List.wrap(config.routers),
      entry_points: List.wrap(config.entry_points),
      module_callbacks: List.wrap(config.module_callbacks),
      scanners: List.wrap(config.scanners),
      ignore: List.wrap(config.ignore),
      max_score: config.max_score
    }
  end
end
