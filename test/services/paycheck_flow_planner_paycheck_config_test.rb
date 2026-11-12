require "test_helper"

# (Direct Deposit): the planner's paycheck-config overlay.
# Covers the no-op invariant (zero config rows = the SAME incomes array
# untouched), the date math vs the house Schedule engine (semi-monthly =
# 15th + last day, 24x/yr; biweekly = 14-day stride from the anchor, 26x/yr),
# the replace/append paths, and the invariant (allocation "wanted" is
# IMMUTABLE to the overlay; the inflow changes when the gross changes).
class PaycheckFlowPlannerPaycheckConfigTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @member = users(:family_member)
    @admin = users(:family_admin)
    @account = accounts(:depository)
    travel_to Date.new(2026, 11, 15)

    # The member's labeled income series with two stored November
    # occurrences (the house Nov 6 / Nov 20 paycheck window).
    @series = @family.recurring_transactions.create!(
      name: "Paycheck", account: @account, amount: 1200, currency: "USD",
      expected_day_of_month: 6, last_occurrence_date: Date.new(2026, 9, 6),
      next_expected_date: Date.new(2026, 12, 20), status: "active",
      bill_type: "income", manual: true, plan_owner: @member
    )
    # The creation pipeline auto-generates occurrences; the house test
    # pattern (api/v1/paycheck_plans_controller_test.rb) clears them and
    # pins the exact window (Nov 6 / Nov 20).
    @series.recurring_occurrences.destroy_all
    [ Date.new(2026, 11, 6), Date.new(2026, 11, 20) ].each do |due_on|
      @family.recurring_occurrences.create!(
        recurring_transaction: @series, due_on: due_on,
        original_due_on: due_on, currency: "USD", expected_amount: 1200,
        status: "scheduled"
      )
    end

    # Edge: the full paycheck (percent 1.0) flows to the bank — so the
    # bank's inflow tracks the paycheck amounts.
    @family.income_account_allocations.create!(
      income_series: @series, account: @account, mode: "percent", value: 1.0
    )
    # A per-paycheck "wanted" that must NOT move when the overlay changes
    # the paycheck amounts.
    @family.plan_allocations.create!(
      account: @account, name: "Rent", cadence: "monthly",
      kind: "bill", mode: "specific", value_cents: 50_000
    )
  end

  def teardown
    travel_back
  end

  def inputs_for
    PaycheckFlowPlanner.inputs_for(family: @family, month: Date.new(2026, 11, 15))
  end

  def config_for(**attrs)
    @family.family_paycheck_configs.create!(
      user: @member, recurring_transaction: @series,
      gross_per_paycheck_cents: 200_000, frequency: "semi_monthly",
      anchor_date: Date.new(2026, 11, 2), **attrs
    )
  end

  test "zero config rows: the overlay returns the SAME incomes array (S0 no-op)" do
    assert_empty @family.family_paycheck_configs
    incomes = inputs_for[:incomes]
    out = PaycheckFlowPlanner.overlay_paycheck_configs(
      family: @family, month: Date.new(2026, 11, 15), incomes: incomes
    )
    assert_same incomes, out, "zero rows must be a byte-identical no-op (same object)"
  end

  test "semi_monthly: the stored Nov 6/20 occurrences are replaced with Nov 15 + Nov 30" do
    config_for
    incomes = inputs_for[:incomes]
    entry = incomes.find { |i| i[:id] == @series.id }
    assert_equal [ Date.new(2026, 11, 15), Date.new(2026, 11, 30) ],
                 entry[:occurrences].map { |o| o[:date] }
    assert entry[:occurrences].all? { |o| o[:amount_cents] == 200_000 }
  end

  test "biweekly: a 14-day stride from the anchor, clipped to the month" do
    # Anchor Fri 2026-10-16: ... Oct 16, Oct 30, Nov 13, Nov 27, Dec 11 ...
    config_for(frequency: "biweekly", anchor_date: Date.new(2026, 10, 16))
    incomes = inputs_for[:incomes]
    entry = incomes.find { |i| i[:id] == @series.id }
    assert_equal [ Date.new(2026, 11, 13), Date.new(2026, 11, 27) ],
                 entry[:occurrences].map { |o| o[:date] }
    strides = entry[:occurrences].each_cons(2).map { |(a, b)| b[:date] - a[:date] }
    assert_equal [ 14 ], strides
  end

  test "biweekly per_year is 26 and semi_monthly is 24" do
    config = config_for
    assert_equal 24, PaycheckFlowPlanner::PaycheckDates.per_year(config)
    config.update!(frequency: "biweekly", anchor_date: Date.new(2026, 10, 16))
    assert_equal 26, PaycheckFlowPlanner::PaycheckDates.per_year(config)
  end

  test "a config without stored occurrences appends the entry (id-ordered, R6)" do
    other = @family.recurring_transactions.create!(
      name: "Second Paycheck", account: @account, amount: 800, currency: "USD",
      expected_day_of_month: 26, last_occurrence_date: Date.new(2026, 10, 26),
      next_expected_date: Date.new(2026, 12, 26), status: "active",
      bill_type: "income", manual: true, plan_owner: @admin
    )
    @family.family_paycheck_configs.create!(
      user: @admin, recurring_transaction: other,
      gross_per_paycheck_cents: 80_000, frequency: "semi_monthly",
      anchor_date: Date.new(2026, 11, 2)
    )
    incomes = inputs_for[:incomes]
    appended = incomes.find { |i| i[:id] == other.id }
    assert_equal @admin.id, appended[:owner_id]
    assert_equal [ Date.new(2026, 11, 15), Date.new(2026, 11, 30) ],
                 appended[:occurrences].map { |o| o[:date] }
    # The stored-occurrence entry stays ahead of the append.
    assert_operator incomes.index { |i| i[:id] == @series.id }, :<,
                    incomes.index { |i| i[:id] == other.id }
  end

  test "B6: allocation wanted is immutable; the bank inflow delta follows the gross" do
    before = PaycheckFlowPlanner.plan_graph(family: @family, month: Date.new(2026, 11, 15))
    wanted_before = before[:allocations].map { |a| [ a[:id], a[:wanted_month] ] }.sort

    config_for # 1200 -> 2000 per paycheck (semi_monthly, 2 pay dates)

    after = PaycheckFlowPlanner.plan_graph(family: @family, month: Date.new(2026, 11, 15))
    wanted_after = after[:allocations].map { |a| [ a[:id], a[:wanted_month] ] }.sort
    assert_equal wanted_before, wanted_after,
                 "the overlay must not move any allocation's wanted amount (B6)"

    bank_before = before[:banks].find { |b| b[:id] == @account.id }
    bank_after = after[:banks].find { |b| b[:id] == @account.id }
    assert_equal "2400.00", bank_before[:inflow_month] # 1200 x 2 (Nov 6 + Nov 20)
    assert_equal "4000.00", bank_after[:inflow_month]  # 2000 x 2 (Nov 15 + Nov 30)
    assert_equal [ "2026-11-15", "2026-11-30" ], after[:paycheck_dates]
    assert_equal 2, after[:total_paychecks]
  end
end
