defmodule DeadCode.SourceIndex do
  @moduledoc false

  alias DeadCode.Config

  def build(config \\ nil, opts \\ []) do
    config = config || Config.load(opts)
    lib_files = Path.wildcard(config.lib_glob) |> Enum.map(&normalize_path/1)

    module_to_file =
      Keyword.get_lazy(opts, :module_to_file, fn ->
        build_module_to_file(config, opts)
      end)

    %{
      lib_files: lib_files,
      module_to_file: module_to_file
    }
  end

  defp build_module_to_file(config, opts) do
    modules = resolve_modules(config, opts)

    Enum.reduce(modules, %{}, fn module, acc ->
      case module_file(module) do
        nil -> acc
        file -> Map.put(acc, module, file)
      end
    end)
  end

  def resolve_modules(config, opts \\ []) do
    case Keyword.get(opts, :modules) do
      mods when is_list(mods) ->
        mods

      nil ->
        case config.otp_app do
          nil ->
            []

          otp_app ->
            ensure_app_loaded(otp_app)

            case :application.get_key(otp_app, :modules) do
              {:ok, mods} -> mods
              :undefined -> []
            end
        end
    end
  end

  def ensure_app_loaded(otp_app) do
    case Application.load(otp_app) do
      :ok -> :ok
      {:error, {:already_loaded, _}} -> :ok
      _ -> :ok
    end
  end

  def module_file(module) do
    case beam_debug_info(module) do
      {:ok, %{file: file}} when is_binary(file) or is_list(file) ->
        normalize_path(to_string(file))

      _ ->
        with {:module, _} <- Code.ensure_loaded(module),
             compile_info when is_list(compile_info) <- module.module_info(:compile),
             source when is_list(source) or is_binary(source) <-
               Keyword.get(compile_info, :source) do
          normalize_path(to_string(source))
        else
          _ -> nil
        end
    end
  end

  def beam_debug_info(module) do
    with [_ | _] = path <- :code.which(module),
         {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(path, [:debug_info]),
         {:ok, info} <- backend.debug_info(:elixir_v1, module, data, []) do
      {:ok, info}
    else
      _ -> :error
    end
  end

  def normalize_path(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> then(fn p ->
      case Path.relative_to(p, File.cwd!()) do
        rel when rel != p -> rel
        _ -> p
      end
    end)
  end

  def normalize_path(path) when is_list(path), do: path |> to_string() |> normalize_path()

  def lib_file?(path), do: String.starts_with?(normalize_path(path), "lib/")
  def test_file?(path), do: String.starts_with?(normalize_path(path), "test/")

  def modules_for_path_pattern(pattern, module_to_file) do
    glob =
      pattern
      |> String.replace_prefix("path:", "")
      |> String.replace("\\", "/")

    matched_files =
      Path.wildcard(glob)
      |> MapSet.new(&normalize_path/1)

    module_to_file
    |> Enum.filter(fn {_mod, file} -> MapSet.member?(matched_files, normalize_path(file)) end)
    |> Enum.map(fn {mod, _file} -> mod end)
  end
end
