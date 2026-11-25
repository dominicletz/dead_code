defmodule DeadCode.CollectExports do
  @moduledoc false

  alias DeadCode.{Config, MFA, SourceIndex}

  def all(opts \\ []) do
    config = Config.load(opts)
    collect(config, opts).exports
  end

  def collect(config, opts \\ []) do
    module_filter = Keyword.get(opts, :module)
    modules = SourceIndex.resolve_modules(config, opts) |> Enum.sort()

    {all_exports, behaviours, default_aliases, module_to_file, debug_infos} =
      Enum.reduce(modules, {[], %{}, %{}, %{}, %{}}, fn module,
                                                        {exps, behs, aliases, files, infos} ->
        case collect_module(module) do
          nil ->
            {exps, behs, aliases, files, infos}

          mod_data ->
            {
              exps ++ mod_data.exports,
              Map.put(behs, module, mod_data.behaviours),
              Map.merge(aliases, mod_data.default_aliases),
              Map.put(files, module, mod_data.file),
              Map.put(infos, module, mod_data.debug_info)
            }
        end
      end)

    %{
      modules: modules,
      all_exports: all_exports,
      exports: maybe_filter_module(all_exports, module_filter),
      behaviours: behaviours,
      default_aliases: default_aliases,
      module_to_file: module_to_file,
      debug_infos: debug_infos
    }
  end

  defp collect_module(module) do
    with {:ok, info} <- SourceIndex.beam_debug_info(module) do
      mod_file = SourceIndex.normalize_path(info.file)
      behaviours = for {:behaviour, b} <- info.attributes, do: b

      user_defs =
        info.definitions
        |> Enum.filter(fn {{fun, _arity}, kind, meta, _clauses} ->
          kind == :def and MFA.export_name?(fun) and not generated_def?(meta)
        end)

      default_aliases =
        Enum.reduce(user_defs, %{}, fn {{fun, max_arity}, _kind, meta, _clauses}, acc ->
          case Keyword.get(meta, :defaults, 0) do
            defaults when is_integer(defaults) and defaults > 0 ->
              Enum.reduce((max_arity - defaults)..(max_arity - 1), acc, fn arity, inner ->
                Map.put(inner, {module, fun, arity}, {module, fun, max_arity})
              end)

            _ ->
              acc
          end
        end)

      exports =
        user_defs
        |> Enum.reject(fn {{fun, arity}, _kind, _meta, _clauses} ->
          Map.has_key?(default_aliases, {module, fun, arity})
        end)
        |> Enum.map(fn {{fun, arity}, _kind, _meta, _clauses} ->
          %{
            mfa: {module, fun, arity},
            file: mod_file
          }
        end)
        |> Enum.sort_by(& &1.mfa)

      %{
        file: mod_file,
        behaviours: behaviours,
        default_aliases: default_aliases,
        exports: exports,
        debug_info: info
      }
    else
      _ -> nil
    end
  end

  defp generated_def?(meta) do
    Keyword.get(meta, :generated, false) == true or
      Keyword.get(meta, :context) != nil or
      deps_file?(Keyword.get(meta, :file))
  end

  defp deps_file?({file, _line}) do
    normalized = SourceIndex.normalize_path(file)
    String.starts_with?(normalized, "deps/") or String.contains?(normalized, "/deps/")
  end

  defp deps_file?(_), do: false

  defp maybe_filter_module(exports, nil), do: exports

  defp maybe_filter_module(exports, module) when is_atom(module) do
    Enum.filter(exports, fn %{mfa: {mod, _, _}} -> mod == module end)
  end
end
