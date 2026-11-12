import assert from "node:assert/strict";
import { test } from "node:test";
import {
  incomeOccurrenceCounts,
  bankInflowInfo,
  paycheckUnitScales,
} from "../../../app/javascript/utils/plan_flow_sankey_unit.mjs";

// the Per-Paycheck unit — per income occurrence count
// (DEFAULT) vs the old family composite. The fixture below is SYNTHETIC
// sample data: primary payroll (2 occurrences, $5400.00/month) + secondary
// payroll (2 occurrences, $2800.00/month); the mortgage bank funded by ONE
// payroll (primary, $2500.00/month); a second bank funded 50/50 by both.

const PRIMARY = "primary";
const SECONDARY = "secondary";
const MORTGAGE = "mortgage";
const POOLED = "pooled";

const graph = {
  paycheck_dates: ["2026-02-02", "2026-02-09", "2026-02-16", "2026-02-23"],
  incomes: [
    { id: PRIMARY, total_month: 5400, occurrences: [{ date: "2026-02-02" }, { date: "2026-02-16" }] },
    { id: SECONDARY, total_month: 2800, occurrences: [{ date: "2026-02-09" }, { date: "2026-02-23" }] },
  ],
  banks: [
    {
      id: MORTGAGE,
      inflow_month: "2500.00",
      surplus_month: "0.00",
      inflow: [
        { income_id: PRIMARY, date: "2026-02-02", amount: "1250.00" },
        { income_id: PRIMARY, date: "2026-02-16", amount: "1250.00" },
      ],
    },
    {
      id: POOLED,
      inflow_month: "2000.00",
      surplus_month: "50.00",
      inflow: [
        { income_id: PRIMARY, date: "2026-02-02", amount: "1000.00" },
        { income_id: SECONDARY, date: "2026-02-09", amount: "1000.00" },
      ],
    },
  ],
};

const approx = (a, b, msg) => assert.ok(Math.abs(a - b) < 0.005, `${msg}: ${a} !~ ${b}`);

test("income unit (default): each income divides by ITS OWN occurrence count", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "income");
  assert.equal(unit.active, true);
  approx(unit.income(PRIMARY, 5400), 2700, "primary 5400/2 = 2700.00");
  approx(unit.income(SECONDARY, 2800), 1400, "secondary 2800/2 = 1400.00");
});

test("income unit: a bank funded by ONE payroll divides by that payroll's count", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "income");
  // Acme Mortgage: funded 100% by primary (2 occurrences) -> 2500.00/2.
  approx(unit.bank(graph.banks[0]), 1250.00, "mortgage 2500.00/2 = 1250.00");
});

test("income unit: a bank funded 50/50 sums each funder's share / its count", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "income");
  // Pooled: primary 1000/2 + secondary 1000/2 = 1000.00.
  approx(unit.bank(graph.banks[1]), 1000, "pooled 1000/2 + 1000/2 = 1000.00");
});

test("family unit: the exact legacy composite (divide by the family total)", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "family");
  assert.equal(unit.active, false);
  approx(unit.income(PRIMARY, 5400), 1350, "primary 5400/4 = 1350.00");
  approx(unit.income(SECONDARY, 2800), 700, "secondary 2800/4 = 700.00");
  approx(unit.bank(graph.banks[0]), 625.00, "mortgage 2500.00/4 = 625.00");
  approx(unit.bank(graph.banks[1]), 500, "pooled 2000/4 = 500.00");
});

test("monthly view: identity regardless of the unit", () => {
  for (const unitName of ["income", "family"]) {
    const unit = paycheckUnitScales(graph, "monthly", unitName);
    assert.equal(unit.active, false);
    assert.equal(unit.income(PRIMARY, 5400), 5400, `primary monthly (${unitName})`);
    assert.equal(unit.income(SECONDARY, 2800), 2800, `secondary monthly (${unitName})`);
    assert.equal(unit.bank(graph.banks[0]), 2500, `mortgage monthly (${unitName})`);
    assert.equal(unit.bank(graph.banks[1]), 2000, `pooled monthly (${unitName})`);
  }
});

test("allocations / shortfall / fan-out follow the source bank's per-paycheck ratio", () => {
  const unit = paycheckUnitScales(graph, "paycheck", "income");
  // Mortgage: ratio = 1250.00 / 2500.00 = 0.5 -> got_month * 0.5.
  approx(unit.fromBank(MORTGAGE, 2500), 1250.00, "mortgage allocation 2500.00 * 0.5");
  approx(unit.fromBank(MORTGAGE, 100), 50, "mortgage shortfall 100 * 0.5");
  // Pooled: ratio = 1000 / 2000 = 0.5 as well (equal counts).
  approx(unit.fromBank(POOLED, 2000), 1000, "pooled allocation 2000 * 0.5");
  // Unassigned (null bankId): always the legacy family scale.
  approx(unit.fromBank(null, 2500), 625.00, "unassigned keeps the family scale");
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
      { id: PRIMARY, total_month: 2700, occurrences: [{ date: "2026-08-07" }] },
      { id: SECONDARY, total_month: 2800, occurrences: [{ date: "2026-08-14" }, { date: "2026-08-21" }, { date: "2026-08-28" }] },
    ],
    banks: [],
  };
  const unit = paycheckUnitScales(g3, "paycheck", "income");
  approx(unit.income(PRIMARY, 2700), 2700, "primary 2700/1");
  approx(unit.income(SECONDARY, 2800), 2800 / 3, "secondary 2800/3");
});

test("an income with zero occurrences divides by 1 (no Infinity)", () => {
  const g0 = {
    paycheck_dates: [],
    incomes: [{ id: PRIMARY, total_month: 5400, occurrences: [] }],
    banks: [],
  };
  const counts = incomeOccurrenceCounts(g0);
  assert.equal(counts.get(PRIMARY), 1);
  const unit = paycheckUnitScales(g0, "paycheck", "income");
  assert.equal(unit.income(PRIMARY, 5400), 5400);
  // familyCount falls back to 1 -> the legacy scale is identity-safe too.
  const legacy = paycheckUnitScales(g0, "paycheck", "family");
  assert.equal(legacy.income(PRIMARY, 5400), 5400);
});

test("family unit reproduces the legacy #scale byte for byte", () => {
  // The legacy house scale: value / (paycheck_dates.length || 1) in the
  // paycheck view, identity otherwise.
  for (const view of ["paycheck", "monthly"]) {
    const unit = paycheckUnitScales(graph, view, "family");
    const count = view === "paycheck" ? graph.paycheck_dates.length : 1;
    for (const value of [5400, 2800, 2500, 2000, 0]) {
      assert.equal(unit.income(PRIMARY, value), value / count, `${view} income ${value}`);
      assert.equal(unit.fromBank(MORTGAGE, value), value / count, `${view} fromBank ${value}`);
    }
  }
});

test("bankInflowInfo sums the dated inflow rows per bank", () => {
  const counts = incomeOccurrenceCounts(graph);
  const info = bankInflowInfo(graph.banks, counts);
  approx(info.get(MORTGAGE).total, 2500, "mortgage total");
  approx(info.get(MORTGAGE).perPaycheck, 1250.00, "mortgage per-paycheck");
  approx(info.get(POOLED).total, 2000, "pooled total");
  approx(info.get(POOLED).perPaycheck, 1000, "pooled per-paycheck");
});
