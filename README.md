# dead_code

Find unused public `def` functions using compile-time xref call graphs plus Phoenix/OTP entry-point heuristics.

## Installation

```elixir
# mix.exs
{:dead_code, github: "dominicletz/dead_code", only: :dev, runtime: false}
```

## Usage

From your host project:

```bash
mix dead_code.public
mix dead_code.public --only-likely-dead
mix dead_code.public --include-review
mix dead_code.public --verify MyApp.MyModule.foo/2
mix dead_code.check
```

The **dead code score** is the count of `:likely_dead` public functions. Configure `:max_score`
and run `mix dead_code.check` in CI to block regressions.

Add project-specific suppressions in `.dead_code_ignore.exs` at the host project root.

## Configuration

Configure the host project in `config/config.exs` (or an imported file):

```elixir
config :dead_code,
  otp_app: :my_app,
  router_files: ["lib/my_app_web/router.ex"],
  router_scope_prefix: "MyAppWeb",
  default_router_module: MyAppWeb.Router,
  partner_module_prefix: "Elixir.MyAppWeb.Partners.",
  modal_show_regex: ~r/MyModals\.show\(\s*([\w\.]+)/,
  rpc_handlers: [{MyAppWeb.RPC, :handle_request, 2}],
  max_score: 950
```

Optional keys:

| Key | Default | Purpose |
|-----|---------|---------|
| `otp_app` | host `Mix.Project` app | Application whose modules are analyzed |
| `lib_glob` | `lib/**/*.{ex,heex}` | Source files indexed |
| `test_glob` | `test/**/*.{ex,exs}` | Test reference scan |
| `report_dir` | `priv/reports` | Report output directory |
| `router_files` | `[]` | Phoenix router paths to scan |
| `router_scope_prefix` | `nil` | Prefix for scoped live/controller modules |
| `default_router_module` | `nil` | Fallback router module atom |
| `rpc_handlers` | `[]` | Extra dynamic RPC entry MFAs |
| `partner_module_prefix` | `nil` | Module prefix for optional plugin callbacks |
| `modal_show_regex` | `nil` | Regex with capture group 1 = modal module |
| `max_score` | `nil` | Fail `mix dead_code.check` when score exceeds this value |

## Report buckets

- `likely_dead` — no lib/test callers, not an entry point
- `test_only` — callers only in `test/`
- `review` — framework/router/modal/RPC entry points without xref callers (excluded by default)

Use `--include-review` to include the review bucket.
