defmodule DeadCode.CollectExports do
  @moduledoc false

  alias DeadCode.{Config, MFA}

  def all(opts \\ []) do
    module_filter = Keyword.get(opts, :module)
    source_index = Keyword.get(opts, :source_index, DeadCode.SourceIndex.build())
    otp_app = Keyword.get(opts, :otp_app, Config.otp_app())

    modules =
      if otp_app do
        case :application.get_key(otp_app, :modules) do
          {:ok, mods} -> mods
          :undefined -> []
        end
      else
        []
      end

    modules
    |> Enum.sort()
    |> Enum.flat_map(&exports_for(&1, source_index))
    |> Enum.filter(fn %{file: file} -> is_binary(file) end)
    |> maybe_filter_module(module_filter)
  end

  defp exports_for(module, source_index) do
    with {:module, _} <- Code.ensure_loaded(module),
         exports when is_list(exports) <- module.module_info(:exports) do
      exports
      |> Enum.filter(fn {name, _arity} -> MFA.export_name?(name) end)
      |> Enum.map(fn {name, arity} ->
        %{
          mfa: {module, name, arity},
          file: Map.get(source_index.module_to_file, module)
        }
      end)
    else
      _ -> []
    end
  end

  defp maybe_filter_module(exports, nil), do: exports

  defp maybe_filter_module(exports, module) when is_atom(module) do
    Enum.filter(exports, fn %{mfa: {mod, _, _}} -> mod == module end)
  end
end
