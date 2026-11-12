# (Direct Deposit): one member's paycheck config for the Paycheck
# Flow Planner. The config overrides the member's labeled income series with
# a gross-per-paycheck amount + cadence; the planner derives the pay dates
# from the house Schedule engine (PaycheckFlowPlanner::PaycheckDates) and the
# overlay swaps the series' occurrences in inputs_for. Zero config rows =
# byte-identical planner output (the no-op invariant).
class FamilyPaycheckConfig < ApplicationRecord
  FREQUENCIES = [ "semi_monthly", "biweekly" ].freeze

  # semi_monthly is the paycheck-config default, even
  # though house income-series creation defaults to biweekly (the signed
  # flag applies to paycheck configs only).
  FREQUENCY_SEMI_MONTHLY = "semi_monthly"
  FREQUENCY_BIWEEKLY = "biweekly"

  belongs_to :family
  belongs_to :user
  # The member's labeled income series (bill_type income, manual). Optional
  # at the DB level (v1 saves require it — see PlanFlowsController#
  # update_paycheck_config); nil configs are skipped by the overlay.
  belongs_to :recurring_transaction, optional: true

  validates :frequency, presence: true, inclusion: { in: FREQUENCIES }
  # No $0.00 paychecks: the model rejects 0 (greater_than, not
  # greater_than_or_equal_to) and the DB stays permissive on rollback.
  validates :gross_per_paycheck_cents, presence: true,
            numericality: { only_integer: true, greater_than: 0 }
  validates :anchor_date, presence: true
  validates :user, uniqueness: { scope: :family_id }
  validate :user_belongs_to_family
  validate :series_is_member_income

  # Monthly equivalent for the member: gross x the count of derived pay
  # dates in the month (semi_monthly = always 2; biweekly = 2 or 3).
  def derived_monthly_cents(month)
    PaycheckFlowPlanner::PaycheckDates.occurrences(
      self, month.beginning_of_month, month.end_of_month
    ).sum { |occurrence| occurrence[:amount_cents] }
  end

  # The member's next pay dates (future-only readout; an anchor in the past
  # is normal — the window clipping handles it).
  def upcoming_dates(count: 4)
    PaycheckFlowPlanner::PaycheckDates.upcoming(self, count: count)
  end

  private
    # Same family-membership guard as RecurringTransaction#
    # plan_owner_belongs_to_family (recurring_transaction.rb).
    def user_belongs_to_family
      return if family_id.blank? || user_id.blank? || user.nil?

      errors.add(:user, :wrong_family) unless user.family_id == family_id
    end

    # When a series is linked it must be the member's own labeled income
    # series (same family, bill_type income) so the overlay can swap its
    # occurrences without crossing the invariant (allocations' wanted
    # amounts are immutable to the overlay).
    def series_is_member_income
      return if recurring_transaction.nil? || family_id.blank?

      series = recurring_transaction
      errors.add(:recurring_transaction, :wrong_family) unless series.family_id == family_id
      errors.add(:recurring_transaction, :not_income) unless series.bill_type == "income"
      errors.add(:recurring_transaction, :wrong_member) if series.plan_owner_id != user_id
    end
end
