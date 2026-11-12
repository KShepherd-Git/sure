# Paycheck Flow Planner (M2): one edge from a declared income series to a bank
# account on the family's money map. Modes resolve in priority order when the
# plan is solved (required -> specific -> percent -> leftover); `value` is the
# per-paycheck amount for `specific`, the 0.0-1.0 fraction for `percent`, the
# stored percent of the bank's required amount this income funds for
# `required` (Round 30: 2 dp major units, 0 < value <= 100; NULL = the equal
# split, today's planner behavior), and NULL for the derived `leftover` edge.
class IncomeAccountAllocation < ApplicationRecord
  enum :mode, { required: "required", specific: "specific", percent: "percent", leftover: "leftover" }

  belongs_to :family
  belongs_to :income_series, class_name: "RecurringTransaction"
  belongs_to :account

  validate :value_matches_mode
  validate :income_series_is_income
  validate :references_belong_to_family

  # specific: positive per-paycheck amount (major units). percent: a fraction
  # in (0, 1]. required: NULL (the equal split — the planner derives it) or
  # the stored percent of the bank's required amount this income funds
  # (Round 30: 2 dp major units, 0 < value <= 100). leftover: derived at solve
  # time (each paycheck's remainder, inherently per-income), so a stored value
  # would be stale by definition (C1: display-only, never persisted).
  # R5 (BUG-7): the message keys are the stock validator keys
  # (:greater_than / :less_than_or_equal_to with count) — the app's trimmed
  # locale set has no :numericality key, so the old add() rendered
  # "translation missing" into the 422 body.
  def value_matches_mode
    case mode
    when "required"
      return if value.nil?

      errors.add(:value, :greater_than, count: 0) unless value > 0
      errors.add(:value, :less_than_or_equal_to, count: 100) if value > 100
    when "leftover"
      errors.add(:value, :blank) unless value.nil?
    when "specific"
      errors.add(:value, :greater_than, count: 0) unless value.present? && value > 0
    when "percent"
      if value.present? && value > 1
        errors.add(:value, :less_than_or_equal_to, count: 1)
      else
        errors.add(:value, :greater_than, count: 0) unless value.present? && value > 0
      end
    end
  end

  # A crafted id could pin an edge to a bill or another family's income
  # series, which the unique index alone does not catch.
  def income_series_is_income
    return if income_series_id.blank?

    errors.add(:income_series, :invalid, message: "must be a declared income series") unless
      income_series.present? && income_series.typed_income?
  end

  def references_belong_to_family
    return if family_id.blank?

    errors.add(:income_series, "must belong to the same family") if
      income_series.present? && income_series.family_id != family_id
    errors.add(:account, "must belong to the same family") if
      account.present? && account.family_id != family_id
  end
end
