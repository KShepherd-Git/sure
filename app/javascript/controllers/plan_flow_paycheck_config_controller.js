import { Controller } from "@hotwired/stimulus";
// the leftover icon glyph + variant constant live on the
// sankey controller (LEFTOVER_ICON_VARIANT / LEFTOVER_ICON_GLYPHS /
// LEFTOVER_ICON_SIZE) so BOTH surfaces share ONE config constant — switching
// the icon is a one-line change there, and this readout follows automatically
// (the module is already loaded on the plan-flow page; the sankey controller
// has no import back here, so there is no cycle).
import PlanFlowSankeyController from "controllers/plan_flow_sankey_controller";

// The Direct Deposit Review dialog is
// now a STATIC READ-ONLY paycheck readout. The old live config form
// (gross / frequency / anchor / derived monthly / next-4 pay dates) is GONE.
// Each member tab is a read-only table of the accounts the member's paycheck
// funds in the current plan, with PER-PAYCHECK amounts (matching what the
// diagram shows in Per Paycheck view) and the leftover row carrying the
// leftover icon + computed value.
//
// The table rows render CLIENT-SIDE from /plan/flow/graph (zero new
// endpoints — the payload carries incomes[owner_id] + bank inflow rows, and
// added the additive inflow.mode field so the leftover row is
// derivable). The header / max-DD-connections note / series context are
// server-rendered (the tab's labeled income series).
//
// House Stimulus pattern (plan_flow_controller.js): the controller element IS
// the dialog (data-controller on the DS::Dialog), so every query is scoped to
// this.element — the rule (dialog-scoped queries, NO document-level
// listeners). The dialog hosts no re-parented popups, so there is no
// outside-click handling either (native <dialog> close: backdrop / esc /
// header X).
//
// Per-paycheck math mirrors the house unit module
// (utils/plan_flow_sankey_unit — bankInflowInfo): each inflow row's amount /
// that income's occurrence count, summed over the member's rows for the bank.
// The payload's inflow amounts are already dollars (the planner runs money
// on raw cents), so the result is dollars.
export default class extends Controller {
  connect() {
    this.#fetchAndRender();
  }

