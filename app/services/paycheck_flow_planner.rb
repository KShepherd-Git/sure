# frozen_string_literal: true

# Paycheck Flow Planner: resolves a family's money map for one calendar
# month — which declared income series funds which account at which mode, how
# monthly obligations prorate over that month's ACTUAL paycheck occurrences
# (biweekly months with 2 vs 3 paychecks come out right), where the leftover
# (fun money) lands, and how it is attributed between partners.
#
# Pure Ruby: the instance holds plain data (hashes, Dates, integer-cent
# BigDecimals) and `plan` never touches ActiveRecord. `for_family` is the
# single AR seam — it fetches the inputs at the top and hands them to the
# pure core, so the math is testable with literal hashes.
#
# Money: integer cents (BigDecimal) in the family currency, mirrored from
# RecurringTransaction::PaycheckPlanner#to_family_currency. Rounding happens
# only at the percent edges (half-up to the cent); the leftover edge absorbs
# the remainder, and everything downstream stays exact.
class PaycheckFlowPlanner
  CENTS = 100

  # The single ActiveRecord seam: fetch the month's inputs at the top, then
  # hand the pure core its data.
  #
  # Occurrences are the declared manual income series' scheduled AND paid
  # arrivals inside the month window (paid so past-month views show what
  # actually paid). Obligations are the family's active recurring bills
  # (bill / subscription / installment) paid from the account — the same
  # payable shape PaycheckPlanner funds — monthly-equivalent in family
  # currency. A series is attributed to the holder of the account its income lands
  # in (the income table itself carries no attribution column).
  def self.for_family(family:, month:)
    new(**inputs_for(family: family, month: month)).plan
  end

  # The `new` kwargs for one month, fetched from AR. Split out of for_family
  # so callers (the flow page's draft preview) can swap :allocations for a
  # shadow set without re-fetching.
  def self.inputs_for(family:, month:)
    window = month.beginning_of_month..month.end_of_month

    occurrences = family.recurring_occurrences
                        .where(status: %w[scheduled paid])
                        .where(due_on: window)
                        .joins(:recurring_transaction)
                        .where(recurring_transactions: { status: :active, bill_type: :income, manual: true })
                        .includes(recurring_transaction: { account: :owner })
                        # ( fix): deterministic tie-break. Two
                        # income series sharing a due_on date previously
                        # ordered by physical (heap) position, leaking into
                        # the incomes array order. :created_at keeps the
                        # meaningful insertion order (the order the streams
                        # were added), which the per-income report ordering
                        # (first leftover row) depends on; :id is only a
                        # final safety net for an identical timestamp.
                        .order(:due_on, :created_at, :id)
                        .to_a

    incomes = occurrences.each_with_object({}) do |occurrence, map|
      series = occurrence.recurring_transaction
      entry = map[series.id] ||= {
        id: series.id,
        # Explicit flow label when set, else the landing account's holder.
        owner_id: series.plan_owner_id,
        occurrences: []
      }
      entry[:occurrences] << {
        date: occurrence.due_on,
        amount_cents: to_family_cents(occurrence.resolved_expected_amount_money, family.currency)
      }
    end.values

    # (Direct Deposit): the paycheck-config overlay — derived pay
    # dates + gross replace/appended per configured member series. ZERO
    # config rows returns the SAME array untouched (the no-op invariant:
    # byte-identical planner output with no configs).
    incomes = overlay_paycheck_configs(family: family, month: month, incomes: incomes)

    debt_accounts = Account.where(family_id: family.id, accountable_type: %w[CreditCard Loan]).select(:id)
    obligations = family.recurring_transactions
                        .where(status: :active, bill_type: %w[bill subscription installment])
                        .where.not(account_id: nil)
                        .merge(
                          RecurringTransaction.where(destination_account_id: nil).or(
                            RecurringTransaction.where(destination_account_id: debt_accounts)
                          )
                        )
                        .to_a
                        .group_by { |series| series.account_id }
                        .transform_values do |series|
                          series.sum { |bill| to_family_cents(bill.monthly_equivalent_amount, family.currency) }
                        end

    {
      month: month,
      incomes: incomes,
      allocations: edge_rows(family),
      obligations_by_account: obligations,
      partners: family.users.order(:created_at, :id).pluck(:id),
      leftover_distribution: family.family_plan_settings&.leftover_distribution || "income_ratio"
    }
  end

  # (Direct Deposit): the paycheck-config overlay. For each
  # configured member it replaces (or appends) that member's labeled income
  # series' occurrences with the pay dates + gross derived from the config,
  # via PaycheckDates (the house Schedule engine — no new math).
  #
  # Idempotent, and a byte-identical NO-OP with ZERO config rows: it returns
  # the SAME `incomes` array untouched (the gate asserts exactly this).
  #
  # invariant (design doc proof): this touches ONLY `incomes`. The
  # allocation "wanted" amounts come from plan_allocations/obligations
  # (edge_rows), which are IMMUTABLE to this overlay — income amount/dates
  # flow only via @incomes -> resolve_edges -> bank_inflow. asserts the
  # wanted-immutable + inflow-delta behavior.
  # configs: nil (default) reads the family's saved configs — the live
  # path, byte-identical to the legacy body. A prebuilt array of
  # (possibly unsaved) FamilyPaycheckConfig instances lets a Flow Scenario
  # re-derive pay dates from its snapshot copy without touching the live
  # table (the design).
  def self.overlay_paycheck_configs(family:, month:, incomes:, configs: nil)
    configs = family.family_paycheck_configs.to_a if configs.nil?
    return incomes if configs.empty?

    window = month.beginning_of_month..month.end_of_month
    by_id = {}
    incomes.each { |entry| by_id[entry[:id]] = entry }

    appends = []
    configs.each do |config|
      series_id = config.recurring_transaction_id
      next if series_id.nil? # nil series: nothing to map onto (v1 saves require one)

      # Only a live, member-labeled income series is a valid overlay target
      # (the model enforces family + bill_type + member; re-check here so a
      # config pointing at a foreign/ended series is a no-op, not a 500).
      series = family.recurring_transactions
                     .find_by(id: series_id, status: :active, bill_type: :income, manual: true)
      next if series.nil?

      derived = PaycheckDates.occurrences(config, window.first, window.last)
      if (entry = by_id[series.id])
        entry[:occurrences] = derived # REPLACE the stored occurrences
      else
        appends << { id: series.id, owner_id: series.plan_owner_id, occurrences: derived }
      end
    end

    return incomes if appends.empty?

    # Append in series :id order ( byte-stable) — the stored-occurrence
    # entries keep their (due_on, created_at, id) order ahead of them.
    appends.sort_by! { |entry| entry[:id] }
    incomes + appends
  end

  # the scenario's :incomes base.
  # Composes the LIVE inputs_for incomes (zero-config path untouched)
  # re-overlaid with the scenario's paycheck-config snapshot copy as
  # UNSAVED instances (nothing is persisted), then the per-series income
  # policy. The policy is an override map, not a whitelist — a series
  # missing from it passes through unchanged (live-derived), so series the
  # user adds after the snapshot still appear in the scenario.
  #
  # Policy rows ({ series_id, enabled, zeroed, gross_per_paycheck_cents }):
  # enabled == false -> the series is dropped from the base
  # zeroed -> its occurrence amounts become 0
  # gross_per_paycheck_cents -> its occurrence amounts become that value
  # (any other row) -> untouched
  #
  # Names are display-only and stay LIVE (the design: "readouts/logos/
  # names" are non-snapshotted, nil-safe): the inputs_for base carries no
  # name, but the sankey labels income nodes by series display_name, so a
  # re-used scenario must render identical to the Default view. Deleted
  # series stay nil (nil-safe).
  def self.scenario_incomes(family:, month:, snapshot:)
    incomes = inputs_for(family: family, month: month)[:incomes]

    config_rows = Array(snapshot["paycheck_configs"])
    configs = config_rows.map do |row|
      # A corrupted anchor_date must not 500 the scenario readout: an
      # unparseable row is skipped as if the member had no config (the
      # biweekly schedule math needs a real anchor, so a nil-anchor copy
      # is unusable).
      anchor_date = parse_snapshot_date(row["anchor_date"])
      next if anchor_date.nil?

      FamilyPaycheckConfig.new(
        user_id: row["user_id"],
        recurring_transaction_id: row["recurring_transaction_id"],
        gross_per_paycheck_cents: row["gross_per_paycheck_cents"],
        frequency: row["frequency"],
        anchor_date: anchor_date
      )
    end.compact
    incomes = overlay_paycheck_configs(family: family, month: month, incomes: incomes, configs: configs)

    series_names = family.recurring_transactions
                         .where(id: incomes.map { |entry| entry[:id] }, status: :active, bill_type: :income, manual: true)
                         .index_by(&:id)
    policy = (Array(snapshot["incomes"]) || []).to_h { |row| [ row["series_id"], row ] }
    incomes.map do |entry|
      row = policy[entry[:id]]
      next nil if row && row["enabled"] == false # series switched off inside the scenario

      base = entry
      if row && row["zeroed"]
        base = entry.merge(occurrences: entry[:occurrences].map { |o| o.merge(amount_cents: BigDecimal(0)) })
      elsif row && row["gross_per_paycheck_cents"]
        base = entry.merge(occurrences: entry[:occurrences].map { |o| o.merge(amount_cents: BigDecimal(row["gross_per_paycheck_cents"])) })
      end
      base.merge(name: series_names[entry[:id]]&.display_name)
    end.compact
  end

  # A snapshot anchor_date string, parsed; blank or unparseable -> nil.
  # (Same rescue/nil guard idiom as PlanFlowsController#parse_snapshot_date,
  # which carries the CashFlowsController#parse_date guard.)
  def self.parse_snapshot_date(value)
    return nil if value.blank?

    Date.parse(value)
  rescue Date::Error
    # A snapshot that cannot be anchored by date is a support-relevant
    # scenario failure (the scenario then plans from a nil anchor).
    DebugLogEntry.capture(
      category: "paycheck_planner",
      level: "warn",
      message: "Unparseable snapshot date in PaycheckFlowPlanner#parse_snapshot_date",
      source: "PaycheckFlowPlanner",
      metadata: { value: value.to_s }
    )
    nil
  end

  # the snapshot's numeric fields, normalized for the planner's
  # BigDecimal arithmetic. The jsonb round-trip stringifies BigDecimals
  # (ActiveSupport's BigDecimal#as_json -> to_s), and required-mode edge
  # percents are stored as the form's major-unit string — so a scenario row
  # read back from the column can carry String numerics. The live draft
  # paths (inputs_for / the controller's form merge) carry real Ruby values,
  # which this also normalizes (idempotent on BigDecimal/Integer/Float).
  SCENARIO_NUMERIC_FIELDS = %i[value_cents value_percent required_percent].freeze

  def self.scenario_row(row)
    normalized = row.symbolize_keys
    SCENARIO_NUMERIC_FIELDS.each do |key|
      normalized[key] = BigDecimal(normalized[key].to_s) if normalized[key]
    end
    normalized
  end

  # the full draft payload for a
  # scenario — the snapshot's stored rows (string-keyed in the jsonb
  # column) symbolized + numerically normalized to the planner's key shape,
  # plus the live scenario_incomes base. linked_bank_counts is derived from
  # the snapshot edge rows exactly like graph_shadow does from the live
  # table, so the per-income limit warnings stay consistent with what the
  # scenario plans. Callers merge the form's unsaved dialog rows on top
  # (the controller's graph_draft / render_flow_json path) before plan_graph.
  def self.scenario_draft(family:, month:, snapshot:)
    snapshot_allocations = Array(snapshot["allocations"])
    {
      incomes: scenario_incomes(family: family, month: month, snapshot: snapshot),
      allocations: snapshot_allocations.map { |row| scenario_row(row) },
      plan_allocations: Array(snapshot["plan_allocations"]).map { |row| scenario_row(row) },
      linked_bank_counts: snapshot_allocations.group_by { |row| row["income_id"] }.transform_values(&:size)
    }
  end

  # The family's income -> bank edge rows in the planner's key shape (the
  # draft-able `allocations` set). Shared by inputs_for and the controller's
  # draft merge so the two can never drift.
  # this read had NO ORDER BY, so the
  # physical (heap) order of the table leaked into the graph — the SHA
  # drift (the upserted po5 edge row re-serialized at banks[5] instead of
  # banks[3]). Ordered by the natural key (income series, account): an
  # upserted edge (destroy + recreate) keeps its position, so the
  # serialization is byte-stable across upserts. h proposed
  # .order(:created_at, :id), but creation order cannot satisfy that
  # property (a recreate gets the newest created_at and moves to the end),
  # so the natural key supersedes it.
  def self.edge_rows(family)
    family.income_account_allocations.order(:income_series_id, :account_id).to_a.map do |allocation|
      {
        income_id: allocation.income_series_id,
        account_id: allocation.account_id,
        mode: allocation.mode,
        value_cents: allocation.mode == "specific" ? allocation.value * CENTS : nil,
        value_percent: allocation.mode == "percent" ? allocation.value : nil,
        # a required-mode edge carries the stored percent of the
        # bank's required amount this income funds (2 dp major units; nil =
        # the equal split, today's behavior). The legacy plan path ignores
        # the key (its resolve_edges call passes no split map).
        required_percent: allocation.mode == "required" ? allocation.value : nil
      }
    end
  end

  # Money in the family currency, in integer cents. An unconvertible amount
  # is unknown, and unknown must not be dressed up as zero fun money — but
  # same-currency families (the common case) never hit this. The conversion
  # failure is support-relevant (the amount is unknown downstream), so it
  # lands in the debug log; only the AR seam calls this, never `plan`.
  def self.to_family_cents(money, currency)
    (money.exchange_to(currency).amount * CENTS).round(0, half: :up)
  rescue Money::ConversionError
    DebugLogEntry.capture(
      category: "paycheck_planner",
      level: "warn",
      message: "Unconvertible amount zeroed in PaycheckFlowPlanner#to_family_cents",
      source: "PaycheckFlowPlanner",
      metadata: { source_currency: money.currency.iso_code, target_currency: currency }
    )
    BigDecimal(0)
  end

  # the planning-diagram entry point. Same pure core +
  # AR-seam shape as for_family, but the inputs also carry the bank -> item
  # allocations, the income link limits, the account roles, and the
  # recommendations the page's "Recommended" list reads.
  #
  # `draft` merges unsaved UI state over the saved inputs (the PR#2 preview
  # pattern): each key present — :allocations (income -> bank edges),
  # plan_allocations (bank -> item allocations), :plan_max_links,
  # plan_roles, :incomes — replaces the saved set WHOLESALE. The controller
  # composes the shadow set; the planner never reads the database.
  def self.plan_graph(family:, month:, draft: nil)
    new(**graph_inputs_for(family: family, month: month), draft: draft).plan_graph
  end

  # The `new` kwargs for plan_graph: everything inputs_for fetches (the edge
  # level + PR#1 report), plus the allocation-level inputs.
  def self.graph_inputs_for(family:, month:)
    base = inputs_for(family: family, month: month)

    # Every declared active manual income series — not just the ones with
    # occurrences this month — so the link-limit warnings and the diagram's
    # income nodes show a configured-but-silent paycheck.
    series_by_id = family.recurring_transactions
                         .where(status: :active, bill_type: "income", manual: true)
                         # ( fix): `missing` series are
                         # appended to the incomes array in read order; the
                         # unordered read leaked the heap order.
                         .order(:id)
                         .index_by(&:id)
    enriched = base[:incomes].map do |income|
      series = series_by_id[income[:id]]
      income.merge(name: series ? series.display_name : nil)
    end
    missing = series_by_id.keys - base[:incomes].map { |income| income[:id] }
    incomes = enriched + missing.map do |id|
      {
        id: id,
        name: series_by_id[id].display_name,
        owner_id: series_by_id[id].plan_owner_id,
        occurrences: []
      }
    end

    base.merge(
      incomes: incomes,
      currency: family.currency,
      **graph_shadow(family),
      recommendations: recommendation_rows(family)
    )
  end

  # The raw shadow set of the draft-able inputs — the same rows the planner
  # receives from the AR seam. A controller merges the form's draft rows over
  # this set and hands the whole thing back as `draft:` (the planner applies
  # each present key wholesale), so a preview never re-queries per row.
  def self.graph_shadow(family)
    {
      plan_allocations: plan_allocation_rows(family),
      required_amounts: required_amount_rows(family),
      plan_max_links: family.recurring_transactions
                            .where(status: :active, bill_type: "income")
                            .where.not(plan_max_account_links: nil)
                            .pluck(:id, :plan_max_account_links)
                            .to_h,
      plan_roles: family.accounts.where.not(plan_role: nil).pluck(:id, :plan_role).to_h,
      auto_transfers: family.accounts
                       .where.not(auto_transfer_to_account_id: nil)
                       .pluck(:id, :auto_transfer_to_account_id)
                       .to_h,
      # the sub-account links (child => parent) and the
      # ordered auto-transfer fan-out targets (parent => [child_ids]). The
      # array order is the diagram's band order, so the raw column flows
      # through untouched; empty arrays are dropped (no fan-out declared).
      sub_account_links: family.accounts
                          .where.not(parent_account_id: nil)
                          .pluck(:id, :parent_account_id)
                          .to_h,
      auto_transfer_targets: family.accounts
                              .pluck(:id, :auto_transfer_target_ids)
                              .reject { |_id, targets| Array(targets).empty? }
                              .to_h,
      # bank display names (the over-plan line names the
      # unsatisfied bucket; the sankey labels themselves come from page
      # state, so this is payload-side only).
      account_names: family.accounts.pluck(:id, :name).to_h,
      # the plaintext last-4 of each bank from
      # plaid_accounts.mask via account_providers (accounts.plaid_account_id
      # is NULL everywhere in dev; the live link is account_providers with
      # provider_type "PlaidAccount"). Blank masks emit nil — the payload
      # NEVER carries fabricated digits.
      account_last4s: account_last4s_for(family),
      # the explicit per-account logo slugs
      # (accounts.bank_logo_slug, set from the bank config dialog's picker)
      # plus the pure input maps for keyword auto-match + the vendored set.
      # Resolution happens in build_graph_report (explicit -> keyword -> nil)
      # so the pure-core tests cover the order.
      account_bank_logos: family.accounts
                            .where.not(bank_logo_slug: nil)
                            .pluck(:id, :bank_logo_slug)
                            .to_h,
      bank_logo_keywords: BankLogoSlugs.keywords,
      bank_logos: BankLogoSlugs.available,
      # category id => { name, color } so the
      # allocation rows can carry the Sure category's color.
      categories: family.categories.pluck(:id, :name, :color)
                             .to_h { |id, name, color| [ id, { name: name, color: color } ] },
      plan_ordered: family.accounts
                        .where.not(plan_order: nil)
                        .order(:plan_order)
                        .pluck(:id, :plan_order)
                        .to_h,
      linked_bank_counts: family.income_account_allocations.group(:income_series_id).count
    }
  end

  def self.plan_allocation_rows(family)
    family.plan_allocations.order(:sort_index, :name, :id).to_a.map do |allocation|
      {
        id: allocation.id,
        account_id: allocation.account_id,
        name: allocation.name,
        kind: allocation.kind,
        mode: allocation.mode,
        value_cents: allocation.value_cents,
        value_percent: allocation.value_percent,
        cadence: allocation.cadence,
        recurring_transaction_id: allocation.recurring_transaction_id,
        auto_transfer: allocation.auto_transfer,
        # the Sure category the diagram colors the band with.
        # nil = no category (the row carries category_name/color nil too).
        category_id: allocation.category_id,
        # the account the row dresses ("Make Allocated
        # Sub-Account"). The diagram draws the node with the account's
        # identity (name + logo, the bank's resolution order: explicit
        # slug first, then keyword match); nil = a plain allocation row.
        target_account_id: allocation.target_account_id,
        target_account_name: allocation.target_account&.name,
        target_account_logo: allocation.target_account ?
          BankLogoSlugs.resolve(allocation.target_account.name, explicit: allocation.target_account.bank_logo_slug) : nil,
        # (Fun Money v2): the fun_money row's configuration —
        # ownership ("household" or a family user id; nil = legacy
        # Household), distribution (equal | rational | percent |
        # individual_leftover), matching (equalize | per_income) and the
        # jsonb params (per-member percents + the input snapshot).
        # nil for every non-fun_money row (additive keys only).
        ownership: allocation.ownership,
        distribution: allocation.distribution,
        matching: allocation.matching,
        distribution_params: allocation.distribution_params
      }
    end
  end

  # { account_id => mask-or-nil } from the
  # plaintext plaid_accounts.mask column, joined through account_providers
  # (the legacy accounts.plaid_account_id FK is NULL everywhere in dev).
  # Two small queries; blank masks become nil — never a fabricated digit.
  def self.account_last4s_for(family)
    rows = family.accounts
                   .joins(:account_providers)
                   .where(account_providers: { provider_type: "PlaidAccount" })
                   .pluck(:id, "account_providers.provider_id")
    return {} if rows.empty?

    masks = PlaidAccount.where(id: rows.map(&:last).uniq)
                           .pluck(:id, :mask)
                           .to_h
    rows.each_with_object({}) do |(account_id, provider_id), result|
      result[account_id] = masks[provider_id].presence
    end
  end

  # Required-mode allocations with no explicit value resolve their amount
  # from the linked transaction's monthly equivalent (AR seam; the pure core
  # receives the map).
  def self.required_amount_rows(family)
    ids = family.plan_allocations
                .where(mode: "required", value_cents: nil)
                .where.not(recurring_transaction_id: nil)
                .pluck(:recurring_transaction_id)
                .uniq
    return {} if ids.empty?

    family.recurring_transactions
         .where(id: ids)
         .to_a
         .to_h { |series| [ series.id, to_family_cents(series.monthly_equivalent_amount, family.currency) ] }
  end

  # The "Recommended" rows the page's autofill reads (spec section 4, query
  # part). Plain hashes — the planner stays AR-free.
  def self.recommendation_rows(family)
    rows = []

    # (a) Detected bills not yet covered by any allocation: an active bill /
    # subscription / installment with a paying account that no allocation
    # references. Autofill: name, cadence from the interval rules, amount =
    # monthly equivalent, source bank = the bill's own account.
    covered = family.plan_allocations.where.not(recurring_transaction_id: nil).pluck(:recurring_transaction_id).to_set
    family.recurring_transactions
         .where(status: :active, bill_type: %w[bill subscription installment])
         .where.not(account_id: nil)
         .where.not(id: covered)
         .order(:name, :id)
         .each do |series|
      rows << {
        type: "recurring_transaction",
        recurring_transaction_id: series.id,
        name: series.display_name,
        kind: series.typed_installment? ? "debt" : "bill",
        cadence: cadence_for(series),
        amount_cents: to_family_cents(series.monthly_equivalent_amount, family.currency),
        source_account_id: series.account_id
      }
    end

    # (b) Accounts labeled with a plan role that have no allocation yet —
    # the "bank as allocation" case ( : any of the five roles). Debt
    # roles (CC / loan payoff) autofill a "Pay off <name>" debt row; the
    # rest (savings bucket / checking / investment) are money destinations
    # and autofill a plain savings-style row. "Already planned" = an
    # allocation sourced from the account, named after it (the autofill
    # name, below), OR DRESSING it ( Item 2: a target allocation
    # draws the account as its own node in the allocation pillar — never
    # recommend a second row for a dressed account). Source bank stays a
    # user choice.
    alloc_names = family.plan_allocations.pluck(:name).map { |name| name.to_s.strip.downcase }.to_set
    family.accounts.visible.where.not(plan_role: nil).order(:name, :id).each do |account|
      next if family.plan_allocations.exists?(account_id: account.id)
      # the account's row is dressed — skip it.
      next if family.plan_allocations.exists?(target_account_id: account.id)
      next if alloc_names.include?(account.name.to_s.strip.downcase)

      rows << {
        type: "account",
        account_id: account.id,
        name: role_allocation_name(account),
        kind: Account.plan_role_debt?(account.plan_role) ? "debt" : "savings",
        cadence: nil,
        amount_cents: nil,
        source_account_id: nil
      }
    end

    # (c) Budget categories with no matching allocation — an envelope that
    # plans money but the diagram does not fund (e.g. "Pet Savings"). Match
    # is by name, case-insensitive, against the allocations' names (the
    # savings-style categories have no recurring transaction to link).
    budget = family.budgets.where.not(budgeted_spending: nil).order(start_date: :desc).first
    if budget
      family.plan_allocations.pluck(:name).map { |name| name.to_s.strip.downcase }.to_set.tap do |names|
        budget.budget_categories
             .joins(:category)
             .where(categories: { parent_id: nil })
             .where("budgeted_spending > 0")
             # ( fix): :id tie-break — a same-name category
             # pair previously ordered by physical position.
             .order("categories.name", "budget_categories.id")
             .each do |budget_category|
          category_name = budget_category.category.name.to_s.strip.downcase
          next if names.include?(category_name)

          rows << {
            type: "budget_category",
            category_id: budget_category.category_id,
            name: budget_category.category.name,
            kind: "savings",
            cadence: nil,
            amount_cents: nil,
            source_account_id: nil
          }
        end
      end
    end

    rows
  end

  # The allocation the (b) autofill proposes for a role account.:
  # debt roles keep the "Pay off <name>" label; the other roles
  # (savings bucket / checking / investment) are destinations, not payoffs.
  def self.role_allocation_name(account)
    Account.plan_role_debt?(account.plan_role) ? "Pay off #{account.name}" : account.name
  end

  # Cadence label from the recurrence interval rules (the allocation dialog
  # autofill). 0 rules = the legacy monthly bill. Mixed rules do not map to
  # one of the five labels, so nil (the dialog shows a blank, editable
  # field).
  def self.cadence_for(series)
    rules = series.recurrence_rules.reject(&:marked_for_destruction?)
    # Zero rules is legal: legacy "monthly on expected_day_of_month".
    return "monthly" if rules.empty?

    signatures = rules.map { |rule| [ rule.frequency, rule.interval ] }
    return nil unless signatures.uniq.size == 1

    frequency, interval = signatures.first
    case frequency
    when "weekly"  then interval == 1 ? "weekly" : (interval == 2 ? "biweekly" : nil)
    when "monthly" then interval == 1 ? "monthly" : (interval == 3 ? "quarterly" : nil)
    when "yearly"  then interval == 1 ? "yearly" : nil
    else nil
    end
  end

  # `incomes` is { id:, owner_id:, occurrences: [{ date:, amount_cents: }] }
  # (occurrences = the actual paycheck dates landing in the month), `allocations`
  # is [{ income_id:, account_id:, mode:, value_cents: (specific),
  # value_percent: (percent) }], `obligations_by_account` is { account_id =>
  # monthly BigDecimal cents }, `partners` the family member ids, and
  # `leftover_distribution` the family's attribution setting.
  # The PR#2b inputs are all optional keyword defaults so the PR#1
  # constructor shape (and its tests) keep working unchanged; `plan` ignores
  # them.
  def initialize(month:, incomes:, allocations:, obligations_by_account:, partners:, leftover_distribution:,
                 currency: nil, plan_allocations: [], required_amounts: {}, plan_max_links: {},
                 plan_roles: {}, auto_transfers: {}, plan_ordered: {}, linked_bank_counts: {},
                 recommendations: [], sub_account_links: {}, auto_transfer_targets: {},
                 account_names: {}, account_last4s: {}, account_bank_logos: {},
                 bank_logo_keywords: [], bank_logos: {}, categories: {}, draft: nil)
    @month = month
    @incomes = incomes
    @allocations = allocations
    @obligations_by_account = obligations_by_account
    @partners = partners
    @leftover_distribution = leftover_distribution
    @currency = currency
    @plan_allocations = plan_allocations
    @required_amounts = required_amounts
    @plan_max_links = plan_max_links
    @plan_roles = plan_roles
    @auto_transfers = auto_transfers
    @plan_ordered = plan_ordered
    @linked_bank_counts = linked_bank_counts
    @recommendations = recommendations
    # sub-account links {child_id => parent_id} and the
    # ordered auto-transfer fan-out targets {parent_id => [child_ids]} (the
    # array order IS the diagram's band order). plan_graph only — the PR#1
    # plan path never reads them (inputs_for carries no such keys).
    @sub_account_links = sub_account_links
    @auto_transfer_targets = auto_transfer_targets
    # Bank display names {id => name}: the bank rows are id-keyed like every
    # other row, and the over-plan line names the unsatisfied bucket by its
    # ACCOUNT name (the sankey itself pulls labels from page-load state).
    @account_names = account_names
    # last-4 {id => mask-or-nil}, explicit logo slugs {id => slug},
    # keyword pairs [normalized_keyword, slug] (longest first), the vendored
    # {slug => label} set, and category id => { name, color }. All optional;
    # plan_graph emits nil where a row has no value (no fabricated data).
    @account_last4s = account_last4s
    @account_bank_logos = account_bank_logos
    @bank_logo_keywords = bank_logo_keywords
    @bank_logos = bank_logos
    @categories = categories
    apply_draft(draft) if draft
  end

  # Draft merge (PR#2 preview pattern): each key present replaces the saved
  # input set WHOLESALE. The controller composes the shadow set (saved rows
  # overlaid with the unsaved dialog rows); the planner just applies it.
  # (Flow Scenarios): :linked_bank_counts is the one display-only
  # shadow input that the scenario's edge rows must drive (per-income limit
  # warnings). Absent key = untouched @linked_bank_counts = byte-identical
  # planner output (the no-op invariant, same shape as the overlay's).
  def apply_draft(draft)
    @incomes = draft[:incomes] if draft.key?(:incomes)
    @allocations = draft[:allocations] if draft.key?(:allocations)
    @plan_allocations = draft[:plan_allocations] if draft.key?(:plan_allocations)
    @plan_max_links = draft[:plan_max_links] if draft.key?(:plan_max_links)
    @plan_roles = draft[:plan_roles] if draft.key?(:plan_roles)
    @linked_bank_counts = draft[:linked_bank_counts] if draft.key?(:linked_bank_counts)
  end

  def plan
    paycheck_events = @incomes.flat_map { |income| income[:occurrences] }
    total_occurrences = paycheck_events.size

    # Monthly obligations prorated over the month's actual occurrences. With
    # no paychecks there is nothing to spread across, so the per-paycheck
    # figure stays the monthly total (it is never applied — no paychecks).
    divisor = [ total_occurrences, 1 ].max
    required_per_paycheck = @obligations_by_account
                            .transform_values { |monthly| monthly / divisor }

    resolve_edges(required_per_paycheck:)

    # Per-paycheck (per date) view: what each paycheck resolves to, per edge
    # and per account.
    by_date = Hash.new { |h, k| h[k] = { total: BigDecimal(0), by_account: {} } }
    @resolved.each do |(income_id, date), entry|
      bucket = by_date[date]
      bucket[:total] += entry[:amount]
      entry[:amounts].each { |account_id, amount| bucket[:by_account][account_id] = (bucket[:by_account][account_id] || BigDecimal(0)) + amount }
      # The remainder lands in the leftover edge's account so the per-account
      # totals reconcile exactly against the paycheck total.
      leftover_edge = entry[:edges].find { |e| e[:mode] == "leftover" }
      if leftover_edge
        account_id = leftover_edge[:account_id]
        bucket[:by_account][account_id] = (bucket[:by_account][account_id] || BigDecimal(0)) + entry[:leftover]
      end
    end

    attribution = compute_attribution

    # Shortfalls: occurrences where the pre-leftover edges outran the income.
    shortfalls = {}
    @resolved.each do |(income_id, _date), entry|
      next if entry[:leftover].zero? || entry[:leftover].positive?

      shortfalls[income_id] = (shortfalls[income_id] || BigDecimal(0)) + entry[:leftover].abs
    end

    build_report(
      by_date: by_date,
      required_per_paycheck: required_per_paycheck,
      total_occurrences: total_occurrences,
      pool_month: attribution[:pool_month],
      weights: attribution[:weights],
      deltas: attribution[:deltas],
      target: attribution[:target],
      spread: attribution[:spread],
      fix: attribution[:fix],
      shortfalls: shortfalls,
      partner_actual_month: attribution[:partner_actual_month]
    )
  end

  # the planning diagram. Incomes -> banks -> items,
  # with the fixed bank-level resolution order:
  #   1. REQUIRED items (bills/debts, mode required) — always first, and
  #      NEVER the over-plan flag target;
  #   2. SPECIFIC items — the per-paycheck hard number;
  #   3. PERCENT items — a share of the bank's leftover pool (the residual
  #      after 1-2);
  #   4. LEFTOVER items — split the final residual equally.
  #
  # The income -> bank edge level resolves EXACTLY like `plan` (the Sankey
  # bands), but a bank's required base is its required plan allocations
  # (explicit monthly value_cents, else the linked transaction's monthly
  # equivalent — see graph_required_monthly) when it has any, falling back
  # to the legacy raw-bill obligations (the pre-redesign behavior, which is
  # this same call with an empty allocation set).
  #
  # Money: integer cents internally; every *_cents field in the JSON is a
  # 2-dp major-unit display string (house convention, same as the PR#1
  # report's money fields).
  def plan_graph
    total_occurrences = @incomes.sum { |income| income[:occurrences].size }
    divisor = [ total_occurrences, 1 ].max

    # Edge level (income -> bank): a bank's required base is reserved from
    # the paychecks that FUND the bank -- the occurrences of the incomes
    # with a required edge to it -- not from the month's total paycheck
    # count. The global divisor (the pre-fix behavior) split a bank's base
    # across payees whose paychecks never reach the bank, so a bank fed by
    # one partner's two paychecks received a quarter of its bills' base and
    # its allocations ran structurally short (issue 1: the
    # /8 artifact). No required edge into a bank means no reservation: the
    # base never flows, and the bank-level fallback shows the full
    # shortfall (see resolve_graph).
    required_monthly = graph_required_monthly
    edge_funding = required_edge_funding_counts
    required_per_paycheck = required_monthly.each_with_object({}) do |(account_id, monthly), per_paycheck|
      funding = edge_funding.fetch(account_id, 0)
      per_paycheck[account_id] = funding.positive? ? monthly / funding : BigDecimal(0)
    end

    # (D-RECON): the stored per-income required split (required
    # edges carrying a percent). The task formula (percent of the displayed
    # per-paycheck figure) governs the UI readouts only — the
    # monthly-preserving charge computed here is the settlement: charging
    # the readout figure would fund only base * sum(pct_i * occ_i) / (100 * F)
    # per month. An empty map (no stored percents) leaves the legacy line
    # byte-identical (the stop-rule property).
    required_splits = required_split_charges(required_monthly: required_monthly)
    # the funding-priority cascade tiers (nil when no account
    # classifies — the legacy settlement, byte-identical).
    resolve_edges(required_per_paycheck:, required_splits: required_splits, tiers: funding_tiers)
    attribution = compute_attribution
    # Unassigned allocations (: a bank was removed
    # from the plan, the allocation persisted without a source bank) take no
    # part in resolution -- they are reported in the graph with status
    # "unassigned" (see build_graph_report) and never become a bank key.
    allocations_by_bank = @plan_allocations.reject { |allocation| allocation[:account_id].nil? }
                                           .group_by { |allocation| allocation[:account_id] }
    graph = resolve_graph(allocations_by_bank: allocations_by_bank, divisor: divisor)

    # (Fun Money v2): the per-income reconciliation (B_k / S_k /
    # L_k / FM_k + the Un-Allocated discrepancies). Runs AFTER resolve_graph
    # (it reads @resolved, the bank inflows and the per-date allocation
    # results) and adds ADDITIVE payload keys only (income reconciliation,
    # the fun_money row's per_member/config echo, root discrepancies).
    # `plan` is untouched: it derives required amounts only from
    # @obligations_by_account, so the new fields never reach the
    # paycheck-plans payload (stop-rule, asserted in the tests).
    @fun_money = fun_money_reconciliation(graph)

    build_graph_report(
      graph: graph,
      allocations_by_bank: allocations_by_bank,
      divisor: divisor,
      total_occurrences: total_occurrences,
      fix: attribution[:fix],
      fun_money: @fun_money
    )
  end

  # the reconciliation's current input totals
  # (per-income I_k / B_k / S_k, integer cents) — the controller persists
  # them into the fun_money row's distribution_params as the drift snapshot
  # at save time (nil until plan_graph ran; no fun_money row -> nil).
  def fun_money_inputs
    @fun_money && @fun_money[:inputs]
  end

  private

    # Edge-level resolution shared by `plan` and `plan_graph`: every
    # occurrence, edge-by-edge, priority required -> specific -> percent ->
    # leftover. The required amount is the caller's per-paycheck figure for
    # the account: `plan` derives it as monthly over the month's total
    # occurrences (the PR#1 behavior); `plan_graph` derives it as monthly
    # over the paychecks that fund the account (see
    # required_edge_funding_counts), so summing the figure over the account's
    # funding paychecks lands on its monthly required base.
    # `required_splits` (plan_graph only): per-occurrence required
    # charges for stored per-income percent splits, keyed
    # [income_id, account_id, date]; the default {} keeps the legacy plan
    # path on today's line exactly. Sets @resolved, keyed [income_id, date].
    #
    # `tiers` (plan_graph only — the legacy plan path passes
    # none and stays byte-identical): the account -> funding-tier map
    # (" " = funding-first, " " = short-carrying). Per occurrence the
    # committed edge charges (the legacy amounts) are classified: when
    # EVERY charged account (charge > 0) is classified, the residual
    # settles by the funding-priority cascade —
    # = Σ charges in band (edge) order; = Σ charges
    # E = max( + − P, 0); T2_short = min(E)
    #   T1_short = E − T2_short
    # so the SAVINGS tier carries the shortfall first and checking goes
    # short only when savings are 100% short. Within a tier the rows fund
    # in band order out of the tier's funded total, so the LAST row in band
    # order absorbs its tier's shortfall first (last-committed-first; NOT
    # pro-rata). The leftover is then P − Σ funded — structurally ≥ 0 and
    # exactly 0 whenever E > 0. When E = 0 the settlement is the legacy
    # one cent-for-cent (the identity property that keeps the Default
    # graph byte-identical), and when any charged account is unclassified
    # the occurrence keeps the legacy full reservation byte-for-byte
    # .
    def resolve_edges(required_per_paycheck:, required_splits: {}, tiers: nil)
      resolved = {}
      @incomes.each do |income|
        edges = @allocations.select { |edge| edge[:income_id] == income[:id] }
        income[:occurrences].each do |occurrence|
          key = [ income[:id], occurrence[:date] ]
          amounts = {}
          charges = {}
          spent = BigDecimal(0)
          edges.each do |edge|
            case edge[:mode]
            when "required"
              # a stored per-income percent split of the bank's
              # required base takes the edge (one charge per occurrence, the
              # last absorbing so the income's monthly share is preserved
              # exactly — see required_split_charges). No entry (empty map,
              # the legacy plan path, or an unfunded account) falls
              # through to today's line exactly.
              split_charge = required_splits[[ income[:id], edge[:account_id], occurrence[:date] ]]
              charge = split_charge || required_per_paycheck.fetch(edge[:account_id], BigDecimal(0))
              amounts[edge[:account_id]] = charge
              charges[edge[:account_id]] = charge
              spent += charge
            when "specific"
              amounts[edge[:account_id]] = edge[:value_cents]
              charges[edge[:account_id]] = edge[:value_cents]
              spent += edge[:value_cents]
            when "percent"
              # Round to the cent; the remainder deliberately lands in leftover.
              amount = (occurrence[:amount_cents] * edge[:value_percent]).round(0, half: :up)
              amounts[edge[:account_id]] = amount
              charges[edge[:account_id]] = amount
              spent += amount
              # leftover is computed below
            end
          end
          leftover = occurrence[:amount_cents] - spent

          # the funding-priority cascade. `charges` preserves the
          # edge (band) order; the leftover edge carries no committed
          # charge. See the method comment for the formula.
          cascade = false
          if tiers
            charged_rows = charges.reject { |_, charge| charge.zero? }
            if charged_rows.any? && charged_rows.all? { |account_id, _| tiers[account_id] }
              t1_rows = charged_rows.select { |account_id, _| tiers[account_id] == "T1" }
              t2_rows = charged_rows.select { |account_id, _| tiers[account_id] == "T2" }
              t1_total = t1_rows.sum { |_, charge| charge }
              t2_total = t2_rows.sum { |_, charge| charge }
              excess = [ t1_total + t2_total - occurrence[:amount_cents], BigDecimal(0) ].max
              t2_short = [ excess, t2_total ].min
              t1_short = [ excess - t2_short, BigDecimal(0) ].max
              # `charges` stays the PRE-cap committed record (the share
              # formulas read it); fund the funded map from a copy.
              amounts = fund_tier(t1_rows, t1_total - t1_short, charges.dup)
              amounts = fund_tier(t2_rows, t2_total - t2_short, amounts)
              leftover = occurrence[:amount_cents] - amounts.values.sum
              cascade = excess.positive?
            end
          end

          resolved[key] = {
            amounts: amounts,
            leftover: leftover,
            edges: edges,
            amount: occurrence[:amount_cents],
            owner_id: income[:owner_id],
            # (ADDITIVE): the pre-cap committed charges (every
            # committed edge, charged or not) and whether the cascade
            # SETTLED this occurrence (excess > 0). The over-plan and
            # fun-money share formulas attribute a bank's demand by
            # COMMITMENT — not by the funded band — so a defunded row's
            # paycheck still names the demand it committed (the root
            # over-plan invariant; see committed_bank_totals).
            committed: charges,
            cascade: cascade
          }
        end
      end
      @resolved = resolved
    end

    # fund the tier's rows (band order) out of the tier's funded
    # total, capping each row at its committed charge — the last row in
    # band order absorbs the tier's shortfall first (last-committed-first).
    # `base` is the full charge map (every committed edge keeps an amounts
    # entry, charged or not).
    def fund_tier(rows, funded_total, base)
      remaining = funded_total
      rows.each do |account_id, charge|
        got = [ charge, remaining ].min
        base[account_id] = got
        remaining -= got
      end
      base
    end

    # the account -> funding-tier map for the cascade
    # classification. The account's plan_role is the classifier ( =
    # checking, = savings_bucket); an account WITHOUT a plan_role falls
    # back to its plan allocations' kinds (any savings-kind row -> ,
    # else — the flagged fallback path); an account with NEITHER stays
    # unclassified — its charged occurrences keep the legacy full
    # reservation (stop-rule). nil when no edge account classifies (the
    # legacy settlement, byte-identical).
    def funding_tiers
      tiers = {}
      @allocations.each do |edge|
        account_id = edge[:account_id]
        next if tiers.key?(account_id)

        role = @plan_roles[account_id]
        if role == "checking"
          tiers[account_id] = "T1"
        elsif role == "savings_bucket"
          tiers[account_id] = "T2"
        else
          allocs = @plan_allocations.select { |a| a[:account_id] == account_id }
          tiers[account_id] = (allocs.any? { |a| a[:kind] == "savings" } ? "T2" : "T1") if allocs.any?
        end
      end
      tiers.empty? ? nil : tiers
    end

    # the per-date, per-bank committed-charge totals (pre-cap
    # edge charges summed over ALL incomes). The over-plan and fun-money
    # share formulas attribute a bank's demand by COMMITMENT, not by the
    # funded band: after the funding-priority cascade a defunded row's
    # funded band is 0 but its paycheck still committed the demand, so the
    # root over-plan must keep naming it (the 2,021.33 invariant). Legacy
    # (non-cascade) occurrences keep the band/inflow share formula.
    def committed_bank_totals
      @committed_bank_totals ||= begin
        totals = Hash.new { |h, date| h[date] = Hash.new { |h2, bank_id| h2[bank_id] = BigDecimal(0) } }
        @resolved.each do |(_income_id, date), entry|
          entry[:committed].each do |bank_id, charge|
            totals[date][bank_id] += charge
          end
        end
        totals
      end
    end

    # (D-RECON / D-UNDER): the stored per-income required split,
    # resolved to per-occurrence charges keyed [income_id, account_id,
    # date]. Only accounts with at least one required edge carrying a
    # stored percent participate — an empty result makes resolve_edges fall
    # through to the legacy line exactly (the stop-rule byte-identity
    # property). Per account (edge order = income_series_id, the edge_rows
    # order): each funded income's MONTHLY share is its rounded percent of
    # the base (round-half-up integer cents), and the LAST funded income
    # absorbs the residual ONLY when the percents sum to exactly 100.00 —
    # under-100 (D-UNDER: the shortfall stays visible via the existing
    # report fields) and over-100 (overfunded, no clamp) take no absorb.
    # Each monthly share then spreads over the income's occurrences
    # round-half-up, the last occurrence absorbing so the per-paycheck
    # charges sum exactly to the share (the monthly invariants are both
    # test-pinned). A zero base makes the percents inert (no division), and
    # a zero-occurrence income never funds (the
    # required_edge_funding_counts rule).
    def required_split_charges(required_monthly:)
      splits = {}
      required_edges = @allocations.select do |edge|
        edge[:mode] == "required" && !edge[:required_percent].nil?
      end
      return splits if required_edges.empty?

      required_edges.group_by { |edge| edge[:account_id] }.each do |account_id, edges|
        base = required_monthly.fetch(account_id, BigDecimal(0))
        next if base.zero?

        funded = edges.map do |edge|
          income = @incomes.find { |i| i[:id] == edge[:income_id] }
          [ edge, income ] if income && income[:occurrences].size.positive?
        end.compact
        next if funded.empty?

        percents = funded.map { |(edge, _income)| BigDecimal(edge[:required_percent]) }
        absorb = percents.sum == BigDecimal("100.00")

        monthly = []
        funded.each_with_index do |(edge, income), i|
          last = i == funded.size - 1 && absorb
          share = last ? base - monthly.sum : (base * percents[i] / 100).round(0, half: :up)
          monthly << share

          occs = income[:occurrences].size
          per_occurrence = (share / occs).round(0, half: :up)
          occs.times do |j|
            charge = j == occs - 1 ? share - per_occurrence * (occs - 1) : per_occurrence
            splits[[ income[:id], account_id, income[:occurrences][j][:date] ]] = charge
          end
        end
      end
      splits
    end

    # Per-partner leftover attribution, shared by `plan` and `plan_graph`:
    # the pooled leftover, the weights, the per-partner deltas against the
    # even target, and the closed-form suggested fix.
    def compute_attribution
      # Leftover pool: only what actually lands in a leftover edge, signed.
      # Negative means obligations outran income (shortfall).
      pool_by_income = {}  # income_id => month leftover across occurrences (streams with a leftover edge)
      @incomes.each do |income|
        next unless income[:occurrences].any?
        next unless @allocations.any? { |edge| edge[:income_id] == income[:id] && edge[:mode] == "leftover" }

        pool_by_income[income[:id]] =
          income[:occurrences].sum { |occ| @resolved[[ income[:id], occ[:date] ]][:leftover] }
      end
      pool_month = pool_by_income.values.sum

      # Per-partner attribution of the pooled leftover.
      partner_income_month = Hash.new { |h, k| h[k] = BigDecimal(0) }
      @incomes.each do |income|
        next unless income[:owner_id]

        partner_income_month[income[:owner_id]] += income[:occurrences].sum { |occ| occ[:amount_cents] }
      end
      total_attributed_income = partner_income_month.values.sum

      n = @partners.size
      weights = {}
      @partners.each do |partner|
        case @leftover_distribution
        when "equal_split", "custom" # custom rules are v2; attribute evenly until they land
          weights[partner] = BigDecimal(1) / n if n.positive?
        else # income_ratio
          share = partner_income_month[partner]
          weights[partner] = if n.positive? && total_attributed_income.positive?
            share / total_attributed_income
          else BigDecimal(1) / n
          end if n.positive?
        end
      end

      # Per-partner ACTUAL leftover (their own streams' remainders, with or
      # without a leftover edge) is what the delta and the suggested fix work
      # on: attribution credits pooled money, the gap shows whose money is
      # actually left unassigned.
      partner_actual_month = Hash.new { |h, k| h[k] = BigDecimal(0) }
      @incomes.each do |income|
        next unless income[:owner_id]

        partner_actual_month[income[:owner_id]] +=
          income[:occurrences].sum { |occ| @resolved[[ income[:id], occ[:date] ]][:leftover] }
      end
      actual_total = partner_actual_month.values.sum
      target = n.positive? ? actual_total / n : BigDecimal(0)
      deltas = @partners.to_h { |partner| [ partner, partner_actual_month[partner] - target ] }
      spread = deltas.values.max - deltas.values.min if deltas.any?

      # Suggested fix: closed-form one-variable solve. Shift the single
      # percent edge of the partner furthest above target so their leftover
      # lands on target. Shifting a stream's fraction by d moves its monthly
      # leftover by d * (stream month total), so d = delta / stream month
      # total.
      fix = suggested_fix(deltas, partner_actual_month)

      {
        pool_month: pool_month,
        weights: weights,
        deltas: deltas,
        target: target,
        spread: spread,
        fix: fix,
        partner_actual_month: partner_actual_month
      }
    end

    # ======================================================================
    # plan_graph helpers
    # ======================================================================

    # The bank -> item resolution for every paycheck date. Returns:
    # dates - sorted paycheck dates with any inflow
    # bands - [{ income_id:, account_id:, date:, amount:, mode: }]
    #                            (income -> bank Sankey bands; signed)
    # unallocated - [{ income_id:, date:, amount: }] (the hatched
    #                            "Un-Allocated" bands; 0 when a leftover edge
    #                            routes the remainder)
    # bank_inflow - { date => { account_id => signed inflow } }
    # bank_surplus - { date => { account_id => signed residual } }
    # allocation_results - { date => { account_id => { allocation_id =>
    #                            { wanted:, got:, shortfall: } } } }
    # over_plans - { income_id => { target:, target_id:, shortfall: } }
    #
    # Statuses: ok (fully funded), partly (0 < got < wanted; bills/debts cap
    # here — they are never the over-plan flag target), over (got == 0 <
    # wanted, savings/fun_money only).
    def resolve_graph(allocations_by_bank:, divisor:)
      dates = @incomes.flat_map { |income| income[:occurrences].map { |occ| occ[:date] } }.uniq

      # The paychecks that fund each bank at the allocation level: the dates
      # on which any resolved income -> bank edge (any mode) fires for the
      # bank. An allocation's MONTHLY figure prorates over its source
      # bank's paychecks -- not the month's total paycheck count, which
      # spans payees whose paychecks never reach the bank (
      # the /N artifact). Banks with no funding dates (no edges
      # into them) keep the legacy global shape: entries on every paycheck
      # date, got 0, so the UI still shows the full monthly shortfall.
      bank_funding_dates = {}
      @incomes.each do |income|
        next unless income[:occurrences].any?

        income_edges = @allocations.select { |edge| edge[:income_id] == income[:id] }
        next if income_edges.empty?

        income[:occurrences].each do |occurrence|
          income_edges.each do |edge|
            (bank_funding_dates[edge[:account_id]] ||= []) << occurrence[:date]
          end
        end
      end
      bank_funding_dates = bank_funding_dates.transform_values { |days| days.uniq }

      bands = []
      unallocated = []
      bank_inflow = Hash.new { |h, k| h[k] = {} }
      bank_surplus = {}
      allocation_results = {}

      # Per-paycheck, per-bank demand for the over-plan formula (required
      # wanted is the FULL prorated figure, not what the bank actually had —
      # the flag measures the gap between what the plan demands and what the
      # income provides).
      demand_by_bank = {}  # date => { account_id => BigDecimal }
      fun_targets_by_bank = {}  # date => { account_id => allocation_id }
      dates.each do |date|
        demand_by_bank[date] = {}
        fun_targets_by_bank[date] = {}
        (allocations_by_bank.keys).each do |bank_id|
          allocs = allocations_by_bank[bank_id]
          next if allocs.empty?

          funding = bank_funding_dates.fetch(bank_id, [])
          scale = if funding.empty?
            # Unfunded bank: the legacy global proration keeps the
            # gap visible on every paycheck date.
            divisor
          else
            next unless funding.include?(date)
            funding.size
          end

          bills = allocs.select { |a| a[:mode] == "required" }.sum { |a| allocation_monthly(a) }
          fixed = allocs.select { |a| a[:mode] == "specific" }.sum { |a| a[:value_cents] || BigDecimal(0) }
          # percent demand is a share of the post-bill pool; computed per
          # date below once the bank's inflow is known.
          demand_by_bank[date][bank_id] = bills / scale + fixed
          fun_targets_by_bank[date][bank_id] = allocs.find { |a| a[:kind] == "fun_money" }&.dig(:id)
        end
      end

      dates.each do |date|
        # Inflow per bank from the resolved income -> bank edges (the
        # leftover edge's signed remainder included).
        inflow = {}
        @incomes.each do |income|
          occurrence = income[:occurrences].find { |occ| occ[:date] == date }
          next unless occurrence

          entry = @resolved[[ income[:id], date ]]
          entry[:amounts].each do |account_id, amount|
            inflow[account_id] = (inflow[account_id] || BigDecimal(0)) + amount
            bands << { income_id: income[:id], account_id: account_id, date: date, amount: amount, mode: entry[:edges].find { |e| e[:account_id] == account_id }&.dig(:mode) }
          end
          leftover_edge = entry[:edges].find { |e| e[:mode] == "leftover" }
          if leftover_edge
            account_id = leftover_edge[:account_id]
            inflow[account_id] = (inflow[account_id] || BigDecimal(0)) + entry[:leftover]
            bands << { income_id: income[:id], account_id: account_id, date: date, amount: entry[:leftover], mode: "leftover" }
          else
            # No leftover edge: the remainder never flows to a bank.
            unallocated << { income_id: income[:id], date: date, amount: [ entry[:leftover], BigDecimal(0) ].max }
          end
        end
        bank_inflow[date] = inflow

        # Percent demand: a share of the bank's post-bill pool.
        allocations_by_bank.each do |bank_id, allocs|
          next if inflow[bank_id].nil? || inflow[bank_id] <= 0
          next unless allocs.any? { |a| a[:mode] == "percent" }

          # Positive inflow implies an edge fired this date, so the bank is
          # funded and this is one of its funding dates (empty only
          # defensively).
          funding = bank_funding_dates.fetch(bank_id, [])
          bills = allocs.select { |a| a[:mode] == "required" }.sum { |a| allocation_monthly(a) } /
            (funding.empty? ? divisor : funding.size)
          pool = inflow[bank_id] - bills
          percent_wanted = pool.positive? ? allocs.select { |a| a[:mode] == "percent" }
                                        .sum { |a| (pool * a[:value_percent]).round(0, half: :up) }
                                          : BigDecimal(0)
          demand_by_bank[date][bank_id] += percent_wanted
        end

        # Bank-level allocation resolution, fixed order. An allocation's
        # monthly figure prorates over its source bank's paychecks (the
        # dates with an edge into the bank); banks with planned allocations
        # but no edges in still resolve (remaining 0) on every paycheck
        # date, so their wanted figures are recorded and the UI can show
        # the shortfall.
        (inflow.keys | allocations_by_bank.keys).each do |bank_id|
          allocs = allocations_by_bank[bank_id] || []
          funding = bank_funding_dates.fetch(bank_id, [])
          # A funded bank resolves only on its funding dates: its monthly
          # figure prorates over exactly those paychecks.
          next if allocs.any? && funding.any? && !funding.include?(date)

          scale = funding.empty? ? divisor : funding.size
          remaining = inflow[bank_id] || BigDecimal(0)
          results = {}
          per = allocation_results[date] ||= {}

          # 1. REQUIRED (bills/debts) — always first, best-effort.
          allocs.select { |a| a[:mode] == "required" }.each do |allocation|
            wanted = allocation_monthly(allocation) / scale
            got = remaining.positive? ? [ wanted, remaining ].min : BigDecimal(0)
            remaining -= got
            results[allocation[:id]] = { wanted: wanted, got: got, shortfall: [ wanted - got, BigDecimal(0) ].max, kind: allocation[:kind] }
          end

          # 2. SPECIFIC — the per-paycheck hard number.
          allocs.select { |a| a[:mode] == "specific" }.each do |allocation|
            wanted = allocation[:value_cents] || BigDecimal(0)
            got = remaining.positive? ? [ wanted, remaining ].min : BigDecimal(0)
            remaining -= got
            results[allocation[:id]] = { wanted: wanted, got: got, shortfall: [ wanted - got, BigDecimal(0) ].max, kind: allocation[:kind] }
          end

          # 3. PERCENT — a share of the bank's leftover pool (the residual
          #    after 1-2); each share comes off the shrinking residual.
          allocs.select { |a| a[:mode] == "percent" }.each do |allocation|
            wanted = remaining.positive? ? (remaining * allocation[:value_percent]).round(0, half: :up) : BigDecimal(0)
            got = remaining.positive? ? [ wanted, remaining ].min : BigDecimal(0)
            remaining -= got
            results[allocation[:id]] = { wanted: wanted, got: got, shortfall: [ wanted - got, BigDecimal(0) ].max, kind: allocation[:kind] }
          end

          # 4. LEFTOVER — the final residual, split equally (exact: the last
          #    share absorbs the remainder so the split sums to the residual).
          leftovers = allocs.select { |a| a[:mode] == "leftover" }
          if leftovers.size.positive?
            base = (remaining / leftovers.size).truncate(0)
            # The last share absorbs the remainder; compute every share off
            # the ORIGINAL residual before any mutation.
            shares = leftovers.each_index.map do |idx|
              idx == leftovers.size - 1 ? remaining - (leftovers.size - 1) * base : base
            end
            leftovers.each_with_index do |allocation, idx|
              share = shares[idx]
              got = share.positive? ? share : BigDecimal(0)
              shortfall = share.positive? ? BigDecimal(0) : -share
              results[allocation[:id]] = { wanted: share.positive? ? share : BigDecimal(0), got: got, shortfall: shortfall, kind: allocation[:kind] }
              remaining -= got
            end
          end

          per[bank_id] = results
          bank_surplus[date] ||= {}
          bank_surplus[date][bank_id] = remaining
        end
      end

      # Over-plan flags per income (monthly). Per paycheck: the income's
      # planned demand across the banks its funds reach — its share of each
      # bank's full demand (required wanted + specific + percent of the
      # post-bill pool) — minus the paycheck. Bills are assumed covered; the
      # gap is what the flag names against the fun money (if planned on a
      # reachable bank) or the surplus/savings line.
      over_plans = {}
      @incomes.each do |income|
        shortfall_month = BigDecimal(0)
        target_id = nil
        income[:occurrences].each do |occurrence|
          entry = @resolved[[ income[:id], occurrence[:date] ]]
          next unless entry

          date = occurrence[:date]
          demand = BigDecimal(0)
          leftover_edge = entry[:edges].find { |e| e[:mode] == "leftover" }
          bank_ids = entry[:amounts].keys
          bank_ids << leftover_edge[:account_id] if leftover_edge
          # a CASCADE-settled occurrence attributes each bank's
          # demand by its COMMITTED (pre-cap) charge share — a defunded row
          # (funded band 0) still names the demand its paycheck committed.
          # The legacy band/inflow share would drop it to 0 and understate
          # the gap (the 2,021.33 invariant). Non-cascade occurrences keep
          # today's formula byte-for-byte.
          committed = entry[:cascade] ? committed_bank_totals[date] : nil
          bank_ids.uniq.each do |bank_id|
            if committed
              total = committed[bank_id] || BigDecimal(0)
              share = total.positive? ? (entry[:committed].fetch(bank_id, BigDecimal(0)) / total) : BigDecimal(0)
            else
              band = entry[:amounts].fetch(bank_id, BigDecimal(0))
              band += entry[:leftover] if leftover_edge && leftover_edge[:account_id] == bank_id
              inflow = (bank_inflow[date] || {})[bank_id] || BigDecimal(0)
              share = if inflow.positive? && band.positive?
                band / inflow
              elsif band.positive?
                BigDecimal(1)
              else
                BigDecimal(0)
              end
            end
            next if share.zero?

            demand += share * ((demand_by_bank[date] || {})[bank_id] || BigDecimal(0))
            target_id ||= fun_targets_by_bank[date][bank_id]
          end

          gap = demand - occurrence[:amount_cents]
          shortfall_month += gap if gap.positive?
        end

        next unless shortfall_month.positive?

        over_plans[income[:id]] = {
          target: target_id ? "fun_money" : "surplus",
          target_id: target_id,
          shortfall: shortfall_month
        }
      end

      # (fan-out pool): the auto-transfer fan-out delivers
      # the parent's buckets from the parent's POST-ALLOCATION surplus — the
      # parent's own allocations resolved first above (bills pay first), so
      # when the parent is underfunded the bills take their share and the
      # buckets come up short, never the other way round (report
      # it, hide nothing). Per parent funding date each target — in
      # target-array order, which is the diagram's band order — draws
      # min(its prorated wanted, its share of the pool), share = the child's
      # required base over the sibling bases. A child WITH its own required
      # edges already resolved its own inflow in the main loop above (the
      # own-edge pool); the fan-out pool is independent and adds on top,
      # and its demand was counted exactly once — in the parent's required
      # base (graph_required_monthly) — so no double counting.
      @auto_transfer_targets.each do |parent_id, targets|
        parent_funding = bank_funding_dates.fetch(parent_id, [])
        next if parent_funding.empty? || targets.empty?

        bases = targets.map { |target_id| fan_out_child_base(target_id) }
        total_base = bases.sum
        parent_funding.each do |date|
          per = allocation_results[date] ||= {}
          # The parent's surplus AFTER its own allocations resolved on this
          # date; a negative residual (the bills outran the inflow) means
          # the fan-out pool is empty for the date.
          pool = [ (bank_surplus[date] || {})[parent_id] || BigDecimal(0), BigDecimal(0) ].max
          consumed_this_date = BigDecimal(0)

          targets.each_with_index do |target_id, index|
            child_allocs = @plan_allocations.select do |allocation|
              allocation[:mode] == "required" && allocation[:account_id] == target_id
            end

            # Record the wanted on EVERY parent funding date — a pool-empty
            # date still reports its proration as shortfall (nothing
            # hidden). The own-edge pool (main loop) may have recorded the
            # same allocation on this date already: it keeps its own
            # proration; the fan-out wanted is added only when the row did
            # not exist (no double count).
            child_results = per[target_id] ||= {}
            child_allocs.each do |allocation|
              wanted = allocation_monthly(allocation) / parent_funding.size
              next if wanted.zero? || child_results[allocation[:id]]
              child_results[allocation[:id]] = { wanted: wanted, got: BigDecimal(0),
                                                 shortfall: wanted, kind: allocation[:kind] }
            end

            share = if total_base.positive?
              bases[index] / total_base
            else
              BigDecimal(1) / targets.size
            end
            pool_share = pool.positive? ? (pool * share).round(0, half: :up) : BigDecimal(0)
            next if pool_share.zero?

            # Bills pay first: the transfer tops up the allocation's
            # unfunded wanted (capacity = wanted - got); anything beyond
            # the target accumulates in the child's bank as surplus, not
            # in the allocation row.
            remaining_share = pool_share
            absorbed = BigDecimal(0)
            child_allocs.each do |allocation|
              result = child_results[allocation[:id]]
              next if result.nil?

              absorb = [ remaining_share, result[:wanted] - result[:got] ].min
              next if absorb.zero?

              result[:got] += absorb
              result[:shortfall] -= absorb
              remaining_share -= absorb
              absorbed += absorb
            end
            consumed_this_date += pool_share
            excess = remaining_share
            if excess.positive?
              bank_surplus[date] ||= {}
              bank_surplus[date][target_id] = (bank_surplus[date][target_id] || BigDecimal(0)) + excess
            end
          end

          # The transfer is a real flow out of the parent: the parent's
          # post-allocation surplus reflects the fan-out consumption.
          if consumed_this_date.positive?
            bank_surplus[date] ||= {}
            bank_surplus[date][parent_id] = (bank_surplus[date][parent_id] || BigDecimal(0)) - consumed_this_date
          end
        end

        # The per-bucket shortfall lands on an over-plan line naming the
        # income that funds the parent and the FIRST unsatisfied bucket
        # (target-array order). Unsatisfied = the bucket's required
        # allocation is still short AFTER both pools (own-edge + fan-out) —
        # an income-level flag for the same income keeps priority, it
        # already names that income's gap.
        first_funding_date = parent_funding.min
        first_funding_income = @incomes.find do |income|
          income[:occurrences].any? { |occ| occ[:date] == first_funding_date } &&
            (@resolved[[ income[:id], first_funding_date ]] || {}).fetch(:amounts, {}).key?(parent_id)
        end
        next if first_funding_income.nil?

        targets.each do |target_id|
          child_allocs = @plan_allocations.select do |allocation|
            allocation[:mode] == "required" && allocation[:account_id] == target_id
          end
          next if child_allocs.empty?

          total_shortfall = dates.sum do |date|
            rows = (allocation_results[date] || {})[target_id] || {}
            child_allocs.sum { |allocation| rows[allocation[:id]]&.dig(:shortfall) || BigDecimal(0) }
          end
          next unless total_shortfall.positive?

          over_plans[first_funding_income[:id]] ||= {
            target: "bucket",
            target_id: target_id,
            shortfall: total_shortfall
          }
          break
        end
      end

      {
        dates: dates.sort,
        bands: bands,
        unallocated: unallocated,
        bank_inflow: bank_inflow,
        bank_surplus: bank_surplus,
        allocation_results: allocation_results,
        over_plans: over_plans
      }
    end

    # The required base per bank (monthly cents): the bank's required plan
    # allocations — explicit value_cents (a MONTHLY figure, prorated over the
    # month's paychecks like everything else here) when set, else the linked
    # transaction's monthly equivalent. A bank with no required plan
    # allocations keeps the legacy raw-bill obligations (the pre-redesign
    # behavior), so an empty allocation set reproduces the PR#1 numbers
    # exactly.
    #
    # Consequence: once a bank has required plan allocations, its required
    # base is those allocations ALONE — other detected bills on the bank are
    # surfaced by the recommendations query instead of silently flowing in.
    def graph_required_monthly
      required_monthly = Hash.new { |h, k| h[k] = BigDecimal(0) }
      @plan_allocations.each do |allocation|
        next unless allocation[:mode] == "required"

        required_monthly[allocation[:account_id]] += allocation_monthly(allocation)
      end
      @obligations_by_account.each do |account_id, monthly|
        # The default block makes an absent key read as 0 (a truthy
        # BigDecimal), so `||=` would never assign — key? instead.
        required_monthly[account_id] = monthly unless required_monthly.key?(account_id)
      end
      # (fan-out): a parent's required base includes the
      # required base of every auto-transfer target — the reservation its
      # funding paychecks must cover for the buckets. required_edge_
      # funding_counts is UNCHANGED: the fan-out adds demand, not funding,
      # so required_per_paycheck[parent] prorates (own base + child bases)
      # over the parent's funding paychecks — the sum over them still lands
      # on the parent's total monthly base (the issue 1 invariant).
      @auto_transfer_targets.each do |parent_id, targets|
        required_monthly[parent_id] += targets.sum { |target_id| fan_out_child_base(target_id) }
      end
      required_monthly
    end

    # The required base (monthly cents) of one fan-out target: the child's
    # own required plan allocations via allocation_monthly when it has any,
    # else its raw-bill obligations — mirroring the graph_required_monthly
    # fallback (a child WITH required allocations never falls back, even to
    # 0).
    def fan_out_child_base(child_id)
      child_allocs = @plan_allocations.select do |allocation|
        allocation[:mode] == "required" && allocation[:account_id] == child_id
      end
      return child_allocs.sum { |allocation| allocation_monthly(allocation) } if child_allocs.any?

      @obligations_by_account.fetch(child_id, BigDecimal(0))
    end

    # The paycheck count that funds each bank at the edge level (plan_graph
    # only): the occurrences in the month of the incomes with a REQUIRED
    # edge to the bank. A bank's required base prorates over exactly these
    # paychecks -- summing the per-paycheck figure over them lands on the
    # monthly base, which is what the bank's allocations resolve against
    # (the dialog copy: "prorated over this month's paychecks" -- the
    # source bank's paychecks). A bank with no required edge receives no
    # reservation at all.
    def required_edge_funding_counts
      counts = Hash.new(0)
      @allocations.each do |edge|
        next unless edge[:mode] == "required"

        income = @incomes.find { |i| i[:id] == edge[:income_id] }
        counts[edge[:account_id]] += income ? income[:occurrences].size : 0
      end
      counts
    end

    # The required-mode monthly figure for one allocation: the explicit
    # value_cents when set, else the linked transaction's monthly equivalent
    # (the AR seam pre-resolves it into @required_amounts).
    def allocation_monthly(allocation)
      return BigDecimal(0) if allocation[:mode] != "required"

      amount = allocation[:value_cents]
      amount ||= allocation[:recurring_transaction_id] && @required_amounts[allocation[:recurring_transaction_id]]
      amount || BigDecimal(0)
    end

    # the per-income
    # reconciliation for the plan's fun_money row (the FIRST one in
    # sort order, — same precedent as fun_targets_by_bank).
    #
    # I_k the income's monthly total;
    # B_k the income's share of the required-mode bill demand = the sum
    #        of its resolved required EDGE charges over the month
    # (@resolved; the stored percents participate via the
    #        same machinery — required_split_charges feeds @resolved);
    # S_k for each savings-kind allocation on bank b: share_k(b) x the
    #        per-date wanted, share = the over-plan formula (band/inflow
    #        when both positive, 1 when band > 0, 0 otherwise);
    # L_k I_k - B_k - S_k (may be negative).
    #
    # Matching + Mode turn L into FM (member ownership): Per Income applies
    # the mode function per income (leftover -> max(0, L), percent ->
    # round(p * L) with 0 when L <= 0, Hard Number / required -> the stored
    # value PER MEMBER); Equalize (the member-ownership default) sets
    # T = max(0, min L_k) over members with an income occurrence this month
    # (a negative residual clamps the target to 0, never negative)
    # and FM_k = T. Household ownership (including legacy NULL rows):
    # FM_total = the row's resolved got_month from the UNCHANGED bank-level
    # resolution; Distribution governs the per-member DISPLAY split only;
    # reconciliation runs at the aggregate level only.
    #
    # RED LABEL: Un-Allocated_k = I_k - (B_k + S_k + FM_k) STRICTLY above
    # the 100-cent tolerance -> a discrepancy row naming the income (an
    # unlabeled income reads "an income"); household mode emits the single
    # aggregate row ("Household"). Over-allocation is NOT labeled here —
    # the existing over-plan flag covers it (no double rendering).
    #
    # Pure core: reads only the input hashes + @resolved. Returns nil when
    # the plan has no fun_money row (the payload keys stay nil — additive).
    # Returns { per_member:, reconciliation_by_income:, discrepancies:,
    #           inputs_stale:, inputs: } — inputs (per-income I/B/S cents)
    # feeds the drift snapshot the controller persists at save time.
    FUN_MONEY_LABEL_TOLERANCE_CENTS = 100

    def fun_money_reconciliation(graph)
      fun_row = @plan_allocations.find { |allocation| allocation[:kind] == "fun_money" }
      return nil unless fun_row

      income_ids_with_occurrences = @incomes.filter_map do |income|
        income[:occurrences].any? ? income[:id] : nil
      end
      return nil if income_ids_with_occurrences.empty?

      income_month = {}
      @incomes.each do |income|
        income_month[income[:id]] = income[:occurrences].sum { |occ| BigDecimal(occ[:amount_cents]) }
      end

      # B_k: the sum of the income's resolved required edge charges over the
      # month (edge-level — a required edge's per-paycheck figure prorates
      # over the funding paychecks and sums to the monthly share).
      bills_month = Hash.new { |h, k| h[k] = BigDecimal(0) }
      @incomes.each do |income|
        next unless income[:occurrences].any?

        income[:occurrences].each do |occurrence|
          entry = @resolved[[ income[:id], occurrence[:date] ]]
          next unless entry

          entry[:edges].each do |edge|
            next unless edge[:mode] == "required"

            bills_month[income[:id]] += entry[:amounts].fetch(edge[:account_id], BigDecimal(0))
          end
        end
      end

      # S_k: the income's band share of the savings-kind demand, per date —
      # the SAME share formula the over-plan path uses (resolve_graph).
      savings_month = Hash.new { |h, k| h[k] = BigDecimal(0) }
      bank_inflow = graph[:bank_inflow]
      allocation_results = graph[:allocation_results]
      @incomes.each do |income|
        next unless income[:occurrences].any?

        income[:occurrences].each do |occurrence|
          date = occurrence[:date]
          entry = @resolved[[ income[:id], date ]]
          next unless entry

          leftover_edge = entry[:edges].find { |e| e[:mode] == "leftover" }
          bank_ids = entry[:amounts].keys
          bank_ids << leftover_edge[:account_id] if leftover_edge
          # the SAME commitment-based share as the over-plan path
          # for cascade-settled occurrences (a defunded row's savings
          # demand is still committed by its paycheck).
          committed = entry[:cascade] ? committed_bank_totals[date] : nil
          bank_ids.uniq.each do |bank_id|
            if committed
              total = committed[bank_id] || BigDecimal(0)
              share = total.positive? ? (entry[:committed].fetch(bank_id, BigDecimal(0)) / total) : BigDecimal(0)
            else
              band = entry[:amounts].fetch(bank_id, BigDecimal(0))
              band += entry[:leftover] if leftover_edge && leftover_edge[:account_id] == bank_id
              inflow = (bank_inflow[date] || {})[bank_id] || BigDecimal(0)
              share = if inflow.positive? && band.positive?
                band / inflow
              elsif band.positive?
                BigDecimal(1)
              else
                BigDecimal(0)
              end
            end
            next if share.zero?

            rows = (allocation_results[date] || {})[bank_id]
            next unless rows

            rows.each_value do |result|
              next unless result[:kind] == "savings"

              savings_month[income[:id]] += share * BigDecimal(result[:wanted])
            end
          end
        end
      end

      # L_k: the residual after bills + savings (may be negative).
      leftover = {}
      income_month.each do |income_id, total|
        leftover[income_id] = total - bills_month[income_id] - savings_month[income_id]
      end

      # Member attribution: a member's L = the sum of their labeled
      # incomes' residuals; members with no income occurrence this month
      # drop out of the per-member matching set but their display
      # rows still appear where the design says (Equalize / Household).
      member_leftover = Hash.new { |h, k| h[k] = BigDecimal(0) }
      @incomes.each do |income|
        next unless income[:occurrences].any? && income[:owner_id]

        member_leftover[income[:owner_id]] += leftover[income[:id]]
      end
      members = @partners.select { |partner| member_leftover.key?(partner) }

      ownership = fun_row[:ownership].presence || "household"
      distribution = fun_row[:distribution]
      matching = fun_row[:matching].presence
      mode = fun_row[:mode]
      value_cents = BigDecimal(fun_row[:value_cents] || 0)
      value_percent = BigDecimal(fun_row[:value_percent] || 0)
      raw_params = fun_row[:distribution_params]
      params = raw_params.is_a?(Hash) ? raw_params : {}
      stored_percents = (params["percents"] || params[:percents] || {}).to_h

      household = ownership == "household"

      # Distribution "Individual Leftover by Allocations" — each
      # member's FM is funded from own leftover only, which IS the per
      # income matching semantics. The dialog locks the Matching select to
      # Per Income for that option; the planner coerces the same way for
      # rows saved before the lock existed.
      matching = "per_income" if distribution == "individual_leftover"

      # Per-member Fun Money (member ownership): the mode function on the
      # member's L. Per Income: leftover -> max(0, L), percent ->
      # round(p * L) with 0 when L <= 0, Hard Number / required -> the
      # stored value H, PER MEMBER. Equalize (the member-ownership default,
      # ): T = max(0, min member L) over members with an income
      # occurrence this month (a negative residual clamps to 0,
      # never negative), FM_k = T.
      fun_money_by_member = {}
      equalize_target = BigDecimal(0)
      unless household
        if matching == "per_income"
          members.each do |partner|
            l = member_leftover[partner]
            fun_money_by_member[partner] =
              case mode
              when "leftover" then [ l, BigDecimal(0) ].max
              when "percent" then l.positive? ? (value_percent * l).round : BigDecimal(0)
              else [ value_cents, BigDecimal(0) ].max
              end
          end
        else
          equalize_target = members.empty? ? BigDecimal(0) :
            [ members.map { |partner| member_leftover[partner] }.min, BigDecimal(0) ].max
          members.each { |partner| fun_money_by_member[partner] = equalize_target }
        end
      end

      # Attribute a member's FM to their PRIMARY income (first occurrence
      # date, then id) so a member with several streams is not charged
      # twice — the reconciliation sums per income.
      primary_income_by_member = {}
      @incomes.select { |income| income[:occurrences].any? && income[:owner_id] }
              .sort_by { |income| [ income[:occurrences].map { |occ| occ[:date] }.min, income[:id].to_s ] }
              .each { |income| primary_income_by_member[income[:owner_id]] ||= income[:id] }

      fun_money_by_income = {}
      unless household
        @incomes.each do |income|
          next unless income[:occurrences].any? && income[:owner_id]

          fun_money_by_income[income[:id]] =
            primary_income_by_member[income[:owner_id]] == income[:id] ?
              (fun_money_by_member[income[:owner_id]] || BigDecimal(0)) : BigDecimal(0)
        end
      end

      # Household: FM_total = the row's resolved got_month (unchanged
      # bank-level resolution) + the Distribution display split (: the
      # pool is shared; the split is a display, not a settlement).
      fun_money_total = BigDecimal(0)
      allocation_results.each_value do |by_bank|
        by_bank.each_value do |rows|
          result = rows[fun_row[:id]]
          fun_money_total += BigDecimal(result[:got]) if result
        end
      end

      per_member = if household
        member_totals = Hash.new { |h, k| h[k] = BigDecimal(0) }
        @incomes.each do |income|
          next unless income[:occurrences].any? && income[:owner_id]

          member_totals[income[:owner_id]] += income_month[income[:id]]
        end
        income_sum = member_totals.values.sum
        @partners.map do |partner|
          display =
            if @partners.empty?
              BigDecimal(0)
            elsif distribution == "rational"
              income_sum.positive? ? (fun_money_total * member_totals[partner]) / income_sum : BigDecimal(0)
            elsif distribution == "percent"
              stored_percents.key?(partner) ? (fun_money_total * BigDecimal(stored_percents[partner].to_d)) / 100 : BigDecimal(0)
            else
              fun_money_total / @partners.size
            end
          {
            member_id: partner,
            leftover_month: money([ member_leftover[partner], BigDecimal(0) ].max),
            fun_money_month: money(display.round),
            un_allocated_month: money(0)
          }
        end
      else
        # Member ownership: Equalize lists every member (a member with no
        # income occurrence shows the target display only); Per Income
        # lists the members with an income.
        listed = matching == "per_income" ? members : @partners
        listed.map do |partner|
          l = member_leftover[partner]
          fm = member_leftover.key?(partner) ?
            (fun_money_by_member[partner] || BigDecimal(0)) :
            (matching == "per_income" ? BigDecimal(0) : equalize_target)
          {
            member_id: partner,
            leftover_month: money(l),
            fun_money_month: money(fm.round),
            un_allocated_month: money([ l - fm, BigDecimal(0) ].max)
          }
        end
      end

      # Reconciliation by income (member ownership only; : household
      # reconciles at the aggregate level).
      reconciliation_by_income = {}
      unless household
        @incomes.each do |income|
          next unless income[:occurrences].any?

          fm = BigDecimal(fun_money_by_income[income[:id]] || 0)
          allocated = bills_month[income[:id]] + savings_month[income[:id]] + fm
          reconciliation_by_income[income[:id]] = {
            bills_month: bills_month[income[:id]],
            savings_month: savings_month[income[:id]],
            fun_money_month: fm,
            allocated_month: allocated,
            un_allocated_month: income_month[income[:id]] - allocated
          }
        end
      end

      # Discrepancies: STRICTLY above the tolerance (a 99-cent residual
      # shows nothing — rounding headroom). Over-allocation stays with the
      # existing over-plan flag.
      discrepancies = []
      if household
        total_leftover = income_ids_with_occurrences.sum { |income_id| leftover[income_id] }
        gap = total_leftover - fun_money_total
        discrepancies << { income_id: nil, income_name: "Household", un_allocated_month: gap } if gap > FUN_MONEY_LABEL_TOLERANCE_CENTS
      else
        @incomes.each do |income|
          next unless income[:occurrences].any?

          row = reconciliation_by_income[income[:id]]
          next unless row

          gap = row[:un_allocated_month]
          discrepancies << { income_id: income[:id], income_name: income[:name], un_allocated_month: gap } if gap > FUN_MONEY_LABEL_TOLERANCE_CENTS
        end
      end

      # the input snapshot the controller persisted at save time.
      # Divergence (per income, any of I/B/S) => the config is stale — an
      # amber prompt, never a red mismatch (no auto-rewrite).
      snapshot = (params["inputs_snapshot"] || params[:inputs_snapshot] || {})
      inputs = income_ids_with_occurrences.to_h do |income_id|
        [ income_id, { "i" => income_month[income_id], "b" => bills_month[income_id], "s" => savings_month[income_id] } ]
      end
      inputs_stale = false
      if snapshot.is_a?(Hash) && !snapshot.empty?
        same = inputs.keys.all? do |income_id|
          entry = snapshot[income_id]
          entry.is_a?(Hash) &&
            entry["i"] == inputs[income_id]["i"] &&
            entry["b"] == inputs[income_id]["b"] &&
            entry["s"] == inputs[income_id]["s"]
        end && snapshot.keys.all? { |income_id| inputs.key?(income_id) }
        inputs_stale = !same
      end

      {
        per_member: per_member,
        reconciliation_by_income: reconciliation_by_income,
        discrepancies: discrepancies,
        inputs_stale: inputs_stale,
        inputs: inputs
      }
    end

    def build_graph_report(graph:, allocations_by_bank:, divisor:, total_occurrences:, fix:, fun_money: nil)
      date_set = graph[:dates]

      # Incomes: occurrences, unallocated remainders, over-plan flags, and
      # the link-limit warnings (config-level, so declared-but-silent
      # paychecks still show them).
      incomes = @incomes.map do |income|
        unallocated_rows = graph[:unallocated].select { |row| row[:income_id] == income[:id] }
        unallocated_month = unallocated_rows.sum { |row| row[:amount] }
        over = graph[:over_plans][income[:id]]
        limit = @plan_max_links[income[:id]]
        linked = @linked_bank_counts[income[:id]].to_i

        {
          id: income[:id],
          name: income[:name],
          owner_id: income[:owner_id],
          occurrences: income[:occurrences].map do |occurrence|
            { date: occurrence[:date].to_s, amount: money(occurrence[:amount_cents]) }
          end,
          total_month: money(income[:occurrences].sum { |occurrence| occurrence[:amount_cents] }),
          unallocated_month: money(unallocated_month),
          unallocated: unallocated_rows.map { |row| { date: row[:date].to_s, amount: money(row[:amount]) } },
          over_plan: over && { target: over[:target], target_id: over[:target_id], shortfall_month: money(over[:shortfall]) },
          limit_warning: (limit && linked > limit) ? { linked_count: linked, limit: limit } : nil,
          # (Fun Money v2): the per-income reconciliation
          # (bills / savings / fun_money / allocated / un_allocated, 2-dp
          # strings) — nil when the plan has no fun_money row or the mode
          # reconciles at the aggregate level only (Household).
          reconciliation:
            if fun_money && (row = fun_money[:reconciliation_by_income][income[:id]])
              row.transform_keys(&:to_sym).transform_values { |value| money(value) }
            else
              nil
            end
        }
      end

      # Banks: the accounts the edges and the allocations touch (plus the
      # labeled role accounts and the plan-ordered accounts added via the
      # Add Account modal — : a plan-ordered bank with
      # no flow yet must still render, or it is a ghost: gone from the
      # add-accounts modal, invisible on the map, unreachable from the UI).
      # Unassigned allocations (account_id nil)
      # name no bank.
      # sub-accounts and fan-out targets get rows even
      # with no edge or allocation of their own — the sankey's child column
      # needs both endpoints of every fan-out band.
      # an account with a target allocation is drawn ONLY
      # as the dressed allocation-pillar node ( Item 2's "never a
      # second row for a dressed account", applied to the bank rows): it
      # drops out of the banks array. It would otherwise be double-drawn —
      # a small bank-column row (via the fan-out, below) AND the dressed
      # allocation node. No band is lost: the allocation's own band
      # (bank:source -> allocation node) already carries the source ->
      # dressed connection.
      dressed_target_ids = @plan_allocations.filter_map { |allocation| allocation[:target_account_id] }.to_set
      # ( fix): every union source was an unordered read
      # (allocation rows / pluck / hash keys), so the first-seen order of
      # the union leaked physical table order into the banks array — the
      # SHA drift. Sorted once at the end by account id (the stable,
      # meaningful key), the banks array order no longer depends on any
      # read's row order.
      bank_ids = (@allocations.map { |edge| edge[:account_id] } |
                  @plan_allocations.map { |allocation| allocation[:account_id] }.compact |
                  @plan_roles.keys |
                  @auto_transfers.keys |
                  @plan_ordered.keys |
                  @sub_account_links.keys |
                  @auto_transfer_targets.values.flatten).uniq
                 .reject { |bank_id| dressed_target_ids.include?(bank_id) }
                 .sort

      banks = bank_ids.map do |bank_id|
        inflow_rows = graph[:bands].select { |band| band[:account_id] == bank_id }
        inflow_month = inflow_rows.sum { |band| band[:amount] }
        surplus_raw = graph[:dates].filter_map do |date|
          amount = (graph[:bank_surplus][date] || {})[bank_id]
          next if amount.nil? || amount.zero?

          [ date, amount ]
        end
        surplus_month = surplus_raw.sum { |_date, amount| amount }

        {
          id: bank_id,
          name: @account_names[bank_id],
          # the plaintext last-4 from the vendored
          # map; nil when the bank has no mask (never fabricated).
          last4: @account_last4s[bank_id],
          # the logo slug — explicit per-account
          # override -> keyword match on the account name -> nil. The value
          # is always a slug from the vendored set (bank_logos), never a URL.
          logo: bank_logo_for(bank_id),
          plan_order: @plan_ordered[bank_id],
          plan_role: @plan_roles[bank_id],
          auto_transfer_to_account_id: @auto_transfers[bank_id],
          # the sub-account link + the ordered fan-out
          # targets (the legacy single-target key stays one more round).
          parent_account_id: @sub_account_links[bank_id],
          sub_account: @sub_account_links.key?(bank_id),
          auto_transfer_target_ids: @auto_transfer_targets[bank_id],
          inflow_month: money(inflow_month),
          # ADDITIVE field — the edge's mode (required /
          # specific / percent / leftover). The bands already carry it
          # (resolve_graph, lines 981/987); exposing it lets the client mark
          # the leftover bank node (the sankey icon) and the per-member
          # Direct Deposit readout (the leftover row) without a new endpoint.
          # Appended LAST so the existing keys keep their order (additive
          # only — the graph sha re-pins).
          inflow: inflow_rows.map do |band|
            { income_id: band[:income_id], date: band[:date].to_s, amount: money(band[:amount]), mode: band[:mode] }
          end,
          surplus_month: money(surplus_month),
          surplus: surplus_raw.map { |date, amount| { date: date.to_s, amount: money(amount) } }
        }
      end

      # Allocations: the per-paycheck resolution plus the monthly rollup
      # (totals from the RAW cents, formatted only for display).
      over_plan_target_ids = graph[:over_plans].values.select { |over| over[:target] == "fun_money" }.map { |over| over[:target_id] }
      allocations = @plan_allocations.map do |allocation|
        account_id = allocation[:account_id]

        # Unassigned: the source bank was removed
        # from the plan. The allocation persists, is excluded from resolution,
        # and is reported with a zero footprint + status "unassigned" so the
        # diagram can draw it with a "No Assignment" marker (no flow band).
        if account_id.nil?
          next {
            id: allocation[:id],
            name: allocation[:name],
            kind: allocation[:kind],
            mode: allocation[:mode],
            value_cents: allocation[:value_cents] ? money(allocation[:value_cents]) : nil,
            value_percent: allocation[:value_percent] ? format("%.4f", allocation[:value_percent]) : nil,
            cadence: allocation[:cadence],
            recurring_transaction_id: allocation[:recurring_transaction_id],
            auto_transfer: allocation[:auto_transfer],
            # the Sure category's name + color so
            # the diagram band matches the category. nil / nil when the
            # allocation has no category (never a fabricated color).
            category_name: category_for(allocation[:category_id])[:name],
            category_color: category_for(allocation[:category_id])[:color],
            account_id: nil,
            per_paycheck: [],
            wanted_month: "0.00",
            got_month: "0.00",
            shortfall_month: "0.00",
            status: "unassigned",
            over_planned: false,
            # the dressed account's identity (nil = a
            # plain row; additive keys — zero-target payloads unchanged).
            target_account_id: allocation[:target_account_id],
            target_account_name: allocation[:target_account_name],
            target_account_logo: allocation[:target_account_logo]
          }
        end

        per_paycheck_raw = graph[:dates].filter_map do |date|
          result = (graph[:allocation_results][date] || {})[account_id]&.dig(allocation[:id])
          next unless result

          [ date, result ]
        end
        per_paycheck = per_paycheck_raw.map do |date, result|
          {
            date: date.to_s,
            wanted: money(result[:wanted]),
            got: money(result[:got]),
            shortfall: money(result[:shortfall]),
            status: allocation_status(result[:kind], result[:got], result[:shortfall])
          }
        end

        wanted_month = per_paycheck_raw.sum { |_date, result| result[:wanted] }
        got_month = per_paycheck_raw.sum { |_date, result| result[:got] }
        shortfall_month = wanted_month - got_month

        {
          id: allocation[:id],
          name: allocation[:name],
          kind: allocation[:kind],
          mode: allocation[:mode],
          value_cents: allocation[:value_cents] ? money(allocation[:value_cents]) : nil,
          value_percent: allocation[:value_percent] ? format("%.4f", allocation[:value_percent]) : nil,
          cadence: allocation[:cadence],
          recurring_transaction_id: allocation[:recurring_transaction_id],
          auto_transfer: allocation[:auto_transfer],
          # the Sure category's name + color so
          # the diagram band matches the category. nil / nil when the
          # allocation has no category (never a fabricated color).
          category_name: category_for(allocation[:category_id])[:name],
          category_color: category_for(allocation[:category_id])[:color],
          account_id: account_id,
          per_paycheck: per_paycheck,
          wanted_month: money(wanted_month),
          got_month: money(got_month),
          shortfall_month: money(shortfall_month),
          status: allocation_status(allocation[:kind], got_month, shortfall_month),
          # The RED node: the fun money the over-plan flag names, when it is
          # actually short.
          over_planned: over_plan_target_ids.include?(allocation[:id]) && shortfall_month.positive?,
          # the dressed account's identity (nil = a
          # plain row; additive keys — zero-target payloads unchanged).
          target_account_id: allocation[:target_account_id],
          target_account_name: allocation[:target_account_name],
          target_account_logo: allocation[:target_account_logo],
          # (Fun Money v2): the per-member reconciliation rows
          # ({ member_id, leftover_month, fun_money_month,
          # un_allocated_month }, 2-dp strings) — nil for every
          # non-fun_money row and when no fun_money row exists.
          per_member: allocation[:kind] == "fun_money" && fun_money ?
            fun_money[:per_member].map do |row|
              {
                member_id: row[:member_id],
                leftover_month: row[:leftover_month],
                fun_money_month: row[:fun_money_month],
                un_allocated_month: row[:un_allocated_month]
              }
            end : nil,
          # The fun_money row's config echo (additive; nil for non-fun_money
          # rows): ownership / distribution / matching / inputs_stale (
          # drift snapshot divergence — the amber prompt).
          ownership: allocation[:kind] == "fun_money" ? allocation[:ownership] : nil,
          distribution: allocation[:kind] == "fun_money" ? allocation[:distribution] : nil,
          matching: allocation[:kind] == "fun_money" ? allocation[:matching] : nil,
          inputs_stale: allocation[:kind] == "fun_money" && fun_money ? fun_money[:inputs_stale] : nil
        }
      end

      {
        month: @month.strftime("%Y-%m"),
        currency: @currency,
        paycheck_dates: date_set.map(&:to_s),
        total_paychecks: total_occurrences,
        incomes: incomes,
        banks: banks,
        allocations: allocations,
        # the full usable logo set at the payload
        # root, so the bank config dialog's searchable picker needs no new
        # endpoint (client-side filtering over this list).
        available_bank_logos: available_bank_logos_rows,
        over_plans: graph[:over_plans].map do |income_id, over|
          { income_id: income_id, target: over[:target], target_id: over[:target_id], shortfall_month: money(over[:shortfall]) }
        end,
        limit_warnings: incomes.reject { |income| income[:limit_warning].nil? }
                              .map { |income| { income_id: income[:id], **income[:limit_warning] } },
        recommendations: @recommendations,
        suggested_fix: format_fix(fix),
        # (Fun Money v2): the RED Un-Allocated lines ({ income_id,
        # income_name, un_allocated_month } — income_id nil = the aggregate
        # Household line) strictly above the 100-cent tolerance. Empty
        # (never nil) when nothing exceeds it.
        discrepancies: fun_money ? fun_money[:discrepancies].map do |row|
          { income_id: row[:income_id], income_name: row[:income_name], un_allocated_month: money(row[:un_allocated_month]) }
        end : []
      }
    end

    # the usable logo set as picker rows
    # ({ slug, label }), sorted by label for a readable dialog. bank_logos
    # is already the file+label intersection (BankLogoSlugs.available), so
    # every row here is a file the asset pipeline serves same-origin.
    def available_bank_logos_rows
      @bank_logos.sort_by { |slug, label| label.to_s.downcase }
                 .map { |slug, label| { slug: slug, label: label } }
    end

    # the resolution order — the explicit
    # per-account slug wins when usable; then the first keyword hit on the
    # account name (longest keyword first); otherwise nil. Only slugs from
    # the vendored set are ever emitted (never a broken <img>).
    def bank_logo_for(bank_id)
      explicit = @account_bank_logos[bank_id].to_s
      return explicit if @bank_logos.key?(explicit)

      name = @account_names[bank_id].to_s.downcase.gsub(/[^a-z0-9]/, "")
      return nil if name.empty?

      # Longest keyword first, GUARANTEED here (the spec's resolution order),
      # so the pure core does not trust the caller's input order.
      hit = bank_logo_keywords_longest_first.find { |keyword, _| name.include?(keyword) }
      return nil unless hit

      @bank_logos.key?(hit.last) ? hit.last : nil
    end

    # [keyword, slug] pairs sorted longest-keyword-first (the "navyfederal"
    # beats "navy" rule). BankLogoSlugs.keywords already sorts, but the
    # planner guarantees the order itself so the pure-core unit tests pass
    # with inputs in any order.
    def bank_logo_keywords_longest_first
      @bank_logo_keywords_longest_first ||=
        @bank_logo_keywords.sort_by { |keyword, _| -keyword.length }
    end

    # category id => { name, color } row; a missing
    # category reads as an empty hash so both lookups return nil (no
    # fabricated color).
    def category_for(category_id)
      category_id ? (@categories[category_id] || {}) : {}
    end

    def allocation_status(kind, got, shortfall)
      return "ok" if shortfall.zero?

      # Bills and debts cap at "partly": they are never the over-plan flag
      # target, so "over" is reserved for savings/fun_money.
      return "partly" if kind == "bill" || kind == "debt"

      got.zero? ? "over" : "partly"
    end

    def suggested_fix(deltas, partner_actual_month)
      candidate = deltas.max_by { |_partner, delta| delta }
      return nil unless candidate
      partner, delta = candidate
      return nil unless delta.positive?

      # The partner's percent edges, across all their streams. The one-variable
      # solve needs exactly one.
      edges = @allocations.select do |edge|
        edge[:mode] == "percent" && edge_incomes(edge).any? { |income| income[:owner_id] == partner }
      end
      return nil unless edges.size == 1

      edge = edges.first
      stream = @incomes.find { |income| income[:id] == edge[:income_id] }
      return nil unless stream

      stream_month = stream[:occurrences].sum { |occ| occ[:amount_cents] }
      return nil unless stream_month.positive?

      shift = delta / stream_month
      suggested = edge[:value_percent] + shift
      return nil unless suggested >= 0 && suggested <= 1

      {
        user_id: partner,
        income_series_id: edge[:income_id],
        account_id: edge[:account_id],
        current_percent: edge[:value_percent],
        suggested_percent: (suggested * 10_000).round(0, half: :up) / 10_000,
        new_leftover_month: partner_actual_month[partner] - delta
      }
    end

    def edge_incomes(edge)
      @incomes.select { |income| income[:id] == edge[:income_id] }
    end

    def build_report(by_date:, required_per_paycheck:, total_occurrences:, pool_month:,
                     weights:, deltas:, target:, spread:, fix:, shortfalls:, partner_actual_month:)
      accounts = (@allocations.map { |edge| edge[:account_id] } | @obligations_by_account.keys).uniq
      accounts_by_month = Hash.new { |h, k| h[k] = BigDecimal(0) }
      by_date.each_value do |bucket|
        bucket[:by_account].each { |account_id, amount| accounts_by_month[account_id] += amount }
      end

      {
        month: @month,
        paycheck_dates: by_date.keys.map(&:to_s).sort,
        total_paychecks: total_occurrences,
        accounts: accounts.map do |account_id|
          {
            id: account_id,
            required_month: money(@obligations_by_account.fetch(account_id, BigDecimal(0))),
            required_per_paycheck: money(required_per_paycheck.fetch(account_id, BigDecimal(0))),
            total_in_month: money(accounts_by_month[account_id])
          }
        end,
        paychecks: by_date.keys.sort.map do |date|
          bucket = by_date[date]
          allocations = resolved_allocations(date)
          {
            date: date.to_s,
            total_income: money(bucket[:total]),
            allocations: allocations,
            by_account: bucket[:by_account].transform_keys(&:to_s).transform_values { |v| money(v) }
          }
        end,
        leftover_attribution: {
          distribution: @leftover_distribution,
          pooled_per_paycheck: money(total_occurrences.positive? ? pool_month / total_occurrences : BigDecimal(0)),
          pooled_month: money(pool_month),
          by_partner: @partners.map do |partner|
            weight = weights[partner] || BigDecimal(0)
            {
              user_id: partner,
              weight: format("%.4f", weight),
              fun_money_per_paycheck: money(total_occurrences.positive? ? weight * pool_month / total_occurrences : BigDecimal(0)),
              fun_money_month: money(weight * pool_month),
              actual_leftover_month: money(partner_actual_month[partner])
            }
          end
        },
        delta: {
          target_month: money(target),
          spread_month: money(spread || BigDecimal(0)),
          by_partner: @partners.map do |partner|
            { user_id: partner, delta_month: money(deltas.fetch(partner, BigDecimal(0))) }
          end
        },
        suggested_fix: format_fix(fix),
        shortfalls: shortfalls.map do |income_id, gap|
          {
            income_series_id: income_id,
            gap_month: money(gap),
            message: "Required and fixed allocations exceed this income for #{month_label}"
          }
        end
      }
    end

    # Edge rows for one paycheck date, in the order the streams resolve.
    def resolved_allocations(date)
      rows = []
      @incomes.each do |income|
        next unless income[:occurrences].any? { |occ| occ[:date] == date }

        entry = @resolved[[ income[:id], date ]]
        entry[:amounts].each do |account_id, amount|
          mode = entry[:edges].find { |e| e[:account_id] == account_id }[:mode]
          rows << { income_series_id: income[:id], account_id: account_id, mode: mode, amount: money(amount) }
        end

        leftover_edge = entry[:edges].find { |e| e[:mode] == "leftover" }
        if leftover_edge
          rows << {
            income_series_id: income[:id],
            account_id: leftover_edge[:account_id],
            mode: "leftover",
            amount: money(entry[:leftover]),
            shortfall: entry[:leftover].negative?
          }
        end
      end
      rows
    end

    def format_fix(fix)
      return nil unless fix

      fix.merge(
        current_percent: format("%.4f", fix[:current_percent]),
        suggested_percent: format("%.4f", fix[:suggested_percent]),
        new_leftover_month: money(fix[:new_leftover_month])
      )
    end

    def money(cents)
      format("%.2f", cents / CENTS)
    end

    def month_label
      @month.strftime("%B %Y")
    end
end
