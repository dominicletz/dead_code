defmodule DeadCode.EntryPoints do
  @moduledoc false

  alias DeadCode.{Config, SourceIndex}

  @otp_callbacks ~w(
    start stop config_change child_spec init start_link handle_call handle_cast handle_info
    handle_continue terminate code_change format_status
  )a
  @lv_callbacks ~w(mount handle_params handle_event handle_async handle_info render update on_mount)a
  @plug_callbacks ~w(call init)a
  @access_callbacks ~w(fetch get_and_update pop)a
  @cowboy_websocket_callbacks ~w(websocket_init websocket_handle websocket_info websocket_terminate)a
  @gen_event_callbacks ~w(handle_event)a
  @modal_callbacks ~w(mount update render parse_msg)a
  @liveview_callback_arities %{
    mount: [1, 3],
    handle_params: [3],
    handle_event: [3],
    handle_async: [3],
    handle_info: [2],
    render: [1],
    update: [2],
    on_mount: [4]
  }

  @partner_callbacks ~w(tagline about url logo execute_cta)a

  def all(source_index, exports) do
    export_set = MapSet.new(Enum.map(exports, & &1.mfa))

    []
    |> Enum.concat(framework_entries(exports))
    |> Enum.concat(router_entries())
    |> Enum.concat(modal_entries(source_index))
    |> Enum.concat(heex_component_entries(source_index))
    |> Enum.concat(Config.rpc_handlers())
    |> Enum.concat(partner_entries(source_index))
    |> Enum.concat(delegate_entries(source_index, export_set))
    |> MapSet.new()
    |> MapSet.intersection(export_set)
    |> MapSet.to_list()
  end

  def framework_entries(exports) do
    Enum.flat_map(exports, fn %{mfa: mfa} ->
      if framework_entry?(mfa), do: [mfa], else: []
    end)
  end

  def framework_entry?({module, function, _arity}) do
    cond do
      mix_task?(module) and function == :run -> true
      function in @otp_callbacks -> true
      function in @lv_callbacks -> true
      function in @plug_callbacks -> true
      function in @access_callbacks -> true
      function in @cowboy_websocket_callbacks -> true
      function in @gen_event_callbacks -> true
      liveview_module?(module) and function in @lv_callbacks -> true
      true -> false
    end
  end

  defp mix_task?(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Mix.Tasks.")
  end

  defp liveview_module?(module) do
    module
    |> Atom.to_string()
    |> String.contains?(".Live") or
      String.ends_with?(Atom.to_string(module), "Live")
  end

  def router_entries do
    Config.router_files()
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} -> router_entries_from_content(content)
        _ -> []
      end
    end)
  end

  defp router_entries_from_content(content) do
    scope = router_scope(content)

    plugs =
      Regex.scan(~r/plug\s+:(\w+)/, content)
      |> Enum.map(fn [_, plug] ->
        {Module.concat([scope]), String.to_atom(plug), 2}
      end)

    lives =
      Regex.scan(~r/live\s+"[^"]+",\s+([\w\.]+)(?:,\s+:(\w+))?/, content)
      |> Enum.flat_map(fn
        [_, mod_str] ->
          live_module_entries(resolve_scope_module(scope, mod_str))

        [_, mod_str, _action] ->
          live_module_entries(resolve_scope_module(scope, mod_str))
      end)

    controllers =
      Regex.scan(
        ~r/(?:get|post|put|patch|delete)\s+"[^"]+",\s+([\w\.]+),\s+:(\w+)/,
        content
      )
      |> Enum.map(fn [_, mod_str, action] ->
        {resolve_scope_module(scope, mod_str), String.to_atom(action), 2}
      end)

    plugs ++ lives ++ controllers
  end

  defp router_scope(content) do
    case Regex.run(~r/defmodule\s+([\w\.]+)/, content) do
      [_, mod_str] -> Module.concat([mod_str])
      _ -> Config.default_router_module()
    end
  end

  defp resolve_scope_module(_scope, mod_str) do
    case Config.router_scope_prefix() do
      nil -> Module.concat([mod_str])
      prefix -> Module.concat([prefix, mod_str])
    end
  end

  defp live_module_entries(module) do
    for {callback, arities} <- @liveview_callback_arities,
        arity <- arities do
      {module, callback, arity}
    end
  end

  def modal_entries(source_index) do
    case Config.modal_show_regex() do
      nil ->
        []

      regex ->
        source_index.lib_files
        |> Enum.filter(&String.ends_with?(&1, ".ex"))
        |> Enum.flat_map(fn path ->
          case File.read(path) do
            {:ok, content} -> modal_entries_from_content(content, regex)
            _ -> []
          end
        end)
    end
  end

  defp modal_entries_from_content(content, regex) do
    Regex.scan(regex, content)
    |> Enum.flat_map(fn [_, mod_str] ->
      module = Module.concat([mod_str])

      for callback <- @modal_callbacks, arity <- modal_callback_arities(callback) do
        {module, callback, arity}
      end
    end)
  end

  defp modal_callback_arities(:mount), do: [1]
  defp modal_callback_arities(:update), do: [2]
  defp modal_callback_arities(:render), do: [1]
  defp modal_callback_arities(:parse_msg), do: [2]

  def heex_component_entries(source_index) do
    source_index.lib_files
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} -> component_calls_from_content(content, path)
        _ -> []
      end
    end)
  end

  defp component_calls_from_content(content, path) do
    owner_module = SourceIndex.module_name(path)

    dot_calls =
      Regex.scan(~r/<\.([\w_]+)/, content)
      |> Enum.flat_map(fn [_, name] ->
        if owner_module do
          [{owner_module, String.to_atom(name), 1}]
        else
          []
        end
      end)

    module_calls =
      Regex.scan(~r/\{([\w\.]+)\.([\w_]+)\(/, content)
      |> Enum.map(fn [_, mod_str, fun] ->
        {Module.concat([mod_str]), String.to_atom(fun), 1}
      end)

    dot_calls ++ module_calls
  end

  def partner_entries(source_index) do
    case Config.partner_module_prefix() do
      nil ->
        []

      prefix ->
        source_index.module_to_file
        |> Enum.filter(fn {module, _file} ->
          module
          |> Atom.to_string()
          |> String.starts_with?(prefix)
        end)
        |> Enum.flat_map(fn {module, _file} ->
          for callback <- @partner_callbacks do
            {module, callback, 0}
          end
        end)
    end
  end

  def delegate_entries(source_index, export_set) do
    source_index.lib_files
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} -> delegates_from_content(content, path, export_set)
        _ -> []
      end
    end)
  end

  defp delegates_from_content(content, path, export_set) do
    owner = SourceIndex.module_name(path)

    Regex.scan(~r/defdelegate\s+(\w+)\(([^\)]*)\),\s*to:\s*([\w\.]+)/, content)
    |> Enum.flat_map(fn [_, fun_str, args, target_str] ->
      target = Module.concat([target_str])
      fun = String.to_atom(fun_str)
      arity = args |> String.split(",") |> Enum.reject(&(&1 == "")) |> length()

      source = {owner, fun, arity}
      target_mfa = {target, fun, arity}

      cond do
        MapSet.member?(export_set, target_mfa) -> [source, target_mfa]
        MapSet.member?(export_set, source) -> [source]
        true -> [source]
      end
    end)
  end
end
