defmodule DeadCode.Ignore do
  @moduledoc false

  alias DeadCode.SourceIndex

  @legacy_path ".dead_code_ignore.exs"

  def load(source_index, config_or_entries \\ [], legacy_path \\ @legacy_path)

  def load(source_index, %{ignore: entries}, legacy_path) do
    load(source_index, entries, legacy_path)
  end

  def load(source_index, entries, legacy_path) when is_list(entries) do
    legacy_entries =
      if is_binary(legacy_path) and File.exists?(legacy_path) do
        {terms, _} = Code.eval_file(legacy_path)
        List.wrap(terms)
      else
        []
      end

    {modules, mfas, fun_wildcards, path_patterns} =
      (entries ++ legacy_entries)
      |> Enum.reduce({MapSet.new(), MapSet.new(), MapSet.new(), []}, &accumulate/2)

    path_modules =
      path_patterns
      |> Enum.flat_map(&SourceIndex.modules_for_path_pattern(&1, source_index.module_to_file))
      |> MapSet.new()

    %{
      modules: MapSet.union(modules, path_modules),
      mfas: mfas,
      fun_wildcards: fun_wildcards
    }
  end

  defp accumulate({module, function, :_}, {modules, mfas, wildcards, paths})
       when is_atom(module) and is_atom(function) do
    {modules, mfas, MapSet.put(wildcards, {module, function}), paths}
  end

  defp accumulate({module, function, arity}, {modules, mfas, wildcards, paths})
       when is_atom(module) and is_atom(function) and is_integer(arity) do
    {modules, MapSet.put(mfas, {module, function, arity}), wildcards, paths}
  end

  defp accumulate({module}, {modules, mfas, wildcards, paths}) when is_atom(module) do
    {MapSet.put(modules, module), mfas, wildcards, paths}
  end

  defp accumulate(module, {modules, mfas, wildcards, paths}) when is_atom(module) do
    {MapSet.put(modules, module), mfas, wildcards, paths}
  end

  defp accumulate("path:" <> _ = pattern, {modules, mfas, wildcards, paths}) do
    {modules, mfas, wildcards, [pattern | paths]}
  end

  defp accumulate(other, acc) do
    Mix.shell().error("Ignoring unknown dead_code ignore entry: #{inspect(other)}")
    acc
  end

  def ignored?(
        {module, function, _arity} = mfa,
        %{modules: modules, mfas: mfas, fun_wildcards: wildcards}
      ) do
    MapSet.member?(modules, module) or
      MapSet.member?(mfas, mfa) or
      MapSet.member?(wildcards, {module, function})
  end

  def ignored?(mfa, %{modules: modules, mfas: mfas}) do
    ignored?(mfa, %{modules: modules, mfas: mfas, fun_wildcards: MapSet.new()})
  end
end
