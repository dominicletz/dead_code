defmodule DeadCode.XrefUsed do
  @moduledoc false

  alias DeadCode.SourceIndex

  @dynamic_kernel_dispatchers [:apply, :spawn, :spawn_link, :spawn_monitor]
  @dynamic_remote_dispatchers [
    {:erlang, :apply, 3},
    {Kernel, :apply, 3},
    {:erlang, :spawn, 3},
    {:erlang, :spawn_link, 3},
    {:erlang, :spawn_monitor, 3},
    {Process, :spawn, 4},
    {Task, :start, 3},
    {Task, :start_link, 3},
    {Task, :async, 3},
    {:timer, :apply_after, 4},
    {:timer, :apply_interval, 4}
  ]

  def calls(collected, source_index) do
    export_set = MapSet.new(collected.all_exports, & &1.mfa)
    exports_by_mf = Enum.group_by(collected.all_exports, fn %{mfa: {m, f, _a}} -> {m, f} end)
    module_set = MapSet.new(collected.modules)

    beam_calls =
      Enum.flat_map(collected.debug_infos, fn {module, info} ->
        walk_definitions(module, SourceIndex.normalize_path(info.file), info.definitions)
      end)

    use_calls = collect_use_dispatch_calls(source_index.lib_files, module_set)

    (beam_calls ++ use_calls)
    |> expand_and_canonicalize(collected.default_aliases, export_set, exports_by_mf)
  end

  def callers_by_callee(calls) do
    Enum.group_by(calls, fn call -> call.callee end)
  end

  def callee_set(calls) do
    calls
    |> Enum.map(& &1.callee)
    |> MapSet.new()
  end

  defp expand_and_canonicalize(raw_calls, default_aliases, _export_set, exports_by_mf) do
    Enum.flat_map(raw_calls, fn call ->
      canonical_caller =
        case call.caller_mfa do
          nil -> nil
          mfa -> Map.get(default_aliases, mfa, mfa)
        end

      case call.callee do
        {mod, fun, :any} ->
          exports_by_mf
          |> Map.get({mod, fun}, [])
          |> Enum.reject(fn %{mfa: mfa} -> mfa == canonical_caller end)
          |> Enum.map(fn %{mfa: mfa} -> %{call | callee: mfa} end)

        mfa ->
          canonical_callee = Map.get(default_aliases, mfa, mfa)

          if canonical_callee == canonical_caller do
            []
          else
            [%{call | callee: canonical_callee}]
          end
      end
    end)
  end

  defp walk_definitions(module, file, definitions) do
    state = %{file: file, module: module, caller_mfa: nil, calls: []}
    state = Enum.reduce(definitions, state, &walk_definition/2)
    state.calls
  end

  defp walk_definition({{fun, arity}, _kind, meta, clauses}, state) do
    caller_state = %{state | caller_mfa: {state.module, fun, arity}}

    with_file_meta(caller_state, meta, fn inner_state ->
      Enum.reduce(clauses, inner_state, &walk_clause/2)
    end)
  end

  defp with_file_meta(%{file: original_file} = state, meta, fun) do
    case Keyword.fetch(meta, :file) do
      {:ok, {meta_file, _}} ->
        next = fun.(%{state | file: SourceIndex.normalize_path(meta_file)})
        %{next | file: original_file}

      :error ->
        fun.(state)
    end
  end

  defp walk_clause({_meta, args, guards, body}, state) do
    state
    |> then(&walk_expr(args, &1))
    |> then(&walk_expr(guards, &1))
    |> then(&walk_expr(body, &1))
  end

  defp walk_expr({:&, meta, [{:/, _, [{{:., _, [module, fun]}, _, []}, arity]}]}, state)
       when is_atom(module) and is_atom(fun) and is_integer(arity) do
    add_call(module, fun, arity, meta, state)
  end

  defp walk_expr({:&, meta, [{:/, _, [{fun, _, ctx}, arity]}]}, state)
       when is_atom(fun) and is_atom(ctx) and is_integer(arity) do
    add_call(state.module, fun, arity, meta, state)
  end

  defp walk_expr({{:., _, [module, fun]}, meta, args}, state)
       when is_atom(module) and is_atom(fun) and is_list(args) do
    state = add_call(module, fun, length(args), meta, state)
    state = maybe_add_dynamic_remote(module, fun, args, meta, state)
    walk_expr(args, state)
  end

  defp walk_expr({:%, meta, [module, {:%{}, _meta, args}]}, state)
       when is_atom(module) and is_list(args) do
    state = add_call(module, :__struct__, 0, meta, state)
    walk_expr(args, state)
  end

  defp walk_expr({fun, meta, args}, state) when is_atom(fun) and is_list(args) do
    state =
      if fun in @dynamic_kernel_dispatchers do
        maybe_add_dynamic_args(args, meta, state)
      else
        add_call(state.module, fun, length(args), meta, state)
      end

    walk_expr(args, state)
  end

  defp walk_expr({left, _meta, right}, state) when is_list(right) do
    state = walk_expr(right, state)
    walk_expr(left, state)
  end

  defp walk_expr({left, right}, state) do
    state = walk_expr(right, state)
    walk_expr(left, state)
  end

  defp walk_expr(list, state) when is_list(list) do
    Enum.reduce(list, state, &walk_expr/2)
  end

  defp walk_expr(_other, state), do: state

  defp maybe_add_dynamic_remote(module, fun, args, meta, state) do
    if {module, fun, length(args)} in @dynamic_remote_dispatchers do
      maybe_add_dynamic_args(args, meta, state)
    else
      state
    end
  end

  defp maybe_add_dynamic_args([mod, fun, args_ast | _rest], meta, state)
       when is_atom(mod) and is_atom(fun) do
    arity = if is_list(args_ast), do: length(args_ast), else: :any
    add_call(mod, fun, arity, meta, state)
  end

  defp maybe_add_dynamic_args([_delay_or_node, mod, fun, args_ast | _rest], meta, state)
       when is_atom(mod) and is_atom(fun) do
    arity = if is_list(args_ast), do: length(args_ast), else: :any
    add_call(mod, fun, arity, meta, state)
  end

  defp maybe_add_dynamic_args(_args, _meta, state), do: state

  defp add_call(module, fun, arity, meta, state) do
    call = %{
      callee: {module, fun, arity},
      caller_module: state.module,
      caller_mfa: state.caller_mfa,
      file: state.file,
      line: meta[:line] || 0,
      source: :beam
    }

    %{state | calls: [call | state.calls]}
  end

  defp collect_use_dispatch_calls(lib_files, module_set) do
    lib_files
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.flat_map(fn path ->
      with {:ok, content} <- File.read(path),
           {:ok, ast} <- Code.string_to_quoted(content, file: path) do
        extract_use_calls(ast, path, module_set)
      else
        _ -> []
      end
    end)
  end

  defp extract_use_calls(ast, path, module_set) do
    {_, calls} = walk_use_ast(ast, %{aliases: %{}, module: nil, file: path}, [], module_set)
    calls
  end

  defp walk_use_ast({:defmodule, _, [mod_ast, [do: body]]}, ctx, calls, module_set) do
    mod = resolve_alias(mod_ast, ctx.aliases)
    {_, calls} = walk_use_ast(body, %{ctx | module: mod}, calls, module_set)
    {ctx, calls}
  end

  defp walk_use_ast({:alias, _, [arg | opts]}, ctx, calls, _module_set) do
    {%{ctx | aliases: apply_alias(arg, opts, ctx.aliases)}, calls}
  end

  defp walk_use_ast({:use, meta, [mod_ast, opt_ast]}, ctx, calls, module_set) do
    mod = resolve_alias(mod_ast, ctx.aliases)

    calls =
      with true <- is_atom(mod) and MapSet.member?(module_set, mod),
           {which, arity} when is_atom(which) <- use_dispatch_target(opt_ast) do
        [
          %{
            callee: {mod, which, arity},
            caller_module: ctx.module,
            caller_mfa: nil,
            file: ctx.file,
            line: meta[:line] || 0,
            source: :beam
          }
          | calls
        ]
      else
        _ -> calls
      end

    {ctx, calls}
  end

  defp walk_use_ast({:__block__, _, exprs}, ctx, calls, module_set) when is_list(exprs) do
    Enum.reduce(exprs, {ctx, calls}, fn expr, {acc_ctx, acc_calls} ->
      walk_use_ast(expr, acc_ctx, acc_calls, module_set)
    end)
  end

  defp walk_use_ast({_, _, args}, ctx, calls, module_set) when is_list(args) do
    {_, calls} =
      Enum.reduce(args, {ctx, calls}, fn arg, {acc_ctx, acc_calls} ->
        walk_use_ast(arg, acc_ctx, acc_calls, module_set)
      end)

    {ctx, calls}
  end

  defp walk_use_ast(list, ctx, calls, module_set) when is_list(list) do
    Enum.reduce(list, {ctx, calls}, fn item, {acc_ctx, acc_calls} ->
      walk_use_ast(item, acc_ctx, acc_calls, module_set)
    end)
  end

  defp walk_use_ast({key, val}, ctx, calls, module_set) do
    {_, calls} = walk_use_ast(key, ctx, calls, module_set)
    walk_use_ast(val, ctx, calls, module_set)
  end

  defp walk_use_ast(_, ctx, calls, _module_set), do: {ctx, calls}

  defp use_dispatch_target(atom) when is_atom(atom), do: {atom, 0}
  defp use_dispatch_target({atom, _arg}) when is_atom(atom), do: {atom, 1}
  defp use_dispatch_target(_), do: nil

  defp apply_alias({{:., _, [prefix_ast, :{}]}, _, sub_asts}, _opts, aliases) do
    prefix = resolve_alias(prefix_ast, aliases)

    Enum.reduce(sub_asts, aliases, fn {:__aliases__, _, parts}, acc ->
      full = Module.concat([prefix | parts])
      Map.put(acc, List.last(parts), full)
    end)
  end

  defp apply_alias({:__aliases__, _, parts} = mod_ast, opts, aliases) do
    full = resolve_alias(mod_ast, aliases)

    as_key =
      case Keyword.get(List.flatten(opts), :as) do
        {:__aliases__, _, [single]} -> single
        _ -> List.last(parts)
      end

    Map.put(aliases, as_key, full)
  end

  defp apply_alias(_, _, aliases), do: aliases

  defp resolve_alias({:__aliases__, _, [first | rest]}, aliases) when is_atom(first) do
    case Map.get(aliases, first) do
      nil -> Module.concat([first | rest])
      resolved -> Module.concat([resolved | rest])
    end
  end

  defp resolve_alias(atom, _aliases) when is_atom(atom), do: atom
  defp resolve_alias(_, _), do: nil
end
