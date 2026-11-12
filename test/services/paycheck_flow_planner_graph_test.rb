require "test_helper"

# Pure-Ruby tests for plan_graph: the planning diagram's fixed
# bank-level resolution order, over-plan flags, unallocated remainders,
# limit warnings, and the draft merge. No ActiveRecord — same style as the
# PR#1 solver tests.
class PaycheckFlowPlannerGraphTest < ActiveSupport::TestCase
  P1 = "partner-1".freeze
  P2 = "partner-2".freeze

  def graph(month:, incomes:, allocations: [], obligations: {}, plan_allocations: [], required_amounts: {}, plan_max_links: {}, plan_roles: {}, auto_transfers: {}, plan_ordered: {}, linked_bank_counts: {}, recommendations: [], partners: [ P1 ], sub_account_links: {}, auto_transfer_targets: {}, account_names: {}, account_last4s: {}, account_bank_logos: {}, bank_logo_keywords: [], bank_logos: {}, categories: {}, draft: nil)
    PaycheckFlowPlanner.new(
      month: month,
      incomes: incomes,
      allocations: allocations,
      obligations_by_account: obligations,
      partners: partners,
      leftover_distribution: "income_ratio",
      currency: "USD",
      plan_allocations: plan_allocations,
      required_amounts: required_amounts,
      plan_max_links: plan_max_links,
      plan_roles: plan_roles,
      auto_transfers: auto_transfers,
      plan_ordered: plan_ordered,
      linked_bank_counts: linked_bank_counts,
      recommendations: recommendations,
      sub_account_links: sub_account_links,
      auto_transfer_targets: auto_transfer_targets,
      account_names: account_names,
      account_last4s: account_last4s,
      account_bank_logos: account_bank_logos,
      bank_logo_keywords: bank_logo_keywords,
      bank_logos: bank_logos,
      categories: categories,
      draft: draft
    ).plan_graph
  end

  def income(id:, owner_id: P1, amounts: [], name: "Paycheck")
    { id: id, name: name, owner_id: owner_id,
      occurrences: amounts.map.with_index do |cents, i|
        day = amounts.size.zero? ? 6 : 1 + (i * 30) / amounts.size
        { date: Date.new(2026, 11, day), amount_cents: BigDecimal(cents) }
      end }
  end

  # required_percent: the stored 2-dp percent of the bank's
  # required amount a required edge carries (nil = the equal split).
  def edge(income_id:, account_id:, mode:, value_cents: nil, value_percent: nil, required_percent: nil)
    { income_id: income_id, account_id: account_id, mode: mode,
      value_cents: value_cents, value_percent: value_percent,
      required_percent: required_percent }
  end

  def alloc(id:, account_id:, name: "Alloc", kind: "bill", mode: "required", value_cents: nil, value_percent: nil, recurring_transaction_id: nil, auto_transfer: false, category_id: nil, ownership: nil, distribution: nil, matching: nil, distribution_params: nil)
    { id: id, account_id: account_id, name: name, kind: kind, mode: mode,
      value_cents: value_cents, value_percent: value_percent,
      cadence: "monthly", recurring_transaction_id: recurring_transaction_id,
      auto_transfer: auto_transfer, category_id: category_id,
      # (Fun Money v2): the fun_money row's config (nil for every
      # non-fun_money row — additive keys).
      ownership: ownership, distribution: distribution, matching: matching,
      distribution_params: distribution_params }
  end

  # Numeric-identity normalization: the `plan_role` field on a bank row is an
  # INPUT echo (it differs between a run that passes plan_roles and one that
  # does not), not a resolution result. Strip it before a deep-equal so the
  # comparison isolates the resolver output (the cascade-vs-legacy question).
  def strip_roles(g)
    g.merge(banks: g[:banks].map { |b| b.reject { |k, _| k == :plan_role } })
  end

  # 1. the example: income 1000, bills 800 (required), fun 300 hard
  # -> bills paid first, fun gets 200 and the 100 gap is the over-plan flag,
  # RED on the fun money allocation.
  test "bills first: fun money short becomes the over-plan flag" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "b1", account_id: "chk", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(80_000)),
        alloc(id: "f1", account_id: "chk", name: "Fun", kind: "fun_money", mode: "specific", value_cents: BigDecimal(30_000))
      ]
    )

    bills = g[:allocations].find { |a| a[:id] == "b1" }
    fun = g[:allocations].find { |a| a[:id] == "f1" }
    assert_equal "800.00", bills[:wanted_month]
    assert_equal "800.00", bills[:got_month]
    assert_equal "ok", bills[:status]
    assert_equal false, bills[:over_planned]
    assert_equal "300.00", fun[:wanted_month]
    assert_equal "200.00", fun[:got_month]
    assert_equal "100.00", fun[:shortfall_month]
    assert_equal "partly", fun[:status]
    assert_equal true, fun[:over_planned]

    flag = g[:over_plans].find { |f| f[:income_id] == "A" }
    assert_equal "fun_money", flag[:target]
    assert_equal "f1", flag[:target_id]
    assert_equal "100.00", flag[:shortfall_month]
    assert_equal "100.00", g[:incomes].find { |i| i[:id] == "A" }[:over_plan][:shortfall_month]

    chk = g[:banks].find { |b| b[:id] == "chk" }
    assert_equal "1000.00", chk[:inflow_month]
    assert_equal "0.00", chk[:surplus_month]
    assert_equal "1000.00", chk[:inflow].find { |band| band[:income_id] == "A" }[:amount]
    assert_equal "0.00", g[:incomes].find { |i| i[:id] == "A" }[:unallocated_month]
  end

  # 2. Same gap with NO fun money planned: the flag lands on the
  # surplus/savings line (target "surplus", no allocation id).
  test "over-plan without fun money targets the surplus line" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "b1", account_id: "chk", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(80_000)),
        alloc(id: "s1", account_id: "chk", name: "Savings", kind: "savings", mode: "specific", value_cents: BigDecimal(30_000))
      ]
    )

    flag = g[:over_plans].find { |f| f[:income_id] == "A" }
    assert_equal "surplus", flag[:target]
    assert_nil flag[:target_id]
    assert_equal "100.00", flag[:shortfall_month]
    assert_equal false, g[:allocations].find { |a| a[:id] == "s1" }[:over_planned]
  end

  # 3. Percent mode takes its share of the bank's leftover pool — the
  # residual after required and specific, not the bank's inflow.
  test "percent mode resolves off the post-bill pool" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [
        edge(income_id: "A", account_id: "X", mode: "specific", value_cents: BigDecimal(40_000)),
        edge(income_id: "A", account_id: "Y", mode: "leftover")
      ],
      plan_allocations: [
        alloc(id: "b1", account_id: "Y", name: "Bills", mode: "required", value_cents: BigDecimal(20_000)),
        alloc(id: "s1", account_id: "Y", name: "Savings", kind: "savings", mode: "specific", value_cents: BigDecimal(10_000)),
        alloc(id: "p1", account_id: "Y", name: "Pct", kind: "savings", mode: "percent", value_percent: BigDecimal("0.5"))
      ]
    )

    # Y inflow 600; pool after bills 400; after specific 300; 50% -> 150.
    pct = g[:allocations].find { |a| a[:id] == "p1" }
    assert_equal "150.00", pct[:got_month]
    assert_equal "ok", pct[:status]
    y = g[:banks].find { |b| b[:id] == "Y" }
    assert_equal "150.00", y[:surplus_month] # 600 - 200 - 100 - 150
    x = g[:banks].find { |b| b[:id] == "X" }
    assert_equal "400.00", x[:surplus_month]
    assert_equal [], g[:over_plans]
  end

  # 4. Leftover mode splits the bank's final residual equally among the
  # leftover allocations; the last share absorbs the remainder exactly.
  test "leftover mode splits the residual equally" do
    two = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_001 ]) ],
      allocations: [ edge(income_id: "A", account_id: "L", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "l1", account_id: "L", kind: "savings", mode: "leftover"),
        alloc(id: "l2", account_id: "L", kind: "savings", mode: "leftover")
      ]
    )
    assert_equal "500.00", two[:allocations].find { |a| a[:id] == "l1" }[:got_month]
    assert_equal "500.01", two[:allocations].find { |a| a[:id] == "l2" }[:got_month]
    assert_equal "0.00", two[:banks].find { |b| b[:id] == "L" }[:surplus_month]

    three = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_003 ]) ],
      allocations: [ edge(income_id: "A", account_id: "L", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "l1", account_id: "L", kind: "savings", mode: "leftover"),
        alloc(id: "l2", account_id: "L", kind: "savings", mode: "leftover"),
        alloc(id: "l3", account_id: "L", kind: "savings", mode: "leftover")
      ]
    )
    gots = three[:allocations].map { |a| a[:id] }
    assert_equal "333.34", three[:allocations].find { |a| a[:id] == "l1" }[:got_month]
    assert_equal "333.34", three[:allocations].find { |a| a[:id] == "l2" }[:got_month]
    assert_equal "333.35", three[:allocations].find { |a| a[:id] == "l3" }[:got_month]
    assert_equal %w[l1 l2 l3], gots
  end

  # 5. Per-income unallocated remainder: money that never flows to a linked
  # bank (no leftover edge) is the hatched "Un-Allocated" band.
  test "income not flowing to any bank shows the unallocated remainder" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 50_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "S", mode: "specific", value_cents: BigDecimal(10_000)) ]
    )

    a = g[:incomes].find { |i| i[:id] == "A" }
    assert_equal "400.00", a[:unallocated_month]
    assert_equal [ "400.00" ], a[:unallocated].map { |row| row[:amount] }
    s = g[:banks].find { |b| b[:id] == "S" }
    assert_equal "100.00", s[:inflow_month]
    assert_equal [], g[:over_plans]
  end

  # 6. Link-limit warnings: linked bank count above plan_max_account_links
  # flags the income; at or under the limit nothing happens. A declared but
  # silent paycheck (no occurrences) still shows its warning.
  test "limit warnings on linked count above the income limit" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 50_000 ]), income(id: "B") ],
      allocations: [],
      plan_max_links: { "A" => 2, "B" => 1 },
      linked_bank_counts: { "A" => 3, "B" => 2 }
    )

    a = g[:incomes].find { |i| i[:id] == "A" }
    b = g[:incomes].find { |i| i[:id] == "B" }
    assert_equal({ linked_count: 3, limit: 2 }, a[:limit_warning])
    assert_equal({ linked_count: 2, limit: 1 }, b[:limit_warning]) # silent paycheck
    assert_equal "0.00", b[:total_month]
    assert_equal %w[A B], g[:limit_warnings].map { |w| w[:income_id] }

    at_limit = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 50_000 ]) ],
      plan_max_links: { "A" => 3 },
      linked_bank_counts: { "A" => 3 }
    )
    assert_nil at_limit[:incomes].first[:limit_warning]
    assert_equal [], at_limit[:limit_warnings]
  end

  # 7. Short bank: bills take everything they can (best-effort, status caps
  # at partly — bills are never the over-plan flag target), the non-bill item
  # goes to 0 and reads "over"; the flag still lands on the surplus line.
  test "short bank caps bills at partly and flags the surplus" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 50_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "B", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "b1", account_id: "B", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(80_000)),
        alloc(id: "s1", account_id: "B", name: "Savings", kind: "savings", mode: "specific", value_cents: BigDecimal(5_000))
      ]
    )

    bills = g[:allocations].find { |a| a[:id] == "b1" }
    savings = g[:allocations].find { |a| a[:id] == "s1" }
    assert_equal "500.00", bills[:got_month]
    assert_equal "300.00", bills[:shortfall_month]
    assert_equal "partly", bills[:status]
    assert_equal "0.00", savings[:got_month]
    assert_equal "over", savings[:status]
    assert_equal "0.00", g[:banks].find { |b| b[:id] == "B" }[:surplus_month] # bills took it all
    flag = g[:over_plans].find { |f| f[:income_id] == "A" }
    assert_equal "surplus", flag[:target]
    assert_equal "350.00", flag[:shortfall_month] # (800+50) - 500
  end

  # 8. Draft merge: a draft plan_allocations set replaces the saved rows
  # wholesale; a draft edges set replaces the saved income->bank edges.
  test "draft rows merge over the saved state" do
    saved_alloc = alloc(id: "a1", account_id: "chk", name: "Bills", value_cents: BigDecimal(50_000))
    draft_allocs = [
      alloc(id: "a1", account_id: "chk", name: "Bills", value_cents: BigDecimal(90_000)),
      alloc(id: "a2", account_id: "chk", name: "Fun", kind: "fun_money", mode: "specific", value_cents: BigDecimal(10_000))
    ]
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      plan_allocations: [ saved_alloc ],
      draft: { plan_allocations: draft_allocs }
    )

    assert_equal %w[a1 a2], g[:allocations].map { |a| a[:id] }
    a1 = g[:allocations].find { |a| a[:id] == "a1" }
    assert_equal "900.00", a1[:wanted_month] # draft value won
    assert_equal "Bills", a1[:name]

    # Edge draft: the saved leftover edge is replaced by a specific edge.
    g2 = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      draft: { allocations: [ edge(income_id: "A", account_id: "other", mode: "specific", value_cents: BigDecimal(30_000)) ] }
    )
    band = g2[:banks].find { |b| b[:id] == "other" }
    assert_equal "300.00", band[:inflow_month]
    assert_nil g2[:banks].find { |b| b[:id] == "chk" }
  end

  # 9. Recommendations pass through untouched; account roles and
  # auto-transfers surface on the bank nodes.
  test "recommendations and bank roles pass through" do
    recs = [
      { type: "recurring_transaction", recurring_transaction_id: "rt9", name: "Netflix",
        kind: "bill", cadence: "monthly", amount: BigDecimal("15.99"), account_id: "chk" }
    ]
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 50_000 ]) ],
      plan_roles: { "cc" => "credit_card_payoff" },
      auto_transfers: { "chk" => "cc" },
      recommendations: recs
    )

    assert_equal recs, g[:recommendations]
    cc = g[:banks].find { |b| b[:id] == "cc" }
    assert_equal "credit_card_payoff", cc[:plan_role]
    assert_equal "cc", g[:banks].find { |b| b[:id] == "chk" }[:auto_transfer_to_account_id]
  end

  # 10. Required mode with a linked recurring transaction and no explicit
  # value: the amount is the RT's monthly equivalent, prorated over the
  # month's paychecks.
  test "required allocation resolves from the linked RT monthly equivalent" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 10_000, 10_000, 10_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      plan_allocations: [
        alloc(id: "b1", account_id: "chk", name: "Netflix", recurring_transaction_id: "rt1")
      ],
      required_amounts: { "rt1" => BigDecimal(30_000) } # 300.00/month
    )

    b1 = g[:allocations].find { |a| a[:id] == "b1" }
    assert_equal "300.00", b1[:wanted_month]
    assert_equal 3, b1[:per_paycheck].size
    assert_equal "100.00", b1[:per_paycheck].first[:wanted] # 300 / 3
    assert_equal "ok", b1[:status]
    assert_equal "300.00", b1[:got_month]
  end

  # 11. Compat: with no plan allocations the graph keeps the PR#1 edge
  # resolution (required base from the raw recurring obligations) and every
  # bank's surplus is just its inflow; the old report is unchanged.
  test "empty allocation set keeps the PR#1 numbers" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 10_000 ]) ],
      allocations: [
        edge(income_id: "A", account_id: "accReq", mode: "required"),
        edge(income_id: "A", account_id: "accSpec", mode: "specific", value_cents: BigDecimal(5_000)),
        edge(income_id: "A", account_id: "accLeft", mode: "leftover")
      ],
      obligations: { "accReq" => BigDecimal(12_000) }
    )

    req = g[:banks].find { |b| b[:id] == "accReq" }
    spec = g[:banks].find { |b| b[:id] == "accSpec" }
    left = g[:banks].find { |b| b[:id] == "accLeft" }
    assert_equal "120.00", req[:inflow_month] # 120.00/month required edge
    assert_equal "50.00", spec[:inflow_month]
    assert_equal "-70.00", left[:inflow_month] # 100 - 120 - 50
    assert_equal "120.00", req[:surplus_month] # no allocations -> surplus = inflow
    assert_equal "-70.00", left[:surplus_month]
    assert_equal [], g[:over_plans]

    # The old entry point is untouched.
    plan = PaycheckFlowPlanner.new(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 10_000 ]) ],
      allocations: [
        edge(income_id: "A", account_id: "accReq", mode: "required"),
        edge(income_id: "A", account_id: "accSpec", mode: "specific", value_cents: BigDecimal(5_000)),
        edge(income_id: "A", account_id: "accLeft", mode: "leftover")
      ],
      obligations_by_account: { "accReq" => BigDecimal(12_000) },
      partners: [ P1 ],
      leftover_distribution: "income_ratio"
    ).plan
    assert_equal "-70.00", plan[:paychecks].first[:allocations].find { |x| x[:account_id] == "accLeft" }[:amount]
  end

  # 12. Two incomes into one bank: the band per income is its own edge
  # amount; the bank's allocations resolve off the combined inflow.
  test "two incomes into one bank share the combined inflow" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 60_000 ]),
        income(id: "B", owner_id: P2, amounts: [ 40_000 ])
      ],
      allocations: [
        edge(income_id: "A", account_id: "C", mode: "leftover"),
        edge(income_id: "B", account_id: "C", mode: "leftover")
      ],
      plan_allocations: [
        alloc(id: "s1", account_id: "C", kind: "savings", mode: "specific", value_cents: BigDecimal(30_000))
      ]
    )

    c = g[:banks].find { |b| b[:id] == "C" }
    assert_equal "1000.00", c[:inflow_month]
    assert_equal "600.00", c[:inflow].find { |band| band[:income_id] == "A" }[:amount]
    assert_equal "400.00", c[:inflow].find { |band| band[:income_id] == "B" }[:amount]
    s1 = g[:allocations].find { |a| a[:id] == "s1" }
    assert_equal "300.00", s1[:got_month]
    assert_equal "700.00", c[:surplus_month]
    assert_equal [], g[:over_plans]
  end

  # 13. The suggested fix travels from the PR#1 computation into the graph
  # report (kept where it still applies, null otherwise).
  test "suggested fix is carried into the graph report" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 100_000 ]),
        income(id: "B", owner_id: P2, amounts: [ 50_000 ])
      ],
      allocations: [
        edge(income_id: "A", account_id: "accPctA", mode: "percent", value_percent: BigDecimal(0.10)),
        edge(income_id: "A", account_id: "accLeftA", mode: "leftover"),
        edge(income_id: "B", account_id: "accPctB", mode: "percent", value_percent: BigDecimal(0.50)),
        edge(income_id: "B", account_id: "accLeftB", mode: "leftover")
      ],
      partners: [ P1, P2 ]
    )

    refute_nil g[:suggested_fix]
    assert_equal P1, g[:suggested_fix][:user_id]
    assert_equal "0.4250", g[:suggested_fix][:suggested_percent]
  end

  # (ghost banks): a plan-ordered account with no flow must be a
  # bank in the graph — the Add Account modal sets plan_order only, and a
  # bank the diagram does not draw is a ghost: gone from the add-accounts
  # modal yet invisible (and unreachable) on the map.
  test "plan-ordered accounts with no flow are banks carrying their plan_order" do
    plan = graph(
      month: Date.new(2026, 11, 15),
      incomes: [ income(id: "A", owner_id: P1, amounts: [ 100_000 ]) ],
      plan_ordered: { "ghost-bank" => 1 }
    )

    bank = plan[:banks].find { |b| b[:id] == "ghost-bank" }
    assert bank, "the added-but-unlinked bank must appear in the graph banks"
    assert_equal "0.00", bank[:inflow_month]
    assert_equal "0.00", bank[:surplus_month]
    assert_equal 1, bank[:plan_order]
    assert bank[:inflow].empty?
  end

  # (fan-out, plan_graph only): (a) the parent's
  # per-paycheck reservation includes the child bases, (b) a child with no
  # own required edge draws its share of the parent's post-allocation pool
  # on the parent's funding dates.
  test "fan-out: parent reservation includes child bases and the child gets its pool share" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "K", amounts: [ 90_000, 90_000 ]) ],
      allocations: [ edge(income_id: "K", account_id: "parent", mode: "required") ],
      plan_allocations: [
        alloc(id: "pb", account_id: "parent", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(40_000)),
        alloc(id: "cb", account_id: "child", name: "Bucket", kind: "savings", mode: "required", value_cents: BigDecimal(10_000))
      ],
      sub_account_links: { "child" => "parent" },
      auto_transfer_targets: { "parent" => [ "child" ] },
      account_names: { "parent" => "SoFi", "child" => "Bucket" }
    )

    # (a) Parent base = own 400 + child 100 = 500 over 2 funding paychecks.
    parent = g[:banks].find { |b| b[:id] == "parent" }
    assert_equal "500.00", parent[:inflow_month]
    assert_equal "250.00", parent[:inflow].first[:amount]

    # The parent's own bills pay first (200 of the 250 per paycheck).
    bills = g[:allocations].find { |a| a[:id] == "pb" }
    assert_equal "400.00", bills[:got_month]
    assert_equal "ok", bills[:status]

    # (b) The pool (50 per paycheck) splits by base share: the only child
    # gets 100% of it and its 100 monthly target is fully funded.
    bucket = g[:allocations].find { |a| a[:id] == "cb" }
    assert_equal "100.00", bucket[:wanted_month]
    assert_equal "100.00", bucket[:got_month]
    assert_equal "0.00", bucket[:shortfall_month]
    assert_equal "ok", bucket[:status]
    assert_equal "50.00", bucket[:per_paycheck].first[:wanted]
    assert_equal "50.00", bucket[:per_paycheck].first[:got]

    # Bank rows carry the sub-account link and the ordered targets.
    assert_equal false, parent[:sub_account]
    assert_nil parent[:parent_account_id]
    assert_equal [ "child" ], parent[:auto_transfer_target_ids]
    assert_equal "SoFi", parent[:name]
    child_row = g[:banks].find { |b| b[:id] == "child" }
    assert_equal true, child_row[:sub_account]
    assert_equal "parent", child_row[:parent_account_id]
    assert_equal "Bucket", child_row[:name]
  end

  # (fan-out): over-fan-out — the parent's own required
  # allocations resolve first, the buckets draw their base shares of what
  # is left, each short bucket reports its shortfall, and the over-plan
  # line names the income and the FIRST unsatisfied bucket (target order).
  test "fan-out over-plan: bills pay first, first unsatisfied bucket names the over-plan line" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "K", amounts: [ 30_000, 30_000 ]) ],
      allocations: [ edge(income_id: "K", account_id: "parent", mode: "specific", value_cents: BigDecimal(30_000)) ],
      plan_allocations: [
        alloc(id: "pb", account_id: "parent", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(40_000)),
        alloc(id: "c1", account_id: "c1", name: "Bucket One", kind: "savings", mode: "required", value_cents: BigDecimal(30_000)),
        alloc(id: "c2", account_id: "c2", name: "Bucket Two", kind: "savings", mode: "required", value_cents: BigDecimal(30_000))
      ],
      sub_account_links: { "c1" => "parent", "c2" => "parent" },
      auto_transfer_targets: { "parent" => [ "c1", "c2" ] },
      account_names: { "parent" => "SoFi", "c1" => "Bucket One", "c2" => "Bucket Two" }
    )

    # The parent's own allocation is covered by the 300 inflow per paycheck.
    bills = g[:allocations].find { |a| a[:id] == "pb" }
    assert_equal "400.00", bills[:got_month]
    assert_equal "ok", bills[:status]

    # The pool is 100 per paycheck (300 - 200); each bucket's base share is
    # 50 of its 150 wanted, so both end 200 short monthly.
    c1 = g[:allocations].find { |a| a[:id] == "c1" }
    c2 = g[:allocations].find { |a| a[:id] == "c2" }
    assert_equal "300.00", c1[:wanted_month]
    assert_equal "100.00", c1[:got_month]
    assert_equal "200.00", c1[:shortfall_month]
    assert_equal "200.00", c2[:shortfall_month]

    # The parent's surplus line reflects the fan-out consumption: the 200
    # pool left of the bills all went to the buckets, nothing hidden.
    parent = g[:banks].find { |b| b[:id] == "parent" }
    assert_equal "0.00", parent[:surplus_month]

    flag = g[:over_plans].find { |f| f[:income_id] == "K" }
    assert flag, "the over-plan line must name the short income"
    assert_equal "bucket", flag[:target]
    assert_equal "c1", flag[:target_id] # first unsatisfied in target order
    assert_equal "200.00", flag[:shortfall_month]
  end

  # a child WITH its own required
  # edges resolves the own-edge pool independently; the fan-out pool adds
  # on top. The child's base is counted ONCE in the parent's reservation
  # (no double counting), and the fan-out transfer beyond the already-met
  # target accumulates in the child's bank surplus, not the allocation row.
  test "fan-out with own-edge child: pools resolve independently, demand counted once" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "K", amounts: [ 50_000, 50_000 ]) ],
      allocations: [
        edge(income_id: "K", account_id: "parent", mode: "required"),
        edge(income_id: "K", account_id: "child", mode: "required")
      ],
      plan_allocations: [
        alloc(id: "pb", account_id: "parent", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(20_000)),
        alloc(id: "cb", account_id: "child", name: "Bucket", kind: "savings", mode: "required", value_cents: BigDecimal(10_000))
      ],
      sub_account_links: { "child" => "parent" },
      auto_transfer_targets: { "parent" => [ "child" ] }
    )

    # The child's own reservation: 100 base over 2 paychecks = 50 each.
    child = g[:banks].find { |b| b[:id] == "child" }
    assert_equal "100.00", child[:inflow_month]

    # The parent's reservation counts the child's base exactly once:
    # (200 + 100) / 2 = 150 per paycheck, not (200 + 100 + 100) / 2.
    parent = g[:banks].find { |b| b[:id] == "parent" }
    assert_equal "300.00", parent[:inflow_month]

    # The allocation's wanted stays its own proration (no double-counted
    # wanted) and it is fully funded from the own-edge pool.
    bucket = g[:allocations].find { |a| a[:id] == "cb" }
    assert_equal "100.00", bucket[:wanted_month]
    assert_equal "100.00", bucket[:got_month]
    assert_equal "0.00", bucket[:shortfall_month]
    assert_equal "ok", bucket[:status]

    # The fan-out transfer (the 50-per-paycheck pool) tops up nothing —
    # the target is met — so it accumulates in the child's bank surplus.
    assert_equal "100.00", child[:surplus_month]
    assert_equal "0.00", parent[:surplus_month]
    assert_empty g[:over_plans]
  end

  # (fan-out, draft parity): the fan-out inputs are
  # SAVED state, not draftable — a wholesale draft edge swap must leave
  # the sub-account/fan-out inputs intact and resolve against the drafted
  # inflow.
  test "fan-out inputs survive the draft merge (parity unchanged)" do
    base = {
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "K", amounts: [ 90_000, 90_000 ]) ],
      plan_allocations: [
        alloc(id: "pb", account_id: "parent", name: "Bills", kind: "bill", mode: "required", value_cents: BigDecimal(40_000)),
        alloc(id: "cb", account_id: "child", name: "Bucket", kind: "savings", mode: "required", value_cents: BigDecimal(10_000))
      ],
      sub_account_links: { "child" => "parent" },
      auto_transfer_targets: { "parent" => [ "child" ] }
    }

    plain = graph(
      allocations: [ edge(income_id: "K", account_id: "parent", mode: "required") ],
      **base
    )
    drafted = graph(
      allocations: [ edge(income_id: "K", account_id: "parent", mode: "required") ],
      draft: { allocations: [ edge(income_id: "K", account_id: "parent", mode: "percent", value_percent: 0.5) ] },
      **base
    )

    # The saved fan-out inputs are untouched by the wholesale edge swap.
    parent = drafted[:banks].find { |b| b[:id] == "parent" }
    assert_equal [ "child" ], parent[:auto_transfer_target_ids]
    assert_equal true, drafted[:banks].find { |b| b[:id] == "child" }[:sub_account]

    # The drafted inflow (450 per paycheck) funds the bills (200) and the
    # pool (250); the bucket takes its 50 wanted and the excess 200
    # accumulates in the child's bank surplus.
    assert_equal "450.00", parent[:inflow].first[:amount]
    bucket = drafted[:allocations].find { |a| a[:id] == "cb" }
    assert_equal "100.00", bucket[:got_month]
    assert_equal "ok", bucket[:status]
    assert_equal "400.00", drafted[:banks].find { |b| b[:id] == "child" }[:surplus_month]
    assert_equal "0.00", parent[:surplus_month]
  end

  # the plaintext last-4 rides on every bank row,
  # nil when the account has no mask — never a fabricated digit.
  test "bank rows carry the last-4 map value, nil when the bank has no mask" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [
        edge(income_id: "A", account_id: "chk", mode: "leftover"),
        edge(income_id: "A", account_id: "sav", mode: "leftover")
      ],
      account_names: { "chk" => "SoFi Savings", "sav" => "Navy Savings" },
      account_last4s: { "chk" => "1234" }
    )

    chk = g[:banks].find { |b| b[:id] == "chk" }
    sav = g[:banks].find { |b| b[:id] == "sav" }
    assert_equal "1234", chk[:last4]
    assert_nil sav[:last4]
  end

  # the logo slug resolution order — explicit
  # per-account override wins when usable; otherwise the first (longest-first)
  # keyword hit on the account name; otherwise nil. Only slugs from the
  # vendored set are ever emitted.
  test "bank rows carry the logo slug in resolution order (explicit, keyword, nil)" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [
        edge(income_id: "A", account_id: "sofi", mode: "leftover"),
        edge(income_id: "A", account_id: "navy", mode: "leftover"),
        edge(income_id: "A", account_id: "other", mode: "leftover"),
        edge(income_id: "A", account_id: "stale", mode: "leftover")
      ],
      account_names: {
        "sofi" => "SoFi Savings",
        "navy" => "NAVY Vari Bills",
        "other" => "Some Unknown Bank",
        "stale" => "Stale Override"
      },
      # "sofi" has an explicit slug; "stale" has an explicit slug that is NOT
      # in the vendored set (must fall through to the keyword match, miss, nil).
      account_bank_logos: { "sofi" => "sofi", "stale" => "not-vendored" },
      bank_logo_keywords: [ [ "navyfederal", "navy-federal" ], [ "navy", "navy-federal" ], [ "sofi", "sofi" ] ],
      bank_logos: { "sofi" => "SoFi", "navy-federal" => "Navy Federal Credit Union" }
    )

    assert_equal "sofi", g[:banks].find { |b| b[:id] == "sofi" }[:logo]
    # "NAVY Vari Bills" normalizes to "navyvaribills" -> keyword "navy" hit.
    assert_equal "navy-federal", g[:banks].find { |b| b[:id] == "navy" }[:logo]
    assert_nil g[:banks].find { |b| b[:id] == "other" }[:logo]
    # Explicit slug missing from the vendored set is ignored, no keyword hit.
    assert_nil g[:banks].find { |b| b[:id] == "stale" }[:logo]
    # The usable logo set rides at the payload root, sorted by label.
    assert_equal [ { slug: "navy-federal", label: "Navy Federal Credit Union" },
                   { slug: "sofi", label: "SoFi" } ],
                 g[:available_bank_logos]
  end

  # longest keyword wins when several match.
  test "longest keyword wins when several match the account name" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "navyfed", mode: "leftover") ],
      account_names: { "navyfed" => "Navy Federal Savings" },
      # Both keywords hit the normalized name; the LONGER one must win.
      # (If "navy" were tried first it would resolve to "ally" instead.)
      bank_logo_keywords: [ [ "navy", "ally" ], [ "navyfederal", "navy-federal" ] ],
      bank_logos: { "ally" => "Ally Financial", "navy-federal" => "Navy Federal Credit Union" }
    )

    assert_equal "navy-federal", g[:banks].find { |b| b[:id] == "navyfed" }[:logo]
  end

  # the allocation rows carry the Sure category's
  # name + color so the diagram band matches the category; nil / nil when the
  # allocation has no category (never a fabricated color).
  test "allocation rows carry the category name and color, nil when unset" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      account_names: { "chk" => "SoFi Savings" },
      plan_allocations: [
        alloc(id: "b1", account_id: "chk", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(50_000), category_id: "cat-1"),
        alloc(id: "b2", account_id: "chk", name: "No Cat", kind: "bill",
              mode: "required", value_cents: BigDecimal(20_000), category_id: nil)
      ],
      categories: { "cat-1" => { name: "Groceries", color: "#6172F3" } }
    )

    b1 = g[:allocations].find { |a| a[:id] == "b1" }
    b2 = g[:allocations].find { |a| a[:id] == "b2" }
    assert_equal "Groceries", b1[:category_name]
    assert_equal "#6172F3", b1[:category_color]
    assert_nil b2[:category_name]
    assert_nil b2[:category_color]
  end

  # a category id that is NOT in the categories map
  # (deleted / foreign) still reads nil — no fabricated color.
  test "allocation rows read nil when the category id is absent from the map" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      account_names: { "chk" => "SoFi Savings" },
      plan_allocations: [
        alloc(id: "b1", account_id: "chk", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(50_000), category_id: "missing")
      ],
      categories: {}
    )

    b1 = g[:allocations].find { |a| a[:id] == "b1" }
    assert_nil b1[:category_name]
    assert_nil b1[:category_color]
  end

  # the required split (P1). A stored percent split of the bank's
  # required base charges each income its monthly share spread over its
  # occurrences; the monthly inflow still sums EXACTLY to the base
  # (monthly-preserving settlement — the UI readout formula is a separate
  # concern, D-RECON).
  test "required percents split the base 30/70 over two incomes (P1)" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 50_000, 50_000 ]),
        income(id: "B", owner_id: P2, amounts: [ 50_000, 50_000 ])
      ],
      allocations: [
        edge(income_id: "A", account_id: "bank", mode: "required", required_percent: BigDecimal("30.00")),
        edge(income_id: "B", account_id: "bank", mode: "required", required_percent: BigDecimal("70.00"))
      ],
      plan_allocations: [
        alloc(id: "b1", account_id: "bank", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(10_000))
      ]
    )

    bank = g[:banks].find { |b| b[:id] == "bank" }
    a_bands = bank[:inflow].select { |band| band[:income_id] == "A" }
    b_bands = bank[:inflow].select { |band| band[:income_id] == "B" }
    assert_equal [ "15.00", "15.00" ], a_bands.map { |band| band[:amount] }
    assert_equal [ "35.00", "35.00" ], b_bands.map { |band| band[:amount] }
    # Monthly shares 3_000 / 7_000; the month sums exactly to the base.
    assert_equal BigDecimal("30.00"), a_bands.sum { |band| BigDecimal(band[:amount]) }
    assert_equal BigDecimal("70.00"), b_bands.sum { |band| BigDecimal(band[:amount]) }
    assert_equal "100.00", bank[:inflow_month]
    assert_equal "100.00", g[:allocations].find { |a| a[:id] == "b1" }[:got_month]
    assert_equal "ok", g[:allocations].find { |a| a[:id] == "b1" }[:status]
  end

  # a 33.33/33.33/33.34 split (the equal-split derivation's
  # 3-income shape, summing to exactly 100.00) — the last income absorbs
  # the rounding residue, so the monthly shares sum to the base EXACTLY.
  test "required percents 33.33/33.33/33.34: last income absorbs to the base (P2)" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 50_000, 50_000 ]),
        income(id: "B", owner_id: P1, amounts: [ 50_000, 50_000 ]),
        income(id: "C", owner_id: P2, amounts: [ 50_000, 50_000 ])
      ],
      allocations: [
        edge(income_id: "A", account_id: "bank", mode: "required", required_percent: BigDecimal("33.33")),
        edge(income_id: "B", account_id: "bank", mode: "required", required_percent: BigDecimal("33.33")),
        edge(income_id: "C", account_id: "bank", mode: "required", required_percent: BigDecimal("33.34"))
      ],
      plan_allocations: [
        alloc(id: "b1", account_id: "bank", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(10_000))
      ]
    )

    bank = g[:banks].find { |b| b[:id] == "bank" }
    a = bank[:inflow].select { |band| band[:income_id] == "A" }.sum { |band| BigDecimal(band[:amount]) }
    b = bank[:inflow].select { |band| band[:income_id] == "B" }.sum { |band| BigDecimal(band[:amount]) }
    c = bank[:inflow].select { |band| band[:income_id] == "C" }.sum { |band| BigDecimal(band[:amount]) }
    assert_equal BigDecimal("33.33"), a
    assert_equal BigDecimal("33.33"), b
    assert_equal BigDecimal("33.34"), c # 10_000 - 3_333 - 3_333 (last absorbs)
    assert_equal "100.00", bank[:inflow_month]
  end

  # a 33/33/34 split on an odd base (10_001) — the non-last
  # shares round half-up individually; the last income absorbs so the
  # monthly total is the base to the cent.
  test "required percents 33/33/34 on an odd base: last absorbs the cent (P3)" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 50_000, 50_000 ]),
        income(id: "B", owner_id: P1, amounts: [ 50_000, 50_000 ]),
        income(id: "C", owner_id: P2, amounts: [ 50_000, 50_000 ])
      ],
      allocations: [
        edge(income_id: "A", account_id: "bank", mode: "required", required_percent: BigDecimal("33.00")),
        edge(income_id: "B", account_id: "bank", mode: "required", required_percent: BigDecimal("33.00")),
        edge(income_id: "C", account_id: "bank", mode: "required", required_percent: BigDecimal("34.00"))
      ],
      plan_allocations: [
        alloc(id: "b1", account_id: "bank", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(10_001))
      ]
    )

    bank = g[:banks].find { |b| b[:id] == "bank" }
    a = bank[:inflow].select { |band| band[:income_id] == "A" }.sum { |band| BigDecimal(band[:amount]) }
    b = bank[:inflow].select { |band| band[:income_id] == "B" }.sum { |band| BigDecimal(band[:amount]) }
    c = bank[:inflow].select { |band| band[:income_id] == "C" }.sum { |band| BigDecimal(band[:amount]) }
    assert_equal BigDecimal("33.00"), a # 10_001 * 0.33 -> 3_300.33 -> 3_300
    assert_equal BigDecimal("33.00"), b
    assert_equal BigDecimal("34.01"), c # 10_001 - 3_300 - 3_300 (last absorbs 1c)
    assert_equal "100.01", bank[:inflow_month]
  end

  # nil percents (every required edge stores nothing) are
  # TODAY'S behavior — each paycheck occurrence charges the full
  # required-per-paycheck figure; the stop-rule byte-identity rests on
  # this path.
  test "nil required percents keep today's per-paycheck charge (P4)" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 50_000, 50_000 ]),
        income(id: "B", owner_id: P2, amounts: [ 50_000, 50_000 ])
      ],
      allocations: [
        edge(income_id: "A", account_id: "bank", mode: "required"),
        edge(income_id: "B", account_id: "bank", mode: "required")
      ],
      plan_allocations: [
        alloc(id: "b1", account_id: "bank", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(10_000))
      ]
    )

    bank = g[:banks].find { |b| b[:id] == "bank" }
    # 4 funding occurrences -> 2_500c ($25.00) each, every occurrence.
    assert_equal [ "25.00", "25.00", "25.00", "25.00" ], bank[:inflow].map { |band| band[:amount] }
    assert_equal "100.00", bank[:inflow_month]
  end

  # a split summing to less than 100 (30/40) is
  # allowed — NO absorb: the charges are the raw shares, the month funds
  # only the split total, and the shortfall surfaces on the required
  # allocation via the existing report fields.
  test "under-100 required percents fund the raw shares, no absorb (P5)" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 50_000, 50_000 ]),
        income(id: "B", owner_id: P2, amounts: [ 50_000, 50_000 ])
      ],
      allocations: [
        edge(income_id: "A", account_id: "bank", mode: "required", required_percent: BigDecimal("30.00")),
        edge(income_id: "B", account_id: "bank", mode: "required", required_percent: BigDecimal("40.00"))
      ],
      plan_allocations: [
        alloc(id: "b1", account_id: "bank", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(10_000))
      ]
    )

    bank = g[:banks].find { |b| b[:id] == "bank" }
    a = bank[:inflow].select { |band| band[:income_id] == "A" }.sum { |band| BigDecimal(band[:amount]) }
    b = bank[:inflow].select { |band| band[:income_id] == "B" }.sum { |band| BigDecimal(band[:amount]) }
    assert_equal BigDecimal("30.00"), a
    assert_equal BigDecimal("40.00"), b
    assert_equal "70.00", bank[:inflow_month] # no absorb: 3_000 + 4_000
    bill = g[:allocations].find { |a| a[:id] == "b1" }
    assert_equal "100.00", bill[:wanted_month]
    assert_equal "70.00", bill[:got_month]
    assert_equal "30.00", bill[:shortfall_month] # dollars, like wanted/got
    assert_equal "partly", bill[:status]
  end

  # (Fun Money v2) — the per-income reconciliation (B_k / S_k /
  # L_k / FM_k) + the Un-Allocated discrepancies. the worked
  # example is a MANDATORY test case with exact
  # payload values.
  #
  # Setup (monthly, single occurrence each on 2026-11-01):
  #   Income A $1000.00 (member A) | Income B $500.00 (member B)
  # Bills $900.00/mo required on bank X (funded 100% by A)
  # Savings $250.00/mo specific on bank Y (funded 100% by B)
  #   Fun Money row: ownership = member A, matching = Equalize,
  #                  mode = Leftover.
  #   L_A = 1000 - 900 - 0 = 100.00 | L_B = 500 - 0 - 250 = 250.00
  #   T = max(0, min(100, 250)) = 100.00 -> FM_A = FM_B = 100.00
  test "Round 31A: owner worked example — Equalize member ownership (exact payload)" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 100_000 ], name: "Income A"),
        income(id: "B", owner_id: P2, amounts: [ 50_000 ], name: "Income B")
      ],
      allocations: [
        edge(income_id: "A", account_id: "X", mode: "required"),
        edge(income_id: "B", account_id: "Y", mode: "leftover")
      ],
      partners: [ P1, P2 ],
      plan_allocations: [
        alloc(id: "b1", account_id: "X", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(90_000)),
        alloc(id: "s1", account_id: "Y", name: "Savings", kind: "savings",
              mode: "specific", value_cents: BigDecimal(25_000)),
        alloc(id: "fm1", account_id: "X", name: "Fun money", kind: "fun_money",
              mode: "leftover", ownership: P1, matching: "equalize")
      ]
    )

    a = g[:incomes].find { |i| i[:id] == "A" }
    b = g[:incomes].find { |i| i[:id] == "B" }
    assert_equal(
      { bills_month: "900.00", savings_month: "0.00", fun_money_month: "100.00",
        allocated_month: "1000.00", un_allocated_month: "0.00" },
      a[:reconciliation]
    )
    assert_equal(
      { bills_month: "0.00", savings_month: "250.00", fun_money_month: "100.00",
        allocated_month: "350.00", un_allocated_month: "150.00" },
      b[:reconciliation]
    )

    # RED line: income B un-allocates 150.00 (strictly above the $1.00
    # tolerance); income A (0.00) has none.
    assert_equal(
      [ { income_id: "B", income_name: "Income B", un_allocated_month: "150.00" } ],
      g[:discrepancies]
    )

    # The fun_money row's per-member rows (the other rows get nil).
    fm = g[:allocations].find { |x| x[:id] == "fm1" }
    assert_equal(
      [
        { member_id: P1, leftover_month: "100.00", fun_money_month: "100.00",
          un_allocated_month: "0.00" },
        { member_id: P2, leftover_month: "250.00", fun_money_month: "100.00",
          un_allocated_month: "150.00" }
      ],
      fm[:per_member]
    )
    # The config echoes on the fun_money row only; no pinned snapshot
    # reads inputs_stale false (the amber prompt fires only on divergence).
    assert_equal P1, fm[:ownership]
    assert_equal "equalize", fm[:matching]
    assert_equal false, fm[:inputs_stale]
    assert_nil g[:allocations].find { |x| x[:id] == "b1" }[:per_member]
    assert_nil g[:allocations].find { |x| x[:id] == "b1" }[:ownership]
    assert_not_nil a[:reconciliation]
  end

  # Per Income matching — each member's FM is the mode
  # function on their OWN leftover; the worked example's B keeps 250.00
  # (no Un-Allocated line: both incomes are fully allocated).
  test "Round 31A: per income matching — leftover mode, no discrepancies" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 100_000 ], name: "Income A"),
        income(id: "B", owner_id: P2, amounts: [ 50_000 ], name: "Income B")
      ],
      allocations: [
        edge(income_id: "A", account_id: "X", mode: "required"),
        edge(income_id: "B", account_id: "Y", mode: "leftover")
      ],
      partners: [ P1, P2 ],
      plan_allocations: [
        alloc(id: "b1", account_id: "X", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(90_000)),
        alloc(id: "s1", account_id: "Y", name: "Savings", kind: "savings",
              mode: "specific", value_cents: BigDecimal(25_000)),
        alloc(id: "fm1", account_id: "X", name: "Fun money", kind: "fun_money",
              mode: "leftover", ownership: P1, matching: "per_income")
      ]
    )

    assert_equal(
      [
        { member_id: P1, leftover_month: "100.00", fun_money_month: "100.00",
          un_allocated_month: "0.00" },
        { member_id: P2, leftover_month: "250.00", fun_money_month: "250.00",
          un_allocated_month: "0.00" }
      ],
      g[:allocations].find { |x| x[:id] == "fm1" }[:per_member]
    )
    assert_equal [], g[:discrepancies]
  end

  # Distribution "Individual Leftover by Allocations"
  # forces the Per Income matching semantics even when the row stores
  # matching "equalize" (rows saved before the dialog lock existed).
  test "Round 31A: individual_leftover distribution coerces per_income" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 100_000 ], name: "Income A"),
        income(id: "B", owner_id: P2, amounts: [ 50_000 ], name: "Income B")
      ],
      allocations: [
        edge(income_id: "A", account_id: "X", mode: "required"),
        edge(income_id: "B", account_id: "Y", mode: "leftover")
      ],
      partners: [ P1, P2 ],
      plan_allocations: [
        alloc(id: "b1", account_id: "X", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(90_000)),
        alloc(id: "s1", account_id: "Y", name: "Savings", kind: "savings",
              mode: "specific", value_cents: BigDecimal(25_000)),
        alloc(id: "fm1", account_id: "X", name: "Fun money", kind: "fun_money",
              mode: "leftover", ownership: P1, matching: "equalize",
              distribution: "individual_leftover")
      ]
    )

    # Equalize would give both 100.00; the coercion gives each their own
    # leftover (100.00 / 250.00).
    assert_equal(
      [ "100.00", "250.00" ],
      g[:allocations].find { |x| x[:id] == "fm1" }[:per_member].map { |row| row[:fun_money_month] }
    )
  end

  # Household ownership ( /) — the shared pool reconciles at
  # the AGGREGATE level only (no per-income reconciliation; the per-member
  # rows are the distribution's DISPLAY split). FM_total is the row's
  # resolved got; the aggregate gap labels "Household".
  test "Round 31A: household ownership — aggregate reconciliation + display split" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 100_000 ], name: "Income A"),
        income(id: "B", owner_id: P2, amounts: [ 50_000 ], name: "Income B")
      ],
      allocations: [
        edge(income_id: "A", account_id: "X", mode: "required"),
        edge(income_id: "B", account_id: "Y", mode: "leftover")
      ],
      partners: [ P1, P2 ],
      plan_allocations: [
        alloc(id: "b1", account_id: "X", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(90_000)),
        alloc(id: "s1", account_id: "Y", name: "Savings", kind: "savings",
              mode: "specific", value_cents: BigDecimal(25_000)),
        # Legacy household row (no config at all) + a 100.00/mo Hard Number
        # on bank Y (B's leftover feeds it) -> got 100.00.
        alloc(id: "fm1", account_id: "Y", name: "Fun money", kind: "fun_money",
              mode: "specific", value_cents: BigDecimal(10_000)),
        # Household + distribution percent: 40/60 display split.
        alloc(id: "fm2", account_id: "Y", name: "Fun money 2", kind: "fun_money",
              mode: "leftover", ownership: "household", distribution: "percent",
              distribution_params: { "percents" => { P1 => "40.00", P2 => "60.00" } })
      ]
    )

    # The FIRST fun_money row (fm1, sort order) drives the reconciliation.
    a = g[:incomes].find { |i| i[:id] == "A" }
    b = g[:incomes].find { |i| i[:id] == "B" }
    assert_nil a[:reconciliation]
    assert_nil b[:reconciliation]

    # L_A = 100.00, L_B = 250.00 -> aggregate 350.00; FM_total = 100.00
    # (fm1's got on Y) -> Household gap 250.00 (strictly above tolerance).
    assert_equal(
      [ { income_id: nil, income_name: "Household", un_allocated_month: "250.00" } ],
      g[:discrepancies]
    )

    fm1 = g[:allocations].find { |x| x[:id] == "fm1" }
    # Equal display split of the 100.00 pool (distribution nil -> equal).
    assert_equal(
      [ "50.00", "50.00" ],
      fm1[:per_member].map { |row| row[:fun_money_month] }
    )
  end

  # the 100-cent tolerance is STRICT — a 98-cent un-allocated
  # residual shows no line; 101 cents does.
  test "Round 31A: tolerance boundary (98c silent, 101c labeled)" do
    build = lambda do |bill_cents|
      graph(
        month: Date.new(2026, 11, 1),
        incomes: [ income(id: "A", owner_id: P1, amounts: [ 100_000 ], name: "Income A") ],
        allocations: [ edge(income_id: "A", account_id: "X", mode: "required") ],
        plan_allocations: [
          alloc(id: "b1", account_id: "X", name: "Bills", kind: "bill",
                mode: "required", value_cents: BigDecimal(bill_cents)),
          alloc(id: "fm1", account_id: "X", name: "Fun money", kind: "fun_money",
                mode: "specific", value_cents: BigDecimal(1),
                ownership: P1, matching: "per_income")
        ]
      )
    end

    assert_equal [], build.call(99_901)[:discrepancies] # 98c residual
    assert_equal(
      [ { income_id: "A", income_name: "Income A", un_allocated_month: "1.01" } ],
      build.call(99_898)[:discrepancies] # 101c residual = $1.01
    )
  end

  # the input snapshot — an exact match reads fresh, a
  # divergent I_k reads stale (the amber prompt; never a red mismatch).
  test "Round 31A: inputs_stale vs the C14 snapshot" do
    base = lambda do |snapshot|
      graph(
        month: Date.new(2026, 11, 1),
        incomes: [
          income(id: "A", owner_id: P1, amounts: [ 100_000 ], name: "Income A"),
          income(id: "B", owner_id: P2, amounts: [ 50_000 ], name: "Income B")
        ],
        allocations: [
          edge(income_id: "A", account_id: "X", mode: "required"),
          edge(income_id: "B", account_id: "Y", mode: "leftover")
        ],
        plan_allocations: [
          alloc(id: "b1", account_id: "X", name: "Bills", kind: "bill",
                mode: "required", value_cents: BigDecimal(90_000)),
          alloc(id: "fm1", account_id: "X", name: "Fun money", kind: "fun_money",
                mode: "leftover", ownership: P1, matching: "equalize",
                distribution_params: { "inputs_snapshot" => snapshot })
        ]
      )
    end

    # This fixture has no savings row, so S is 0 for both incomes.
    fresh = { "A" => { "i" => 100_000, "b" => 90_000, "s" => 0 },
              "B" => { "i" => 50_000, "b" => 0, "s" => 0 } }
    stale_income = { "A" => { "i" => 95_000, "b" => 90_000, "s" => 0 },
                     "B" => { "i" => 50_000, "b" => 0, "s" => 0 } }
    stale_missing = { "A" => { "i" => 100_000, "b" => 90_000, "s" => 0 } }

    assert_equal false, base.call(fresh)[:allocations].find { |x| x[:id] == "fm1" }[:inputs_stale]
    assert_equal true, base.call(stale_income)[:allocations].find { |x| x[:id] == "fm1" }[:inputs_stale]
    assert_equal true, base.call(stale_missing)[:allocations].find { |x| x[:id] == "fm1" }[:inputs_stale]
    assert_equal false, base.call(nil)[:allocations].find { |x| x[:id] == "fm1" }[:inputs_stale]
  end

  # an UNLABELED income (owner_id nil) still reconciles — its
  # residual enters the rows (income_name nil -> the "an income" chrome
  # fallback) but it never joins the Equalize min.
  test "Round 31A: unlabeled income excluded from Equalize min, still labeled" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [
        income(id: "A", owner_id: P1, amounts: [ 100_000 ], name: "Income A"),
        income(id: "B", owner_id: P2, amounts: [ 50_000 ], name: "Income B"),
        # name nil: the chrome falls back to "an income".
        income(id: "C", owner_id: nil, amounts: [ 20_000 ], name: nil)
      ],
      allocations: [
        edge(income_id: "A", account_id: "X", mode: "required"),
        edge(income_id: "B", account_id: "Y", mode: "leftover")
      ],
      partners: [ P1, P2 ],
      plan_allocations: [
        alloc(id: "b1", account_id: "X", name: "Bills", kind: "bill",
              mode: "required", value_cents: BigDecimal(90_000)),
        alloc(id: "fm1", account_id: "X", name: "Fun money", kind: "fun_money",
              mode: "leftover", ownership: P1, matching: "equalize")
      ]
    )

    # C's 200.00 residual never lowers the Equalize target (T stays 100.00).
    c = g[:incomes].find { |i| i[:id] == "C" }
    assert_equal "200.00", c[:reconciliation][:un_allocated_month]
    assert_equal "0.00", g[:incomes].find { |i| i[:id] == "A" }[:reconciliation][:un_allocated_month]
    # B un-allocates 400.00 (this fixture has no savings row: L_B = 500.00
    # minus the 100.00 Equalize target); C's 200.00 residual carries no
    # name -> the chrome's "an income" fallback.
    assert_equal(
      [
        { income_id: "B", income_name: "Income B", un_allocated_month: "400.00" },
        { income_id: "C", income_name: nil, un_allocated_month: "200.00" }
      ],
      g[:discrepancies]
    )
  end

  # (stop-rule): plan — the paycheck-plans payload — is
  # byte-identical with the fun_money config fields present on the
  # plan_allocations rows (plan derives required only from the
  # obligations; the new fields never reach it).
  test "Round 31A: plan() byte-identical with fun_money fields (stop-rule)" do
    common = {
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", owner_id: P1, amounts: [ 100_000, 100_000 ]) ],
      allocations: [ edge(income_id: "A", account_id: "chk", mode: "leftover") ],
      obligations_by_account: { "chk" => BigDecimal(80_000) },
      partners: [ P1 ],
      leftover_distribution: "income_ratio",
      currency: "USD",
      required_amounts: {}, plan_max_links: {}, plan_roles: {},
      auto_transfers: {}, plan_ordered: {}, linked_bank_counts: {},
      recommendations: [], sub_account_links: {}, auto_transfer_targets: {},
      account_names: {}, account_last4s: {}, account_bank_logos: {},
      bank_logo_keywords: [], bank_logos: {}, categories: {}
    }
    bill = alloc(id: "b1", account_id: "chk", name: "Bills", kind: "bill",
                 mode: "required", value_cents: BigDecimal(80_000))
    fm = alloc(id: "fm1", account_id: "chk", name: "Fun money", kind: "fun_money",
               mode: "leftover", ownership: P1, distribution: "equal",
               matching: "equalize",
               distribution_params: { "percents" => { P1 => "100.00" } })

    plain = PaycheckFlowPlanner.new(**common, plan_allocations: [ bill ]).plan
    with_fm = PaycheckFlowPlanner.new(**common, plan_allocations: [ bill, fm ]).plan
    assert_equal JSON.pretty_generate(plain), JSON.pretty_generate(with_fm)
    assert_equal plain, with_fm
  end

  # ---------------------------------------------------------------------
  # the funding-priority CASCADE.
  # Tiers come from the account's plan_role (checking -> funding-first,
  # savings_bucket -> short-carrying); within a tier the LAST committed
  # row (last in band order) goes short first. A charged edge whose account
  # has no usable plan_role AND no plan allocations keeps the legacy
  # behavior for that occurrence (byte-identical, negative leftover
  # allowed) — the stop rule.
  # ---------------------------------------------------------------------

  # The demo-shaped leg: P 2700.00/paycheck (2 occurrences), = 2450.00
  # (fully funded), = 1200.00 in band order sav1 -> sav2; the 950.00/
  # paycheck excess hits LAST-COMMITTED-FIRST: sav1 funded 250.00 short
  # 825.00, sav2 (last) funded 0.00 short 125.00. The leftover edge takes
  # exactly 0 (structurally non-negative) — no negative inflow row.
  test "Round 36: cascade funds T1 fully, T2 goes short last-committed-first" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 270_000, 270_000 ], name: "Bob Payroll") ],
      allocations: [
        edge(income_id: "A", account_id: "c1", mode: "required"),
        edge(income_id: "A", account_id: "c2", mode: "required"),
        edge(income_id: "A", account_id: "c3", mode: "required"),
        edge(income_id: "A", account_id: "s1", mode: "required"),
        edge(income_id: "A", account_id: "s2", mode: "required"),
        edge(income_id: "A", account_id: "lo", mode: "leftover")
      ],
      plan_allocations: [
        alloc(id: "a1", account_id: "c1", name: "Auto Bills", kind: "bill", mode: "required", value_cents: BigDecimal(360_000)),
        alloc(id: "a2", account_id: "c2", name: "Vari Bills", kind: "bill", mode: "required", value_cents: BigDecimal(80_000)),
        alloc(id: "a3", account_id: "c3", name: "Groceries", kind: "bill", mode: "required", value_cents: BigDecimal(50_000)),
        alloc(id: "a4", account_id: "s1", name: "Savings A", kind: "savings", mode: "required", value_cents: BigDecimal(215_000)),
        alloc(id: "a5", account_id: "s2", name: "Savings B", kind: "savings", mode: "required", value_cents: BigDecimal(25_000))
      ],
      plan_roles: {
        "c1" => "checking", "c2" => "checking", "c3" => "checking",
        "s1" => "savings_bucket", "s2" => "savings_bucket"
      }
    )

    a1 = g[:allocations].find { |a| a[:id] == "a1" }
    a2 = g[:allocations].find { |a| a[:id] == "a2" }
    a3 = g[:allocations].find { |a| a[:id] == "a3" }
    a4 = g[:allocations].find { |a| a[:id] == "a4" }
    a5 = g[:allocations].find { |a| a[:id] == "a5" }
    # (checking) is fully funded at the full MONTHLY figure (value_cents
    # is monthly; 2 paychecks => x2 the per-paycheck charge).
    [ [ "3600.00", "0.00" ], [ "800.00", "0.00" ], [ "500.00", "0.00" ] ].zip([ a1, a2, a3 ]).each do |(got, short), a|
      assert_equal got, a[:got_month]
      assert_equal short, a[:shortfall_month]
      assert_equal "ok", a[:status]
    end
    # (savings_bucket): the 250.00/paycheck remainder funds sav1 in band
    # order; sav1 short 825.00/paycheck (1650.00/mo), sav2 — the LAST
    # committed row — takes the whole 125.00/paycheck gap (250.00/mo).
    # House status: a fully defunded row is "over" (over_planned), a
    # partially funded one "partly".
    assert_equal "500.00", a4[:got_month]
    assert_equal "1650.00", a4[:shortfall_month]
    assert_equal "partly", a4[:status]
    assert_equal "0.00", a5[:got_month]
    assert_equal "250.00", a5[:shortfall_month]
    assert_equal "over", a5[:status]

    # ROOT over-plan: per-paycheck excess 950.00 x 2 occurrences = 1900.00
    # monthly, on the surplus line (no fun money planned).
    flag = g[:over_plans].find { |f| f[:income_id] == "A" }
    assert_equal "surplus", flag[:target]
    assert_nil flag[:target_id]
    assert_equal "1900.00", flag[:shortfall_month]
    assert_equal "1900.00", g[:incomes].find { |i| i[:id] == "A" }[:over_plan][:shortfall_month]

    # No negative inflow anywhere: the leftover edge takes exactly 0.00
    # (the legacy client-clamped wavy row is gone at the source).
    g[:banks].each do |bank|
      bank[:inflow].each { |band| assert_operator band[:amount].to_f, :>=, 0.0 }
    end
    lo = g[:banks].find { |b| b[:id] == "lo" }
    assert_equal "0.00", lo[:inflow].find { |band| band[:income_id] == "A" }[:amount]
  end

  # The scratch leg: the same plan with P cut to 2000.00/paycheck. is
  # 100% short (both rows funded 0.00); the excess (450.00/paycheck)
  # splits LAST-COMMITTED-FIRST in band order: c1 covered, c2 funded
  # 200.00 short 200.00, c3 (last) funded 0.00 short 250.00.
  test "Round 36: cascade scratch leg shorts T2 fully, then T1 last-committed-first" do
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 200_000, 200_000 ], name: "Bob Payroll") ],
      allocations: [
        edge(income_id: "A", account_id: "c1", mode: "required"),
        edge(income_id: "A", account_id: "c2", mode: "required"),
        edge(income_id: "A", account_id: "c3", mode: "required"),
        edge(income_id: "A", account_id: "s1", mode: "required"),
        edge(income_id: "A", account_id: "s2", mode: "required")
      ],
      plan_allocations: [
        alloc(id: "a1", account_id: "c1", name: "Auto Bills", kind: "bill", mode: "required", value_cents: BigDecimal(360_000)),
        alloc(id: "a2", account_id: "c2", name: "Vari Bills", kind: "bill", mode: "required", value_cents: BigDecimal(80_000)),
        alloc(id: "a3", account_id: "c3", name: "Groceries", kind: "bill", mode: "required", value_cents: BigDecimal(50_000)),
        alloc(id: "a4", account_id: "s1", name: "Savings A", kind: "savings", mode: "required", value_cents: BigDecimal(215_000)),
        alloc(id: "a5", account_id: "s2", name: "Savings B", kind: "savings", mode: "required", value_cents: BigDecimal(25_000))
      ],
      plan_roles: {
        "c1" => "checking", "c2" => "checking", "c3" => "checking",
        "s1" => "savings_bucket", "s2" => "savings_bucket"
      }
    )

    a1 = g[:allocations].find { |a| a[:id] == "a1" }
    a2 = g[:allocations].find { |a| a[:id] == "a2" }
    a3 = g[:allocations].find { |a| a[:id] == "a3" }
    a4 = g[:allocations].find { |a| a[:id] == "a4" }
    a5 = g[:allocations].find { |a| a[:id] == "a5" }
    # (1200.00/paycheck of the 1650.00 excess) is 100% short ("over").
    [ a4, a5 ].each do |a|
      assert_equal "0.00", a[:got_month]
      assert_equal "over", a[:status]
    end
    assert_equal "2150.00", a4[:shortfall_month]
    assert_equal "250.00", a5[:shortfall_month]
    # excess 450.00/paycheck LAST-COMMITTED-FIRST: c1 covered 1800.00;
    # c2 funded 200.00 short 200.00 (per-paycheck; monthly doubles); c3 —
    # the last committed row — funded 0.00 short 250.00.
    assert_equal "3600.00", a1[:got_month]
    assert_equal "0.00", a1[:shortfall_month]
    assert_equal "400.00", a2[:got_month]
    assert_equal "400.00", a2[:shortfall_month]
    assert_equal "0.00", a3[:got_month]
    assert_equal "500.00", a3[:shortfall_month]
    # ROOT over-plan: 1650.00/paycheck x 2 = 3300.00 monthly.
    flag = g[:over_plans].find { |f| f[:income_id] == "A" }
    assert_equal "3300.00", flag[:shortfall_month]
  end

  # The identity gate: with no shortfall (P >= + ) the cascade is the
  # identity — the report is deep-equal to the legacy (no plan_roles)
  # resolution. This is the unit-level guard behind the Default payload
  # byte pin.
  test "Round 36: cascade is the identity when nothing is short (deep-equal to legacy)" do
    build = lambda do |roles|
      graph(
        month: Date.new(2026, 11, 1),
        incomes: [ income(id: "A", amounts: [ 400_000, 400_000 ], name: "Bob Payroll") ],
        allocations: [
          edge(income_id: "A", account_id: "c1", mode: "required"),
          edge(income_id: "A", account_id: "s1", mode: "required"),
          edge(income_id: "A", account_id: "lo", mode: "leftover")
        ],
        plan_allocations: [
          alloc(id: "a1", account_id: "c1", name: "Auto Bills", kind: "bill", mode: "required", value_cents: BigDecimal(360_000)),
          alloc(id: "a2", account_id: "s1", name: "Savings A", kind: "savings", mode: "required", value_cents: BigDecimal(215_000))
        ],
        plan_roles: roles
      )
    end
    cascade = build.call({ "c1" => "checking", "s1" => "savings_bucket" })
    legacy = build.call({})
    # plan_role is an input echo on the bank rows — normalized out above;
    # every resolution field (inflow, got, shortfall, over_plans, ...) is
    # deep-equal: with no shortfall the cascade is the identity.
    assert_equal strip_roles(legacy), strip_roles(cascade)
  end

  # The stop rule: a CHARGED edge on an account with no usable plan_role
  # AND no plan allocations keeps the LEGACY resolution for that
  # occurrence (negative leftover allowed, byte-identical to the
  # no-roles run) — the legacy behavior that the PR#1 compatibility test
  # pins.
  test "Round 36: unclassified charged edge keeps the legacy occurrence" do
    build = lambda do |roles|
      graph(
        month: Date.new(2026, 11, 1),
        incomes: [ income(id: "A", amounts: [ 50_000, 50_000 ], name: "Bob Payroll") ],
        allocations: [
          edge(income_id: "A", account_id: "chk", mode: "specific", value_cents: BigDecimal(70_000)),
          edge(income_id: "A", account_id: "lo", mode: "leftover")
        ],
        plan_roles: roles
      )
    end
    legacy = build.call({})
    flagged = build.call({ "lo" => "checking" })
    # The presence of a plan_role on an UNCHARGED account (the leftover
    # bank) must not pull the charged, unclassified occurrence into the
    # cascade — byte-identical to the no-roles (legacy) resolution
    # (plan_role normalized out: input echo, not a resolution result).
    assert_equal strip_roles(legacy), strip_roles(flagged)
    # Legacy semantics survive: the specific edge reserves 700.00 against a
    # 500.00 paycheck — the leftover bank carries the NEGATIVE monthly
    # inflow (2 x -200.00), NOT clamped to 0.00 (the legacy behavior the
    # PR#1 compatibility test pins as "-70.00").
    lo = legacy[:banks].find { |b| b[:id] == "lo" }
    assert_equal "-400.00", lo[:inflow_month]
  end

  # The proration documentation (design doc: documented, not fixed): the
  # ROOT figure is the exact monthly sum of the per-paycheck gaps. With a
  # half-cent per-paycheck shortfall (1010.665) the money display
  # truncates to "1010.66" — so 2 x the DISPLAYED per-paycheck figure
  # (2021.32) differs from the exact monthly figure (2021.33) by the
  # display truncation only. The monthly figure is the source of truth.
  test "Round 36: half-cent per-paycheck gap displays 1010.66 but the monthly figure is 2021.33" do
    # The demo-shaped plan with the EXACT demo half-cent: = 2510.665/
    # paycheck (5021.33/mo, a1's required split is the half-cent carrier),
    # = 1075.00 + 125.00/paycheck, P = 2700.00/paycheck.
    g = graph(
      month: Date.new(2026, 11, 1),
      incomes: [ income(id: "A", amounts: [ 270_000, 270_000 ], name: "Bob Payroll") ],
      allocations: [
        edge(income_id: "A", account_id: "c1", mode: "required"),
        edge(income_id: "A", account_id: "s1", mode: "required"),
        edge(income_id: "A", account_id: "s2", mode: "required")
      ],
      plan_allocations: [
        # 2510.665/paycheck (the exact demo figure incl. its half-cent).
        alloc(id: "a1", account_id: "c1", name: "Checking", kind: "bill", mode: "required", value_cents: BigDecimal(502_133)),
        # 1075.00 + 125.00/paycheck.
        alloc(id: "a2", account_id: "s1", name: "Savings A", kind: "savings", mode: "required", value_cents: BigDecimal(215_000)),
        alloc(id: "a3", account_id: "s2", name: "Savings B", kind: "savings", mode: "required", value_cents: BigDecimal(25_000))
      ],
      plan_roles: { "c1" => "checking", "s1" => "savings_bucket", "s2" => "savings_bucket" }
    )
    flag = g[:over_plans].find { |f| f[:income_id] == "A" }
    # Per-paycheck short = 2510.665 + 1200.00 - 2700.00 = 1010.665 (a
    # half-cent). The MONTHLY figure is the exact 2021.33 = 2 x 1010.665;
    # the per-paycheck figure DISPLAYS as 1010.66 (money truncates the
    # half-cent), so 2 x the displayed per-paycheck figure (2021.32) differs
    # from the exact monthly figure (2021.33) by the display truncation
    # only — documented, not fixed (design doc).
    assert_equal "2021.33", flag[:shortfall_month]
    per_paycheck_display = format("%.2f", 101_066.5 / 100)
    assert_equal "1010.66", per_paycheck_display
    # The 1-cent proration, pinned: 2 x the DISPLAYED per-paycheck figure
    # is 2021.32, one cent off the exact monthly figure.
    assert_equal "2021.32", format("%.2f", per_paycheck_display.to_f * 2)
  end
end
