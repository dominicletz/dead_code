defmodule DeadCode.TestReferences do
  @moduledoc false

  alias DeadCode.SourceIndex

  def callers_by_callee(config, collected, opts \\ []) do
    module_set = MapSet.new(collected.modules)
    export_set = MapSet.new(collected.all_exports, & &1.mfa)
    exports_by_mf = Enum.group_by(collected.all_exports, fn %{mfa: {m, f, _}} -> {m, f} end)

    test_files = Keyword.get_lazy(opts, :test_files, fn -> Path.wildcard(config.test_glob) end)

    test_files
    |> Enum.flat_map(fn path ->
      with {:ok, content} <- File.read(path),
           {:ok, ast} <- Code.string_to_quoted(content, file: path) do
        references_from_ast(ast, SourceIndex.normalize_path(path), module_set, export_set)
      else
        _ -> []
      end
    end)
    |> expand_and_canonicalize(collected.default_aliases, exports_by_mf)
    |> Enum.group_by(& &1.callee)
  end

  def merge_callers(xref_callers, test_callers) do
    Map.merge(xref_callers, test_callers, fn _callee, xref, test ->
      (xref || []) ++ (test || [])
    end)
  end

  defp expand_and_canonicalize(refs, default_aliases, exports_by_mf) do
    Enum.flat_map(refs, fn ref ->
      case ref.callee do
        {mod, fun, :any} ->
          exports_by_mf
          |> Map.get({mod, fun}, [])
          |> Enum.map(fn %{mfa: mfa} -> %{ref | callee: mfa} end)

        mfa ->
          [%{ref | callee: Map.get(default_aliases, mfa, mfa)}]
      end
    end)
  end

  defp references_from_ast(ast, path, module_set, export_set) do
    state = %{
      path: path,
      module_set: module_set,
      export_set: export_set,
      aliases: %{},
      imports: [],
      refs: []
    }

    walk_ast(ast, state).refs
  end

  defp walk_ast({:defmodule, _, [_mod_ast, [do: body]]}, state) do
    body_state = walk_ast(body, state)
    %{state | refs: body_state.refs}
  end

  defp walk_ast({scope, _, args}, state)
       when scope in [:describe, :test, :setup, :setup_all, :def, :defp] and is_list(args) do
    inner = Enum.reduce(args, state, &walk_ast/2)
    %{state | refs: inner.refs}
  end

  defp walk_ast({:alias, _, [arg | opts]}, state) do
    %{state | aliases: apply_alias(arg, opts, state.aliases)}
  end

  defp walk_ast({:import, _, [arg | opts]}, state) do
    %{state | imports: apply_import(arg, opts, state.aliases, state.imports)}
  end

  defp walk_ast({:|>, meta, [lhs, rhs]}, state) do
    state = walk_ast(lhs, state)
    walk_piped_rhs(rhs, meta, state)
  end

  defp walk_ast({:&, meta, [{:/, _, [{{:., _, [mod_ast, fun]}, _, []}, arity]}]}, state)
       when is_atom(fun) and is_integer(arity) do
    maybe_add_remote_ref(mod_ast, fun, arity, meta, state)
  end

  defp walk_ast({:&, meta, [{:/, _, [{fun, _, ctx}, arity]}]}, state)
       when is_atom(fun) and is_atom(ctx) and is_integer(arity) do
    maybe_add_imported_ref(fun, arity, meta, state)
  end

  defp walk_ast({{:., _, [mod_ast, fun]}, meta, args}, state)
       when is_atom(fun) and is_list(args) do
    state = maybe_add_remote_ref(mod_ast, fun, length(args), meta, state)
    state = maybe_add_apply_ref(mod_ast, fun, args, meta, state)
    Enum.reduce(args, state, &walk_ast/2)
  end

  defp walk_ast({:%, meta, [mod_ast, {:%{}, _, args}]}, state) when is_list(args) do
    state = maybe_add_remote_ref(mod_ast, :__struct__, 0, meta, state)
    Enum.reduce(args, state, &walk_ast/2)
  end

  defp walk_ast({:apply, meta, [mod_ast, fun, args_ast]}, state) when is_atom(fun) do
    arity = if is_list(args_ast), do: length(args_ast), else: :any
    state = maybe_add_remote_ref(mod_ast, fun, arity, meta, state)
    state = walk_ast(mod_ast, state)
    walk_ast(args_ast, state)
  end

  defp walk_ast({fun, meta, args}, state) when is_atom(fun) and is_list(args) do
    state = maybe_add_imported_ref(fun, length(args), meta, state)
    Enum.reduce(args, state, &walk_ast/2)
  end

  defp walk_ast({left, _meta, right}, state) when is_list(right) do
    state = walk_ast(right, state)
    walk_ast(left, state)
  end

  defp walk_ast({left, right}, state) do
    state = walk_ast(right, state)
    walk_ast(left, state)
  end

  defp walk_ast(list, state) when is_list(list) do
    Enum.reduce(list, state, &walk_ast/2)
  end

  defp walk_ast(_, state), do: state

  defp walk_piped_rhs({{:., _, [mod_ast, fun]}, meta, args}, _pipe_meta, state)
       when is_atom(fun) and is_list(args) do
    state = maybe_add_remote_ref(mod_ast, fun, length(args) + 1, meta, state)
    Enum.reduce(args, state, &walk_ast/2)
  end

  defp walk_piped_rhs({fun, meta, args}, _pipe_meta, state)
       when is_atom(fun) and is_list(args) do
    state = maybe_add_imported_ref(fun, length(args) + 1, meta, state)
    Enum.reduce(args, state, &walk_ast/2)
  end

  defp walk_piped_rhs(other, _pipe_meta, state), do: walk_ast(other, state)

  defp maybe_add_apply_ref(mod_ast, :apply, [target_mod_ast, fun, args_ast], meta, state)
       when is_atom(fun) do
    case resolve_module(mod_ast, state.aliases) do
      mod when mod in [Kernel, :erlang] ->
        arity = if is_list(args_ast), do: length(args_ast), else: :any
        maybe_add_remote_ref(target_mod_ast, fun, arity, meta, state)

      _ ->
        state
    end
  end

  defp maybe_add_apply_ref(_, _, _, _, state), do: state

  defp maybe_add_remote_ref(mod_ast, fun, arity, meta, state) do
    module = resolve_module(mod_ast, state.aliases)

    if is_atom(module) and MapSet.member?(state.module_set, module) do
      add_ref({module, fun, arity}, meta, state)
    else
      state
    end
  end

  defp maybe_add_imported_ref(fun, arity, meta, state) do
    Enum.reduce(state.imports, state, fn {mod, only}, acc ->
      allowed? = is_nil(only) or {fun, arity} in only

      if allowed? and MapSet.member?(state.module_set, mod) and
           (arity == :any or MapSet.member?(state.export_set, {mod, fun, arity})) do
        add_ref({mod, fun, arity}, meta, acc)
      else
        acc
      end
    end)
  end

  defp add_ref(callee, meta, state) do
    ref = %{
      callee: callee,
      caller_module: nil,
      file: state.path,
      line: meta[:line] || 0,
      source: :test
    }

    %{state | refs: [ref | state.refs]}
  end

  defp apply_alias({{:., _, [prefix_ast, :{}]}, _, sub_asts}, _opts, aliases) do
    prefix = resolve_module(prefix_ast, aliases)

    Enum.reduce(sub_asts, aliases, fn {:__aliases__, _, parts}, acc ->
      full = Module.concat([prefix | parts])
      Map.put(acc, List.last(parts), full)
    end)
  end

  defp apply_alias({:__aliases__, _, parts} = mod_ast, opts, aliases) do
    full = resolve_module(mod_ast, aliases)

    as_key =
      case Keyword.get(List.flatten(opts), :as) do
        {:__aliases__, _, [single]} -> single
        _ -> List.last(parts)
      end

    Map.put(aliases, as_key, full)
  end

  defp apply_alias(_, _, aliases), do: aliases

  defp apply_import(mod_ast, opts, aliases, imports) do
    case resolve_module(mod_ast, aliases) do
      mod when is_atom(mod) and mod != nil ->
        only =
          case Keyword.get(List.flatten(opts), :only) do
            list when is_list(list) -> list
            _ -> nil
          end

        [{mod, only} | imports]

      _ ->
        imports
    end
  end

  defp resolve_module({:__aliases__, _, [first | rest]}, aliases) when is_atom(first) do
    case Map.get(aliases, first) do
      nil -> Module.concat([first | rest])
      resolved -> Module.concat([resolved | rest])
    end
  end

  defp resolve_module(atom, _aliases) when is_atom(atom), do: atom
  defp resolve_module(_, _), do: nil
end
