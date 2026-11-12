import { readFile } from "node:fs/promises"
import { describe, it } from "node:test"
import assert from "node:assert/strict"

// Round 34b (T1/T2): the leftover-icon slot geometry + the 4-variant glyph
// set are STATIC + DOM-free on the sankey controller, so the test runs the
// shipped code (not a copy): the controller source is read, its importmap
// bare specifiers are rewritten to stubs (stimulus/d3/d3-sankey) and file
// URLs (the pure utils modules the controller imports), and it is imported
// as a data URL — the house pattern from parse_amount_paste_test.mjs.
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

// leftoverIconPlacement is a STATIC method that reads this.LEFTOVER_ICON_*
// constants, so it must run with `this` = the controller class. In the app it
// is always called as `this.constructor.leftoverIconPlacement(...)`; here we
// wrap it the same way (a bare call would leave `this` undefined in strict
// mode). The glyph map + slot size are plain data, destructure directly.
const leftoverIconPlacement = (args) => PlanFlowSankeyController.leftoverIconPlacement(args)
const { LEFTOVER_ICON_GLYPHS, LEFTOVER_ICON_SIZE } = PlanFlowSankeyController

describe("leftoverIconPlacement (round 34b T1)", () => {
  it("anchor=end, narrow text->band gap (<18px): icon LEFT of the name text with exactly 4px clearance, centered on the band center", () => {
    // Live case: right-anchored bank label, text run ends 8px (LABEL_GUTTER)
    // left of the band edge -> gap 8 < 18 -> fallback slot.
    const slot = leftoverIconPlacement({
      anchor: "end",
      labelBox: { x: 700, width: 200 }, // textRight = 900
      bandX0: 908, // gapToBand = 8
      bandX1: 923,
      boxSize: 14,
      centerY: 100,
    })
    assert.equal(slot.y, 93) // 100 - 14/2
    assert.equal(slot.x, 682) // 700 - 4 - 14
    // exactly 4px clearance to the label text, no intersection:
    assert.equal(700 - (slot.x + 14), 4)
  })

  it("anchor=end, gap >= 18px: icon centered in the text->band gap (preferred slot)", () => {
    const slot = leftoverIconPlacement({
      anchor: "end",
      labelBox: { x: 700, width: 150 }, // textRight = 850
      bandX0: 880, // gapToBand = 30
      bandX1: 895,
      boxSize: 14,
      centerY: 100,
    })
    assert.equal(slot.x, 858) // 850 + (30 - 14)/2
    assert.equal(slot.y, 93)
    // equal clearance to text end and band edge:
    assert.equal(slot.x - 850, 880 - (slot.x + 14))
  })

  it("anchor=end, gap exactly 18px takes the preferred slot (>= boundary)", () => {
    const slot = leftoverIconPlacement({
      anchor: "end",
      labelBox: { x: 700, width: 162 }, // textRight = 862
      bandX0: 880, // gapToBand = 18
      bandX1: 895,
      boxSize: 14,
      centerY: 40,
    })
    assert.equal(slot.x, 864) // 862 + (18 - 14)/2
  })

  it("anchor=end, gap just under 18px falls back to the left-of-text slot", () => {
    const slot = leftoverIconPlacement({
      anchor: "end",
      labelBox: { x: 700, width: 162.1 }, // textRight = 862.1
      bandX0: 880, // gapToBand = 17.9
      bandX1: 895,
      boxSize: 14,
      centerY: 40,
    })
    assert.equal(slot.x, 700 - 4 - 14)
  })

  it("anchor=start (label right of the band) mirrors the rule: narrow gap -> RIGHT of the text end; wide gap -> centered between band edge and text start", () => {
    const narrow = leftoverIconPlacement({
      anchor: "start",
      labelBox: { x: 1000, width: 200 }, // textLeft 1000, textRight 1200
      bandX0: 977,
      bandX1: 992, // gapToBand = 8
      boxSize: 14,
      centerY: 100,
    })
    assert.equal(narrow.x, 1204) // 1200 + 4
    assert.equal(narrow.y, 93)

    const wide = leftoverIconPlacement({
      anchor: "start",
      labelBox: { x: 1010, width: 200 },
      bandX0: 970,
      bandX1: 990, // gapToBand = 20
      boxSize: 14,
      centerY: 100,
    })
    assert.equal(wide.x, 1007) // 1010 - (20 - 14)/2
  })

  it("slot size scales: boxSize 7 (k=0.5) halves the footprint and the y offset", () => {
    const slot = leftoverIconPlacement({
      anchor: "end",
      labelBox: { x: 700, width: 200 },
      bandX0: 908,
      bandX1: 923,
      boxSize: 7,
      centerY: 100,
    })
    assert.equal(slot.x, 700 - 4 - 7)
    assert.equal(slot.y, 96.5) // 100 - 7/2
  })
})

