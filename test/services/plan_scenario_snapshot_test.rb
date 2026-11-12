require "test_helper"

# (Flow Scenarios): the snapshot builders. The shapes MUST match
# the planner's draft seam exactly — `plan_allocation_rows` / `edge_rows`
# stringified — so a Re-Use Current snapshot deep-equals the live rows and
# a Start Fresh snapshot is an empty plan over the live income series.
class PlanScenarioSnapshotTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @member = users(:family_member)
    @admin = users(:family_admin)
    @account = accounts(:depository)
    travel_to Date.new(2026, 11, 15)

    # Two live income series (Primary / Secondary payroll pattern) with the house
    # Nov 6 / Nov 20 occurrence window.
    @primary_series = income_series("Primary Payroll", @admin, 2_700)
    @secondary_series = income_series("Secondary Payroll", @member, 2_700)

    # Live plan state: one required bill allocation, one fun_money row (the
    # the fun-money fields must ride along byte-faithful), one income->bank edge.
    @family.plan_allocations.create!(
      account: @account, name: "Rent", cadence: "monthly",
      kind: "bill", mode: "required", recurring_transaction: rent_series,
      value_cents: nil
    )
    @family.plan_allocations.create!(
      account: @account, name: "Fun Money", kind: "fun_money",
      mode: "percent", value_percent: 0.25, ownership: "household",
      distribution: "percent", matching: "equalize",
      distribution_params: { "percents" => { @member.id => "30.00", @admin.id => "70.00" } }
    )
    @family.income_account_allocations.create!(
      income_series: @primary_series, account: @account,
      mode: "specific", value: 1000
    )
    @family.income_account_allocations.create!(
      income_series: @secondary_series, account: @account, mode: "leftover"
    )
    # One paycheck config copy source (gross / frequency / anchor).
    @family.family_paycheck_configs.create!(
      user: @member, recurring_transaction: @secondary_series,
      gross_per_paycheck_cents: 270_000, frequency: "semi_monthly",
      anchor_date: Date.new(2026, 11, 15)
    )
  end

  def teardown
    travel_back
  end

  private

    def income_series(name, owner, amount)
      series = @family.recurring_transactions.create!(
        name: name, account: @account, amount: amount, currency: "USD",
        expected_day_of_month: 6, last_occurrence_date: Date.new(2026, 9, 6),
        next_expected_date: Date.new(2026, 12, 20), status: "active",
        bill_type: "income", manual: true, plan_owner: owner
      )
      series.recurring_occurrences.destroy_all
      [ Date.new(2026, 11, 6), Date.new(2026, 11, 20) ].each do |due_on|
        @family.recurring_occurrences.create!(
          recurring_transaction: series, due_on: due_on,
          original_due_on: due_on, currency: "USD", expected_amount: amount,
          status: "scheduled"
        )
      end
      series
    end

    def rent_series
      @rent_series ||= @family.recurring_transactions.create!(
        name: "Rent", account: @account, amount: 2_500, currency: "USD",
        expected_day_of_month: 1, last_occurrence_date: Date.new(2026, 9, 1),
        next_expected_date: Date.new(2027, 1, 1), status: "active",
        bill_type: "bill", manual: true
      )
    end

  public

    test "fresh: empty plan over the family's current incomes" do
      snapshot = PlanScenarioSnapshot.fresh(@family)

      assert_equal 1, snapshot["v"]
      assert_equal [], snapshot["plan_allocations"]
      assert_equal [], snapshot["allocations"]
      assert_equal [], snapshot["paycheck_configs"]

      policy = snapshot["incomes"]
      assert_equal [ @primary_series.id, @secondary_series.id ].sort,
                   policy.map { |row| row["series_id"] },
                   "policy lists the live series in :id (uuid) order"
      policy.each do |row|
        assert_equal true, row["enabled"]
        assert_equal false, row["zeroed"]
        assert_nil row["gross_per_paycheck_cents"]
      end
    end

    test "reuse_current: plan allocations deep-equal the live rows (byte-faithful)" do
      snapshot = PlanScenarioSnapshot.reuse_current(@family)
      live = PaycheckFlowPlanner.plan_allocation_rows(@family).map(&:stringify_keys)

      assert_equal live, snapshot["plan_allocations"]
      # Fun Money rides along automatically (it is a plan_allocation of
      # kind fun_money): ownership/distribution/matching/params survive.
      fun_money = snapshot["plan_allocations"].find { |row| row["kind"] == "fun_money" }
      assert_equal "household", fun_money["ownership"]
      assert_equal "percent", fun_money["distribution"]
      assert_equal "equalize", fun_money["matching"]
      assert_equal({ "percents" => { @member.id => "30.00", @admin.id => "70.00" } },
                   fun_money["distribution_params"])
    end

    test "reuse_current: edges deep-equal the live edge_rows (mode-conditional values)" do
      snapshot = PlanScenarioSnapshot.reuse_current(@family)
      live = PaycheckFlowPlanner.edge_rows(@family).map(&:stringify_keys)

      assert_equal live, snapshot["allocations"]
      specific = snapshot["allocations"].find { |row| row["mode"] == "specific" }
      assert_equal 100_000, specific["value_cents"]
      leftover = snapshot["allocations"].find { |row| row["mode"] == "leftover" }
      assert_nil leftover["value_cents"]
      assert_nil leftover["value_percent"]
    end

    test "reuse_current: paycheck config copies carry the occurrence inputs" do
      snapshot = PlanScenarioSnapshot.reuse_current(@family)

      configs = snapshot["paycheck_configs"]
      assert_equal 1, configs.size
      assert_equal @member.id, configs.first["user_id"]
      assert_equal @secondary_series.id, configs.first["recurring_transaction_id"]
      assert_equal 270_000, configs.first["gross_per_paycheck_cents"]
      assert_equal "semi_monthly", configs.first["frequency"]
      assert_equal "2026-11-15", configs.first["anchor_date"]
    end

    test "reuse_current keeps the live uuids (stable sankey node ids)" do
      snapshot = PlanScenarioSnapshot.reuse_current(@family)
      live_ids = @family.plan_allocations.pluck(:id).to_set

      assert_equal live_ids, snapshot["plan_allocations"].map { |row| row["id"] }.to_set
    end
end
