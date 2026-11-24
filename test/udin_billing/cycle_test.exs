defmodule UdinBilling.CycleTest do
  use ExUnit.Case, async: true

  alias UdinBilling.Cycle

  @anchor ~U[2026-01-31 10:00:00Z]

  test "monthly cycles shift from the original anchor without drifting" do
    assert {:ok, %{index: 0, starts_at: @anchor, ends_at: ~U[2026-02-28 10:00:00Z]}} =
             Cycle.window(@anchor, :month, 1, nil, ~U[2026-02-10 00:00:00Z])

    assert {:ok,
            %{index: 1, starts_at: ~U[2026-02-28 10:00:00Z], ends_at: ~U[2026-03-31 10:00:00Z]}} =
             Cycle.window(@anchor, :month, 1, nil, ~U[2026-03-15 00:00:00Z])

    assert {:ok, %{index: 2, starts_at: ~U[2026-03-31 10:00:00Z]}} =
             Cycle.window(@anchor, :month, 1, nil, ~U[2026-03-31 10:00:00Z])
  end

  test "a cycle boundary belongs to the next cycle" do
    assert {:ok, %{index: 1}} = Cycle.window(@anchor, :month, 1, nil, ~U[2026-02-28 10:00:00Z])
    assert {:ok, %{index: 0}} = Cycle.window(@anchor, :month, 1, nil, ~U[2026-02-28 09:59:59Z])
  end

  test "days, weeks, years and multiples" do
    assert {:ok, %{index: 3}} = Cycle.window(@anchor, :day, 1, nil, ~U[2026-02-03 11:00:00Z])

    assert {:ok, %{index: 2, starts_at: ~U[2026-02-28 10:00:00Z]}} =
             Cycle.window(@anchor, :week, 2, nil, ~U[2026-03-01 00:00:00Z])

    assert {:ok, %{index: 1, starts_at: ~U[2027-01-31 10:00:00Z]}} =
             Cycle.window(@anchor, :year, 1, nil, ~U[2027-06-01 00:00:00Z])

    assert {:ok, %{index: 1, starts_at: ~U[2026-04-30 10:00:00Z]}} =
             Cycle.window(@anchor, :month, 3, nil, ~U[2026-05-01 00:00:00Z])
  end

  test "a yearly plan with monthly cycles ends its last cycle at access end" do
    ends = ~U[2027-01-31 10:00:00Z]

    assert {:ok, %{index: 11, ends_at: ^ends}} =
             Cycle.window(@anchor, :month, 1, ends, ~U[2027-01-15 00:00:00Z])
  end

  test "no cycle unit means one cycle for the whole access period" do
    ends = ~U[2026-02-07 10:00:00Z]

    assert {:ok, %{index: 0, starts_at: @anchor, ends_at: ^ends}} =
             Cycle.window(@anchor, nil, nil, ends, ~U[2026-02-01 00:00:00Z])

    assert {:ok, %{ends_at: nil}} = Cycle.window(@anchor, nil, nil, nil, ~U[2030-01-01 00:00:00Z])
  end

  test "before the start or at/after the end there is no cycle" do
    assert :none = Cycle.window(@anchor, :month, 1, nil, ~U[2026-01-31 09:59:59Z])

    assert :none =
             Cycle.window(@anchor, :month, 1, ~U[2026-02-07 10:00:00Z], ~U[2026-02-07 10:00:00Z])
  end
end