describe("leftover icon variant set (round 34b T2)", () => {
  it("exposes exactly the four owner-facing variants, 14px slot", () => {
    assert.deepEqual(Object.keys(LEFTOVER_ICON_GLYPHS).sort(), ["bracket", "loop", "tail", "wave"])
    assert.equal(LEFTOVER_ICON_SIZE, 14)
  })

  it("defaults to 'wave' (the round-34c owner pick) and resolves it to the wave glyph", () => {
    assert.equal(PlanFlowSankeyController.LEFTOVER_ICON_VARIANT, "wave")
    assert.equal(
      PlanFlowSankeyController.LEFTOVER_ICON,
      '<path d="M1 7C2 4.5 3 4.5 4.5 7C6 9.5 7 9.5 8.5 7C10 4.5 11 4.5 13 7"></path>',
    )
  })

  it("switching LEFTOVER_ICON_VARIANT is a one-line change (getter follows the constant)", () => {
    const original = PlanFlowSankeyController.LEFTOVER_ICON_VARIANT
    try {
      for (const variant of ["wave", "bracket", "loop", "tail"]) {
        PlanFlowSankeyController.LEFTOVER_ICON_VARIANT = variant
        assert.equal(PlanFlowSankeyController.LEFTOVER_ICON, LEFTOVER_ICON_GLYPHS[variant])
      }
    } finally {
      PlanFlowSankeyController.LEFTOVER_ICON_VARIANT = original
    }
  })

  it("an unknown variant falls back to 'tail' (a typo never blanks the icon)", () => {
    const original = PlanFlowSankeyController.LEFTOVER_ICON_VARIANT
    try {
      PlanFlowSankeyController.LEFTOVER_ICON_VARIANT = "nope"
      assert.equal(PlanFlowSankeyController.LEFTOVER_ICON, LEFTOVER_ICON_GLYPHS.tail)
    } finally {
      PlanFlowSankeyController.LEFTOVER_ICON_VARIANT = original
    }
  })

  it("all glyphs are stroke-only (no fill attribute in the inner markup) and non-empty", () => {
    for (const [name, markup] of Object.entries(LEFTOVER_ICON_GLYPHS)) {
      assert.ok(markup.length > 0, `${name} is non-empty`)
      assert.ok(!markup.includes("fill="), `${name} carries no fill attribute`)
    }
  })
})

// Round 34c (owner): the default variant is now "wave", and the FALLBACK
// slot clearance is a per-node measured value (the name<->dollar-amount gap
// of the single-line label run) instead of the fixed 4px default.
describe("leftoverIconPlacement (round 34c)", () => {
  it("the default variant is 'wave' and the getter follows it", () => {
    assert.equal(PlanFlowSankeyController.LEFTOVER_ICON_VARIANT, "wave")
    assert.equal(PlanFlowSankeyController.LEFTOVER_ICON, LEFTOVER_ICON_GLYPHS.wave)
  })

  it("anchor=end fallback: a custom clearance replaces the 4px default (icon right edge = clearance from the name)", () => {
    const slot = leftoverIconPlacement({
      anchor: "end",
      labelBox: { x: 700, width: 200 }, // textRight = 900
      bandX0: 908, // gapToBand = 8 < 18 -> fallback
      bandX1: 923,
      boxSize: 14,
      centerY: 100,
      clearance: 6.2, // e.g. the measured name<->amount space width
    })
    assert.ok(Math.abs(700 - (slot.x + 14) - 6.2) < 1e-9)
    assert.equal(slot.y, 93)
  })

  it("anchor=start fallback: a custom clearance replaces the 4px default", () => {
    const slot = leftoverIconPlacement({
      anchor: "start",
      labelBox: { x: 920, width: 200 }, // textLeft = 920
      bandX0: 905,
      bandX1: 913, // gapToBand = 7 < 18 -> fallback
      boxSize: 14,
      centerY: 50,
      clearance: 5.5,
    })
    assert.ok(Math.abs(slot.x - (920 + 200) - 5.5) < 1e-9)
    assert.equal(slot.y, 43)
  })

  it("absent/null clearance keeps the 4px default (byte-identical to round 34b)", () => {
    for (const clearance of [undefined, null]) {
      const slot = leftoverIconPlacement({
        anchor: "end",
        labelBox: { x: 700, width: 200 },
        bandX0: 908,
        bandX1: 923,
        boxSize: 14,
        centerY: 100,
        clearance,
      })
      assert.equal(700 - (slot.x + 14), 4)
    }
  })

  it("anchor=end: a MEASURED clearance bypasses the centered slot — icon hugs the text end at exactly that gap (round-34c owner: 'same gap as name->amount')", () => {
    // Live bank-label geometry: wide text->band gap (30px). Round 34b would
    // have centered the icon (x = 908); the measured clearance wins instead.
    const slot = leftoverIconPlacement({
      anchor: "end",
      labelBox: { x: 700, width: 200 }, // textRight = 900
      bandX0: 930, // gapToBand = 30 >= 18 (would be the centered slot)
      bandX1: 945,
      boxSize: 14,
      centerY: 100,
      clearance: 6.2,
    })
    assert.ok(Math.abs(slot.x - (900 + 6.2)) < 1e-9)
    assert.equal(slot.y, 93)
  })

  it("anchor=start: a measured clearance mirrors — icon hugs the text start from the left", () => {
    const slot = leftoverIconPlacement({
      anchor: "start",
      labelBox: { x: 1010, width: 200 }, // textLeft = 1010
      bandX0: 970,
      bandX1: 990, // gapToBand = 20 >= 18 (would be the centered slot)
      boxSize: 14,
      centerY: 100,
      clearance: 5.5,
    })
    assert.ok(Math.abs(slot.x - (1010 - 5.5 - 14)) < 1e-9)
    assert.equal(slot.y, 93)
  })

  it("a measured clearance never overflows the gap: icon that would touch the band falls back to the round-34 slot", () => {
    // gap 30px but the clearance (20px) + icon (14px) exceed it -> the
    // centered slot (round-34b behavior) applies instead.
    const slot = leftoverIconPlacement({
      anchor: "end",
      labelBox: { x: 700, width: 200 }, // textRight = 900
      bandX0: 930,
      bandX1: 945,
      boxSize: 14,
      centerY: 100,
      clearance: 20, // hugX + boxSize = 934 > 930 -> no fit
    })
    assert.equal(slot.x, 900 + (30 - 14) / 2)
  })
})
