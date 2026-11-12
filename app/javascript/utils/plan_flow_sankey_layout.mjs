// Pure manage-mode row re-stack math for the plan-flow sankey (R32).
//
// The R24 restack (#manageRowGapsAndExtent in the plan-flow sankey controller)
// re-anchors every drawn bank / allocation-surplus row to
// [top, top + hDrawn) with exactly rowGap between adjacent DRAWN rows, then
// re-centers the layout rect (y0/y1, which the flow anchors derive from) on
// the drawn center. The node label is drawn from the SAME _fy0/_fy1 pair
// (controller #applyGeometry: d._y0 = d._fy0 ?? d.y0; #setLabelGeoms: label
// y = (d._y0 + d._y1) / 2 + _labelDy), so the label center and the band
// center are the same number by construction. That coupling is the invariant
// the pre-R24 label-only tiling pass broke (labels tiled at their own pitch
// while the bands sat at the row-gap pitch — the owner's "drift" screenshot:
// middle bank-column labels up to ~185px below their bands), and this module
// exists so the math is unit-testable: expected label-center == band-center
// for every row, and label pitch == band pitch down the whole column.

/**
 * Restack the rows of one manage-mode column, top-down.
 * Mutates the given node objects in place (they are the live d3 bindings the
 * controller hands over) and returns the column span.
 *
 * @param {Array<{y0: number, y1: number, _fy0?: number, _fy1?: number}>} rows
 *   The column's rows, already filtered to visible nodes and sorted by y0 —
 *   the controller does both before calling (the math is order-pure).
 * @param {{rowGap?: number, headerSpace?: number}} opts
 *   rowGap: exact gap between adjacent DRAWN rows (controller: ROW_GAP).
 *   headerSpace: top room before the first row (controller: HEADER_SPACE).
 * @returns {number} span from headerSpace to the last row's drawn bottom
 *   (0 for an empty column — the controller early-returns before calling).
 */
export function restackManageRows(rows, { rowGap = 8, headerSpace = 44 } = {}) {
  let top = headerSpace;
  for (const n of rows) {
    const h = n.y1 - n.y0; // layout height (preserved as-is)
    const hDrawn = (n._fy1 ?? n.y1) - (n._fy0 ?? n.y0); // drawn height (READ ONLY)
    // DRAWN-anchored: the drawn rect (the band) occupies [top, top + hDrawn)
    // so the gap to the next drawn rect is exactly rowGap; the layout rect
    // (height h) is centered on the drawn center.
    n._fy0 = top;
    n._fy1 = top + hDrawn;
    n.y0 = top + (hDrawn - h) / 2;
    n.y1 = n.y0 + h;
    top += hDrawn + rowGap;
  }
  return rows.length > 0 ? rows[rows.length - 1]._fy1 - headerSpace : 0;
}
