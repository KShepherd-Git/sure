import { readFile } from "node:fs/promises"
import { describe, it } from "node:test"
import assert from "node:assert/strict"

// the three new shortage statics on the sankey
// controller are STATIC + DOM-free, so the test runs the shipped code (not a
// copy): the controller source is read, its importmap bare specifiers are
// rewritten to stubs (stimulus/d3/d3-sankey) and file URLs (the pure utils
// modules), and it is imported as a data URL — the house pattern from
// plan_flow_leftover_icon_test.mjs.
const CONTROLLER_URL = new URL(
  "../../app/javascript/controllers/plan_flow_sankey_controller.js",
  import.meta.url,
)
const stub = (code) => `data:text/javascript;base64,${Buffer.from(code).toString("base64")}`

const source = (await readFile(CONTROLLER_URL, "utf8"))
  .replace('"@hotwired/stimulus"', JSON.stringify(stub("export class Controller {}")))
  .replace('"d3"', JSON.stringify(stub("export const select = () => { throw new Error('d3 stub') }")))
  .replace('"d3-sankey"', JSON.stringify(stub("export const sankey = () => { throw new Error('d3-sankey stub') }")))
  .replace('"utils/cash_flow_chart_data"', JSON.stringify(new URL("../../app/javascript/utils/cash_flow_chart_data.mjs", import.meta.url).href))
  .replace('"utils/chart_tooltip"', JSON.stringify(new URL("../../app/javascript/utils/chart_tooltip.js", import.meta.url).href))
  .replace('"utils/sankey_labels"', JSON.stringify(new URL("../../app/javascript/utils/sankey_labels.mjs", import.meta.url).href))
  .replace('"utils/plan_flow_sankey_layout"', JSON.stringify(new URL("../../app/javascript/utils/plan_flow_sankey_layout.mjs", import.meta.url).href))
  .replace('"utils/plan_flow_sankey_unit"', JSON.stringify(new URL("../../app/javascript/utils/plan_flow_sankey_unit.mjs", import.meta.url).href))
  .replace('"utils/replace_url"', JSON.stringify(new URL("../../app/javascript/utils/replace_url.js", import.meta.url).href))

const { default: PlanFlowSankeyController } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
)
// The pure unit util (no DOM/stimulus dependency) — imported directly for
// the unit-invariance tests.
const { paycheckUnitScales } = await import(
  new URL("../../app/javascript/utils/plan_flow_sankey_unit.mjs", import.meta.url)
)

const overHatchPath = (args) => PlanFlowSankeyController.overHatchPath(args)
const labelShortHatchBox = (box, k) => PlanFlowSankeyController.labelShortHatchBox(box, k)
const shortageGhostLinks = (args) => PlanFlowSankeyController.shortageGhostLinks(args)

describe("overHatchPath (round 36 §4.1: the income over-allocation ghost)", () => {
  it("hangs the ghost rect BELOW the bar's bottom edge, height = excess * live s", () => {
    // Live demo shape: the income bar draws 2700.00 (the earned figure) at
    // y0..y1; the 1010.665/month excess scales with the SAME px-per-dollar
    // as the bar (s = 200px / 2700.00).
    const d = overHatchPath({
      x0: 100, barWidth: 14, y0: 50, y1: 250,
      excess: 1010.665, displayValue: 2700,
    })
    // s = 200/2700; h = 1010.665 * (200/2700) = 74.864074... -> 74.864
    assert.equal(d, "M100.000,250.000 L114.000,250.000 L114.000,324.864 L100.000,324.864 Z")
    // The rect starts exactly at the bar's bottom edge (y1) and grows DOWN.
    const m = d.match(/M([\d.]+),([\d.]+) L([\d.]+),([\d.]+) L([\d.]+),([\d.]+) L([\d.]+),([\d.]+) Z/)
    assert.equal(Number(m[2]), 250) // top edge = bar bottom
    assert.equal(Number(m[6]), 324.864) // bottom edge = y1 + E*s
    assert.ok(Number(m[6]) > Number(m[2]), "the ghost extends below the bar")
  })

  it("returns null for a not-over-planned income (excess <= 0.005) — no ghost", () => {
    assert.equal(overHatchPath({ x0: 0, barWidth: 14, y0: 0, y1: 100, excess: 0, displayValue: 1000 }), null)
    assert.equal(overHatchPath({ x0: 0, barWidth: 14, y0: 0, y1: 100, excess: 0.004, displayValue: 1000 }), null)
    assert.equal(overHatchPath({ x0: 0, barWidth: 14, y0: 0, y1: 100, displayValue: 1000 }), null)
    // exactly the gate boundary is NOT a ghost (strictly > 0.005):
    assert.equal(overHatchPath({ x0: 0, barWidth: 14, y0: 0, y1: 100, excess: 0.005, displayValue: 1000 }), null)
    assert.notEqual(overHatchPath({ x0: 0, barWidth: 14, y0: 0, y1: 100, excess: 0.006, displayValue: 1000 }), null)
  })

  it("returns null when the bar has no displayValue (the scale would NaN)", () => {
    assert.equal(overHatchPath({ x0: 0, barWidth: 14, y0: 0, y1: 100, excess: 500, displayValue: 0 }), null)
    assert.equal(overHatchPath({ x0: 0, barWidth: 14, y0: 0, y1: 100, excess: 500 }), null)
  })
})

