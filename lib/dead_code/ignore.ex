defmodule DeadCode.Ignore do
  @moduledoc false

  alias DeadCode.SourceIndex

  @default_path ".dead_code_ignore.exs"

  def load(source_index, path \\ @default_path) do
    entries =
      if File.exists?(path) do
        {terms, _} = Code.eval_file(path)
        List.wrap(terms)
      else
        []
      end

    {modules, mfas, path_patterns} =
      Enum.reduce(entries, {MapSet.new(), MapSet.new(), []}, &accumulate/2)

    path_modules =
      path_patterns
      |> Enum.flat_map(&SourceIndex.modules_for_path_pattern(&1, source_index.module_to_file))
      |> MapSet.new()

    %{
      modules: MapSet.union(modules, path_modules),
      mfas: mfas
    }
  end

  defp accumulate({module, function, arity}, {modules, mfas, paths})
       when is_atom(module) and is_atom(function) do
    {modules, MapSet.put(mfas, {module, function, arity}), paths}
  end

  defp accumulate({module}, {modules, mfas, paths}) when is_atom(module) do
    {MapSet.put(modules, module), mfas, paths}
  end

  defp accumulate("path:" <> _ = pattern, {modules, mfas, paths}) do
    {modules, mfas, [pattern | paths]}
  end

  defp accumulate(other, acc) do
    Mix.shell().error("Ignoring unknown dead_code ignore entry: #{inspect(other)}")
    acc
  end

  def ignored?({module, _function, _arity} = mfa, %{modules: modules, mfas: mfas}) do
    MapSet.member?(modules, module) or MapSet.member?(mfas, mfa)
  end
end
