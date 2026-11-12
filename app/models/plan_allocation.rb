# M2 PR#2b (Sure Paycheck Flow redesign): one allocation pulled out of a
# source bank on the family's planning diagram -- a bill, debt payment,
# savings target, or fun money. The mode decides how much it gets per
# paycheck; the bank-level resolution order is fixed and non-configurable
# (required -> specific -> percent of the bank's leftover pool -> leftover
# split equally), which the planner applies: PaycheckFlowPlanner#plan_graph.
class PlanAllocation < ApplicationRecord
  # weekly | biweekly | monthly | quarterly | yearly -- autofilled from the
  # linked recurring transaction's interval/weekday, editable in the dialog.
  CADENCES = %w[weekly biweekly monthly quarterly yearly].freeze

  # Round 31A (Fun Money as a first-class allocation): the fun_money row's
  # OWNERSHIP + DISTRIBUTION + MATCHING configuration (fun_money kind only —
  # every other kind ignores the columns, model-scoped below).
  #   ownership:      "household" or a family user id; NULL = legacy row
  #                   (treated as Household, byte-identical behavior).
  #   distribution:   mirrors the bank-dialog Split Behavior values (C2);
  #                   "percent" carries per-member percents in
  #                   distribution_params (sum 100.00 +/- 0.01, C9).
  #   matching:       C1's behaviors (Equalize | Per Income); NULL/ignored
  #                   on Household and legacy rows (M2).
  FM_OWNERSHIP_HOUSEHOLD = "household".freeze
  FM_DISTRIBUTIONS = %w[equal rational percent individual_leftover].freeze
  FM_MATCHINGS = %w[equalize per_income].freeze

  # bill | debt | savings | fun_money. Bills and debts are REQUIRED by
  # definition (paid first, never the over-plan flag target); savings and
  # fun_money are what the over-plan flag measures against.
  enum :kind, { bill: "bill", debt: "debt", savings: "savings", fun_money: "fun_money" }

  # required: value_cents OR a linked recurring transaction (amount from its
  #   monthly_equivalent_amount). specific: per-paycheck hard number.
  # percent: share of the bank's leftover pool. leftover: splits the bank's
  #   final residual equally.
  enum :mode, { required: "required", specific: "specific", percent: "percent", leftover: "leftover" }

  belongs_to :family
  # The source bank the money is pulled from (the diagram's "SOURCE BANK").
  # Optional (owner review round 3, R3): a bank removed from the plan leaves
  # its allocations behind, unassigned ("No Assignment" marker) — they are
  # excluded from resolution until re-assigned.
  # The source bank the money is pulled from (the diagram's "SOURCE BANK").
  # Optional (owner review round 3, R3): a bank removed from the plan leaves
  # its allocations behind, unassigned ("No Assignment" marker) — they are
  # excluded from resolution until re-assigned. For kind "savings" (owner
  # round 10, issue 4) this SAME field is the bucket's associated account:
  # the planner resolution and the Sankey band both key off it, and the
  # dialog labels it "Which Account is this Savings Bucket Associated to".
  belongs_to :account, optional: true
  # The detected bill/debt this allocation represents (autofill source).
  belongs_to :recurring_transaction, optional: true
  # Round 16 (owner note 2): the Sure category whose color the diagram uses
  # for this allocation's band. Optional — an allocation without a category
  # renders with no color (nil), never a fabricated one.
  belongs_to :category, optional: true
  # Round 25 (Item 2): "Make Allocated Sub-Account" — the account this row
  # DRESSES. Present, the row is the account's own pillar node in the
  # allocation column (the diagram draws it with the account's identity)
  # funded from the source bank (account_id, frozen semantics); the bank's
  # own row keeps its income edges and degrades to the ghost hairline only
  # when those stop feeding it. nil = a plain allocation row.
  # class_name: the association name would otherwise infer a TargetAccount
  # model (Rails camelizes the whole association name).
  belongs_to :target_account, optional: true, class_name: "Account"

  validates :name, presence: true
  validates :cadence, inclusion: { in: CADENCES }, allow_nil: true
  validate :value_matches_mode
  validate :references_belong_to_family
  validate :fun_money_configuration

  # Round 31A (C11 legacy-safe): the ownership as the planner reads it —
  # NULL (legacy rows) behaves as the Household shared pool.
  def resolved_ownership
    ownership.presence || FM_OWNERSHIP_HOUSEHOLD
  end

  # Required-mode amounts resolve from the linked transaction's
  # monthly-equivalent amount when no explicit value_cents is set.
  def resolved_monthly_amount
    return value_cents if value_cents.present?

    return nil unless recurring_transaction

    recurring_transaction.monthly_equivalent_amount.amount * 100
  end

  private
    # Round 31A (Fun Money v2): the ownership / distribution / matching
    # configuration is fun_money-kind only (C1-C2, C9, C11). House pattern
    # (cf. references_belong_to_family): model-level validation, 422
    # contract on violation; no DB check constraints (the migration is
    # additive + nullable on purpose).
    #   - non-fun_money kinds keep the columns blank (the dialog never
    #     submits them for other kinds; the sanitizer drops them — this is
    #     the backstop for hand-edited rows);
    #   - ownership must be "household" or a user id that exists AND
    #     belongs to this family (a dangling / cross-family id is a 422,
    #     same as the existing dialog path);
    #   - distribution / matching must be one of the fixed sets;
    #   - distribution "percent" requires per-member percents in
    #     distribution_params: keyed by family user ids, 0-100, summing to
    #     100.00 +/- 0.01 (C9).
    def fun_money_configuration
      unless kind == "fun_money"
        # Fun Money v2 (Round 31A): the config columns are fun_money-only —
        # a value on any other kind is a 422 (the dialog never submits
        # them; this is the backstop for hand-edited rows).
        errors.add(:ownership, "is only set on a Fun Money allocation") if ownership.present?
        errors.add(:distribution, "is only set on a Fun Money allocation") if distribution.present?
        errors.add(:matching, "is only set on a Fun Money allocation") if matching.present?
        return
      end

      return unless [ ownership, distribution, matching ].any?(&:present?)

      errors.add(:ownership, "must be the household or a family member") if
        ownership.present? &&
        ownership != FM_OWNERSHIP_HOUSEHOLD &&
        (family.blank? || !family.users.exists?(id: ownership))

      errors.add(:distribution, "must be one of #{FM_DISTRIBUTIONS.join(" / ")}") if
        distribution.present? && !FM_DISTRIBUTIONS.include?(distribution)

      errors.add(:matching, "must be one of #{FM_MATCHINGS.join(" / ")}") if
        matching.present? && !FM_MATCHINGS.include?(matching)

      return unless distribution == "percent"

      raw_params = distribution_params
      percents = raw_params.is_a?(Hash) ?
        (raw_params["percents"] || raw_params[:percents] || {}) : {}
      percents = percents.to_h
      errors.add(:distribution, "needs per-member percents (Percentage of Pooled)") if
        percents.empty?

      percents.each do |user_id, value|
        unless family.present? && family.users.exists?(id: user_id.to_s)
          errors.add(:distribution_params, "percents must be keyed by family members")
        end
        num = value.to_d rescue BigDecimal(-1)
        errors.add(:distribution_params, "percents must be 0-100") if
          num < 0 || num > 100
      end

      return if percents.empty?

      total = percents.values.sum { |v| v.to_d rescue BigDecimal(0) }
      errors.add(:distribution_params, "percents must sum to 100.00 (allowance 0.01)") if
        (total - 100).abs > 0.01
    end

    # Mode-specific value rules (the DB check constraint
    # chk_plan_allocations_value_mode enforces the same shape at the edge).
    def value_matches_mode
      case mode
      when "required"
        if kind == "savings"
          # Round 10 issue 4: a savings bucket's monthly figure is always
          # TYPED (the dialog hides the detected-bill link for kind
          # "savings"), so a linked recurring transaction is no substitute
          # — the explicit monthly amount is required.
          errors.add(:value_cents, "is required for a savings bucket") if value_cents.nil?
        elsif value_cents.nil? && recurring_transaction_id.blank?
          errors.add(:value_cents, "is required unless a recurring transaction is linked")
        end
        # An explicit required amount must be positive; the linked-transaction
        # fallback is only used when the amount is absent.
        errors.add(:value_cents, :numericality, greater_than: 0) if value_cents.present? && value_cents <= 0
        errors.add(:value_percent, "is not allowed for this mode") if value_percent.present?
      when "specific"
        if value_cents.blank? || value_cents <= 0
          errors.add(:value_cents, :numericality, greater_than: 0)
        end
        errors.add(:value_percent, "is not allowed for this mode") if value_percent.present?
      when "percent"
        if value_percent.blank? || value_percent <= 0 || value_percent > 1
          errors.add(:value_percent, :numericality, greater_than: 0, less_than_or_equal_to: 1)
        end
        errors.add(:value_cents, "is not allowed for this mode") if value_cents.present?
      when "leftover"
        errors.add(:value_cents, "is not allowed for this mode") if value_cents.present?
        errors.add(:value_percent, "is not allowed for this mode") if value_percent.present?
      end
    end

    # House pattern (account.rb owner_belongs_to_family): an allocation may
    # only reference the source bank and the recurring transaction of its
    # own family.
    def references_belong_to_family
      return if family_id.blank?

      errors.add(:account, "must belong to the same family") if
        account.present? && account.family_id != family_id

      errors.add(:recurring_transaction, "must belong to the same family") if
        recurring_transaction.present? && recurring_transaction.family_id != family_id

      errors.add(:category, "must belong to the same family") if
        category.present? && category.family_id != family_id

      # Round 25 (Item 2): the dressed account (Make Allocated Sub-Account)
      # must exist AND belong to this family. A blank id is a plain row;
      # a dangling id loads nil (existence check), a cross-family id loads
      # the account (membership check) — same shape as the checks above.
      errors.add(:target_account, "must name a family account") if
        target_account_id.present? && target_account.nil?

      errors.add(:target_account, "must belong to the same family") if
        target_account.present? && target_account.family_id != family_id
    end
end