  async #fetchAndRender() {
    let graph;
    try {
      const response = await fetch("/plan/flow/graph", {
        headers: { Accept: "application/json" },
      });
      if (!response.ok)
        throw new Error(`plan-flow graph status ${response.status}`);
      graph = await response.json();
    } catch (error) {
      // Leave the server-rendered placeholder rows; never leave a broken
      // dialog (the header / note / series context are still visible).
      console.error("DD review: graph fetch failed", error);
      return;
    }
    this.#render(graph);
  }

  // income id -> the month's occurrence (paycheck) count. 0 -> 1 (the house
  // unit module's guard: divide by at least one paycheck).
  #incomeCounts(graph) {
    const counts = new Map();
    (graph.incomes || []).forEach((income) => {
      const n = (income.occurrences || []).length;
      counts.set(income.id, n > 0 ? n : 1);
    });
    return counts;
  }

  // Per-member DD rows: for each bank this member's paycheck funds in the
  // current plan, the per-paycheck amount + the leftover flag. Ordered by the
  // bank's plan_order (the diagram's order). A member with no labeled income
  // series yields no rows (the tab's empty state is server-rendered instead).
  #memberRows(graph, memberId) {
    const counts = this.#incomeCounts(graph);
    const memberIncomeIds = new Set(
      (graph.incomes || [])
        .filter((income) => income.owner_id === memberId)
        .map((income) => income.id),
    );
    if (memberIncomeIds.size === 0) return [];
    const rows = [];
    (graph.banks || []).forEach((bank) => {
      const inflow = (bank.inflow || []).filter((row) =>
        memberIncomeIds.has(row.income_id),
      );
      if (inflow.length === 0) return;
      const perPaycheck = inflow.reduce(
        (sum, row) =>
          sum + Number(row.amount || 0) / (counts.get(row.income_id) || 1),
        0,
      );
      const leftover = inflow.some((row) => row.mode === "leftover");
      rows.push({ bank, perPaycheck, leftover });
    });
    rows.sort((a, b) => (a.bank.plan_order ?? 0) - (b.bank.plan_order ?? 0));
    return rows;
  }

  #currency() {
    return this.element.dataset.paycheckCurrency || "USD";
  }

  // Format dollars (the payload's inflow amounts are already dollars).
  #money(dollars) {
    const value = Number(dollars);
    try {
      return new Intl.NumberFormat("en-US", {
        style: "currency",
        currency: this.#currency(),
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      }).format(value);
    } catch {
      return `$${value.toFixed(2)}`;
    }
  }

  // The leftover icon — the SAME line-vector glyph as the sankey,
  // inline SVG, 14px, stroke-only with stroke=currentColor so it inherits the
  // row's text color.: the inner markup is read from the
  // sankey controller's shared LEFTOVER_ICON (variant-driven), so the readout
  // and the diagram always show the same glyph. Positioning: the icon sits in
  // its own flex slot (gap-1.5 = 6px >= the 4px clearance rule) to the LEFT
  // of the "Leftover - $X" text — the same slot/variant as the sankey label
  // placement, no overlap by construction (measured in the DOM per release).
  #leftoverIconSvg() {
    const size = PlanFlowSankeyController.LEFTOVER_ICON_SIZE;
    return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" class="dd-leftover-icon" aria-hidden="true">${PlanFlowSankeyController.LEFTOVER_ICON}</svg>`;
  }

  #render(graph) {
    // One tbody per member tab (the server-rendered data-paycheck-dd-member).
    this.element
      .querySelectorAll("[data-paycheck-dd-member]")
      .forEach((tbody) => {
        const memberId = tbody.dataset.paycheckDdMember;
        const rows = this.#memberRows(graph, memberId);
        tbody.innerHTML = "";
        if (rows.length === 0) {
          const tr = document.createElement("tr");
          tr.dataset.paycheckDdEmpty = "";
          const td = document.createElement("td");
          td.colSpan = 2;
          td.className = "text-xs text-secondary py-2";
          td.textContent =
            tbody.dataset.paycheckDdEmptyText ||
            "This paycheck has no direct deposit rows in the current plan.";
          tr.appendChild(td);
          tbody.appendChild(tr);
          return;
        }
        rows.forEach(({ bank, perPaycheck, leftover }) => {
          const tr = document.createElement("tr");
          tr.className = "border-b border-primary/10 last:border-b-0";
          // Account cell — the same "Name [last4]" identity as the diagram
          // (labelName), so the rows match the sankey labels and same-named
          // accounts disambiguate.
          const tdAccount = document.createElement("td");
          tdAccount.className = "py-1.5 pr-3 text-sm text-primary";
          tdAccount.textContent =
            bank.last4 != null && String(bank.last4) !== ""
              ? `${bank.name} [${bank.last4}]`
              : bank.name;
          // Amount cell.
          const tdAmount = document.createElement("td");
          tdAmount.className =
            "py-1.5 text-right text-sm font-mono tabular-nums";
          if (leftover) {
            // "Leftover" in the amount cell, with the computed
            // per-paycheck value + the leftover icon.
            tdAmount.classList.add("text-secondary");
            const wrap = document.createElement("span");
            wrap.className =
              "dd-leftover-cell inline-flex items-center justify-end gap-1.5";
            const icon = document.createElement("span");
            icon.className = "dd-leftover-icon-wrap";
            icon.innerHTML = this.#leftoverIconSvg();
            const label = document.createElement("span");
            label.className = "font-medium";
            label.textContent = `Leftover - ${this.#money(perPaycheck)}`;
            wrap.appendChild(icon);
            wrap.appendChild(label);
            tdAmount.appendChild(wrap);
          } else {
            tdAmount.classList.add("text-primary");
            tdAmount.textContent = this.#money(perPaycheck);
          }
          tr.appendChild(tdAccount);
          tr.appendChild(tdAmount);
          tbody.appendChild(tr);
        });
      });
  }
}
