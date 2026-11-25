defmodule DeadCode.TestReferencesTest do
  use ExUnit.Case, async: true

  alias DeadCode.{CollectExports, Config, TestReferences}

  @fixture_modules [DeadCode.Fixtures.TestTargets]

  test "tracks exact arities across aliases, pipes, captures, imports, defaults, and apply/3" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "dead_code_test_refs_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    test_file = Path.join(tmp_dir, "targets_test.exs")

    File.write!(test_file, """
    defmodule TargetsSampleTest do
      use ExUnit.Case

      alias DeadCode.Fixtures.TestTargets
      alias DeadCode.Fixtures.TestTargets, as: TT
      import DeadCode.Fixtures.TestTargets, only: [imported_two: 2]

      test "exercises various call forms" do
        TestTargets.zero_arity()
        TestTargets.one_arity(1)
        TT.two_arity(1, 2)
        1 |> TT.piped_two(2)
        TestTargets.defaulted_in_test(:only_one)
        imported_two(:a, :b)
        _cap = &TestTargets.captured_three/3
        apply(TestTargets, :apply_two, [:a, :b])
      end
    end
    """)

    config = Config.load(otp_app: :dead_code)
    collected = CollectExports.collect(config, modules: @fixture_modules)
    callers = TestReferences.callers_by_callee(config, collected, test_files: [test_file])

    assert Map.has_key?(callers, {DeadCode.Fixtures.TestTargets, :zero_arity, 0})
    assert Map.has_key?(callers, {DeadCode.Fixtures.TestTargets, :one_arity, 1})
    assert Map.has_key?(callers, {DeadCode.Fixtures.TestTargets, :two_arity, 2})
    assert Map.has_key?(callers, {DeadCode.Fixtures.TestTargets, :piped_two, 2})
    # Default-arg function called at /1 canonicalizes to /2
    assert Map.has_key?(callers, {DeadCode.Fixtures.TestTargets, :defaulted_in_test, 2})
    assert Map.has_key?(callers, {DeadCode.Fixtures.TestTargets, :imported_two, 2})
    assert Map.has_key?(callers, {DeadCode.Fixtures.TestTargets, :captured_three, 3})
    assert Map.has_key?(callers, {DeadCode.Fixtures.TestTargets, :apply_two, 2})

    # Must NOT falsely credit never_called_one/1 or piped_two/1
    refute Map.has_key?(callers, {DeadCode.Fixtures.TestTargets, :never_called_one, 1})
    refute Map.has_key?(callers, {DeadCode.Fixtures.TestTargets, :piped_two, 1})
  end
end
