// Round 33 (spec 1): the Per-Paycheck unit scaling — PURE helpers the
// plan-flow Sankey controller composes. The /plan/flow/graph payload is
// untouched (the per-income occurrence counts are derivable client-side
// from graph.incomes[].occurrences), so the graph sha pin stays green.
//
// "income" unit (DEFAULT): every Per Paycheck figure divides the monthly
// amount by how many times THAT income lands in the month (its
// occurrences.length). A bank / obligation is the SUM over its funding
// incomes of (that income's resolved monthly inflow share / that income's
// occurrence count) — never the family total.
// "family" unit (legacy): every Per Paycheck figure divides by the month's
// TOTAL paycheck count (the house divisor — the old family composite).
// "monthly" view: identity — the unit only applies to the paycheck view.

// income id -> the month's occurrence count for that income (0 -> 1: a
// one-off income lands at most once; dividing by 0 would Infinity).
export function incomeOccurrenceCounts(graph) {
  const counts = new Map();
  (graph.incomes || []).forEach((income) => {
    const n = Array.isArray(income.occurrences) ? income.occurrences.length : 0;
    counts.set(income.id, n > 0 ? n : 1);
  });
  return counts;
}

// bank id -> { total, perPaycheck }: total = the resolved monthly inflow
// (the sum of the dated inflow rows), perPaycheck = the sum over the dated
// rows of (amount / that income's occurrence count) — the income unit's
// per-paycheck figure for the bank.
export function bankInflowInfo(banks, counts) {
  const info = new Map();
  (banks || []).forEach((bank) => {
    let total = 0;
    let perPaycheck = 0;
    (bank.inflow || []).forEach((row) => {
      const amount = Number(row.amount) || 0;
      total += amount;
      perPaycheck += amount / (counts.get(row.income_id) || 1);
    });
    info.set(bank.id, { total, perPaycheck });
  });
  return info;
}

// The scale closures for the active unit/view. When the income unit is NOT
// active (family unit, or the monthly view) every closure is the EXACT
// legacy house scale — the pre-Round-33 behavior, byte for byte.
export function paycheckUnitScales(graph, view, unit) {
  const counts = incomeOccurrenceCounts(graph);
  const info = bankInflowInfo(graph.banks, counts);
  const familyCount = (graph.paycheck_dates && graph.paycheck_dates.length) || 1;
  const active = view === "paycheck" && unit === "income";
  // The legacy house scale (the pre-R33 #scale): monthly -> per-paycheck
  // over the month's total paycheck count; identity in the monthly view.
  const legacy = (value) => (view === "paycheck" ? Number(value || 0) / familyCount : Number(value || 0));
  // The source bank's per-paycheck inflow ratio (perPaycheck / total) —
  // null when the bank has no inflow rows (the impossible case keeps the
  // legacy display instead of collapsing to 0).
  const bankRatio = (bankId) => {
    const row = bankId == null ? null : info.get(bankId);
    return row && row.total > 0 ? row.perPaycheck / row.total : null;
  };
  return {
    active,
    counts,
    info,
    // Monthly value -> the per-paycheck value for ONE income (income nodes,
    // Un-Allocated pillars, income -> bank bands, hatched ribbons): / that
    // income's occurrence count (income unit), legacy otherwise.
    income: (incomeId, value) => (active ? Number(value || 0) / (counts.get(incomeId) || 1) : legacy(value)),
    // Bank node value from the payload row (the row's monthly inflow): the
    // per-paycheck inflow (income unit), legacy = the row's monthly inflow
    // over the family count.
    bank: (bankRow) => {
      if (!active) return legacy(Math.max(Number(bankRow.inflow_month), 0));
      const row = info.get(bankRow.id);
      return row ? Math.max(row.perPaycheck, 0) : 0;
    },
    // Bank surplus: the per-paycheck share of the inflow (the source bank's
    // ratio), legacy otherwise.
    surplus: (bankId, value) => {
      const ratio = active ? bankRatio(bankId) : null;
      return ratio == null ? legacy(value) : Math.max(Number(value || 0), 0) * ratio;
    },
    // Allocation / shortfall / fan-out figures settled FROM a bank: the
    // monthly figure x the source bank's per-paycheck inflow ratio (income
    // unit), legacy otherwise (null bankId = unassigned rows, always
    // legacy — they have no source bank).
    fromBank: (bankId, value) => {
      const ratio = active ? bankRatio(bankId) : null;
      return ratio == null ? legacy(value) : Number(value || 0) * ratio;
    },
  };
}
