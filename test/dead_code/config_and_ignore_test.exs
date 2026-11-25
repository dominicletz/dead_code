defmodule DeadCode.ConfigAndIgnoreTest do
  use ExUnit.Case, async: true

  alias DeadCode.{Analyze, Config, Score}

  test "loads dead_code.exs with entry_points, module_callbacks, scanners, ignore, and max_score" do
    tmp_dir = Path.join(System.tmp_dir!(), "dead_code_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    cfg_path = Path.join(tmp_dir, "dead_code.exs")

    File.write!(cfg_path, """
    [
      max_score: 10,
      entry_points: [
        {DeadCode.Fixtures.Basic, :completely_unused, 1}
      ],
      module_callbacks: [
        {"DeadCode.Fixtures.Partner.", [tagline: 0, logo: 1]}
      ],
      scanners: [
        fn %{lib_files: files} ->
          for path <- files,
              String.ends_with?(path, ".ex"),
              {:ok, content} <- [File.read(path)],
              [_, mod_str] <- Regex.scan(~r/ModalBridge\\.open\\(\\s*([\\w\\.]+)/, content) do
            {Module.concat([mod_str]), :parse_msg, 2}
          end
        end
      ],
      ignore: [
        {DeadCode.Fixtures.MultiA, :unused_a, 1},
        "path:test/support/multi_module_fixtures.ex"
      ]
    ]
    """)

    config = Config.load(config: cfg_path, otp_app: :dead_code)
    assert config.max_score == 10

    analysis =
      Analyze.run(
        config: cfg_path,
        modules: [
          DeadCode.Fixtures.Basic,
          DeadCode.Fixtures.Partner.Alpha,
          DeadCode.Fixtures.ModalSample,
          DeadCode.Fixtures.ModalOpener,
          DeadCode.Fixtures.MultiA,
          DeadCode.Fixtures.MultiB
        ],
        lib_glob: "test/support/**/*.ex",
        test_files: [],
        include_review: true,
        ignore_path: nil
      )

    cats = Map.new(analysis.results, fn %{mfa: mfa, category: c} -> {mfa, c} end)

    assert cats[{DeadCode.Fixtures.Basic, :completely_unused, 1}] == :review
    assert cats[{DeadCode.Fixtures.Partner.Alpha, :tagline, 0}] == :review
    assert cats[{DeadCode.Fixtures.Partner.Alpha, :logo, 1}] == :review
    assert cats[{DeadCode.Fixtures.Partner.Alpha, :unused_partner_fn, 0}] == :likely_dead

    assert cats[{DeadCode.Fixtures.ModalSample, :parse_msg, 2}] == :review
    assert cats[{DeadCode.Fixtures.ModalSample, :unused_modal_fn, 0}] == :likely_dead

    # Ignored via path glob
    refute Map.has_key?(cats, {DeadCode.Fixtures.MultiA, :unused_a, 1})
    refute Map.has_key?(cats, {DeadCode.Fixtures.MultiB, :unused_b, 1})

    # Score check passes within max_score
    assert :ok == Score.check!(analysis.score, config.max_score)
    assert_raise Mix.Error, fn -> Score.check!(analysis.score, 0) end
  end
end
