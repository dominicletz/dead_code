# dead_code

Find unused public `def` functions using BEAM `debug_info` call graphs, AST test reference scanning, `@behaviour`/protocol/router introspection, and project-local configuration in `dead_code.exs`.

## Installation

```elixir
# mix.exs
{:dead_code, github: "dominicletz/dead_code", tag: "v0.2.0", only: :dev, runtime: false}
```

## Usage

From your host project:

```bash
mix dead_code.public
mix dead_code.public --only-likely-dead
mix dead_code.public --include-review
mix dead_code.public --module MyApp.Accounts
mix dead_code.public --verify MyApp.Accounts.create/1
mix dead_code.check
```

The **dead code score** is the count of `:likely_dead` public functions. Configure `:max_score` in `dead_code.exs` and run `mix dead_code.check` in CI to block regressions.

## Configuration (`dead_code.exs`)

Place a `dead_code.exs` (or `.dead_code.exs`) file at the root of your host project:

```elixir
[
  otp_app: :my_app,
  max_score: 25,
  routers: [MyAppWeb.Router],
  entry_points: [
    {MyAppWeb.RPC, :_, :_}
  ],
  module_callbacks: [
    {"MyAppWeb.Plugins.", [name: 0, render: 1]}
  ],
  scanners: [
    fn %{lib_files: files} ->
      for path <- files,
          String.ends_with?(path, ".ex"),
          {:ok, content} <- [File.read(path)],
          [_, mod] <- Regex.scan(~r/DynamicModal\.open\(\s*([\w\.]+)/, content) do
        {Module.concat([mod]), :parse_msg, 2}
      end
    end
  ],
  ignore: [
    "path:lib/mix/tasks/**",
    {MyApp.LegacyBridge}
  ]
]
```

Optional keys:

| Key | Default | Purpose |
|-----|---------|---------|
| `otp_app` | host `Mix.Project` app | Application whose modules are analyzed |
| `lib_glob` | `"lib/**/*.{ex,heex}"` | Source files passed to scanners and `use` dispatch scanning |
| `test_glob` | `"test/**/*.{ex,exs}"` | Test files scanned for AST call references |
| `report_dir` | `"priv/reports"` | Report output directory |
| `routers` | `[]` | Phoenix router modules (auto-discovers `__routes__/0` modules too) |
| `entry_points` | `[]` | Extra dynamic MFAs (`{Mod, :fun, arity}`, `{Mod, :fun, :_}`, `{Mod, :_, :_}`) |
| `module_callbacks` | `[]` | `{prefix_or_regex, [{fun, arity}]}` for convention-based plugin modules |
| `scanners` | `[]` | Custom 1-arity `fn context -> [mfa] end` entry-point scanners |
| `ignore` | `[]` | Suppressions (`{Mod}`, `{Mod, :fun, arity}`, `{Mod, :fun, :_}`, `"path:glob"`) |
| `max_score` | `nil` | Fail `mix dead_code.check` when score exceeds this value |

## Report buckets

- `likely_dead` — no BEAM or test callers, not an entry point
- `test_only` — callers only in `test/`
- `review` — `@behaviour`/protocol/router/configured entry points without BEAM callers (excluded by default)

Use `--include-review` to include the review bucket.
