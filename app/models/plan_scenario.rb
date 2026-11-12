# Round 35 (Flow Scenarios): one what-if plan for a family. The `snapshot`
# jsonb holds the plan state in the planner's draft row shapes (see
# PlanScenarioSnapshot) — plan allocations, income->bank edges, paycheck
# config copies and the per-series income policy. "Default" is not a row:
# the absence of an active scenario IS the live plan (the invariants are
# structural — a Default row can never be created, renamed, or deleted).
class PlanScenario < ApplicationRecord
  SOURCES = %w[reuse_current fresh].freeze
  RESERVED_NAME = "default"

  belongs_to :family

  validates :name, presence: true
  validates :name, length: { maximum: 40 }
  validates :name, uniqueness: { scope: :family_id, case_sensitive: false,
                                message: "has already been taken" }
  validates :source, inclusion: { in: SOURCES, message: "is invalid" }
  validate :name_not_reserved

  before_validation :default_snapshot, :default_source

  private

    # "default" (case-insensitive) is the live plan — it has no row and
    # must not be typable as a scenario.
    def name_not_reserved
      errors.add(:name, "is reserved") if name.to_s.casecmp?(RESERVED_NAME)
    end

    def default_snapshot
      self.snapshot = {} if snapshot.nil?
    end

    # Mirror the DB column default so a new record validates in-memory
    # (the inclusion check would otherwise see nil before the insert).
    def default_source
      self.source = "reuse_current" if source.nil?
    end
end
