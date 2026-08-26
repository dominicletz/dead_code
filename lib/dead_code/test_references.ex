defmodule DeadCode.TestReferences do
  @moduledoc false

  alias DeadCode.Config

  def callers_by_callee(exports) do
    modules = exports |> Enum.map(fn %{mfa: {mod, _, _}} -> mod end) |> MapSet.new()

    Path.wildcard(Config.test_glob())
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} -> references_from_content(content, path, modules)
        _ -> []
      end
    end)
    |> Enum.group_by(fn ref -> ref.callee end)
  end

  defp references_from_content(content, path, modules) do
    dot_calls =
      Regex.scan(~r/([\w\.]+)\.([\w_]+)\(/, content)
      |> Enum.flat_map(fn [_, mod_str, fun_str] ->
        module = Module.concat([mod_str])

        if MapSet.member?(modules, module) do
          fun = String.to_atom(fun_str)
          arity = 1

          [
            %{
              callee: {module, fun, arity},
              caller_module: nil,
              file: path,
              line: line_for_match(content, mod_str <> "." <> fun_str <> "(")
            }
          ]
        else
          []
        end
      end)

    apply_calls =
      Regex.scan(~r/apply\(\s*([\w\.]+)\s*,\s*:(\w+)/, content)
      |> Enum.flat_map(fn [_, mod_str, fun_str] ->
        module = Module.concat([mod_str])

        if MapSet.member?(modules, module) do
          [
            %{
              callee: {module, String.to_atom(fun_str), 1},
              caller_module: nil,
              file: path,
              line: line_for_match(content, "apply(" <> mod_str)
            }
          ]
        else
          []
        end
      end)

    dot_calls ++ apply_calls
  end

  defp line_for_match(content, needle) do
    content
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, needle))
    |> case do
      nil -> 0
      idx -> idx + 1
    end
  end

  def merge_callers(xref_callers, test_callers) do
    Map.merge(xref_callers, test_callers, fn _callee, xref, test ->
      (xref || []) ++ (test || [])
    end)
  end
end
