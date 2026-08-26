defmodule DeadCode.SourceIndex do
  @moduledoc false

  alias DeadCode.Config

  def build do
    lib_files = Path.wildcard(Config.lib_glob())

    module_to_file =
      lib_files
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.reduce(%{}, fn path, acc ->
        case module_name(path) do
          nil -> acc
          module -> Map.put(acc, module, path)
        end
      end)

    %{
      lib_files: lib_files,
      module_to_file: module_to_file
    }
  end

  def module_name(path) do
    case File.read(path) do
      {:ok, content} ->
        case Regex.run(~r/defmodule\s+([\w\.]+)/, content) do
          [_, mod_str] -> Module.concat([mod_str])
          _ -> nil
        end

      _ ->
        nil
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

  def lib_file?(path), do: String.starts_with?(normalize_path(path), "lib/")
  def test_file?(path), do: String.starts_with?(normalize_path(path), "test/")

  def modules_for_path_pattern(pattern, module_to_file) do
    glob =
      pattern
      |> String.replace_prefix("path:", "")
      |> String.replace("\\", "/")

    Path.wildcard(glob)
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.map(&module_name/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
    |> then(fn modules ->
      module_to_file
      |> Map.filter(fn {_mod, file} -> file in Path.wildcard(glob) end)
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(modules)
    end)
    |> MapSet.to_list()
  end
end
