defmodule DeadCode.EntryPoints do
  @moduledoc false

  @liveview_callbacks [
    mount: 3,
    handle_params: 3,
    handle_event: 3,
    handle_async: 3,
    handle_info: 2,
    render: 1,
    terminate: 2
  ]

  @otp_child_behaviours [
    GenServer,
    Supervisor,
    DynamicSupervisor,
    Registry,
    Agent,
    Task
  ]

  @application_callbacks [
    start: 2,
    stop: 1,
    config_change: 3,
    prep_stop: 1,
    start_phase: 3
  ]

  def all(source_index, collected, calls, config) do
    export_set = MapSet.new(collected.all_exports, & &1.mfa)
    exports_by_module = Enum.group_by(collected.all_exports, fn %{mfa: {m, _, _}} -> m end)
    exports_by_mf = Enum.group_by(collected.all_exports, fn %{mfa: {m, f, _}} -> {m, f} end)

    context = %{
      exports: collected.all_exports,
      calls: calls,
      modules: collected.modules,
      lib_files: source_index.lib_files,
      config: config
    }

    []
    |> Enum.concat(behaviour_entries(collected.behaviours))
    |> Enum.concat(otp_child_entries(collected.behaviours, collected.modules))
    |> Enum.concat(protocol_entries(collected.modules))
    |> Enum.concat(application_entries(config.otp_app))
    |> Enum.concat(mix_task_entries(collected.modules))
    |> Enum.concat(router_entries(config.routers, collected.modules))
    |> Enum.concat(configured_entry_points(config.entry_points))
    |> Enum.concat(module_callback_entries(config.module_callbacks, collected.modules))
    |> Enum.concat(scanner_entries(config.scanners, context))
    |> Enum.flat_map(
      &expand_and_canonicalize(&1, collected.default_aliases, exports_by_module, exports_by_mf)
    )
    |> MapSet.new()
    |> MapSet.intersection(export_set)
    |> MapSet.to_list()
  end

  defp behaviour_entries(behaviours_by_module) do
    Enum.flat_map(behaviours_by_module, fn {module, behaviours} ->
      Enum.flat_map(behaviours, fn behaviour ->
        if Code.ensure_loaded?(behaviour) and function_exported?(behaviour, :behaviour_info, 1) do
          callbacks =
            (behaviour.behaviour_info(:callbacks) || []) ++
              (behaviour.behaviour_info(:optional_callbacks) || [])

          Enum.map(callbacks, fn {fun, arity} -> {module, fun, arity} end)
        else
          []
        end
      end)
    end)
  end

  defp otp_child_entries(behaviours_by_module, modules) do
    Enum.flat_map(modules, fn module ->
      behaviours = Map.get(behaviours_by_module, module, [])

      has_child_spec? =
        Enum.any?(behaviours, &(&1 in @otp_child_behaviours)) or
          (Code.ensure_loaded?(module) and function_exported?(module, :child_spec, 1))

      if has_child_spec? do
        [{module, :start_link, :_}]
      else
        []
      end
    end)
  end

  defp protocol_entries(modules) do
    Enum.flat_map(modules, fn module ->
      if Code.ensure_loaded?(module) and function_exported?(module, :__impl__, 1) do
        proto =
          try do
            module.__impl__(:protocol)
          rescue
            _ -> nil
          end

        if (proto && Code.ensure_loaded?(proto)) and function_exported?(proto, :__protocol__, 1) do
          for {fun, arity} <- proto.__protocol__(:functions) do
            {module, fun, arity}
          end
        else
          []
        end
      else
        []
      end
    end)
  end

  defp application_entries(nil), do: []

  defp application_entries(otp_app) do
    case Application.spec(otp_app, :mod) do
      {app_mod, _args} when is_atom(app_mod) ->
        for {fun, arity} <- @application_callbacks, do: {app_mod, fun, arity}

      _ ->
        []
    end
  end

  defp mix_task_entries(modules) do
    modules
    |> Enum.filter(fn mod ->
      mod |> Atom.to_string() |> String.starts_with?("Elixir.Mix.Tasks.")
    end)
    |> Enum.map(&{&1, :run, 1})
  end

  defp router_entries(configured_routers, modules) do
    discovered_routers =
      Enum.filter(modules, fn mod ->
        Code.ensure_loaded?(mod) and function_exported?(mod, :__routes__, 0)
      end)

    (configured_routers ++ discovered_routers)
    |> Enum.uniq()
    |> Enum.flat_map(&routes_from_router/1)
  end

  defp routes_from_router(router) do
    if Code.ensure_loaded?(router) and function_exported?(router, :__routes__, 0) do
      router.__routes__()
      |> Enum.flat_map(&entries_from_route/1)
    else
      []
    end
  end

  defp entries_from_route(route) do
    meta = Map.get(route, :metadata, %{})

    live_entries =
      case Map.get(meta, :phoenix_live_view) do
        {live_mod, _action, _opts, _extra} when is_atom(live_mod) ->
          for {fun, arity} <- @liveview_callbacks, do: {live_mod, fun, arity}

        _ ->
          []
      end

    plug_entries =
      case {Map.get(route, :plug), Map.get(route, :plug_opts)} do
        {plug, action}
        when is_atom(plug) and is_atom(action) and plug != Phoenix.LiveView.Plug ->
          [
            {plug, action, 2},
            {plug, :init, 1},
            {plug, :call, 2},
            {plug, :action, 2}
          ]

        {plug, _} when is_atom(plug) and plug != Phoenix.LiveView.Plug ->
          [{plug, :init, 1}, {plug, :call, 2}]

        _ ->
          []
      end

    mfa_entries =
      case Map.get(meta, :mfa) do
        {m, f, a} when is_atom(m) and is_atom(f) and is_integer(a) -> [{m, f, a}]
        _ -> []
      end

    live_entries ++ plug_entries ++ mfa_entries
  end

  defp configured_entry_points(entries) do
    Enum.flat_map(entries, fn
      {mod, fun, arity} when is_atom(mod) and is_atom(fun) ->
        [{mod, fun, arity}]

      _ ->
        []
    end)
  end

  defp module_callback_entries(module_callbacks, modules) do
    Enum.flat_map(module_callbacks, fn
      {matcher, callbacks} when is_list(callbacks) ->
        modules
        |> Enum.filter(&module_matches?(&1, matcher))
        |> Enum.flat_map(fn mod ->
          Enum.map(callbacks, fn {fun, arity} -> {mod, fun, arity} end)
        end)

      _ ->
        []
    end)
  end

  defp module_matches?(module, prefix) when is_binary(prefix) do
    full_name = Atom.to_string(module)
    short_name = inspect(module)
    String.starts_with?(full_name, prefix) or String.starts_with?(short_name, prefix)
  end

  defp module_matches?(module, %Regex{} = regex) do
    Regex.match?(regex, inspect(module))
  end

  defp module_matches?(_, _), do: false

  defp scanner_entries(scanners, context) do
    Enum.flat_map(scanners, fn
      scanner when is_function(scanner, 1) -> List.wrap(scanner.(context))
      _ -> []
    end)
  end

  defp expand_and_canonicalize({mod, :_, :_}, _aliases, exports_by_module, _exports_by_mf) do
    exports_by_module
    |> Map.get(mod, [])
    |> Enum.map(& &1.mfa)
  end

  defp expand_and_canonicalize({mod, fun, :_}, _aliases, _exports_by_module, exports_by_mf) do
    exports_by_mf
    |> Map.get({mod, fun}, [])
    |> Enum.map(& &1.mfa)
  end

  defp expand_and_canonicalize(
         {mod, fun, arity},
         default_aliases,
         _exports_by_module,
         _exports_by_mf
       )
       when is_integer(arity) do
    mfa = {mod, fun, arity}
    [Map.get(default_aliases, mfa, mfa)]
  end

  defp expand_and_canonicalize(_, _, _, _), do: []
end
