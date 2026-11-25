defmodule DeadCode.Fixtures.DelegateTarget do
  def delegated_used(x), do: x + 1
  def delegated_unused(x), do: x + 2
end

defmodule DeadCode.Fixtures.Basic do
  def entry_caller do
    val = local_helper(1)
    list = Enum.map([1, 2], &local_captured/1)
    _ = guard_helper(val)
    _ = apply(DeadCode.Fixtures.Basic, :applied_literal, [1])
    _ = Task.start(DeadCode.Fixtures.Basic, :task_target, [:ok])
    _ = apply(DeadCode.Fixtures.Basic, :applied_dynamic, dynamic_args())
    {val, list}
  end

  defp dynamic_args, do: [1, 2]

  def local_helper(x) when x > 0, do: x * 2
  def local_captured(x), do: x + 10
  def guard_helper(x) when is_integer(x), do: x
  def applied_literal(x), do: x
  def applied_dynamic(a, b), do: a + b
  def task_target(arg), do: arg

  defdelegate delegated(x), to: DeadCode.Fixtures.DelegateTarget, as: :delegated_used

  def self_recursive_dead(0), do: :done
  def self_recursive_dead(n), do: self_recursive_dead(n - 1)

  def completely_unused(x), do: x
end

defmodule DeadCode.Fixtures.BasicCaller do
  def trigger do
    {DeadCode.Fixtures.Basic.entry_caller(), DeadCode.Fixtures.Basic.delegated(5)}
  end
end

defmodule DeadCode.Fixtures.Defaults do
  def caller do
    {used_via_min(10), used_via_max(1, 2)}
  end

  def used_via_min(a, b \\ 1), do: a + b
  def used_via_max(a, b \\ 2), do: a + b
  def unused_with_default(a, b \\ 3), do: a + b
end

defmodule DeadCode.Fixtures.MacroHelper do
  def called_from_macro_injection(x), do: {:macro_ok, x}
  def not_called_anywhere(x), do: x
end

defmodule DeadCode.Fixtures.Macros do
  defmacro __using__(_opts) do
    quote do
      def injected_fn(x) do
        DeadCode.Fixtures.MacroHelper.called_from_macro_injection(x)
      end
    end
  end

  defmacro custom_macro(x) do
    quote do
      {:custom, unquote(x)}
    end
  end
end

defmodule DeadCode.Fixtures.MacroConsumer do
  use DeadCode.Fixtures.Macros
  import DeadCode.Fixtures.Macros

  def run(x) do
    _ = custom_macro(x)
    injected_fn(x)
  end
end

defmodule DeadCode.Fixtures.WebMacro do
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  def controller do
    quote do
      def web_kind, do: :controller
    end
  end

  def unused_kind do
    quote do
      def unused_web_kind, do: :unused
    end
  end
end

defmodule DeadCode.Fixtures.WebMacroConsumer do
  use DeadCode.Fixtures.WebMacro, :controller
end

defmodule DeadCode.Fixtures.CustomBehaviour do
  @callback required_cb(term()) :: term()
  @callback optional_cb(term()) :: term()
  @optional_callbacks optional_cb: 1
end

defmodule DeadCode.Fixtures.BehaviourImpl do
  @behaviour DeadCode.Fixtures.CustomBehaviour

  @impl true
  def required_cb(x), do: x

  @impl true
  def optional_cb(x), do: x

  def extra_unused(x), do: x
end

defprotocol DeadCode.Fixtures.Proto do
  def serialize(data)
end

defmodule DeadCode.Fixtures.ProtoStruct do
  defstruct [:value]
end

defimpl DeadCode.Fixtures.Proto, for: DeadCode.Fixtures.ProtoStruct do
  def serialize(%{value: value}), do: to_string(value)
end

defmodule DeadCode.Fixtures.FakeController do
  def show(conn, _params), do: conn
  def unused_action(conn, _params), do: conn
end

defmodule DeadCode.Fixtures.FakeLive do
  def mount(_params, _session, socket), do: {:ok, socket}
  def render(assigns), do: assigns
  def unused_helper(x), do: x
end

defmodule DeadCode.Fixtures.FakeRouter do
  def __routes__ do
    [
      %{
        plug: DeadCode.Fixtures.FakeController,
        plug_opts: :show,
        metadata: %{}
      },
      %{
        plug: Phoenix.LiveView.Plug,
        plug_opts: DeadCode.Fixtures.FakeLive,
        metadata: %{
          phoenix_live_view: {DeadCode.Fixtures.FakeLive, :index, [], %{}}
        }
      }
    ]
  end
end

defmodule DeadCode.Fixtures.Partner.Alpha do
  def tagline, do: "Alpha"
  def logo(assigns), do: assigns
  def unused_partner_fn, do: :nope
end

defmodule DeadCode.Fixtures.ModalSample do
  def parse_msg(msg, _args), do: msg
  def unused_modal_fn, do: :nope
end

defmodule DeadCode.Fixtures.ModalBridge do
  def open(mod), do: mod
end

defmodule DeadCode.Fixtures.ModalOpener do
  def open do
    # Matched by custom scanner in tests
    DeadCode.Fixtures.ModalBridge.open(DeadCode.Fixtures.ModalSample)
  end
end

defmodule DeadCode.Fixtures.OtpWorker do
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}

  def unused_worker_helper, do: :dead
end

defmodule DeadCode.Fixtures.TestTargets do
  def zero_arity, do: :zero
  def one_arity(a), do: a
  def two_arity(a, b), do: {a, b}
  def piped_two(a, b), do: {a, b}
  def defaulted_in_test(a, b \\ :default), do: {a, b}
  def imported_two(a, b), do: {a, b}
  def captured_three(a, b, c), do: {a, b, c}
  def apply_two(a, b), do: {a, b}
  def never_called_one(_a), do: :dead
end
