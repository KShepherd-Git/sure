# (Flow Scenarios): the scenario-owned snapshot blob (design (a2):
# one plan_scenarios.snapshot jsonb column per scenario, in the planner's
# draft row shapes). Default is NOT a row — the absence of an active
# scenario is the live plan — so the invariants are structural: Default
# cannot be deleted, renamed, or snapshotted because no row exists to act
# on. No other table is touched (isolation by construction; the IAA unique
# index is untouched, unlike the (a1) scoped-rows variant).
class CreatePlanScenarios < ActiveRecord::Migration[8.1]
  def change
    create_table :plan_scenarios, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: true
      t.string :name, null: false, limit: 40
      t.jsonb :snapshot, null: false, default: {}
      t.string :source, null: false, default: "reuse_current" # reuse_current | fresh
      t.datetime :snapshotted_at # nil for fresh
      t.timestamps
    end
    add_index :plan_scenarios, %i[family_id name], unique: true
    add_check_constraint :plan_scenarios, "source IN ('reuse_current','fresh')", name: "chk_plan_scenarios_source"
  end
end
