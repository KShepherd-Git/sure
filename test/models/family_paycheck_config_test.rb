require "test_helper"

# (Direct Deposit): the FamilyPaycheckConfig model — validations
# (frequency set, no $0.00 paycheck, one config per member per family,
# family/series guards), the semi_monthly default, and the derived
# readouts (derived_monthly_cents, upcoming_dates).
class FamilyPaycheckConfigTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @member = users(:family_member)
    @other_family = families(:empty)

    @series = @family.recurring_transactions.create!(
      name: "Paycheck", account: accounts(:depository), amount: 1000,
      currency: "USD", expected_day_of_month: 6,
      last_occurrence_date: Date.new(2026, 9, 6),
      next_expected_date: Date.new(2026, 12, 20), status: "active",
      bill_type: "income", manual: true, plan_owner: @member
    )
    travel_to Date.new(2026, 11, 15)
  end

  def teardown
    travel_back
  end

  def build_config(**attrs)
    @family.family_paycheck_configs.new(
      user: @member, recurring_transaction: @series,
      gross_per_paycheck_cents: 150_000, frequency: "semi_monthly",
      anchor_date: Date.new(2026, 10, 2), **attrs
    )
  end

  test "a valid config persists with the B5 semi_monthly default" do
    config = @family.family_paycheck_configs.create!(
      user: @member, recurring_transaction: @series,
      gross_per_paycheck_cents: 150_000, anchor_date: Date.new(2026, 10, 2)
    )
    assert_equal "semi_monthly", config.frequency
    assert config.valid?
  end

  test "frequency must be in the set" do
    assert_not build_config(frequency: "weekly").valid?
    assert build_config(frequency: "biweekly").valid?
  end

  test "a $0.00 paycheck is rejected (greater_than 0)" do
    assert_not build_config(gross_per_paycheck_cents: 0).valid?
  end

  test "one config per member per family (unique scope)" do
    build_config.save!
    assert_not build_config.save, "a second config for the same member must fail the unique (family_id, user_id) index"
  end

  test "the member must belong to the config's family" do
    # Built directly (NOT through the family collection proxy, which would
    # force family_id to the collection's family).
    config = FamilyPaycheckConfig.new(
      family: @other_family, user: @member, recurring_transaction: @series,
      gross_per_paycheck_cents: 150_000, frequency: "semi_monthly",
      anchor_date: Date.new(2026, 10, 2)
    )
    assert_not config.valid?
    assert config.errors[:user].any?
  end

  test "a linked series must be the member's own income series" do
    bill = @family.recurring_transactions.create!(
      name: "Rent", account: accounts(:depository), amount: 1800,
      currency: "USD", expected_day_of_month: 1,
      last_occurrence_date: Date.new(2026, 10, 1),
      next_expected_date: Date.new(2026, 12, 1), status: "active",
      bill_type: "bill", manual: true, plan_owner: @member
    )
    assert_not build_config(recurring_transaction: bill).valid?

    # A sibling member's series: same family, income — wrong member.
    sibling = @family.recurring_transactions.create!(
      name: "Admin Paycheck", account: accounts(:depository), amount: 900,
      currency: "USD", expected_day_of_month: 15,
      last_occurrence_date: Date.new(2026, 10, 15),
      next_expected_date: Date.new(2027, 1, 15), status: "active",
      bill_type: "income", manual: true, plan_owner: users(:family_admin)
    )
    assert_not build_config(recurring_transaction: sibling).valid?
  end

  test "derived_monthly_cents: semi_monthly is always 2 x gross" do
    config = build_config(gross_per_paycheck_cents: 200_000)
    assert_equal 400_000, config.derived_monthly_cents(Date.new(2026, 11, 15))
  end

  test "upcoming_dates: four future dates, semi_monthly = 15th + last day" do
    config = build_config
    dates = config.upcoming_dates
    assert_equal 4, dates.size
    assert_equal [ Date.new(2026, 11, 15), Date.new(2026, 11, 30),
                   Date.new(2026, 12, 15), Date.new(2026, 12, 31) ], dates
    assert dates.all? { |date| date >= Date.current }
  end

  test "upcoming_dates: biweekly = a 14-day stride from the anchor" do
    # Anchor Fri 2026-11-13 (two days BEFORE today, Nov 15): the window
    # starts today, so the first upcoming pay date is the next stride,
    # Nov 27: Nov 27, Dec 11, Dec 25, Jan 8.
    config = build_config(frequency: "biweekly", anchor_date: Date.new(2026, 11, 13))
    dates = config.upcoming_dates
    assert_equal [ Date.new(2026, 11, 27), Date.new(2026, 12, 11),
                   Date.new(2026, 12, 25), Date.new(2027, 1, 8) ], dates
    strides = dates.each_cons(2).map { |(a, b)| b - a }
    assert_equal [ 14, 14, 14 ], strides
  end
end
