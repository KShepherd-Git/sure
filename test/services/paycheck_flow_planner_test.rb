require "test_helper"

# Pure-Ruby solver tests. No ActiveRecord: the planner is fed plain hashes and
# integer-cent BigDecimals, so the math is exercised exactly as it will run.
class PaycheckFlowPlannerTest < ActiveSupport::TestCase
  P1 = "partner-1".freeze
  P2 = "partner-2".freeze

  def planner(month:, incomes:, allocations: [], obligations: {}, partners: [ P1, P2 ], distribution: "equal_split")
    PaycheckFlowPlanner.new(
      month: month,
      incomes: incomes,
      allocations: allocations,
      obligations_by_account: obligations,
      partners: partners,
      leftover_distribution: distribution
    ).plan
  end

  def income(id:, owner_id:, amounts:)
    n = amounts.size
    { id: id, owner_id: owner_id,
      occurrences: amounts.map.with_index do |cents, i|
        day = n.zero? ? 6 : 1 + (i * 30) / n
        { date: Date.new(2026, 11, day), amount_cents: BigDecimal(cents) }
      end }
  end

  # required_percent: the stored 2-dp percent of the bank's
  # required amount a required edge carries (nil = the equal split). The
  # LEGACY plan path ignores it (the graph path is the only consumer —
  # a dedicated test pins the byte-identity).
  def edge(income_id:, account_id:, mode:, value_cents: nil, value_percent: nil, required_percent: nil)
    { income_id: income_id, account_id: account_id, mode: mode,
      value_cents: value_cents, value_percent: value_percent,
      required_percent: required_percent }
  end

  # 1. A 90/10 income split is equalized under equal_split: the pooled leftover
  # is credited 1/N per partner, so the smaller earner is not left with less.
  test "90/10 income split equalized under equal_split" do
    a = income(id: "A", owner_id: P1, amounts: [ 90_000 ]) # 900.00
    b = income(id: "B", owner_id: P2, amounts: [ 10_000 ]) # 100.00
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: [
        edge(income_id: "A", account_id: "accA", mode: "leftover"),
        edge(income_id: "B", account_id: "accB", mode: "leftover")
      ],
      distribution: "equal_split"
    )

    attr = plan[:leftover_attribution]
    assert_equal "equal_split", attr[:distribution]
    assert_equal "1000.00", attr[:pooled_month] # 900 + 100
    p1, p2 = attr[:by_partner]
    assert_equal "0.5000", p1[:weight]
    assert_equal "0.5000", p2[:weight]
    # Equal credit despite the 9x income gap.
    assert_equal "500.00", p1[:fun_money_month]
    assert_equal "500.00", p2[:fun_money_month]
    assert_equal "500.00", attr[:pooled_per_paycheck] # 1000 / 2 paychecks
  end

  # 2. income_ratio attributes by each partner's share of total income.
  test "income_ratio attribution math" do
    a = income(id: "A", owner_id: P1, amounts: [ 90_000 ])
    b = income(id: "B", owner_id: P2, amounts: [ 10_000 ])
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: [
        edge(income_id: "A", account_id: "accA", mode: "leftover"),
        edge(income_id: "B", account_id: "accB", mode: "leftover")
      ],
      distribution: "income_ratio"
    )

    attr = plan[:leftover_attribution]
    p1, p2 = attr[:by_partner]
    assert_equal "0.9000", p1[:weight] # 900 / 1000
    assert_equal "0.1000", p2[:weight] # 100 / 1000
    assert_equal "900.00", p1[:fun_money_month]
    assert_equal "100.00", p2[:fun_money_month]
  end

  # 3. Biweekly reality: the same monthly obligation prorates over 2 paychecks
  # in a 2-paycheck month and 3 in a 3-paycheck month.
  test "obligations prorate over 2 vs 3 paychecks" do
    # 2 paychecks.
    two = income(id: "A", owner_id: P1, amounts: [ 50_000, 50_000 ])
    plan_two = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ two ],
      allocations: [
        edge(income_id: "A", account_id: "accObl", mode: "required"),
        edge(income_id: "A", account_id: "accFun", mode: "leftover")
      ],
      obligations: { "accObl" => BigDecimal(60_000) }, # 600.00/month
      partners: [ P1 ]
    )
    # 3 paychecks.
    three = income(id: "A", owner_id: P1, amounts: [ 40_000, 40_000, 40_000 ])
    plan_three = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ three ],
      allocations: [
        edge(income_id: "A", account_id: "accObl", mode: "required"),
        edge(income_id: "A", account_id: "accFun", mode: "leftover")
      ],
      obligations: { "accObl" => BigDecimal(60_000) },
      partners: [ P1 ]
    )

    acc2 = plan_two[:accounts].find { |x| x[:id] == "accObl" }
    acc3 = plan_three[:accounts].find { |x| x[:id] == "accObl" }
    assert_equal "600.00", acc2[:required_month]
    assert_equal "600.00", acc3[:required_month]
    assert_equal "300.00", acc2[:required_per_paycheck] # 600 / 2
    assert_equal "200.00", acc3[:required_per_paycheck] # 600 / 3
    assert_equal 2, plan_two[:total_paychecks]
    assert_equal 3, plan_three[:total_paychecks]

    # Summing the per-paycheck required over the month lands exactly on the
    # monthly total in both cases (frequencies partition the paychecks).
    total_two = plan_two[:paychecks].sum { |p| BigDecimal(p[:by_account]["accObl"]) }
    total_three = plan_three[:paychecks].sum { |p| BigDecimal(p[:by_account]["accObl"]) }
    assert_equal BigDecimal("600.00"), total_two
    assert_equal BigDecimal("600.00"), total_three
  end

  # 4. Percent rounding: the half-cent is rounded up into the percent edge and
  # the remainder lands in leftover, so the two sum exactly to the income.
  test "percent rounding remainder lands in leftover" do
    a = income(id: "A", owner_id: P1, amounts: [ 9_999 ]) # 99.99
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a ],
      allocations: [
        edge(income_id: "A", account_id: "accPct", mode: "percent", value_percent: BigDecimal(0.5)),
        edge(income_id: "A", account_id: "accLeft", mode: "leftover")
      ],
      partners: [ P1 ]
    )

    paycheck = plan[:paychecks].first
    pct = paycheck[:allocations].find { |x| x[:account_id] == "accPct" }[:amount]
    left = paycheck[:allocations].find { |x| x[:account_id] == "accLeft" }
    # 99.99 * 0.5 = 49.995 -> rounds half-up to 50.00; remainder 49.99.
    assert_equal "50.00", pct
    assert_equal "49.99", left[:amount]
    assert_equal BigDecimal("99.99"), BigDecimal(pct) + BigDecimal(left[:amount])
  end

  # 5. Multiple income streams can fund the same account.
  test "multiple income streams into one account" do
    a = income(id: "A", owner_id: P1, amounts: [ 50_000 ])
    b = income(id: "B", owner_id: P2, amounts: [ 30_000 ])
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: [
        edge(income_id: "A", account_id: "accShared", mode: "specific", value_cents: 10_000),
        edge(income_id: "A", account_id: "accFunA", mode: "leftover"),
        edge(income_id: "B", account_id: "accShared", mode: "specific", value_cents: 5_000),
        edge(income_id: "B", account_id: "accFunB", mode: "leftover")
      ]
    )

    shared = plan[:accounts].find { |x| x[:id] == "accShared" }
    assert_equal "150.00", shared[:total_in_month] # 100 + 50
    paycheck = plan[:paychecks].first
    assert_equal "150.00", paycheck[:by_account]["accShared"]
  end

  # 6. A required edge on an account with no obligations resolves to 0.
  test "required mode on a zero-obligation account is 0" do
    a = income(id: "A", owner_id: P1, amounts: [ 50_000 ])
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a ],
      allocations: [
        edge(income_id: "A", account_id: "accReq", mode: "required"),
        edge(income_id: "A", account_id: "accFun", mode: "leftover")
      ],
      obligations: {},
      partners: [ P1 ]
    )

    req = plan[:paychecks].first[:allocations].find { |x| x[:account_id] == "accReq" }
    assert_equal "0.00", req[:amount]
    assert_equal "0.00", plan[:paychecks].first[:by_account]["accReq"]
    # The whole paycheck falls through to leftover.
    assert_equal "500.00", plan[:paychecks].first[:by_account]["accFun"]
  end

  # 7. When required + specific outrun the income, the leftover goes negative
  # and a shortfall is flagged.
  test "shortfall when required plus specific exceeds income" do
    a = income(id: "A", owner_id: P1, amounts: [ 10_000 ]) # 100.00
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a ],
      allocations: [
        edge(income_id: "A", account_id: "accReq", mode: "required"),
        edge(income_id: "A", account_id: "accSpec", mode: "specific", value_cents: 5_000),
        edge(income_id: "A", account_id: "accLeft", mode: "leftover")
      ],
      obligations: { "accReq" => BigDecimal(12_000) }, # 120.00 > 100.00
      partners: [ P1 ]
    )

    assert_equal 1, plan[:shortfalls].size
    assert_equal "A", plan[:shortfalls].first[:income_series_id]
    assert_equal "70.00", plan[:shortfalls].first[:gap_month] # (120+50) - 100
    left = plan[:paychecks].first[:allocations].find { |x| x[:account_id] == "accLeft" }
    assert_equal "-70.00", left[:amount]
    assert_equal true, left[:shortfall]
  end

  # 8. specific + percent + leftover mixed on one stream.
  test "specific plus percent plus leftover mixed" do
    a = income(id: "A", owner_id: P1, amounts: [ 100_000 ]) # 1000.00
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a ],
      allocations: [
        edge(income_id: "A", account_id: "accSpec", mode: "specific", value_cents: 10_000),
        edge(income_id: "A", account_id: "accPct", mode: "percent", value_percent: BigDecimal(0.10)),
        edge(income_id: "A", account_id: "accLeft", mode: "leftover")
      ],
      partners: [ P1 ]
    )

    paycheck = plan[:paychecks].first
    assert_equal "100.00", paycheck[:by_account]["accSpec"]
    assert_equal "100.00", paycheck[:by_account]["accPct"] # 1000 * 0.10
    assert_equal "800.00", paycheck[:by_account]["accLeft"]
    assert_equal "1000.00", paycheck[:total_income]
  end

  # 9. Suggested fix: the partner above target with exactly one percent edge
  # gets a closed-form shift so their leftover lands on the mean.
  test "suggested fix shifts the over-target partner's percent edge" do
    a = income(id: "A", owner_id: P1, amounts: [ 100_000 ]) # 1000.00, 10% -> leftover 900
    b = income(id: "B", owner_id: P2, amounts: [ 50_000 ]) # 500.00, 50% -> leftover 250
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: [
        edge(income_id: "A", account_id: "accPctA", mode: "percent", value_percent: BigDecimal(0.10)),
        edge(income_id: "A", account_id: "accLeftA", mode: "leftover"),
        edge(income_id: "B", account_id: "accPctB", mode: "percent", value_percent: BigDecimal(0.50)),
        edge(income_id: "B", account_id: "accLeftB", mode: "leftover")
      ]
    )

    fix = plan[:suggested_fix]
    refute_nil fix
    assert_equal P1, fix[:user_id] # P1 leftover 900 > P2 250
    assert_equal "A", fix[:income_series_id]
    assert_equal "0.1000", fix[:current_percent]
    # target = (900 + 250)/2 = 575; delta = +325; shift = 325/1000 = 0.325.
    assert_equal "0.4250", fix[:suggested_percent]
    assert_equal "575.00", fix[:new_leftover_month]

    delta = plan[:delta]
    assert_equal "575.00", delta[:target_month]
    assert_equal "650.00", delta[:spread_month] # 900 - 250
  end

  # 10. No paychecks in the month: the plan is still valid, nothing applies.
  test "a month with no paychecks produces an empty but valid plan" do
    a = income(id: "A", owner_id: P1, amounts: [])
    plan = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a ],
      allocations: [ edge(income_id: "A", account_id: "accReq", mode: "required") ],
      obligations: { "accReq" => BigDecimal(60_000) },
      partners: [ P1 ]
    )

    assert_equal 0, plan[:total_paychecks]
    assert_equal [], plan[:paychecks]
    # With no paychecks the per-paycheck required stays the monthly total but
    # is never applied; no shortfall is claimed.
    assert_equal "600.00", plan[:accounts].first[:required_per_paycheck]
    assert_equal [], plan[:shortfalls]
  end

  # (regression guard): the PR#1 plan path is
  # BYTE-IDENTICAL for a family with sub-accounts + fan-out configured —
  # inputs_for carries no sub-account keys and the PR#1 resolver ignores
  # them (they exist for plan_graph only).
  test "plan() output is byte-identical with sub-accounts and fan-out configured" do
    a = income(id: "A", owner_id: P1, amounts: [ 90_000, 90_000 ])
    b = income(id: "B", owner_id: P2, amounts: [ 10_000, 10_000 ])
    edges = [
      edge(income_id: "A", account_id: "accA", mode: "specific", value_cents: BigDecimal(50_000)),
      edge(income_id: "A", account_id: "leftover", mode: "leftover"),
      edge(income_id: "B", account_id: "accB", mode: "leftover")
    ]

    plain = PaycheckFlowPlanner.new(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: edges,
      obligations_by_account: { "accA" => BigDecimal(20_000), "accB" => BigDecimal(15_000) },
      partners: [ P1, P2 ],
      leftover_distribution: "income_ratio"
    ).plan

    with_links = PaycheckFlowPlanner.new(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: edges,
      obligations_by_account: { "accA" => BigDecimal(20_000), "accB" => BigDecimal(15_000) },
      partners: [ P1, P2 ],
      leftover_distribution: "income_ratio",
      sub_account_links: { "sub" => "accA", "sub2" => "accB" },
      auto_transfer_targets: { "accA" => [ "sub", "sub2" ], "accB" => [ "sub" ] },
      account_names: { "accA" => "Checking", "accB" => "Savings", "sub" => "Bucket" }
    ).plan

    assert_equal plain.to_json, with_links.to_json,
      "the PR#1 plan() output must be byte-identical with fan-out inputs present"
  end

  # Failure-path observability (house style: DebugLogEntry.capture over
  # Rails.logger for support-relevant failures). to_family_cents is only
  # reached through the AR seam, so this test is the one AR-backed test in
  # an otherwise pure-Ruby file.
  test "to_family_cents captures a DebugLogEntry when the amount is unconvertible" do
    money = Money.new(12_345, "EUR")
    money.expects(:exchange_to).raises(
      Money::ConversionError.new(from_currency: "EUR", to_currency: "USD", date: Date.new(2026, 11, 1))
    )

    assert_difference -> { DebugLogEntry.where(category: "paycheck_planner").count }, 1 do
      assert_equal BigDecimal(0), PaycheckFlowPlanner.to_family_cents(money, "USD")
    end

    entry = DebugLogEntry.where(category: "paycheck_planner").recent.first
    assert_equal "warn", entry.level
    assert_equal "PaycheckFlowPlanner", entry.source
    assert_includes entry.message, "Unconvertible amount zeroed"
    assert_equal "EUR", entry.metadata["source_currency"]
    assert_equal "USD", entry.metadata["target_currency"]
  end

  # ( fix): AR-seam regression for deterministic graph
  # serialization (the SHA drift). The app's own upsert destroys and
  # recreates an income_account_allocations row (fresh id + created_at, a
  # new physical table position), and the planner's unordered edge read let
  # that reposition the bank in the serialized banks array. The edge read
  # is now ordered by the natural key (income series, account) and the
  # banks union is sorted by account id, so the serialized graph must be
  # byte-identical across the upsert. ( h's proposed
  # .order(:created_at, :id) cannot satisfy this property — a recreate
  # gets the newest created_at and moves to the end — so the natural key
  # supersedes it.)
  test "plan_graph serialization is byte-stable across an allocation upsert" do
    family = users(:family_admin).family
    owner = users(:family_admin)
    bank_a = accounts(:depository)
    bank_b = Account.create!(name: "R6 Regression Bank B", family: family,
      owner: owner, currency: "USD", balance: 0, status: "active",
      accountable_type: "Depository", accountable: Depository.new)
    bank_c = Account.create!(name: "R6 Regression Bank C", family: family,
      owner: owner, currency: "USD", balance: 0, status: "active",
      accountable_type: "Depository", accountable: Depository.new)

    # Two income series sharing BOTH due_on dates — also exercises the
    # id tie-break on the occurrences read.
    series_a = family.recurring_transactions.create!(
      name: "R6 Payroll A", account: bank_a, amount: 2700, currency: "USD",
      expected_day_of_month: 6, last_occurrence_date: Date.new(2026, 9, 6),
      next_expected_date: Date.new(2026, 12, 20), status: "active",
      bill_type: "income", manual: true)
    series_b = family.recurring_transactions.create!(
      name: "R6 Payroll B", account: bank_a, amount: 900, currency: "USD",
      expected_day_of_month: 6, last_occurrence_date: Date.new(2026, 9, 20),
      next_expected_date: Date.new(2026, 12, 20), status: "active",
      bill_type: "income", manual: true)
    [ [ series_a, 2700 ], [ series_b, 900 ] ].each do |series, amount|
      # The series create-callback backfills occurrences up to
      # next_expected_date — clear them (the house pattern) before the
      # exact two are created below.
      series.recurring_occurrences.destroy_all
      [ Date.new(2026, 11, 6), Date.new(2026, 11, 20) ].each do |date|
        series.recurring_occurrences.create!(family: family, due_on: date,
          original_due_on: date, currency: "USD", expected_amount: amount,
          status: "scheduled")
      end
    end

    # Five edges — one leftover per income (no multi-leftover ambiguity).
    # The middle edge is the upsert target (mirrors the po5 drift).
    upserted = family.income_account_allocations.create!(
      income_series: series_a, account: bank_b, mode: "percent", value: 0.25)
    family.income_account_allocations.create!(
      income_series: series_a, account: bank_a, mode: "specific", value: 100.0)
    family.income_account_allocations.create!(
      income_series: series_a, account: bank_c, mode: "leftover")
    family.income_account_allocations.create!(
      income_series: series_b, account: bank_a, mode: "specific", value: 50.0)
    family.income_account_allocations.create!(
      income_series: series_b, account: bank_c, mode: "leftover")

    month = Date.new(2026, 11, 15)
    before = PaycheckFlowPlanner.plan_graph(family: family, month: month)

    # The app's upsert shape (save_bank_links): destroy + recreate the
    # same edge — fresh id + created_at, a new physical table position.
    upserted.destroy!
    family.income_account_allocations.create!(
      income_series: series_a, account: bank_b, mode: "percent", value: 0.25)

    after = PaycheckFlowPlanner.plan_graph(family: family, month: month)

    assert_equal before.to_json, after.to_json,
      "the serialized plan_graph must be byte-stable across an allocation upsert"
    assert_equal before[:banks].map { |bank| bank[:id] }, after[:banks].map { |bank| bank[:id] },
      "the serialized banks order must be stable across an allocation upsert"
    assert_equal before[:banks].map { |bank| bank[:id] }.sort,
      before[:banks].map { |bank| bank[:id] },
      "the banks array must be in stable account-id order"
  end

  # the LEGACY plan path (plan, not plan_graph) never reads
  # the required percents — resolve_edges receives an empty split map, so a
  # required edge carrying a stored percent plans EXACTLY as today. This is
  # the stop-rule's legacy-side half (the graph-side half is pinned in the
  # graph test file).
  test "the legacy plan ignores required percents (P6)" do
    a = income(id: "A", owner_id: P1, amounts: [ 50_000, 50_000 ])
    b = income(id: "B", owner_id: P2, amounts: [ 50_000, 50_000 ])
    plain = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: [
        edge(income_id: "A", account_id: "accObl", mode: "required"),
        edge(income_id: "B", account_id: "accObl", mode: "required"),
        edge(income_id: "A", account_id: "accFun", mode: "leftover"),
        edge(income_id: "B", account_id: "accFun", mode: "leftover")
      ],
      obligations: { "accObl" => BigDecimal(60_000) }
    )
    with_percents = planner(
      month: Date.new(2026, 11, 1),
      incomes: [ a, b ],
      allocations: [
        edge(income_id: "A", account_id: "accObl", mode: "required", required_percent: BigDecimal("30.00")),
        edge(income_id: "B", account_id: "accObl", mode: "required", required_percent: BigDecimal("70.00")),
        edge(income_id: "A", account_id: "accFun", mode: "leftover"),
        edge(income_id: "B", account_id: "accFun", mode: "leftover")
      ],
      obligations: { "accObl" => BigDecimal(60_000) }
    )
    assert_equal plain.to_json, with_percents.to_json,
      "the legacy plan output must be byte-identical with or without required percents"
  end