describe("labelShortHatchBox (round 36 §4.3: the short-label hatch rect)", () => {
  it("grows the label box by the 4px padding at k=1", () => {
    assert.deepEqual(labelShortHatchBox({ x: 100, y: 20, w: 150, h: 16 }, 1), {
      x: 96, y: 16, width: 158, height: 24,
    })
  })

  it("scales the padding with the label scale k (compact labels, k<1)", () => {
    assert.deepEqual(labelShortHatchBox({ x: 100, y: 20, w: 150, h: 16 }, 0.6), {
      x: 97.6, y: 17.6, width: 154.8, height: 20.8,
    })
  })

  it("falls back to k=1 when k is missing or 0", () => {
    assert.deepEqual(labelShortHatchBox({ x: 10, y: 10, w: 50, h: 12 }), {
      x: 6, y: 6, width: 58, height: 20,
    })
    assert.deepEqual(labelShortHatchBox({ x: 10, y: 10, w: 50, h: 12 }, 0), {
      x: 6, y: 6, width: 58, height: 20,
    })
  })
})

describe("shortageGhostLinks (round 36 §4.4: the defunded ghost ribbons)", () => {
  it("builds the income->bank and bank->allocation datums for one short allocation", () => {
    // The demo's Emergency Fund row: 885.66/paycheck short (the SAME
    // per-paycheck figure the label suffix shows — ghost and suffix agree).
    const ghosts = shortageGhostLinks({
      incomeId: "c7297d4f", bankId: "8333579d", allocationId: "8413da7f",
      allocationNode: "allocation:8413da7f", shortfall: 885.66,
    })
    assert.equal(ghosts.length, 2)
    const [toBank, toAlloc] = ghosts
    assert.equal(toBank.source, "income:c7297d4f")
    assert.equal(toBank.target, "bank:8333579d")
    assert.equal(toAlloc.source, "bank:8333579d")
    assert.equal(toAlloc.target, "allocation:8413da7f")
    for (const g of ghosts) {
      assert.equal(g.value, 885.66) // per-paycheck shortfall, both ribbons
      assert.equal(g.hatched, true)
      assert.equal(g.redHatch, true)
      assert.equal(g.ghost, "shortage")
    }
    assert.equal(toBank.ghostKind, "income")
    assert.equal(toAlloc.ghostKind, "allocation")
    // Stable keys (the d3 join identity across in-place re-draws):
    assert.equal(toBank.ghostKey, "ghost-income:c7297d4f:8333579d:8413da7f")
    assert.equal(toAlloc.ghostKey, "ghost-bank:8333579d:8413da7f")
  })

  it("returns null for a not-short allocation — the link array is untouched", () => {
    assert.equal(shortageGhostLinks({ incomeId: "i", bankId: "b", allocationId: "a", allocationNode: "allocation:a", shortfall: 0 }), null)
    assert.equal(shortageGhostLinks({ incomeId: "i", bankId: "b", allocationId: "a", allocationNode: "allocation:a", shortfall: 0.005 }), null) // strict gate
    assert.equal(shortageGhostLinks({ incomeId: "i", bankId: "b", allocationId: "a", allocationNode: "allocation:a" }), null)
  })
})

describe("hatchPatternId (round 36 §4.4: the crosshatch pattern ids)", () => {
  const hatchPatternId = (chartId, red) => PlanFlowSankeyController.hatchPatternId(chartId, red)

  it("derives the grey and red ids from the chart id — #ensureSvg uses the same static", () => {
    assert.equal(hatchPatternId("planflow-abc", false), "planflow-planflow-abc-hatch")
    assert.equal(hatchPatternId("planflow-abc", true), "planflow-planflow-abc-hatch-red")
    assert.equal(hatchPatternId("chart1", true), "planflow-chart1-hatch-red")
    // red and grey differ ONLY by the -red suffix (same pattern geometry).
    assert.equal(hatchPatternId("c", true), hatchPatternId("c", false).replace("hatch", "hatch-red"))
  })
})

