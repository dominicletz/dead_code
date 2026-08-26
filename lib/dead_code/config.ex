defmodule DeadCode.Config do
  @moduledoc false

  def otp_app do
    Application.get_env(:dead_code, :otp_app) || Mix.Project.config()[:app]
  end

  def get(key, default \\ nil) do
    Application.get_env(:dead_code, key, default)
  end

  def lib_glob, do: get(:lib_glob, "lib/**/*.{ex,heex}")
  def test_glob, do: get(:test_glob, "test/**/*.{ex,exs}")
  def report_dir, do: get(:report_dir, "priv/reports")
  def router_files, do: get(:router_files, [])
  def router_scope_prefix, do: get(:router_scope_prefix)
  def default_router_module, do: get(:default_router_module)
  def rpc_handlers, do: get(:rpc_handlers, [])
  def partner_module_prefix, do: get(:partner_module_prefix)
  def modal_show_regex, do: get(:modal_show_regex)
  def max_score, do: get(:max_score)
end
