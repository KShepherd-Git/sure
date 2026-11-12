# now carry a stored split — the percent of the bank's required amount that
# this income funds (2 dp major units, 0 < value <= 100; NULL stays the
# equal split, i.e. today's planner behavior). The R26 constraint
# chk_income_account_allocations_value_mode rejects ANY value on a required
# row (mode IN ('required','leftover') AND value IS NULL), which would raise
# StatementInvalid (a 500) instead of the model's 422 on an invalid percent.
# Constraint-only change: no data migration (all existing rows are
# required + NULL), the column stays decimal(12,2) nullable, and the unique
# (income_series_id, account_id) index is untouched. Leftover keeps the
# value-IS-NULL rule (C1: display-only, no persisted split).
# Reversible: down restores the original two-branch expression.

class ExtendIaaValueModeConstraint < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :income_account_allocations,
      name: "chk_income_account_allocations_value_mode"
    add_check_constraint :income_account_allocations,
      "mode = 'specific' AND value > 0 OR mode = 'percent' AND value > 0 AND value <= 1 OR (mode = 'required' AND (value IS NULL OR (value > 0 AND value <= 100))) OR (mode = 'leftover' AND value IS NULL)",
      name: "chk_income_account_allocations_value_mode"
  end

  def down
    remove_check_constraint :income_account_allocations,
      name: "chk_income_account_allocations_value_mode"
    add_check_constraint :income_account_allocations,
      "mode = 'specific' AND value > 0 OR mode = 'percent' AND value > 0 AND value <= 1 OR (mode IN ('required', 'leftover')) AND value IS NULL",
      name: "chk_income_account_allocations_value_mode"
  end
end