describe("unit invariance (round 36 §4.1: the ghost scale follows the view unit)", () => {
  // The income-ghost height is `excess * s` where s comes from the bar's
  // DISPLAY value — so the ghost must use the same scale closures as the
  // bar itself. The closures live in the pure unit util (imported at the
  // module top — it has no DOM/stimulus dependency).
  // Demo shape: the primary income lands twice; the month carries three pay
  // dates (two primary + one secondary) so the family divisor (3) differs
  // from the primary's own occurrence count (2).
  const graph = {
    incomes: [{ id: "i1", occurrences: ["2026-11-06", "2026-11-20"] }],
    banks: [{ id: "b1", inflow: [
      { income_id: "i1", amount: "100.00" },
      { income_id: "i1", amount: "100.00" },
    ] }],
    paycheck_dates: ["2026-11-06", "2026-11-13", "2026-11-20"],
  }

  it("the monthly view is the identity — the ghost draws the FULL monthly excess", () => {
    const s = paycheckUnitScales(graph, "monthly", "income")
    assert.equal(s.active, false)
    assert.equal(s.income("i1", 2000), 2000) // bar value: identity
    assert.equal(s.fromBank("b1", 200), 200) // shortfall figure: identity
  })

  it("the paycheck view scales the ghost with the SAME closure as the bar", () => {
    const s = paycheckUnitScales(graph, "paycheck", "income")
    assert.equal(s.active, true)
    // The income's bar: 2000.00/month over 2 OWN occurrences = 1000.00 (NOT the
    // family divisor 3 — 666.67 would desync the ghost from the bar).
    assert.equal(s.income("i1", 2000), 1000)
    // The bank's per-paycheck inflow ratio: perPaycheck 100.00 / total 200.00.
    assert.equal(s.fromBank("b1", 200), 100)
  })

  it("the family unit (legacy) divides by the month's total paycheck count", () => {
    const s = paycheckUnitScales(graph, "paycheck", "family")
    assert.equal(s.active, false)
    assert.equal(s.income("i1", 2000), 2000 / 3)
  })
})

// (top bar + labels to the cent): money2 reproduces the server's
// Ruby format("%.2f") — 15-significant-digit view, half-even on the digit
// string — so the .xx5 demo doubles print the SAME figure in the chart
// labels as in the top bar. Every expectation below was verified side by
// side with Ruby in the dev container (format("%.2f", <same double>)).
describe("money2 / moneyCash (round 36: server format(\"%.2f\") parity)", () => {
  const money2 = (v) => PlanFlowSankeyController.money2(v)
  const moneyCash = (v, c) => PlanFlowSankeyController.moneyCash(v, c)

  it("the demo .xx5 doubles print the server's figures", () => {
    // 2021.33/2 -> 1010.66 (true binary 1010.66499999999996; ICU would
    // round its 15-sig view up to 1010.67)
    assert.equal(money2(2021.33 / 2), 1010.66)
    // 1771.33/2 -> 885.66 (Emergency Fund per occurrence)
    assert.equal(money2(1771.33 / 2), 885.66)
    // 521.33/2 -> 260.66 (ffecfa07 short per occurrence; the double is
    // 260.66500000000002 — ABOVE the tie — but the 15-sig view is the tie)
    assert.equal(money2(521.33 / 2), 260.66)
    // 1021.33/2 -> 510.66, 3421.33/2 -> 1710.66, 111.33/2 -> 55.66
    assert.equal(money2(1021.33 / 2), 510.66)
    assert.equal(money2(3421.33 / 2), 1710.66)
    assert.equal(money2(111.33 / 2), 55.66)
  })

  it("exact 3-decimal ties round half-even on the hundredths digit", () => {
    // Ruby-verified: 1.125 -> 1.12 (even 2 kept), 0.125 -> 0.12 (even),
    // 1.135 -> 1.14 (odd 3 bumped), 1010.675 -> 1010.68 (odd 7 bumped).
    assert.equal(money2(1.125), 1.12)
    assert.equal(money2(0.125), 0.12)
    assert.equal(money2(1.135), 1.14)
    assert.equal(money2(1010.675), 1010.68)
  })

  it("non-tie and exact values round like ordinary 2-decimal display", () => {
    assert.equal(money2(885.6649), 885.66)
    assert.equal(money2(885.67), 885.67)
    assert.equal(money2(885.666), 885.67)
    assert.equal(money2(1828.16), 1828.16)
    assert.equal(money2(1075), 1075)
    assert.equal(money2(0), 0)
    assert.equal(money2(-1010.665), -1010.66)
  })

  it("moneyCash formats the server-parity number as currency", () => {
    assert.equal(moneyCash(2021.33 / 2, "USD"), "$1,010.66")
    assert.equal(moneyCash(1771.33 / 2, "USD"), "$885.66")
    assert.equal(moneyCash(1075, "USD"), "$1,075.00")
    assert.equal(moneyCash(0.125, "USD"), "$0.12")
  })
})
