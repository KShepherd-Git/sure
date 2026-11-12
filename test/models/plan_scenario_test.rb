require "test_helper"

# (Flow Scenarios): the PlanScenario model. The "Default" plan is
# the ABSENCE of an active scenario (no row), so the model only guards what
# a row may be: a family-scoped name (presence, 40 chars, case-insensitive
# uniqueness, the reserved word "default"), a valid source, and the
# snapshot default.
#
# NOTE: a keyword argument's default expression shadows same-named methods
# (the unassigned parameter wins) — the helper below defaults `family:`
# from `families(:dylan_family)`, NOT from a `family` method (a `family:
# family` default silently evaluated to nil and masked every assertion).
class PlanScenarioTest < ActiveSupport::TestCase
  def build(name:, source: "reuse_current", family: families(:dylan_family))
    PlanScenario.new(family: family, name: name, source: source)
  end

  test "name presence" do
    scenario = build(name: nil)
    assert_not scenario.valid?
    assert_equal [ "can't be blank" ], scenario.errors[:name]

    # Whitespace-only is blank (String#blank?) — presence rejects it too;
    # the controller strips before the save so it never reaches the DB.
    scenario = build(name: "   ")
    assert_not scenario.valid?
    assert scenario.errors[:name].include?("can't be blank")
  end

  test "name limit 40" do
    assert build(name: "a" * 40).valid?
    scenario = build(name: "a" * 41)
    assert_not scenario.valid?
    assert scenario.errors[:name].any? { |message| message.include?("too long") }
  end

  test "case-insensitive family-scoped uniqueness" do
    family = families(:dylan_family)
    family.plan_scenarios.create!(name: "Second income quits", snapshot: {})

    assert_not build(name: "Second Income Quits").valid?, "case-insensitive collision must fail"
    collision = build(name: "second income quits")
    assert_not collision.valid?
    assert_equal [ "has already been taken" ], collision.errors[:name]

    # Other families may use the same name (family-scoped).
    other = families(:empty)
    assert build(name: "Second income quits", family: other).valid?
  end

  test "reserved name default (case-insensitive)" do
    %w[default Default DEFAULT].each do |reserved|
      scenario = build(name: reserved)
      assert_not scenario.valid?, "#{reserved} must be reserved"
      assert_equal [ "is reserved" ], scenario.errors[:name]
    end
  end

  test "source inclusion + check-constraint values" do
    assert build(name: "A", source: "reuse_current").valid?
    assert build(name: "B", source: "fresh").valid?

    scenario = build(name: "C", source: "bogus")
    assert_not scenario.valid?
    assert_equal [ "is invalid" ], scenario.errors[:source]
  end

  test "snapshot defaults to {}" do
    scenario = build(name: "Fresh", source: "fresh")
    assert_equal({}, scenario.snapshot, "the DB default {} is the new-record default")
    scenario.valid?
    assert_equal({}, scenario.snapshot)

    persisted = families(:dylan_family).plan_scenarios.create!(name: "Persisted", source: "reuse_current")
    assert_equal({}, persisted.reload.snapshot)
  end

  test "belongs_to family" do
    scenario = PlanScenario.new(name: "Orphan")
    assert_not scenario.valid?
    assert scenario.errors[:family].any?
  end

  test "snapshot jsonb round-trip (the draft row shapes)" do
    family = families(:dylan_family)
    snapshot = PlanScenarioSnapshot.reuse_current(family)
    persisted = family.plan_scenarios.create!(name: "Round trip", snapshot: snapshot)

    reloaded = persisted.reload.snapshot
    assert_equal snapshot["v"], reloaded["v"]
    assert_equal snapshot["plan_allocations"], reloaded["plan_allocations"]
    assert_equal snapshot["incomes"], reloaded["incomes"]
    # jsonb returns string keys (the draft seam reads string keys).
    reloaded["plan_allocations"].each do |row|
      assert_equal row.keys.map(&:to_s), row.keys
    end
  end
end
