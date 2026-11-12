# dress an account: target_account_id names the account the row represents
# in the allocation pillar (the owner's "move this all the way into the
# Allocation Pillar" flow). account_id semantics stay FROZEN — it is (and
# only stays) the source bank the money comes from.
#
# Nullable uuid, no FK (plan_allocations.account_id carries no FK either —
# family scoping is enforced in the model, not the database). nil = a plain
# allocation row; the planner's "already planned" recommendation skip and
# the diagram dressing key off presence only.
class AddTargetAccountIdToPlanAllocations < ActiveRecord::Migration[8.1]
  def up
    add_column :plan_allocations, :target_account_id, :uuid
    add_index :plan_allocations, :target_account_id
  end

  def down
    remove_index :plan_allocations, :target_account_id
    remove_column :plan_allocations, :target_account_id
  end
end