end

# ---------------------------------------------------------------------------
# (Flow Scenarios): the planner seam. Scenario mode is "a preview whose
# base set is the snapshot instead of the live tables" (the design). The
# seam is three edits, each with an invariant:
#   * apply_draft :linked_bank_counts — absent key = byte-identical no-op,
#     present key = wholesale replace (build_graph_report's per-income
#     limit warnings must follow the SCENARIO's edge set);
#   * overlay_paycheck_configs configs: kwarg — nil/empty = the SAME incomes
# array (the gate, now also for the explicit empty array);
#   * scenario_incomes / scenario_draft — the snapshot policy over the live
# base (the design): disabled drops the series, zeroed zeroes amounts,
#     gross replaces them, absent policy rows pass through (override map,
#     not a whitelist), the snapshot paycheck-config copy re-derives dates
#     from the copy (PaycheckDates on unsaved instances).
class PaycheckFlowPlannerScenarioTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @primary = users(:family_admin)
    @secondary = users(:family_member)
    @bank_a = accounts(:depository)
    travel_to Date.new(2026, 11, 15)

    # Primary: $400 x 2 (Nov 6 / Nov 20) = 80_000 cents/month.
    # Secondary: $900 x 2 = 180_000 cents/month.
    # Rent: $1000/month demand on bank A — covered by both incomes, SHORT
    # when Secondary's paycheck disappears (the second-income-quits shortfall).
    @primary_series = make_series(@primary, "Primary Paycheck", 400)
    @secondary_series = make_series(@secondary, "Secondary Paycheck", 900)
    [ @primary_series, @secondary_series ].each do |series|
      series.recurring_occurrences.destroy_all
      [ Date.new(2026, 11, 6), Date.new(2026, 11, 20) ].each do |due_on|
        @family.recurring_occurrences.create!(
          recurring_transaction: series, due_on: due_on,
          original_due_on: due_on, currency: "USD",
          expected_amount: series.amount.to_d, status: "scheduled"
        )
      end
      @family.income_account_allocations.create!(
        income_series: series, account: @bank_a, mode: "leftover"
      )
    end
    @family.plan_allocations.create!(
      account: @bank_a, name: "Rent", cadence: "monthly",
      kind: "bill", mode: "specific", value_cents: 100_000
    )
  end

  def teardown
    travel_back
  end

  def make_series(owner, name, amount)
    @family.recurring_transactions.create!(
      name: name, account: @bank_a, amount: amount, currency: "USD",
      expected_day_of_month: 6, last_occurrence_date: Date.new(2026, 9, 6),
      next_expected_date: Date.new(2026, 12, 20), status: "active",
      bill_type: "income", manual: true, plan_owner: owner
    )
  end

  def month
    Date.new(2026, 11, 15)
  end

  def snapshot_with(secondary_policy: { "enabled" => true })
    base = PlanScenarioSnapshot.reuse_current(@family)
    incomes = base["incomes"].map do |row|
      row["series_id"] == @secondary_series.id ?
        row.merge("enabled" => secondary_policy["enabled"],
                  "zeroed" => secondary_policy["zeroed"] || false,
                  "gross_per_paycheck_cents" => secondary_policy["gross_per_paycheck_cents"]) : row
    end
    base.merge("incomes" => incomes)
  end

  # --- overlay_paycheck_configs configs: kwarg ( + unsaved parity) ---

  test "configs: [] returns the SAME incomes array (explicit-empty S0 no-op)" do
    assert_empty @family.family_paycheck_configs
    incomes = PaycheckFlowPlanner.inputs_for(family: @family, month: month)[:incomes]
    out = PaycheckFlowPlanner.overlay_paycheck_configs(
      family: @family, month: month, incomes: incomes, configs: []
    )
    assert_same incomes, out, "zero configs must be a byte-identical no-op (same object)"
  end

  test "an unsaved config instance overlays identically to its saved twin" do
    saved = @family.family_paycheck_configs.create!(
      user: @primary, recurring_transaction: @primary_series,
      gross_per_paycheck_cents: 60_000, frequency: "biweekly",
      anchor_date: Date.new(2026, 11, 2)
    )
    live_base = PaycheckFlowPlanner.inputs_for(family: @family, month: month)[:incomes]
    live = PaycheckFlowPlanner.overlay_paycheck_configs(
      family: @family, month: month, incomes: live_base
    )

    unsaved = FamilyPaycheckConfig.new(
      user_id: saved.user_id, recurring_transaction_id: saved.recurring_transaction_id,
      gross_per_paycheck_cents: saved.gross_per_paycheck_cents,
      frequency: saved.frequency, anchor_date: saved.anchor_date
    )
    scenario_base = PaycheckFlowPlanner.inputs_for(family: @family, month: month)[:incomes]
    scenario = PaycheckFlowPlanner.overlay_paycheck_configs(
      family: @family, month: month, incomes: scenario_base, configs: [ unsaved ]
    )
    assert_equal live.to_json, scenario.to_json,
      "the unsaved config copy must re-derive identical occurrences"
  end

  # --- apply_draft :linked_bank_counts ---

  test "apply_draft without :linked_bank_counts is a byte-identical no-op" do
    @primary_series.update!(plan_max_account_links: 1)
    bank_b = Account.create!(name: "R35 Bank B", family: @family, owner: @primary,
      currency: "USD", balance: 0, status: "active",
      accountable_type: "Depository", accountable: Depository.new)
    # A second live edge on Primary's series -> live count 2 > limit 1.
    @family.income_account_allocations.create!(
      income_series: @primary_series, account: bank_b, mode: "specific", value: 1.0
    )

    live = PaycheckFlowPlanner.plan_graph(family: @family, month: month)
    assert live[:limit_warnings].any? { |w| w[:income_id] == @primary_series.id },
      "the live graph must carry the limit warning for the fixture"

    inputs = PaycheckFlowPlanner.graph_inputs_for(family: @family, month: month)
    draft = {
      incomes: inputs[:incomes],
      allocations: inputs[:allocations],
      plan_allocations: inputs[:plan_allocations]
    }
    no_key = PaycheckFlowPlanner.new(**inputs, draft: draft).plan_graph
    assert_equal live.to_json, no_key.to_json,
      "an absent :linked_bank_counts key must leave the fetched value untouched"
  end

  test "apply_draft with :linked_bank_counts replaces it wholesale" do
    @primary_series.update!(plan_max_account_links: 1)
    bank_b = Account.create!(name: "R35 Bank B", family: @family, owner: @primary,
      currency: "USD", balance: 0, status: "active",
      accountable_type: "Depository", accountable: Depository.new)
    @family.income_account_allocations.create!(
      income_series: @primary_series, account: bank_b, mode: "specific", value: 1.0
    )

    live = PaycheckFlowPlanner.plan_graph(family: @family, month: month)
    assert live[:limit_warnings].any? { |w| w[:income_id] == @primary_series.id }

    inputs = PaycheckFlowPlanner.graph_inputs_for(family: @family, month: month)
    draft = {
      incomes: inputs[:incomes],
      allocations: inputs[:allocations],
      plan_allocations: inputs[:plan_allocations],
      linked_bank_counts: {} # the scenario's (empty) edge set
    }
    replaced = PaycheckFlowPlanner.new(**inputs, draft: draft).plan_graph
    assert_empty replaced[:limit_warnings],
      "a wholesale-replaced (empty) count must clear the limit warning"
  end

  # --- scenario_incomes policy (the design) ---

  test "reuse policy all-enabled: scenario incomes match the live base" do
    snapshot = PlanScenarioSnapshot.reuse_current(@family)
    scenario = PaycheckFlowPlanner.scenario_incomes(family: @family, month: month, snapshot: snapshot)
    live = PaycheckFlowPlanner.inputs_for(family: @family, month: month)[:incomes]

    assert_equal live.map { |e| [ e[:id], e[:occurrences].map { |o| [ o[:date], o[:amount_cents] ] } ] },
                 scenario.map { |e| [ e[:id], e[:occurrences].map { |o| [ o[:date], o[:amount_cents] ] } ] },
      "an untouched re-use snapshot must carry the live occurrence base"
    scenario.each do |entry|
      refute_nil entry[:name], "income node names stay live (display-only)"
    end
  end

  test "enabled == false drops the series entirely" do
    scenario = PaycheckFlowPlanner.scenario_incomes(
      family: @family, month: month, snapshot: snapshot_with(secondary_policy: { "enabled" => false })
    )
    assert scenario.map { |e| e[:id] }.exclude?(@secondary_series.id),
      "a disabled series must be absent from the scenario base"
    assert_equal [ @primary_series.id ], scenario.map { |e| e[:id] }
  end

  test "zeroed zeroes the amounts (occurrences remain)" do
    scenario = PaycheckFlowPlanner.scenario_incomes(
      family: @family, month: month, snapshot: snapshot_with(secondary_policy: { "zeroed" => true })
    )
    secondary = scenario.find { |e| e[:id] == @secondary_series.id }
    refute_nil secondary
    assert secondary[:occurrences].all? { |o| o[:amount_cents].zero? }
    assert_equal 2, secondary[:occurrences].size, "dates stay; only the amounts zero"
  end

  test "gross_per_paycheck_cents replaces the amounts" do
    scenario = PaycheckFlowPlanner.scenario_incomes(
      family: @family, month: month,
      snapshot: snapshot_with(secondary_policy: { "gross_per_paycheck_cents" => 70_000 })
    )
    secondary = scenario.find { |e| e[:id] == @secondary_series.id }
    assert secondary[:occurrences].all? { |o| o[:amount_cents] == BigDecimal(70_000) }
  end

  test "a series absent from the policy passes through (override map, not a whitelist)" do
    snapshot = PlanScenarioSnapshot.reuse_current(@family)
    late = make_series(@primary, "Late Freelance", 250)
    late.recurring_occurrences.destroy_all
    late.recurring_occurrences.create!(
      family: @family, recurring_transaction: late, due_on: Date.new(2026, 11, 9),
      original_due_on: Date.new(2026, 11, 9), currency: "USD",
      expected_amount: 250, status: "scheduled"
    )
    # The snapshot (taken earlier) has no policy row for the late series.
    scenario = PaycheckFlowPlanner.scenario_incomes(family: @family, month: month, snapshot: snapshot)
    late_entry = scenario.find { |e| e[:id] == late.id }
    refute_nil late_entry, "a post-snapshot series must still appear"
    assert_equal BigDecimal(25_000), late_entry[:occurrences].first[:amount_cents]
  end

  test "the snapshot paycheck-config copy re-derives dates from the copy" do
    # Live config on Primary's series (biweekly, 60_000 gross).
    @family.family_paycheck_configs.create!(
      user: @primary, recurring_transaction: @primary_series,
      gross_per_paycheck_cents: 60_000, frequency: "biweekly",
      anchor_date: Date.new(2026, 11, 2)
    )
    snapshot = PlanScenarioSnapshot.reuse_current(@family)
    # The scenario edits the copy: semi_monthly, 55_000 gross.
    row = snapshot["paycheck_configs"].find { |c| c["recurring_transaction_id"] == @primary_series.id }
    refute_nil row
    row["gross_per_paycheck_cents"] = 55_000
    row["frequency"] = "semi_monthly"

    scenario = PaycheckFlowPlanner.scenario_incomes(family: @family, month: month, snapshot: snapshot)
    primary = scenario.find { |e| e[:id] == @primary_series.id }
    assert_equal [ Date.new(2026, 11, 15), Date.new(2026, 11, 30) ],
                 primary[:occurrences].map { |o| o[:date] },
      "semi_monthly = 15th + last day (the house Schedule engine)"
    assert primary[:occurrences].all? { |o| o[:amount_cents] == BigDecimal(55_000) }

    # The LIVE path is untouched by the scenario edit.
    live = PaycheckFlowPlanner.inputs_for(family: @family, month: month)[:incomes]
    primary_live = live.find { |e| e[:id] == @primary_series.id }
    assert primary_live[:occurrences].all? { |o| o[:amount_cents] == BigDecimal(60_000) }
  end

  # --- scenario_draft shape ---

  test "scenario_draft symbolizes the snapshot rows and derives linked_bank_counts" do
    snapshot = PlanScenarioSnapshot.reuse_current(@family)
    draft = PaycheckFlowPlanner.scenario_draft(family: @family, month: month, snapshot: snapshot)

    assert_equal PaycheckFlowPlanner.edge_rows(@family), draft[:allocations]
    assert_equal PaycheckFlowPlanner.plan_allocation_rows(@family), draft[:plan_allocations]
    assert_equal(
      @family.income_account_allocations.group(:income_series_id).count,
      draft[:linked_bank_counts]
    )
    assert draft[:allocations].all? { |row| row.keys.all? { |k| k.is_a?(Symbol) } }
  end

  test "a fresh (empty) scenario draft: live income base, zero rows" do
    snapshot = PlanScenarioSnapshot.fresh(@family)
    draft = PaycheckFlowPlanner.scenario_draft(family: @family, month: month, snapshot: snapshot)

    assert_empty draft[:allocations]
    assert_empty draft[:plan_allocations]
    assert_equal({}, draft[:linked_bank_counts])
    live = PaycheckFlowPlanner.inputs_for(family: @family, month: month)[:incomes]
    assert_equal live.map { |e| e[:id] }, draft[:incomes].map { |e| e[:id] },
      "Start Fresh = empty plan over the family's CURRENT incomes"
  end

  # --- second-income-quits end-to-end (the design) ---

  test "second-income-quits: the re-use snapshot with Secondary disabled plans Primary-only" do
    live = PaycheckFlowPlanner.plan_graph(family: @family, month: month)
    assert_empty live[:over_plans], "both incomes cover the rent — no live shortfall"

    scenario = PaycheckFlowPlanner.plan_graph(
      family: @family, month: month,
      draft: PaycheckFlowPlanner.scenario_draft(
        family: @family, month: month, snapshot: snapshot_with(secondary_policy: { "enabled" => false })
      )
    )

    # Secondary's income node is GONE; Primary's stays on the live occurrence base.
    income_ids = scenario[:incomes].map { |i| i[:id] }
    assert income_ids.exclude?(@secondary_series.id)
    assert_equal [ @primary_series.id ], income_ids
    primary = scenario[:incomes].first
    assert_equal "400.00", primary[:occurrences].first[:amount]
    assert_equal "800.00", primary[:total_month]

    # Primary-only funding is short of the $1000 rent: the over-plan line
    # surfaces. A specific-mode rent demands its FULL value_cents on every
    # funded date (the demand math prorates only required-mode bills), so
    # the gap is 2 x (100_000 demanded - 40_000 funded) = 120_000 cents.
    assert_equal 1, scenario[:over_plans].size
    over = scenario[:over_plans].first
    assert_equal @primary_series.id, over[:income_id]
    assert_equal "surplus", over[:target]
    assert_equal "1200.00", over[:shortfall_month]

    # Graph JSON valid: no nil node ids anywhere, and the rent row keeps
    # its bank assignment + wanted amount in the scenario plan.
    scenario[:incomes].each { |i| refute_nil i[:id] }
    scenario[:banks].each { |b| refute_nil b[:id] }
    scenario[:allocations].each { |a| refute_nil a[:id] }
    rent = scenario[:allocations].find { |a| a[:name] == "Rent" }
    refute_nil rent
    assert_equal @bank_a.id, rent[:account_id]
    # wanted is per-paycheck (specific demand is the full value on every
    # funded date): 2 dates x 100_000 cents.
    assert_equal "2000.00", rent[:wanted_month]
  end
end
