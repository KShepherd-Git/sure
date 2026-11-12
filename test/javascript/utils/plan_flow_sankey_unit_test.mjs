import assert from "node:assert/strict";
import { test } from "node:test";
import {
  incomeOccurrenceCounts,
  bankInflowInfo,
  paycheckUnitScales,
} from "../../../app/javascript/utils/plan_flow_sankey_unit.mjs";

// Round 33 (spec 1): the Per-Paycheck unit — per income occurrence count
// (DEFAULT) vs the old family composite. The live-plan fixture mirrors the
// verified data: Kurt payroll (2 occurrences, $5400.00/month) + Sammi
// payroll (2 occurrences, $2800.00/month); Freedom Mortgage funded by ONE
// payroll (Kurt, $2547.12/month); a second bank funded 50/50 by both.

const KURT = "kurt";
const SAMMI = "sammi";
const MORTGAGE = "mortgage";
const POOLED = "pooled";

const graph = {
  paycheck_dates: ["2026-11-06", "2026-11-13", "2026-11-20", "2026-11-27"],
  incomes: [
    { id: KURT, total_month: 5400, occurrences: [{ date: "2026-11-06" }, { date: "2026-11-20" }] },
    { id: SAMMI, total_month: 2800, occurrences: [{ date: "2026-11-13" }, { date: "2026-11-27" }] },
  ],
  banks: [
    {
      id: MORTGAGE,
      inflow_month: "2547.12",
      surplus_month: "0.00",
      inflow: [
        { income_id: KURT, date: "2026-11-06", amount: "1273.56" },
        { income_id: KURT, date: "2026-11-20", amount: "1273.56" },
      ],
    },
    {
      id: POOLED,
      inflow_month: "2000.00",
      surplus_month: "50.00",
      inflow: [
        { income_id: KURT, date: "2026-11-06", amount: "1000.00" },
        { income_id: SAMMI, date: "2026-11-13", amount: "1000.00" },
      ],
    },
  ],
};

const approx = (a, b, msg) => assert.ok(Math.abs(a - b) < 0.005, `${msg}: ${a} !~ ${b}`);

test("income unit (default): each income divides by ITS OWN occurrence count", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "income");
  assert.equal(unit.active, true);
  approx(unit.income(KURT, 5400), 2700, "Kurt 5400/2 = 2700.00");
  approx(unit.income(SAMMI, 2800), 1400, "Sammi 2800/2 = 1400.00");
});

test("income unit: a bank funded by ONE payroll divides by that payroll's count", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "income");
  // Freedom Mortgage: funded 100% by Kurt (2 occurrences) -> 2547.12/2.
  approx(unit.bank(graph.banks[0]), 1273.56, "mortgage 2547.12/2 = 1273.56");
});

test("income unit: a bank funded 50/50 sums each funder's share / its count", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "income");
  // Pooled: Kurt 1000/2 + Sammi 1000/2 = 1000.00.
  approx(unit.bank(graph.banks[1]), 1000, "pooled 1000/2 + 1000/2 = 1000.00");
});

test("family unit: the exact legacy composite (divide by the family total)", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "family");
  assert.equal(unit.active, false);
  approx(unit.income(KURT, 5400), 1350, "Kurt 5400/4 = 1350.00");
  approx(unit.income(SAMMI, 2800), 700, "Sammi 2800/4 = 700.00");
  approx(unit.bank(graph.banks[0]), 636.78, "mortgage 2547.12/4 = 636.78");
  approx(unit.bank(graph.banks[1]), 500, "pooled 2000/4 = 500.00");
});

test("monthly view: identity regardless of the unit", () => {
  for (const unitName of ["income", "family"]) {
    const unit = paycheckUnitScales(graph, "monthly", unitName);
    assert.equal(unit.active, false);
    assert.equal(unit.income(KURT, 5400), 5400, `Kurt monthly (${unitName})`);
    assert.equal(unit.income(SAMMI, 2800), 2800, `Sammi monthly (${unitName})`);
    assert.equal(unit.bank(graph.banks[0]), 2547.12, `mortgage monthly (${unitName})`);
    assert.equal(unit.bank(graph.banks[1]), 2000, `pooled monthly (${unitName})`);
  }
});

