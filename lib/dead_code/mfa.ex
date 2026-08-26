defmodule DeadCode.MFA do
  @moduledoc false

  @type t :: {module(), atom(), non_neg_integer()}

  def format({module, function, arity}) do
    "#{inspect(module)}.#{function}/#{arity}"
  end

  def parse(string) when is_binary(string) do
    string |> String.trim() |> parse_slash()
  end

  defp parse_slash(string) do
    case Regex.run(~r/^(.+)\.([^\/]+)\/(\d+)$/, string) do
      [_, mod_str, fun_str, arity_str] ->
        with {:ok, module} <- quoted_atom_module(mod_str),
             {:ok, function} <- quoted_atom(fun_str),
             {arity, ""} <- Integer.parse(arity_str) do
          {:ok, {module, function, arity}}
        else
          _ -> {:error, :invalid_mfa}
        end

      _ ->
        {:error, :invalid_mfa}
    end
  end

  defp quoted_atom_module(string) do
    case Code.string_to_quoted(string) do
      {:ok, module} when is_atom(module) ->
        {:ok, module}

      {:ok, {:__aliases__, _, parts}} ->
        {:ok, Module.concat(parts)}

      _ ->
        {:error, :invalid_module}
    end
  end

  defp quoted_atom(string) do
    case Code.string_to_quoted(":" <> string) do
      {:ok, atom} when is_atom(atom) -> {:ok, atom}
      _ -> {:error, :invalid_function}
    end
  end

  def export_name?(name) when is_atom(name) do
    name_str = Atom.to_string(name)

    not String.starts_with?(name_str, "__") and
      name not in [:module_info, :behaviour_info]
  end
end
