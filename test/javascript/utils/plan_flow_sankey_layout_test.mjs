import assert from "node:assert/strict";
import { test } from "node:test";
import { restackManageRows } from "../../../app/javascript/utils/plan_flow_sankey_layout.mjs";

// regression surface: the manage-mode row re-stack must keep every node
// label vertically centered on its band (the drawn rect) — the
// "drift" screenshot showed the middle bank-column labels up to ~185px below
// their bands because a legacy label tiling pass placed labels at their own
// pitch while the bands sat at the row-gap pitch. The invariant:
//   expected label-center == band-center, for every row, at every scale.

const ROW_GAP = 8;
const HEADER_SPACE = 44;
const opts = { rowGap: ROW_GAP, headerSpace: HEADER_SPACE };

// One column of manage-mode rows, top to bottom. y0/y1 are the d3 layout
// rect; _fy0/_fy1 (when given) are the label-floor drawn rect set by
// #applyManageFloors — taller than the layout rect for small rows.
const column = (rows) =>
  rows.map(([y0, y1, fy0, fy1], i) => {
    const n = { index: i, y0, y1 };
    if (fy0 != null) n._fy0 = fy0;
    if (fy1 != null) n._fy1 = fy1;
    return n;
  });

// The band (drawn rect) center — the flows attach here.
const bandCenter = (n) => (n._fy0 + n._fy1) / 2;
// The label center: #applyGeometry sets d._y0 = d._fy0 ?? d.y0 and
// #setLabelGeoms draws the label at (d._y0 + d._y1) / 2, so after the
// restack the label center is (_fy0 + _fy1) / 2 of the same row.
const labelCenter = (n) => (n._fy0 + n._fy1) / 2;

test("every label is centered on its own band (expected label-center == band-center)", () => {
  // Mixed column: two big rows, then small rows with label floors taller
  // than their d3 layout rect (the live plan shape: big banks, then a stack
  // of small checking/savings rows).
  const rows = column([
    [10, 200, 10, 200], // big row, no floor
    [212, 300, 212, 300], // big row, no floor
    [312, 322, 307, 327], // small row, label floor (20px) vs layout (10px)
    [334, 344, 329, 349],
    [356, 361, 353, 367],
  ]);
  restackManageRows(rows, opts);
  rows.forEach((n) => {
    assert.equal(labelCenter(n), bandCenter(n), `row ${n.index}: label must sit at the band center`);
    assert.equal(bandCenter(n), n._fy0 + (n._fy1 - n._fy0) / 2, `row ${n.index}: band center is its own drawn mid`);
  });
});

test("label pitch equals band pitch down the whole column (no accumulated drift)", () => {
  // The legacy drift: labels marched at their own (~30px) pitch while the
  // bands sat at the row-gap pitch (~22px) — the offset grew down the
  // column (+39.5 ... +185px in the screenshot). The restack must
  // keep the two pitches identical, so the offset cannot accumulate.
  const rows = column([
    [10, 100, 10, 100],
    [110, 190, 110, 190],
    [200, 210, 195, 215],
    [220, 230, 215, 235],
    [240, 245, 237, 251],
    [255, 260, 252, 266],
  ]);
  restackManageRows(rows, opts);
  for (let i = 0; i < rows.length - 1; i += 1) {
    const a = rows[i];
    const b = rows[i + 1];
    assert.equal(labelCenter(b) - labelCenter(a), bandCenter(b) - bandCenter(a));
    // and the band pitch is exactly ROW_GAP plus half of each row's drawn
    // height — no other term, so no drift can accumulate between rows.
    assert.equal(
      bandCenter(b) - bandCenter(a),
      ROW_GAP + ((a._fy1 - a._fy0) + (b._fy1 - b._fy0)) / 2,
    );
  }
});

test("the gap between adjacent drawn rows is exactly ROW_GAP, first row at HEADER_SPACE", () => {
  const rows = column([
    [0, 50, 0, 60],
    [60, 110, 58, 112],
    [120, 130, 117, 133],
  ]);
  const span = restackManageRows(rows, opts);
  assert.equal(rows[0]._fy0, HEADER_SPACE, "first row top-anchored under the header");
  for (let i = 0; i < rows.length - 1; i += 1) {
    assert.equal(rows[i + 1]._fy0 - rows[i]._fy1, ROW_GAP, `row ${i + 1}: exact ROW_GAP below row ${i}`);
  }
  assert.equal(span, rows[rows.length - 1]._fy1 - HEADER_SPACE, "span = last drawn bottom - headerSpace");
});

test("drawn heights are preserved (owner constraint: block sizes unchanged)", () => {
  const before = [
    { y0: 0, y1: 50, _fy0: 0, _fy1: 60 }, // 60px drawn
    { y0: 60, y1: 110 }, // no floor -> drawn == layout (50px)
    { y0: 120, y1: 130, _fy0: 117, _fy1: 133 }, // 16px drawn
  ];
  const drawnBefore = before.map((n) => (n._fy1 ?? n.y1) - (n._fy0 ?? n.y0));
  restackManageRows(before, opts);
  before.forEach((n, i) => {
    assert.equal(n._fy1 - n._fy0, drawnBefore[i], `row ${i}: drawn height read-only`);
  });
});

test("layout rect keeps its height and is centered on the drawn center (flow anchors)", () => {
  const rows = column([
    [10, 30, 5, 45], // layout 20px inside a 40px drawn row
    [50, 90, 50, 90], // layout == drawn
  ]);
  const layoutHeights = rows.map((n) => n.y1 - n.y0);
  restackManageRows(rows, opts);
  rows.forEach((n, i) => {
    assert.equal(n.y1 - n.y0, layoutHeights[i], `row ${i}: layout height preserved`);
    assert.equal((n.y0 + n.y1) / 2, bandCenter(n), `row ${i}: layout rect centered on the drawn center`);
  });
});

test("rows without floors (no _fy0/_fy1) restack at their layout size", () => {
  const rows = column([
    [0, 50],
    [60, 110],
    [120, 130],
  ]);
  restackManageRows(rows, opts);
  assert.equal(rows[0]._fy0, HEADER_SPACE);
  assert.equal(rows[0]._fy1, HEADER_SPACE + 50, "drawn == layout when no floor exists");
  assert.equal(rows[1]._fy0, rows[0]._fy1 + ROW_GAP);
  assert.equal(rows[2]._fy0, rows[1]._fy1 + ROW_GAP);
});

test("empty column returns span 0 and mutates nothing", () => {
  const rows = [];
  assert.equal(restackManageRows(rows, opts), 0);
});