test("allocations / shortfall / fan-out follow the source bank's per-paycheck ratio", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "income");
  // Mortgage: ratio = 1273.56 / 2547.12 = 0.5 -> got_month * 0.5.
  approx(unit.fromBank(MORTGAGE, 2547.12), 1273.56, "mortgage allocation 2547.12 * 0.5");
  approx(unit.fromBank(MORTGAGE, 100), 50, "mortgage shortfall 100 * 0.5");
  // Pooled: ratio = 1000 / 2000 = 0.5 as well (equal counts).
  approx(unit.fromBank(POOLED, 2000), 1000, "pooled allocation 2000 * 0.5");
  // Unassigned (null bankId): always the legacy family scale.
  approx(unit.fromBank(null, 2547.12), 636.78, "unassigned keeps the family scale");
});

test("surplus keeps the source bank's per-paycheck share of the inflow", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "income");
  approx(unit.surplus(POOLED, 50), 25, "pooled surplus 50 * (1000/2000)");
  approx(unit.surplus(MORTGAGE, 100), 50, "mortgage surplus 100 * 0.5");
});

test("a month where one income lands 3 times divides by 3 for that income only", () => {
  const g3 = {
    paycheck_dates: ["2026-08-07", "2026-08-14", "2026-08-21", "2026-08-28"],
    incomes: [
      { id: KURT, total_month: 2700, occurrences: [{ date: "2026-08-07" }] },
      { id: SAMMI, total_month: 2800, occurrences: [{ date: "2026-08-14" }, { date: "2026-08-21" }, { date: "2026-08-28" }] },
    ],
    banks: [],
  };
  const unit = paycheckUnitScales(g3, "paycheck", "income");
  approx(unit.income(KURT, 2700), 2700, "Kurt 2700/1");
  approx(unit.income(SAMMI, 2800), 2800 / 3, "Sammi 2800/3");
});

test("an income with zero occurrences divides by 1 (no Infinity)", () => {
  const g0 = {
    paycheck_dates: [],
    incomes: [{ id: KURT, total_month: 5400, occurrences: [] }],
    banks: [],
  };
  const counts = incomeOccurrenceCounts(g0);
  assert.equal(counts.get(KURT), 1);
  const unit = paycheckUnitScales(g0, "paycheck", "income");
  assert.equal(unit.income(KURT, 5400), 5400);
  // familyCount falls back to 1 -> the legacy scale is identity-safe too.
  const legacy = paycheckUnitScales(g0, "paycheck", "family");
  assert.equal(legacy.income(KURT, 5400), 5400);
});

test("family unit reproduces the legacy #scale byte for byte", () => {
  // The pre-R33 house scale: value / (paycheck_dates.length || 1) in the
  // paycheck view, identity otherwise.
  for (const view of ["paycheck", "monthly"]) {
    const unit = paycheckUnitScales(graph, view, "family");
    const count = view === "paycheck" ? graph.paycheck_dates.length : 1;
    for (const value of [5400, 2800, 2547.12, 2000, 0]) {
      assert.equal(unit.income(KURT, value), value / count, `${view} income ${value}`);
      assert.equal(unit.fromBank(MORTGAGE, value), value / count, `${view} fromBank ${value}`);
    }
  }
});

test("bankInflowInfo sums the dated inflow rows per bank", () => {
  const counts = incomeOccurrenceCounts(graph);
  const info = bankInflowInfo(graph.banks, counts);
  approx(info.get(MORTGAGE).total, 2547.12, "mortgage total");
  approx(info.get(MORTGAGE).perPaycheck, 1273.56, "mortgage per-paycheck");
  approx(info.get(POOLED).total, 2000, "pooled total");
  approx(info.get(POOLED).perPaycheck, 1000, "pooled per-paycheck");
});
