defmodule DeadCode.MFATest do
  use ExUnit.Case, async: true

  alias DeadCode.MFA

  test "format/1 and parse/1 round-trip standard, predicate, bang, and special names" do
    samples = [
      {MyApp.Accounts, :create, 2},
      {MyApp.Accounts, :valid?, 1},
      {MyApp.Accounts, :save!, 1},
      {:lists, :reverse, 1}
    ]

    for mfa <- samples do
      formatted = MFA.format(mfa)
      assert {:ok, ^mfa} = MFA.parse(formatted)
    end
  end

  test "parse/1 returns error for malformed inputs" do
    assert {:error, :invalid_mfa} = MFA.parse("not_an_mfa")
    assert {:error, :invalid_mfa} = MFA.parse("MyApp.Foo.bar")
    assert {:error, :invalid_mfa} = MFA.parse("MyApp.Foo.bar/abc")
  end

  test "parse_module/1 handles Elixir aliases and Erlang module atoms" do
    assert {:ok, DeadCode.MFA} = MFA.parse_module("DeadCode.MFA")
    assert {:ok, :lists} = MFA.parse_module(":lists")
    assert {:error, :invalid_module} = MFA.parse_module("123invalid")
  end

  test "export_name?/1 excludes compiler and macro internal names" do
    assert MFA.export_name?(:foo)
    assert MFA.export_name?(:valid?)
    refute MFA.export_name?(:__struct__)
    refute MFA.export_name?(:__info__)
    refute MFA.export_name?(:"MACRO-__using__")
    refute MFA.export_name?(:module_info)
    refute MFA.export_name?(:behaviour_info)
  end
end
