# nullable columns on plan_allocations — the fun_money row IS the Fun Money
# entity (kind already exists), so no new tables. All fields are
# fun_money-kind only; every other kind ignores them (model-scoped
# validations; planner treats NULL fields as the legacy Household behavior,
# byte-identical to today).
#
#   ownership            "household" or a family user id (string); NULL =
#                        legacy row (treated as Household).
#   distribution         equal | rational | percent | individual_leftover —
#                        mirrors the bank-dialog Split Behavior values.
#   matching             equalize | per_income (C1); NULL/ignored on
#                        Household and legacy rows.
#   distribution_params  jsonb default {}: per-member percents when
#                        distribution == "percent" ({ "percents":
#                        {user_id => "40.00"} }) + the drift input snapshot
#                        (C14: { "inputs_snapshot": {...} }).
#
# No DB check constraints (house pattern: model-level validation); the
# existing chk_plan_allocations_* constraints are untouched.
class AddFunMoneyFieldsToPlanAllocations < ActiveRecord::Migration[8.1]
  def change
    add_column :plan_allocations, :ownership, :string
    add_column :plan_allocations, :distribution, :string
    add_column :plan_allocations, :matching, :string
    add_column :plan_allocations, :distribution_params, :jsonb, default: {}
  end
end
