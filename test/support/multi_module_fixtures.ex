defmodule DeadCode.Fixtures.MultiA do
  def call_b(x), do: DeadCode.Fixtures.MultiB.used_by_a(x)
  def unused_a(x), do: x
end

defmodule DeadCode.Fixtures.MultiB do
  def used_by_a(x), do: x + 1
  def unused_b(x), do: x
end
