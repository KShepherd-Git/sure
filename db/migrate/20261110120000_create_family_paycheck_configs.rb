# (Direct Deposit): per-member paycheck configs for the Paycheck
# Flow Planner. A config overrides one member's labeled income series with a
# gross-per-paycheck amount + pay cadence (semi_monthly = 15th & last,
# biweekly = every 14 days from the anchor weekday). Pay dates are DERIVED
# from the house Schedule engine at plan time — no occurrences are stored
# here (v1 gap: the bills/paycheck page still reads the stored series
# occurrences until the follow-up "sync to series").
#
# the default frequency is semi_monthly for paycheck
# configs even though house income-series creation defaults to biweekly
# (recurring_transactions_controller.rb) — the signed flag applies to
# paycheck configs only. Existing members only: the UI offers one tab
# per existing family member; no member creation here.
#
# Existing members only + one config per member: unique (family_id,
# user_id). gross_per_paycheck_cents > 0 is enforced by the model (the DB
# constraint stays permissive on rollback).
class CreateFamilyPaycheckConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :family_paycheck_configs, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: true
      t.references :user, null: false, type: :uuid, foreign_key: { to_table: :users }
      t.references :recurring_transaction, null: true, type: :uuid,
        foreign_key: { to_table: :recurring_transactions, on_delete: :nullify }
      t.integer :gross_per_paycheck_cents, null: false
      t.string :frequency, null: false, default: "semi_monthly"
      t.date :anchor_date, null: false

      t.timestamps
    end

    add_check_constraint :family_paycheck_configs,
      "frequency = 'semi_monthly' OR frequency = 'biweekly'",
      name: "chk_family_paycheck_configs_frequency"
    # NOTE: t.references (Rails 8.1) already auto-creates the single-column
    # indexes on family_id / user_id / recurring_transaction_id — only the
    # uniqueness invariant needs an explicit index.
    add_index :family_paycheck_configs, [ :family_id, :user_id ], unique: true
  end
end
