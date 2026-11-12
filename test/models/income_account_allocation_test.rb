require "test_helper"

# Value-presence rules for each edge mode, plus the guardrails that keep a
# crafted id from pinning an edge to a bill or another family's series.
class IncomeAccountAllocationTest < ActiveSupport::TestCase
  setup do
    @family = users(:family_admin).family
    @account = accounts(:depository)
    @income = create_income_series(family: @family, account: @account)
    @other_family = families(:empty)
  end

  def create_income_series(family:, account:, amount: 100)
    family.recurring_transactions.create!(
      name: "Payroll",
      account: account,
      amount: amount,
      currency: "USD",
      expected_day_of_month: 1,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 5.days.from_now.to_date,
      status: "active",
      bill_type: "income",
      manual: true
    )
  end

  def build(mode:, value:)
    IncomeAccountAllocation.new(
      family: @family,
      income_series: @income,
      account: @account,
      mode: mode,
      value: value
    )
  end

  test "specific requires a positive per-paycheck amount" do
    assert_not build(mode: "specific", value: nil).valid?
    assert_not build(mode: "specific", value: 0).valid?
    assert_not build(mode: "specific", value: -5).valid?
    assert build(mode: "specific", value: 100).valid?
    assert build(mode: "specific", value: 0.01).valid?
  end

  test "percent requires a fraction in (0, 1]" do
    assert_not build(mode: "percent", value: nil).valid?
    assert_not build(mode: "percent", value: 0).valid?
    assert_not build(mode: "percent", value: 1.5).valid?
    assert build(mode: "percent", value: 0.5).valid?
    assert build(mode: "percent", value: 1).valid?
  end

  # Required carries the stored PERCENT of the bank's
  # required amount (2 dp major units) or nil (nil = the equal split =
  # today's planner behavior).
  test "required stores a percent of the required amount (0 < v <= 100) or nil" do
    assert build(mode: "required", value: nil).valid?
    assert build(mode: "required", value: 30.00).valid?
    assert build(mode: "required", value: 50).valid?
    assert build(mode: "required", value: 100.00).valid?
  end

  # out-of-range percents fail with the stock validator
  # wording (the trimmed locale set has no :numericality key — ).
  test "required rejects zero and over-100 percents with stock wording" do
    zero = build(mode: "required", value: 0)
    assert_not zero.valid?
    assert zero.errors[:value].any? { |m| m.include?("must be greater than 0") }

    over = build(mode: "required", value: 100.01)
    assert_not over.valid?
    assert over.errors[:value].any? { |m| m.include?("must be less than or equal to 100") }
  end

  # (M3): leftover stays display-only — no stored value.
  test "leftover carries no stored value" do
    assert build(mode: "leftover", value: nil).valid?
    leftover = build(mode: "leftover", value: 5.00)
    assert_not leftover.valid?
    assert leftover.errors[:value].any?
  end

  test "the income series must be a declared income" do
    bill = recurring_transactions(:netflix_subscription) # a subscription
    allocation = IncomeAccountAllocation.new(
      family: @family,
      income_series: bill,
      account: @account,
      mode: "leftover"
    )
    assert_not allocation.valid?
    assert allocation.errors[:income_series].any?
  end

  test "the series and account must belong to the same family" do
    allocation = build(mode: "leftover", value: nil)
    other_user = @other_family.users.first
    other_account = @other_family.accounts.create!(
      name: "Other", owner: other_user, currency: "USD", balance: 0, accountable: Depository.new
    )
    allocation.account = other_account
    assert_not allocation.valid?
    assert allocation.errors[:account].any?
  end
end
