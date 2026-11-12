import { readFile } from "node:fs/promises"
import { describe, it } from "node:test"
import assert from "node:assert/strict"

// the allocation dialog's Bank source prefill broke on re-open
// after any in-place bank add/remove, because the swap re-checked the panel
// radio from the browser's natively-checked radio (the bank radios of EVERY
// allocation dialog share one name in one document, so only the last
// dialog's radio survives the radio-button-group constraint) and from a
// dialog-wide [value=...] query that matched the form's hidden carrier
// (empty dataset) instead of the panel's radio. The swap now reads each
// dialog's hidden carrier and re-checks the panel-scoped radio for the
// value bankRowsSwapValue picks: the carrier's value when the fresh
// fragment still offers it, else the unassigned row.
const CONTROLLER_URL = new URL(
  "../../app/javascript/controllers/plan_flow_controller.js",
  import.meta.url,
)
const stub = (code) => `data:text/javascript;base64,${Buffer.from(code).toString("base64")}`

const source = (await readFile(CONTROLLER_URL, "utf8")).replace(
  '"@hotwired/stimulus"',
  JSON.stringify(stub("export class Controller {}")),
)

const { default: PlanFlowController } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
)

describe("bankRowsSwapValue (round 37 bank-source prefill)", () => {
  const ON_PLAN = ["", "a1", "a2", "a3"]

  it("keeps the carrier's bank when the fresh fragment still offers it", () => {
    assert.equal(PlanFlowController.bankRowsSwapValue("a2", ON_PLAN), "a2")
  })

  it("keeps the unassigned row when the carrier is unassigned", () => {
    assert.equal(PlanFlowController.bankRowsSwapValue("", ON_PLAN), "")
  })

  it("falls back to unassigned when the bank left the plan", () => {
    assert.equal(PlanFlowController.bankRowsSwapValue("gone", ON_PLAN), "")
  })

  it("falls back to unassigned when the fragment offers nothing", () => {
    assert.equal(PlanFlowController.bankRowsSwapValue("a1", []), "")
  })

  it("never revives a bank the carrier no longer holds", () => {
    assert.equal(PlanFlowController.bankRowsSwapValue("", ["", "a1"]), "")
  })
})
