defmodule DeadCode.AnalyzeTest do
  use ExUnit.Case, async: true

  alias DeadCode.Analyze

  @fixture_modules [
    DeadCode.Fixtures.DelegateTarget,
    DeadCode.Fixtures.Basic,
    DeadCode.Fixtures.BasicCaller,
    DeadCode.Fixtures.Defaults,
    DeadCode.Fixtures.MacroHelper,
    DeadCode.Fixtures.Macros,
    DeadCode.Fixtures.MacroConsumer,
    DeadCode.Fixtures.WebMacro,
    DeadCode.Fixtures.WebMacroConsumer,
    DeadCode.Fixtures.CustomBehaviour,
    DeadCode.Fixtures.BehaviourImpl,
    DeadCode.Fixtures.Proto,
    DeadCode.Fixtures.ProtoStruct,
    DeadCode.Fixtures.Proto.DeadCode.Fixtures.ProtoStruct,
    DeadCode.Fixtures.FakeController,
    DeadCode.Fixtures.FakeLive,
    DeadCode.Fixtures.FakeRouter,
    DeadCode.Fixtures.MultiA,
    DeadCode.Fixtures.MultiB,
    DeadCode.Fixtures.OtpWorker
  ]

  defp analyze_fixtures(extra_opts \\ []) do
    opts =
      Keyword.merge(
        [
          modules: @fixture_modules,
          lib_glob: "test/support/**/*.ex",
          test_files: [],
          include_review: true,
          ignore_path: nil
        ],
        extra_opts
      )

    Analyze.run(opts)
  end

  defp category_map(analysis) do
    Map.new(analysis.results, fn %{mfa: mfa, category: category} -> {mfa, category} end)
  end

  test "detects local calls, local captures, delegates, apply/3, Task.start/3, and catches self-recursion" do
    cats = analyze_fixtures() |> category_map()

    # entry_caller/0 is called by BasicCaller.trigger/0
    refute Map.has_key?(cats, {DeadCode.Fixtures.Basic, :entry_caller, 0})
    # Local calls and captures inside Basic are :used (absent from results)
    refute Map.has_key?(cats, {DeadCode.Fixtures.Basic, :local_helper, 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Basic, :local_captured, 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Basic, :guard_helper, 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Basic, :applied_literal, 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Basic, :applied_dynamic, 2})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Basic, :task_target, 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Basic, :delegated, 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.DelegateTarget, :delegated_used, 1})

    # Unused delegate target, self-recursive dead function, and dead helper are :likely_dead
    assert cats[{DeadCode.Fixtures.DelegateTarget, :delegated_unused, 1}] == :likely_dead
    assert cats[{DeadCode.Fixtures.Basic, :self_recursive_dead, 1}] == :likely_dead
    assert cats[{DeadCode.Fixtures.Basic, :completely_unused, 1}] == :likely_dead
  end

  test "groups default-argument families cleanly without sibling false positives" do
    cats = analyze_fixtures() |> category_map()

    # Neither /1 nor /2 of used_via_min or used_via_max should appear as dead
    refute Map.has_key?(cats, {DeadCode.Fixtures.Defaults, :used_via_min, 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Defaults, :used_via_min, 2})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Defaults, :used_via_max, 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Defaults, :used_via_max, 2})

    # unused_with_default counts once at canonical arity /2, not duplicated at /1
    assert cats[{DeadCode.Fixtures.Defaults, :unused_with_default, 2}] == :likely_dead
    refute Map.has_key?(cats, {DeadCode.Fixtures.Defaults, :unused_with_default, 1})
  end

  test "excludes macro-injected defs and MACRO-* exports while tracking calls made inside injected code" do
    cats = analyze_fixtures() |> category_map()

    refute Map.has_key?(cats, {DeadCode.Fixtures.MacroConsumer, :injected_fn, 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Macros, :"MACRO-custom_macro", 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.Macros, :"MACRO-__using__", 1})

    # Helper called from injected_fn/1 is :used; uncalled helper is :likely_dead
    refute Map.has_key?(cats, {DeadCode.Fixtures.MacroHelper, :called_from_macro_injection, 1})
    assert cats[{DeadCode.Fixtures.MacroHelper, :not_called_anywhere, 1}] == :likely_dead
  end

  test "tracks use Mod, :which compile-time dispatch" do
    cats = analyze_fixtures() |> category_map()

    refute Map.has_key?(cats, {DeadCode.Fixtures.WebMacro, :controller, 0})
    assert cats[{DeadCode.Fixtures.WebMacro, :unused_kind, 0}] == :likely_dead
  end

  test "recognizes @behaviour callbacks (including optional), OTP child start_link, and protocol implementations as :review" do
    cats = analyze_fixtures() |> category_map()

    assert cats[{DeadCode.Fixtures.BehaviourImpl, :required_cb, 1}] == :review
    assert cats[{DeadCode.Fixtures.BehaviourImpl, :optional_cb, 1}] == :review
    assert cats[{DeadCode.Fixtures.BehaviourImpl, :extra_unused, 1}] == :likely_dead

    assert cats[{DeadCode.Fixtures.OtpWorker, :start_link, 1}] == :review
    assert cats[{DeadCode.Fixtures.OtpWorker, :init, 1}] == :review
    assert cats[{DeadCode.Fixtures.OtpWorker, :unused_worker_helper, 0}] == :likely_dead

    assert cats[{DeadCode.Fixtures.Proto.DeadCode.Fixtures.ProtoStruct, :serialize, 1}] == :review
  end

  test "introspects __routes__/0 routers for controller actions and LiveView callbacks" do
    cats = analyze_fixtures() |> category_map()

    assert cats[{DeadCode.Fixtures.FakeController, :show, 2}] == :review
    assert cats[{DeadCode.Fixtures.FakeController, :unused_action, 2}] == :likely_dead

    assert cats[{DeadCode.Fixtures.FakeLive, :mount, 3}] == :review
    assert cats[{DeadCode.Fixtures.FakeLive, :render, 1}] == :review
    assert cats[{DeadCode.Fixtures.FakeLive, :unused_helper, 1}] == :likely_dead
  end

  test "discovers multiple modules defined in the same source file" do
    cats = analyze_fixtures() |> category_map()

    refute Map.has_key?(cats, {DeadCode.Fixtures.MultiB, :used_by_a, 1})
    assert cats[{DeadCode.Fixtures.MultiA, :unused_a, 1}] == :likely_dead
    assert cats[{DeadCode.Fixtures.MultiB, :unused_b, 1}] == :likely_dead
  end

  test "categorizes entry points called in tests as :review rather than :test_only" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "dead_code_review_prec_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    test_file = Path.join(tmp_dir, "behaviour_test.exs")

    File.write!(test_file, """
    defmodule BehaviourPrecTest do
      test "calls behaviour callback" do
        DeadCode.Fixtures.BehaviourImpl.required_cb(:ok)
      end
    end
    """)

    cats =
      analyze_fixtures(
        modules: [DeadCode.Fixtures.CustomBehaviour, DeadCode.Fixtures.BehaviourImpl],
        test_files: [test_file]
      )
      |> category_map()

    assert cats[{DeadCode.Fixtures.BehaviourImpl, :required_cb, 1}] == :review
  end

  test "verify/2 reports accurate category and callers" do
    res =
      Analyze.verify("DeadCode.Fixtures.Basic.local_helper/1",
        modules: @fixture_modules,
        lib_glob: "test/support/**/*.ex",
        test_files: [],
        ignore_path: nil
      )

    assert res.category == :used
    assert length(res.callers) == 1
  end
end
