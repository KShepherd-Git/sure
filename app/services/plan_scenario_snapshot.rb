# (Flow Scenarios): the snapshot builders. A scenario's `snapshot`
# jsonb holds the plan state in the EXACT row shapes the planner's draft
# seam already consumes — `PaycheckFlowPlanner.plan_allocation_rows` and
# `edge_rows` (stringified) — plus per-member paycheck-config copies and a
# per-series income policy. A scenario is literally a draft: at plan time
# `PaycheckFlowPlanner.scenario_draft` hands these rows to `apply_draft`,
# which replaces the saved input sets wholesale.
#
# Shape (v1 — versioned so a future shape change can migrate old blobs):
#   {
#     "v" => 1,
#     "plan_allocations" => [ plan_allocation_rows shape (string keys) ],
# "allocations" => [ edge_rows shape (string keys) ],
#     "paycheck_configs" => [ { user_id, recurring_transaction_id,
#                               gross_per_paycheck_cents, frequency,
#                               anchor_date } ],
# "incomes" => [ { series_id, enabled, zeroed,
#                               gross_per_paycheck_cents } ]
#   }
#
# Identity: a Re-Use Current copy keeps the live uuids (byte-faithful
# snapshot — sankey node ids stay stable across the Default<->scenario
# switch). Rows created inside a scenario get fresh uuids at write time
# (the controller generates them; no AR involvement, the blob holds it).
class PlanScenarioSnapshot
  VERSION = 1

  class << self
    # Start Fresh: an empty plan over the family's CURRENT INCOMES (no
    # allocations, no links, no config copies; the income policy lists the
    # live series all-enabled with no overrides — the sankey keeps its
    # income nodes, the plan is blank). The existing empty-state chrome
    # (the @plan_allocations.empty? CTA) renders it correctly.
    def fresh(family)
      {
        "v" => VERSION,
        "plan_allocations" => [],
        "allocations" => [],
        "paycheck_configs" => [],
        "incomes" => income_policy(family)
      }
    end

    # Re-Use Current: snapshot the current live plan — allocations,
    # links, Fun Money (it is a plan_allocation of kind fun_money, so it
    # rides along automatically), paycheck configs — byte-faithful.
    def reuse_current(family)
      {
        "v" => VERSION,
        "plan_allocations" => PaycheckFlowPlanner.plan_allocation_rows(family).map { |row| row.stringify_keys },
        "allocations" => PaycheckFlowPlanner.edge_rows(family).map { |row| row.stringify_keys },
        "paycheck_configs" => family.family_paycheck_configs.order(:user_id).to_a.map do |config|
          {
            "user_id" => config.user_id,
            "recurring_transaction_id" => config.recurring_transaction_id,
            "gross_per_paycheck_cents" => config.gross_per_paycheck_cents,
            "frequency" => config.frequency,
            "anchor_date" => config.anchor_date&.to_date&.iso8601
          }
        end,
        "incomes" => income_policy(family)
      }
    end

    # The per-series income policy (NOT per-month occurrence rows — keeps
    # scenarios month-independent). One row per active manual income
    # series, :id order (the same read order the planner's incomes array
    # carries), all enabled with no overrides.
    def income_policy(family)
      family.recurring_transactions
           .where(status: :active, bill_type: "income", manual: true)
           .order(:id)
           .to_a
           .map do |series|
             {
               "series_id" => series.id,
               "enabled" => true,
               "zeroed" => false,
               "gross_per_paycheck_cents" => nil
             }
           end
    end

    # The stringified plan_allocation_rows shape for one model instance —
    # the same field mapping as PaycheckFlowPlanner.plan_allocation_rows
    # (verified by the deep-equality test), so a row merged inside a
    # scenario serializes identically to its live twin.
    def plan_allocation_row(allocation)
      {
        "id" => allocation.id,
        "account_id" => allocation.account_id,
        "name" => allocation.name,
        "kind" => allocation.kind,
        "mode" => allocation.mode,
        "value_cents" => allocation.value_cents,
        "value_percent" => allocation.value_percent,
        "cadence" => allocation.cadence,
        "recurring_transaction_id" => allocation.recurring_transaction_id,
        "auto_transfer" => allocation.auto_transfer,
        "category_id" => allocation.category_id,
        "target_account_id" => allocation.target_account_id,
        "target_account_name" => allocation.target_account&.name,
        "target_account_logo" => allocation.target_account ?
          BankLogoSlugs.resolve(allocation.target_account.name,
                                explicit: allocation.target_account.bank_logo_slug) : nil,
        "ownership" => allocation.ownership,
        "distribution" => allocation.distribution,
        "matching" => allocation.matching,
        "distribution_params" => allocation.distribution_params
      }
    end

    # The stringified edge_rows shape for one income->bank edge (the same
    # mode-conditional value mapping as PaycheckFlowPlanner.edge_rows):
    # specific -> value_cents, percent -> value_percent (fraction),
    # required -> required_percent, leftover -> nil.
    def edge_row(income_series_id:, account_id:, mode:, value: nil)
      {
        "income_id" => income_series_id,
        "account_id" => account_id,
        "mode" => mode,
        "value_cents" => mode == "specific" ? (value.nil? ? nil : (value * 100).round) : nil,
        "value_percent" => mode == "percent" ? value : nil,
        "required_percent" => mode == "required" ? value : nil
      }
    end
  end
end
