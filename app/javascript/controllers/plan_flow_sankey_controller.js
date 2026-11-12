import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { sankey } from "d3-sankey";
import { formatCashFlowCurrency } from "utils/cash_flow_chart_data";
import {
  CHART_TOOLTIP_CLASSES,
  CHART_TOOLTIP_CONTEXT_CLASSES,
  CHART_TOOLTIP_VALUE_CLASSES,
  createChartTooltip,
} from "utils/chart_tooltip";
import { hiddenSankeyLabels } from "utils/sankey_labels";
import { restackManageRows } from "utils/plan_flow_sankey_layout";
import { paycheckUnitScales } from "utils/plan_flow_sankey_unit";
import replaceUrl from "utils/replace_url";

let nextChartId = 0;

// Plan-flow planning diagram (M2 PR#2b): incomes -> banks -> allocations,
// drawn in the house Cashflow Sankey style (same layout constants, node
// path shapes, gradient .sankey-link bands, label typography, tooltip
// contract, and hover behavior as preview_sankey_chart_controller — the
// house controller was extracted rather than reused verbatim because the
// plan graph has no categories/zoom/sort; deviation recorded in PR2b-STATE).
//
// Node vertical order is ALGORITHMIC (spec A2): a stable per-column
// comparator (flow-weighted: big flows first, then name) plus d3-sankey's
// crossing-minimizing relaxation. d3-sankey keeps the comparator order
// through relaxation (nodeSort set => the ascendingBreadth re-sort pass is
// skipped), so the layout is deterministic — no manual ordering anywhere.
//
// Data source: GET /plan/flow/graph (fetched here). The page embeds only
// static account names + in-plan membership — no client-side plan state.
//
// Issue 10 (View/Manage, 2026-11-01): the header sizing-mode toggle is
// CLIENT-SIDE ONLY — this controller re-renders in place (same mechanism
// as the plan mutations: re-build + re-layout + TWEEN; no reload, no
// re-fetch — the mode never changes the data).
//
// Round 15 (owner note 1, 2026-11-07): MANAGE is redefined as the VIEW
// layout (strictly proportional) with the only difference that every
// labelled node's minimum size is expanded from zero to the size that
// SUPPORTS SHOWING ITS LABEL — the measured label box (the real shared
// measure-probe box #prepareDraw feeds hiddenSankeyLabels in VIEW mode)
// plus a small padding (LABEL_FLOOR_PADDING). The fixed MIN_NODE_HEIGHT /
// MIN_BAND_WIDTH / 1.5% sliver floors are gone from MANAGE (the 3px
// MIN_BAND_WIDTH floor survives for ZERO-VALUE minBand links only — the Q3
// unsatisfied-bucket wiring). d3-sankey conserves flow: a node taller than
// its link sum keeps the larger side's bands filling its edge, and the
// incomes grow with their label floors — expected and desired by the
// owner. MANAGE never hides labels (explicit empty hidden set). VIEW is
// strictly proportional with the dashboard-style small-label hide — the
// owner's honest-ratio answer, untouched by round 15.
export default class PlanFlowSankeyController extends Controller {
  static values = {
    graphUrl: String,
    view: String, // "paycheck" | "monthly"
    currency: String,
    accounts: Object, // { account_id: name }
    inPlan: Array, // account ids on the plan
    labels: Object, // income/bank/allocation/surplus/unallocated
    mode: String, // issue 10 (View/Manage): "manage" (default) | "view"
    unit: String, // round 33 (spec 1/2): "income" (default) | "family"
  };

  // House visual constants (cf. preview_sankey_chart_controller).
  static EXTENT_MARGIN = 16;
  static HEADER_SPACE = 44; // top room for the column headers
  static NODE_WIDTH = 15;
  static NODE_PADDING = 20;
  static MIN_NODE_PADDING = 4;
  static MAX_PADDING_RATIO = 0.4;
  static CORNER_RADIUS = 8;
  static HOVER_OPACITY = 0.4;
  static HOVER_FILTER = "saturate(1.3) brightness(1.1)";
  static MIN_LABEL_SPACING = 28;
  static VALUE_FLOOR = 0.01; // keeps zero-flow banks placeable (d3 ky guard)
  // Owner round 3: R2 — allocation / surplus rows never render shorter than
  // this (a guaranteed minimum height, so small bars hold their compact
  // label without overlapping neighbours); R7 — the node / band tween
  // durations for the in-place animation.
  // Round 15 (owner note 1): MANAGE minimums are now LABEL-SUPPORTING
  // (see #labelFloorHeight) — these fixed floors are the legacy constants;
  // MIN_NODE_HEIGHT no longer bounds any manage node.
  static MIN_NODE_HEIGHT = 22;
  // Round 9: a bank -> allocation band never renders thinner than this —
  // an allocation whose bank has no inflow yet ($0 flow) still shows the
  // wiring to its source bank at the floor width. Round 15: the 3px floor
  // applies to ZERO-VALUE minBand links only (the Q3 unsatisfied bucket);
  // non-zero bands keep their true proportional width.
  static MIN_BAND_WIDTH = 3;
  // Round 21 (T1, owner): the gap between the income's right edge and the
  // Un-Allocated stub's left edge — see #placeUnallocatedNearTails.
  // Round 22 (N3, owner): the gap is GONE — the stub is flush at the
  // income's right edge (zero gap, "straight out and stop super early")
  // on EVERY plan (allocating AND empty), so the constant is 0. It is
  // kept (not deleted) because the battery tracks it: pillar.x0 ==
  // income.x1 + UA_GAP.
  static UA_GAP = 0;
  // Round 15 (owner note 1): the manage node floor is the MEASURED label
  // box height plus this padding — the minimum size that supports showing
  // the node's label (never a fixed pixel count).
  static LABEL_FLOOR_PADDING = 4;
  // Round 20 (T1, owner round 20): the reference-dashboard label padding,
  // measured from round20-reference-dashboard.png (12px-font world): the
  // label-to-node-bar gutter is 8px (measured 7-9px across the right
  // column) and consecutive label blocks keep >= 15px of vertical padding
  // (the tightest inter-block gap in the reference's allocation column).
  static LABEL_GUTTER = 8;
  static LABEL_BLOCK_PADDING = 15;
  // Round 24 (owner): the visible block-to-block padding in MANAGE mode —
  // the drawn rows of the bank and allocation/surplus columns are re-stacked
  // (top-anchored) with exactly this gap between every adjacent DRAWN row,
  // and the overall diagram height grows to fit (the round 16.6/16.8
  // "manage locked to the container" height lock is lifted for MANAGE by
  // owner directive; the individual drawn block heights are UNCHANGED and
  // VIEW mode keeps the locked container height — see
  // #manageRowGapsAndExtent).
  static ROW_GAP = 8;
  static ANIM_NODE_MS = 500;
  static ANIM_LINK_MS = 400;
  static COLORS = {
    income: "#10A861",
    bank: "#9E9E9E",
    bill: "#EAB308",
    debt: "#EC2222",
    savings: "#2563EB", // R4: savings allocations are BLUE
    // Round 31A (C7, owner spec a): the fun_money kind default is the app's
    // income green (a category color still wins — validHex precedence below).
    fun_money: "#10A861",
    surplus: "#10A861",
    unallocated: "#9E9E9E",
    over: "#EC2222",
    amber: "#EAB308",
    badgeText: "#1F1F1F",
  };
  // Round 16 (owner note 3b): the bank favicon chip geometry — part of the
  // label box (it sits node-side of the text), so the measured label floors
  // adapt automatically.
  static LOGO_CHIP_SIZE = 14; // px, chip height (owner: ~14-16px)
  static LOGO_CHIP_GAP = 4; // px between the chip and the label text

  // Round 16.6 (owner note: "a static default icon by account kind when no
  // logo is selected — Sure already uses some icons, so just grab some"):
  // lucide-rails path data (24x24 coordinate space, stroke-based), vendored
  // VERBATIM from the gem (lucide-rails-0.7.3/icons/stripped) so the default
  // chip is the same icon language as the rest of the app. savings ->
  // piggy-bank, debt -> credit-card, checking -> wallet, everything else
  // (incl. nil kind) -> circle.
  // Round 34 (spec 4): the LEFTOVER icon — a small line-vector glyph, 14px,
  // stroke-only, stroke = the computed amount-text color so it inherits the
  // dollar-amount text color. Drawn on a bank node whose inflow is a leftover
  // (and on the Direct Deposit readout's leftover rows). Round 34b (owner
  // complaint: "I can't even really see it, it almost looks like it's
  // overlapping with the Text Label for the Bank"): the glyph now sits in a
  // measured slot OUTSIDE the label text run (see #leftoverIconPlacement)
  // and the owner gets FOUR glyph options behind ONE constant. Round 34c
  // (owner pick): the default is now "wave" ("Let's go with the Wave") —
  // the DD readout (plan_flow_paycheck_config_controller) imports these
  // statics, so the variant switch is a ONE-LINE change for both surfaces.
  // Glyph space is 14x14, stroke-only (no fill), drawn at the same
  // stroke-width/linecap the round-34 glyph used.
  static LEFTOVER_ICON_VARIANT = "wave";
  static LEFTOVER_ICON_GLYPHS = {
    // "tail" (round 34): horizontal line ending in a dot.
    tail: '<line x1="1" y1="7" x2="9.5" y2="7"></line><circle cx="11.8" cy="7" r="1.6"></circle>',
    // "wave": a small wavy tilde line (~3 humps, sine through the midline) —
    // reads as "leftover / residual".
    wave:
      '<path d="M1 7C2 4.5 3 4.5 4.5 7C6 9.5 7 9.5 8.5 7C10 4.5 11 4.5 13 7"></path>',
    // "bracket": a C arc OPENING toward the bank band (the band is always on
    // the far side of the label text from the icon's preferred slot), reads
    // as "pocket".
    bracket: '<path d="M9.7 4A4.764 4.764 0 1 0 9.7 10"></path>',
    // "loop": a small circle (the rest looped back) with a short tail stub
    // on its left.
    loop:
      '<circle cx="8.5" cy="7" r="3.2"></circle><line x1="1" y1="7" x2="5.3" y2="7"></line>',
  };
  static LEFTOVER_ICON_SIZE = 14;
  // Resolves LEFTOVER_ICON_VARIANT to its 14x14 glyph markup (an unknown
  // variant falls back to "tail" so a typo never blanks the icon).
  static get LEFTOVER_ICON() {
    return this.LEFTOVER_ICON_GLYPHS[this.LEFTOVER_ICON_VARIANT] ?? this.LEFTOVER_ICON_GLYPHS.tail;
  }
  // Round 34b (T1): the leftover-icon slot geometry is a PURE function of
  // the measured label text box + the node band edges + the label anchor
  // side + the slot size — no magic x. { x, y } is the icon <g> translate;
  // y is the slot top (slot = 14*k tall, vertically centered on the band
  // center centerY). Rule (deterministic from the measured label width):
  //   * anchor "end" (label LEFT of the band, right-aligned text run
  //     "Name [last4] $amount"): the text->band gap is d.x0 - textRight
  //     (= LABEL_GUTTER 8px < 18, so this always falls to the fallback):
  //     the icon sits LEFT of the name text with a 4px clearance.
  //   * if that gap is >= 18px (a wider gutter / future layout): the
  //     preferred slot is BETWEEN the label text end and the band edge,
  //     centered in the gap (equal clearance to text and band edge).
  //   * anchor "start" (label RIGHT of the band) mirrors it: gap
  //     textLeft - d.x1 >= 18 -> icon centered between band edge and text
  //     start; else RIGHT of the label text end with the 4px clearance.
  // Static + DOM-free so the unit test (test/javascript) exercises the same
  // math the draw path (#writeLabelText) and the per-frame reposition
  // (#setLabelGeoms) consume.
  static LEFTOVER_ICON_PREFERRED_GAP = 18; // px: min text<->band gap for the preferred slot
  static LEFTOVER_ICON_CLEARANCE = 4; // px: min icon<->text clearance (spec: >= 4px)
  // Round 34c (owner): an optional MEASURED per-node `clearance` (the
  // name<->dollar-amount gap of the single-line label run, measured by the
  // draw path) BYPASSES the centered preferred slot: the icon hugs the label
  // text end at exactly that gap — "the same amount of Gap that you have
  // between the Text and the Dollar Amount" — i.e. the bank-label icon no
  // longer floats centered in the text<->band gap. The hug slot is used only
  // when the icon fits inside the gap (no band overlap); otherwise the
  // round-34 fallback (left of the text, measured or 4px clearance) applies.
  // null/absent = round-34b behavior unchanged.
  static leftoverIconPlacement({ anchor, labelBox, bandX0, bandX1, boxSize, centerY, clearance = null }) {
    const clr = clearance ?? this.LEFTOVER_ICON_CLEARANCE;
    const y = centerY - boxSize / 2;
    const textLeft = labelBox.x;
    const textRight = labelBox.x + labelBox.width;
    if (anchor === "end") {
      const gapToBand = bandX0 - textRight;
      const hugX = textRight + clr;
      if (clearance != null && hugX + boxSize <= bandX0) {
        return { x: hugX, y };
      }
      if (gapToBand >= this.LEFTOVER_ICON_PREFERRED_GAP) {
        return { x: textRight + (gapToBand - boxSize) / 2, y };
      }
      return { x: textLeft - clr - boxSize, y };
    }
    const gapToBand = textLeft - bandX1;
    const hugX = textLeft - clr - boxSize;
    if (clearance != null && hugX >= bandX1) {
      return { x: hugX, y };
    }
    if (gapToBand >= this.LEFTOVER_ICON_PREFERRED_GAP) {
      return { x: textLeft - (gapToBand - boxSize) / 2, y };
    }
    return { x: textRight + clr, y };
  }

  static KIND_ICONS = {
    savings:
      '<path d="M11 17h3v2a1 1 0 0 0 1 1h2a1 1 0 0 0 1-1v-3a3.16 3.16 0 0 0 2-2h1a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1h-1a5 5 0 0 0-2-4V3a4 4 0 0 0-3.2 1.6l-.3.4H11a6 6 0 0 0-6 6v1a5 5 0 0 0 2 4v3a1 1 0 0 0 1 1h2a1 1 0 0 0 1-1z"></path><path d="M16 10h.01"></path><path d="M2 8v1a2 2 0 0 0 2 2h1"></path>',
    debt:
      '<rect width="20" height="14" x="2" y="5" rx="2"></rect><line x1="2" x2="22" y1="10" y2="10"></line>',
    checking:
      '<path d="M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1"></path><path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"></path>',
    other: '<circle cx="12" cy="12" r="10"></circle>',
  };

  // The kind -> KIND_ICONS key (same family split as #bankKindColor).
  static kindIconKey(kind) {
    if (kind === "savings" || kind === "savings_bucket") return "savings";
    if (kind === "debt" || kind === "credit_card_payoff" || kind === "loan_payoff") return "debt";
    if (kind === "checking") return "checking";
    return "other";
  }

  // Round 16 (owner note 3a): the bank (middle) column fill varies by
  // account KIND when the payload carries kind data — the owner's grey
  // "feels bland" note, answered by desaturating the LEGEND palette tokens
  // (derived values, no new palette): savings -> muted blue toward
  // COLORS.savings, debt -> muted red toward COLORS.debt, checking/other/
  // nil -> the current COLORS.bank grey (the owner's "or just leave it
  // gray"). "savings"/"debt" would be a bank-row `kind`; the *_payoff /
  // savings_bucket values are Account.plan_role (M2 PR#2b) when the
  // planner emits that instead.
  static bankKind(bank) {
    if (bank == null) return null;
    return bank.kind ?? bank.plan_role ?? null;
  }

  static bankKindColor(kind) {
    // Round 16 fix (owner's Edge for Android): the static private #blendHex
    // is ONLY reachable through the exact declaring class — a subclass
    // receiver (what this browser's `this.constructor` proved to be) throws
    // "TypeError: Receiver must be class default" (V8 names an anonymous
    // class "default"). Reference the class by its declared name so the
    // receiver is exact no matter how the method is invoked.
    const C = PlanFlowSankeyController;
    // biome-ignore lint/complexity/noThisInStatic: deliberate — `this` is the caller's receiver; `C !== this` is the warn-once receiver check (a class-name substitution would make it a tautology).
    if (C !== this && !C._warnedKindReceiver) {
      C._warnedKindReceiver = true;
      console.warn(
        `plan-flow: bankKindColor receiver is not the declaring class: ${
          // biome-ignore lint/complexity/noThisInStatic: deliberate — same receiver check; reports the caller's actual receiver.
          (this && this.name) || String(this)
        }`
      );
    }
    const { COLORS } = C;
    if (kind === "savings" || kind === "savings_bucket")
      return C.#blendHex(COLORS.savings, COLORS.bank, 0.6); // -> #6E86BD
    if (kind === "debt" || kind === "credit_card_payoff" || kind === "loan_payoff")
      return C.#blendHex(COLORS.debt, COLORS.bank, 0.6); // -> #BD6C6C
    return COLORS.bank; // checking / other / nil: the current grey
  }

  // Deterministic desaturation of hexA toward hexB (t = weight on hexB,
  // 0 = hexA unchanged) — a pure function of the palette tokens above.
  static #blendHex(hexA, hexB, t) {
    const parse = (h) => [1, 3, 5].map((i) => Number.parseInt(h.slice(i, i + 2), 16));
    const a = parse(hexA);
    const b = parse(hexB);
    return (
      `#${[0, 1, 2].map((i) => Math.round(a[i] * (1 - t) + b[i] * t).toString(16).padStart(2, "0")).join("").toUpperCase()}`
    );
  }

  // Round 16 (owner note 5): defensive hex guard for the payload's
  // category_color — nil / non-hex -> null so the kind fallback (the
  // pre-round-16 colors) applies.
  static validHex(value) {
    return typeof value === "string" && /^#[0-9A-Fa-f]{3,8}$/.test(value) ? value : null;
  }

  connect() {
    this.chartId = nextChartId++;
    this.redrawInFlight = false;
    this.lastLayout = null; // committed { nodes, links } of the last draw
    this.currentFrame = null; // live tween geometry (interruption handoff)
    this.svg = null;
    this.rafId = null;
    this.animationToken = 0;
    // Round 24 (owner): the observer is WIDTH-ONLY. The manage row-gap
    // pass grows this.lastChartHeight (the svg — and with it this wrapper
    // — grows vertically, 480 -> 704 on the live plan), and a height-only
    // change must NOT re-trigger the layout: the layout is width-driven,
    // so a height change would just re-fetch + re-lay-out + re-tween to
    // the exact same grown size (and re-enter this observer — a loop).
    this.lastObservedWidth = null;
    this.resizeObserver = new ResizeObserver(() => {
      const w = this.element.clientWidth;
      if (this.lastObservedWidth !== null && w === this.lastObservedWidth) return;
      this.lastObservedWidth = w;
      this.#redraw();
    });
    this.resizeObserver.observe(this.element);
    document.fonts?.ready?.then(() => this.#redraw());
    // In-place graph updates (owner round 3, R1/R7): a plan mutation (the
    // plan-flow controller's submitInPlace fetch) hands the fresh plan-graph
    // JSON to the diagram, which TWEENS to it instead of a full reload.
    this._onGraphUpdate = (event) => this.#graphUpdated(event.detail?.graph);
    this.element.addEventListener("plan-flow:graph", this._onGraphUpdate);
    // Issue 10 (View/Manage): the header sizing-mode toggle sits OUTSIDE
    // this controller's scope (a sibling of the chart container), so a
    // Stimulus data-action cannot reach it — a document-level click
    // delegation finds the segment by its data attribute instead (house
    // pattern, cf. activity_label_quick_edit_controller /
    // color_icon_picker_controller / dashboard_widget_size_controller).
    this._onModeClick = (event) => {
      const segment = event.target?.closest?.("[data-plan-flow-sankey-mode]");
      if (!segment) return;
      this.#modeToggled(segment.dataset.planFlowSankeyMode);
    };
    document.addEventListener("click", this._onModeClick);
    // Round 33 (spec 3): the Per Paycheck <-> Per Month segments (plain
    // buttons, like the mode segments — the house pattern).
    this._onViewClick = (event) => {
      const segment = event.target?.closest?.("[data-plan-flow-sankey-view]");
      if (!segment) return;
      this.#viewToggled(segment.dataset.planFlowSankeyView);
    };
    document.addEventListener("click", this._onViewClick);
    // Round 33 (spec 2): the paycheck-unit kebab items are LINKS (the
    // no-JS full-reload fallback is their href), so the interception runs
    // in the CAPTURE phase — before Turbo's document click handler can
    // start a navigation. preventDefault + stopPropagation keep the rest
    // of the page (and the menu's own outside-click close, which would
    // fire on the bubbled event) out of it; #unitToggled closes the menu.
    this._onUnitClick = (event) => {
      const item = event.target?.closest?.("[data-plan-flow-sankey-unit]");
      if (!item) return;
      event.preventDefault();
      event.stopPropagation();
      this.#unitToggled(item.dataset.planFlowSankeyUnit, item);
    };
    document.addEventListener("click", this._onUnitClick, true);
    // Round 20 (T2): the tooltip is anchored at a PAGE coordinate
    // (position:absolute in document.body, left = event.pageX + 10); a
    // scroll moves the pointer away from that point, so the floating
    // label hides with the scroll.
    this._onScroll = () => this.#hideTooltip();
    document.addEventListener("scroll", this._onScroll, { passive: true });
    this.#redraw();
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    this.element.removeEventListener("plan-flow:graph", this._onGraphUpdate);
    document.removeEventListener("click", this._onModeClick);
    document.removeEventListener("click", this._onViewClick);
    document.removeEventListener("click", this._onUnitClick, true);
    window.clearTimeout(this.morphTimer);
    if (this._onScroll) document.removeEventListener("scroll", this._onScroll);
    this.#cancelAnimation();
    this.element.innerHTML = "";
    this.svg = null;
    this.lastLayout = null;
    this.currentFrame = null;
    this.tooltip?.remove();
    this.tooltip = null;
  }

  async #redraw() {
    if (this.redrawInFlight) return;
    this.redrawInFlight = true;
    try {
      await this.#doRedraw();
    } finally {
      this.redrawInFlight = false;
    }
  }

  async #doRedraw() {
    // Round 16 (owner note A) + 16.6: the layout starts from the DESIGN
    // height (the wrapper's min-height), not the clientHeight — the MANAGE
    // chart is locked to the container, but the guard stays (a leaked
    // clientHeight would pin VIEW to a stale size).
    const width = this.element.clientWidth;
    const height = this.#designHeight();
    if (width < 100 || height < 100) return;

    let graph;
    try {
      graph = await this.#fetchGraph();
    } catch (error) {
      console.error("plan-flow graph fetch failed", error);
      this.#fallback(`${this.labelsValue.error || "Couldn't load the diagram — refresh the page."} [${error.name}: ${error.message}]`);
      return;
    }
    if (!graph) {
      this.#fallback(this.labelsValue.error || "Couldn't load the diagram — refresh the page.");
      return;
    }
    this.graph = graph;

    let layout;
    let chartWidth = width;
    let chartHeight = height;
    try {
      const { nodes, links } = this.#buildGraph(graph);
      if (nodes.length === 0) return;
      const totalValue = nodes.reduce((sum, node) => sum + Number(node.fixedValue ?? node.value ?? 0), 0);
      if (totalValue <= 0) {
        // Nothing to draw (e.g. no paychecks this month) — say so instead of
        // leaving the diagram silently empty.
        this.#fallback(this.labelsValue.empty || "Nothing to plan this month yet.");
        return;
      }
      layout = this.#generateSankeyData(nodes, links, width, height);
      // Round 16.8: the chart is LOCKED at the container (the manage label
      // floors are a draw-level clamp only). Round 24 (owner) unlocked that
      // lock for MANAGE ONLY: the row-gap pass may grow lastChartHeight
      // during the flatten, so the re-read BELOW the flatten (not this
      // pre-flatten design-height read, which stays the runLayout input)
      // is what #draw uses. View stays locked at the design height.
      chartWidth = this.lastChartWidth || width;
      chartHeight = this.lastChartHeight || height;
      this.#flattenColumns(layout, chartWidth, chartHeight);
      // Round 24 (E4): re-read AFTER the flatten — #manageRowGapsAndExtent
      // may have grown this.lastChartHeight in place (manage row-gap
      // layout). View mode: the pass early-returns, so this is a no-op.
      chartHeight = this.lastChartHeight || chartHeight;
    } catch (error) {
      // Never leave the chart silently blank: any data anomaly surfaces as a
      // visible note + console error (owner review round 2, F4).
      console.error("plan-flow diagram failed to render", error);
      this.#fallback(`${this.labelsValue.error || "Couldn't draw the diagram — refresh the page."} [${error.name}: ${error.message}${error.stack ? ` | ${String(error.stack).split("\n").slice(1, 2).join("")}` : ""}`);
      return;
    }
    this.#draw(layout, chartWidth, chartHeight);
    this.#flushModePending();
  }

  #fallback(message) {
    this.#cancelAnimation();
    this.lastLayout = null;
    this.currentFrame = null;
    this.svg = null;
    this.nodeSelection = null;
    this.linkSelection = null;
    this.element.innerHTML = "";
    this.tooltip?.remove();
    this.tooltip = null;
    const note = document.createElement("div");
    note.className = "h-full flex items-center justify-center";
    const text = document.createElement("p");
    text.className = "text-sm text-secondary";
    text.textContent = message;
    note.append(text);
    this.element.append(note);
  }

  async #fetchGraph() {
    const response = await fetch(this.graphUrlValue, {
      headers: { Accept: "application/json" },
    });
    if (!response.ok) throw new Error(`plan-flow graph request failed (${response.status})`);
    return await response.json();
  }

  // In-place graph update (owner round 3, R1/R7): a plan mutation came back
  // as fresh plan-graph JSON — re-layout and TWEEN the existing diagram to
  // it (no reload, no destroy/hide). Any exception -> the visible fallback.
  #graphUpdated(graph) {
    if (!graph) return;
    if (!this.lastLayout) {
      // Nothing drawn yet — the normal fetch path does the first draw.
      this.graph = graph;
      this.#redraw();
      return;
    }
    const width = this.element.clientWidth;
    // Round 16 (owner note A): the DESIGN height (see #designHeight).
    const height = this.#designHeight();
    if (width < 100 || height < 100) return;
    this.graph = graph;

    let layout;
    let chartWidth = width;
    let chartHeight = height;
    try {
      const { nodes, links } = this.#buildGraph(graph);
      const totalValue = nodes.reduce((sum, node) => sum + Number(node.fixedValue ?? node.value ?? 0), 0);
      if (totalValue <= 0) {
        this.#fallback(this.labelsValue.empty || "Nothing to plan this month yet.");
        return;
      }
      layout = this.#generateSankeyData(nodes, links, width, height);
      chartWidth = this.lastChartWidth || width;
      chartHeight = this.lastChartHeight || height;
      this.#flattenColumns(layout, chartWidth, chartHeight);
      // Round 24 (E4): re-read AFTER the flatten — #manageRowGapsAndExtent
      // may have grown this.lastChartHeight in place (manage row-gap
      // layout). View mode: the pass early-returns, so this is a no-op.
      chartHeight = this.lastChartHeight || chartHeight;
    } catch (error) {
      console.error("plan-flow diagram failed to render", error);
      this.#fallback(`${this.labelsValue.error || "Couldn't draw the diagram — refresh the page."} [${error.name}: ${error.message}${error.stack ? ` | ${String(error.stack).split("\n").slice(1, 2).join("")}` : ""}`);
      return;
    }
    this.#draw(layout, chartWidth, chartHeight);
    this.#flushModePending();
  }

  // Issue 10 (View/Manage): the header sizing-mode toggle (client-side
  // only — the mode never changes the data, only the floors, so no
  // re-fetch). MANAGE is the default on load: the current behavior — the
  // floor passes keep every label showable. VIEW is the honest-ratio
  // answer: strictly proportional to the data, floor passes skipped, very
  // small labels hidden the dashboard way. Flipping the mode re-renders IN
  // PLACE through the same house mechanism the plan mutations use:
  // re-build + re-layout + TWEEN the existing diagram (no page reload).
  #modeToggled(mode) {
    const next = mode === "view" ? "view" : "manage";
    if (next === this.mode) return;
    this.mode = next;
    // Round 20 (T2): a mode switch redraws the chart - the old item's
    // floating label must not survive the redraw.
    this.#hideTooltip();
    this.#updateModeToggleUI(next);
    if (this.redrawInFlight) {
      // A draw is in flight: the mode is applied once it completes.
      this.modePending = true;
      return;
    }
    this.#rerenderForMode();
  }

  // Mirror the DS::SegmentedControl contract client-side (plain buttons, no
  // server round trip): flip the active segment class + aria-pressed.
  #updateModeToggleUI(mode) {
    document.querySelectorAll("[data-plan-flow-sankey-mode]").forEach((segment) => {
      const active = segment.dataset.planFlowSankeyMode === mode;
      segment.classList.toggle("segmented-control__segment--active", active);
      segment.setAttribute("aria-pressed", String(active));
    });
  }

  #rerenderForMode() {
    if (!this.lastLayout) {
      // Nothing drawn yet — the normal fetch path does the first draw (it
      // reads this.mode, so the pending mode is honored there).
      this.#redraw();
      return;
    }
    const width = this.element.clientWidth;
    // Round 16 (owner note A): the DESIGN height (see #designHeight).
    const height = this.#designHeight();
    if (width < 100 || height < 100) return;
    let layout;
    let chartWidth = width;
    let chartHeight = height;
    try {
      const { nodes, links } = this.#buildGraph(this.graph);
      const totalValue = nodes.reduce((sum, node) => sum + Number(node.fixedValue ?? node.value ?? 0), 0);
      if (totalValue <= 0) {
        this.#fallback(this.labelsValue.empty || "Nothing to plan this month yet.");
        return;
      }
      layout = this.#generateSankeyData(nodes, links, width, height);
      chartWidth = this.lastChartWidth || width;
      chartHeight = this.lastChartHeight || height;
      this.#flattenColumns(layout, chartWidth, chartHeight);
      // Round 24 (E4): re-read AFTER the flatten — #manageRowGapsAndExtent
      // may have grown this.lastChartHeight in place (manage row-gap
      // layout). View mode: the pass early-returns, so this is a no-op.
      chartHeight = this.lastChartHeight || chartHeight;
    } catch (error) {
      console.error("plan-flow diagram failed to render", error);
      this.#fallback(`${this.labelsValue.error || "Couldn't draw the diagram — refresh the page."} [${error.name}: ${error.message}${error.stack ? ` | ${String(error.stack).split("\n").slice(1, 2).join("")}` : ""}`);
      return;
    }
    this.#draw(layout, chartWidth, chartHeight);
  }

  // Round 16 (owner note A) + 16.6: the layout starts from the DESIGN
  // height — the wrapper's min-height (the fixed 480px the page sets) —
  // not the clientHeight: the MANAGE chart is now LOCKED to the container
  // (no growth), but the guard stays (a non-locked clientHeight would leak
  // into the next layout and pin VIEW to it). Falls back to clientHeight
  // when no layout engine exists (harnesses).
  #designHeight() {
    try {
      const css = typeof getComputedStyle === "function" ? getComputedStyle(this.element) : null;
      const min = css ? Number.parseFloat(css.minHeight) : Number.NaN;
      if (Number.isFinite(min) && min >= 100) return min;
    } catch { /* no layout engine (headless harness) */ }
    return this.element.clientHeight;
  }

  // Issue 10: a mode toggle that landed while a draw was in flight applies
  // once the current draw commits (#draw hands off the live tween frame, so
  // a back-to-back re-render tweens cleanly).
  #flushModePending() {
    // Round 33: a view or unit flip that landed while a draw was in flight
    // applies here too (same mechanism as the mode pending above — one
    // re-render honors all the pending state).
    const modePending = this.modePending;
    const viewOrUnitPending = this.viewPending || this.unitPending;
    if (!modePending && !viewOrUnitPending) return;
    this.modePending = false;
    this.viewPending = false;
    this.unitPending = false;
    if (viewOrUnitPending) this.#morphRerender();
    else this.#rerenderForMode();
  }

  // Round 33 (spec 3): the Per Paycheck <-> Per Month toggle — IN PLACE.
  // Same house mechanism as the mode toggle (re-build + re-layout + TWEEN,
  // no reload, no re-fetch), PRESERVING the current Manage/View sizing mode
  // (the old full-reload links reset it to Manage), morphing ONLY the
  // dollar values (the value-label blur/fade below + the geometry tween).
  // ?view= persists through #syncFlowUrl; the server-rendered segments
  // honor ?view= on any full reload.
  #viewToggled(view) {
    const next = view === "monthly" ? "monthly" : "paycheck";
    if (next === this.viewValue) return;
    this.viewValue = next;
    this.#hideTooltip();
    this.#updateViewToggleUI(next);
    this.#syncFlowUrl();
    if (this.redrawInFlight) {
      // A draw is in flight: the view is applied once it completes.
      this.viewPending = true;
      return;
    }
    this.#morphRerender();
  }

  // Round 33 (spec 2): the paycheck-unit kebab — IN PLACE (the capture-phase
  // document delegation intercepted the item links before Turbo). The unit
  // only matters in the paycheck view (the monthly view is identity), but
  // the choice persists and the values morph when the view is paycheck.
  #unitToggled(unit, item) {
    const next = unit === "family" ? "family" : "income";
    const previous = this.#unitName();
    this.unitValue = next;
    this.#hideTooltip();
    this.#updateUnitToggleUI(next);
    this.#closeUnitMenu(item);
    this.#syncFlowUrl();
    if (next === previous) return; // the check gutter already moved
    if (this.viewValue !== "paycheck") return; // monthly view: nothing to morph
    if (this.redrawInFlight) {
      this.unitPending = true;
      return;
    }
    this.#morphRerender();
  }

  // Mirror the DS::SegmentedControl contract client-side (plain buttons):
  // flip the active segment class + aria-pressed, exactly like
  // #updateModeToggleUI.
  #updateViewToggleUI(view) {
    document.querySelectorAll("[data-plan-flow-sankey-view]").forEach((segment) => {
      const active = segment.dataset.planFlowSankeyView === view;
      segment.classList.toggle("segmented-control__segment--active", active);
      segment.setAttribute("aria-pressed", String(active));
    });
  }

  // The kebab's selectable rows (DS::MenuItem `selected:` contract): flip
  // aria-checked and move the check icon to the selected row's gutter (the
  // gutter span is reserved fixed-width by the component; the icon node is
  // MOVED, never re-rendered — no markup hardcoded here).
  #updateUnitToggleUI(unit) {
    const items = Array.from(document.querySelectorAll("[data-plan-flow-sankey-unit]"));
    items.forEach((item) => {
      item.setAttribute("aria-checked", String(item.dataset.planFlowSankeyUnit === unit));
    });
    const gutters = items.map((item) => item.querySelector('span[aria-hidden="true"]'));
    const fromIndex = items.findIndex((item, i) => item.dataset.planFlowSankeyUnit !== unit && gutters[i] && gutters[i].querySelector("svg"));
    const toIndex = items.findIndex((item) => item.dataset.planFlowSankeyUnit === unit);
    if (fromIndex === -1 || toIndex === -1) return;
    const svg = gutters[fromIndex]?.querySelector("svg");
    if (svg && gutters[toIndex] && !gutters[toIndex].querySelector("svg")) {
      // appendChild MOVES the node out of its current gutter — no separate
      // removeChild (it would throw: the node is no longer a child there).
      gutters[toIndex].appendChild(svg);
    }
  }

  // The item click is INSIDE the DS--menu element, so its own outside-click
  // close never fires for a selection — close it the way its controller's
  // close() does (content hidden class + trigger aria-expanded).
  #closeUnitMenu(item) {
    const menuEl = item?.closest?.('[data-controller="DS--menu"]');
    if (!menuEl) return;
    const content = menuEl.querySelector('[data-DS--menu-target="content"]');
    const button = menuEl.querySelector('[data-DS--menu-target="button"]');
    if (content) content.classList.add("hidden");
    if (button) button.setAttribute("aria-expanded", "false");
  }

  // Round 33 (spec 2/3): persist ?view= + ?paycheck_unit= IN PLACE (the
  // house replaceUrl — no history entry, no request), keeping every other
  // param (e.g. ?income=) the page arrived with.
  #syncFlowUrl() {
    try {
      const url = new URL(window.location.href);
      url.searchParams.set("view", this.viewValue);
      url.searchParams.set("paycheck_unit", this.#unitName());
      if (url.toString() === window.location.href) return;
      replaceUrl(url.toString());
    } catch { /* non-browser harness: no URL to rewrite */ }
  }

  // The in-place value morph (spec 3): the house re-render mechanism
  // (re-build from this.graph + re-layout + TWEEN — no reload, no fetch)
  // plus the CSS value-label blur/fade (the wrapper class, removed after
  // the animation window; a fresh toggle re-adds it, so the animation
  // restarts on the next morph).
  #morphRerender() {
    this.element.classList.add("plan-flow-sankey--morphing");
    this.#rerenderForMode();
    window.clearTimeout(this.morphTimer);
    this.morphTimer = window.setTimeout(() => {
      this.element.classList.remove("plan-flow-sankey--morphing");
    }, 600);
  }

  // Monthly figures -> the view's scale (Per Paycheck divides by the
  // month's actual paycheck count — the house divisor). ROUND 33: the
  // FAMILY-unit closure — the income unit's per-source divisors live in
  // utils/plan_flow_sankey_unit (paycheckUnitScales); this is the legacy
  // composite every per-paycheck figure used before the unit existed, and
  // the fallback for unassigned allocations (no source bank to prorate).
  #scale(graph) {
    const count = this.viewValue === "paycheck" ? (graph.paycheck_dates?.length || 1) : 1;
    return (value) => Number(value || 0) / count;
  }

  // Round 33 (spec 1): the active Per-Paycheck unit name — "income" is the
  // DEFAULT (the server always renders the data attr; the normalization
  // keeps a missing attr on the default too).
  #unitName() {
    return this.unitValue === "family" ? "family" : "income";
  }

  #buildGraph(graph) {
    // Round 21 (T1, round 22): record the payload on the instance so the
    // Un-Allocated stub pass inside #flattenColumns (#placeUnallocatedNearTails,
    // round 22: gate-free — one rule for every plan) is stable however the
    // pipeline is driven: the three live re-render paths assign this.graph
    // the SAME object just before calling #buildGraph (idempotent), and
    // the test harnesses call #buildGraph/#flattenColumns directly via
    // ForTest aliases without ever setting this.graph.
    this.graph = graph;
    const scale = this.#scale(graph);
    // Round 33 (spec 1): the Per-Paycheck unit. `unit` is the per-source
    // scale closures for the active unit (income | family); when the income
    // unit is NOT active (family unit, or the monthly view) every closure
    // degrades to the EXACT legacy family scale, so pre-R33 values are
    // reproduced byte for byte. `scale` (the family-total closure) stays
    // for the unassigned allocations that have no source bank to prorate
    // over.
    const unit = paycheckUnitScales(graph, this.viewValue, this.#unitName());
    const { COLORS, VALUE_FLOOR } = this.constructor;

    const incomeNodes = (graph.incomes || [])
      .filter((income) => Number(income.total_month) > 0)
      .map((income) => ({
        id: `income:${income.id}`,
        sourceId: income.id,
        kind: "income",
        column: 0,
        name: income.name,
        color: COLORS.income,
        // Round 33 (spec 1): the Per-Paycheck unit — the income's monthly
        // share over THIS income's occurrence count (income unit) / the
        // family composite (family unit) / identity (monthly view).
        value: unit.income(income.id, income.total_month),
        // d3-sankey overwrites node.value with the (possibly fixedValue)
        // layout value; labels/tooltips need the currency figure, so keep it
        // on a side field the layout never touches.
        displayValue: unit.income(income.id, income.total_month),
        limit: income.limit_warning || null,
        label: true,
      }));
    // Incomes: stable flow-weighted order (amount desc), and that order is
    // the barycenter reference for the bank column.
    incomeNodes.sort((a, b) => b.value - a.value || String(a.name).localeCompare(String(b.name)));
    incomeNodes.forEach((node, index) => { node.sortKey = index; });

    // Un-Allocated (round 10): one pillar node PER INCOME, each carrying
    // only that income's no-leftover-edge remainder (its unallocated_month
    // from the payload — the split is already per-income server-side). The
    // old single shared node bundled every income's remainder, so its
    // ribbons crossed and overlapped; per-income nodes keep every ribbon on
    // its own lane (an income feeds only its own node, and the nodes stack
    // in the rendered income order, so nothing crosses). The sum of the
    // per-income values equals the old single-node total by construction.
    // Round 14 (issue 5b, owner 2026-11-04 sketch): the pillars own a
    // dedicated layer BETWEEN the incomes and the banks (rescinding the
    // round 11 bank-column placement, which drew the hatched ribbons across
    // the chart middle). Each pillar renders as a SMALL TAIL hanging off its
    // source income's bottom edge: #placeUnallocatedTails - run at the END
    // of #flattenColumns, AFTER the flat-top re-anchoring that undid the
    // round 10/11 pre-flatten shifts - sets the pillar's top edge at the
    // income's bottom edge and re-stacks the income's outgoing anchors so
    // the hatched band is LAST: it exits the bottom of the income's outflow
    // stack, below every income -> bank band, with zero crossings.
    const unallocatedNodes = [];
    incomeNodes.forEach((incomeNode) => {
      const row = (graph.incomes || []).find((income) => income.id === incomeNode.sourceId);
      const amount = Number(row?.unallocated_month || 0);
      if (amount > 0) {
        unallocatedNodes.push({
          id: `unallocated:${incomeNode.sourceId}`,
          sourceId: incomeNode.sourceId,
          kind: "unallocated",
          // Round 14: its own slot (1) between the incomes (0) and the banks
          // (2 in the four-slot layout). The x is fixed by d3-sankey from the
          // layer; the tail y is applied post-flatten by
          // #placeUnallocatedTails. A future sub-account column (round 14
          // issue 8) lands at 3+, so column 1 stays shift-safe.
          column: 1,
          name: this.labelsValue.unallocated || "Un-Allocated",
          color: COLORS.unallocated,
          // Round 33 (spec 1): this income's leftover in the Per Paycheck
          // unit (its own occurrence count divides it, not the family's).
          value: unit.income(incomeNode.sourceId, amount),
          displayValue: unit.income(incomeNode.sourceId, amount),
          label: true,
          // Round 14: the sortKey is assigned in the ordering section below
          // (rendered income order) so the pillars stack Kurt-above-Sammi in
          // their own layer; the hidden bridge (sortKey = income count)
          // sits after them in the same layer.
        });
      }
    });
    // Four x-slots (incomes | Un-Allocated pillars + hidden bridge | banks |
    // allocations) while any pillar exists, else the classic 3-column layout.
    // Round 14 (issue 5b): the pillars own the middle slot again; the hidden
    // bridge shares it (zero value, invisible) purely to keep the layer
    // count and the four-slot x layout.
    const fourCol = unallocatedNodes.length > 0;

    // Round 11 issue 8: the DEDICATED sub-account column. When any bank row
    // is a sub-account (sub_account true — the server set parent_account_id),
    // the layout gains a column BETWEEN the top-level banks and the
    // allocations — a sub-account is its own row there (a band from a parent
    // to a same-column child would have zero horizontal extent), and the
    // parent's fan-out (auto_transfer_target_ids, ordered = the diagram's
    // band order) draws one REAL band per target. The pillar layer (G's
    // round 5b tail placement) stays exactly where it is — column 1,
    // derived shift-safe — so:
    //   no pillars:    0 incomes | 1 banks | 2 sub-accounts | 3 alloc+anchor
    //   with pillars:  0 incomes | 1 pillars | 2 banks | 3 subs | 4 alloc
    // NO sub-accounts -> the columns collapse back and every computed value
    // below is identical to the pre-issue-8 layout (byte-identical).
    const hasSubAccounts = (graph.banks || []).some((bank) => bank.sub_account === true);
    const subAccountCol = fourCol ? 3 : 2;
    const allocationCol = fourCol ? (hasSubAccounts ? 4 : 3) : (hasSubAccounts ? 3 : 2);
    // The child's reservation base (dollars/month). The planner keeps the
    // fan-out transfer OUT of graph[:bands] (it is a RESERVATION on the
    // parent's post-allocation surplus, not an inflow movement), so the
    // payload carries no per-transfer flow: the JS derives each child's
    // monthly base from its required-mode plan allocations (value_cents).
    // A child with zero required allocations (the zero-base bucket) gets
    // base 0 -> its band renders at the 3px minBand floor (owner Q3).
    const fanoutBase = new Map();
    (graph.allocations || []).forEach((allocation) => {
      if (allocation.mode !== "required" || allocation.account_id == null) return;
      fanoutBase.set(allocation.account_id, (fanoutBase.get(allocation.account_id) || 0) + Number(allocation.value_cents || 0));
    });

    // Banks: the graph's banks plus in-plan accounts it does not touch yet
    // (added but not linked) — they sit at the value floor.
    const graphBanks = new Map((graph.banks || []).map((bank) => [bank.id, bank]));
    // Round 16 (owner note 3b): the chip's allowed slug set — the payload
    // root's available_bank_logos (nil-safe; empty when the payload does not
    // carry it). A chip NEVER draws a broken <img>: only a slug that is
    // present on the row AND in this set gets one.
    const availableBankLogos = new Set(
      (graph.available_bank_logos || [])
        .filter((row) => row && typeof row.slug === "string" && row.slug !== "")
        .map((row) => row.slug),
    );
    const bankNodes = [
      ...graphBanks.values(),
      // Round 7: the in-plan list is page-load state; a null id (an
      // unassigned allocation used to leak one) or a stale id must never
      // synthesize a phantom bank node.
      ...this.inPlanValue
        .filter((id) => id != null && !graphBanks.has(id))
        .map((id) => ({ id, inflow_month: "0.00", surplus_month: "0.00", inflow: [] })),
    ].map((bank) => {
      const isSubAccount = bank.sub_account === true;
      // Round 11 issue 8: a child node sits in the dedicated column and its
      // value is the scaled FAN-OUT inflow (the reservation base, same
      // paycheck scaling as banks) — its own-edge inflow still draws its own
      // income band; the #generateSankeyData floor pass grows the node to
      // cover both. Non-children keep the exact original expressions.
      // Round 33 (spec 1): the sub-account's fan-out reservation base in the
      // Per Paycheck unit — prorated over the PARENT bank's funders (the
      // parent's per-paycheck inflow ratio), family composite otherwise.
      const fanoutValue = unit.fromBank(bank.parent_account_id, fanoutBase.get(bank.id) || 0);
      return {
        id: `bank:${bank.id}`,
        sourceId: bank.id,
        kind: "bank",
        subAccount: isSubAccount,
        parentAccount: bank.parent_account_id,
        parentName: isSubAccount && bank.parent_account_id != null ? (this.accountsValue[bank.parent_account_id] || "Account") : undefined,
        auto_transfer_target_ids: bank.auto_transfer_target_ids || [],
        labelPrefix: isSubAccount ? "↳ " : undefined,
        column: isSubAccount ? subAccountCol : fourCol ? 2 : 1,
        name: this.accountsValue[bank.id] || "Account",
        // Round 16 (owner note 4): the LABEL-ONLY display name — the account
        // number suffix ("SoFi Savings [8979]"). d.name stays plain for the
        // sorts, the dialog lookups and the planner identity; the suffix
        // lives here so the measured label boxes (floors) adapt to the
        // FINAL text automatically.
        labelName: bank.last4 != null && String(bank.last4) !== ""
          ? `${this.accountsValue[bank.id] || "Account"} [${bank.last4}]`
          : undefined,
        // Round 16 (owner note 3b): the chip slug — nil when absent OR not
        // in the payload's available set (never a broken <img>).
        logoSlug:
          typeof bank.logo === "string" && bank.logo !== "" && availableBankLogos.has(bank.logo)
            ? bank.logo
            : null,
        // Round 16.6: the DEFAULT kind icon, drawn when no logo resolves
        // (never both — a selected logo always wins).
        kindIcon: this.constructor.kindIconKey(this.constructor.bankKind(bank)),
        // Round 16 (owner note 3a): the kind fill (nil-safe — the current
        // grey when the payload carries no kind/plan_role on the row).
        color: this.constructor.bankKindColor(this.constructor.bankKind(bank)),
        // Round 33 (spec 1): the bank's Per Paycheck figure = each funding
        // income's resolved monthly inflow share / that income's occurrence
        // count (income unit) — the family composite (the old /total
        // paychecks) otherwise. The surplus keeps the same per-paycheck
        // share of the inflow (the source bank's ratio).
        value: isSubAccount
          ? fanoutValue
          : unit.bank(bank),
        surplus: unit.surplus(bank.id, Math.max(Number(bank.surplus_month), 0)),
        fixedValue: 0,
        // Round 34 (spec 4): the LEFTOVER flag — true when ANY inflow row on
        // this bank is mode "leftover" (the per-paycheck remainder lands
        // here). Drives the leftover icon in the bank node's label
        // (#writeLabelText). The flag is DERIVED client-side from the
        // payload's additive inflow.mode field (no new endpoint).
        leftover: (bank.inflow || []).some((row) => row.mode === "leftover"),
        label: true,
      };
    });
    bankNodes.forEach((bank) => {
      bank.fixedValue = Math.max(bank.value, VALUE_FLOOR);
      bank.displayValue = bank.value;
    });

    // Allocations. Unassigned rows (owner round 3, R3: the source bank was
    // removed from the plan) take no part in the resolution — they sit in
    // the allocations column at the minimum height with the red "No
    // Assignment" marker and NO flow band; the value shown is the monthly
    // figure (so the row reads like its assigned siblings).
    const allocationNodes = (graph.allocations || []).map((allocation) => {
      const unassigned = allocation.status === "unassigned" || allocation.account_id == null;
      // Round 25 (Item 2): a target allocation DRESSES the target account —
      // the node label is the account identity and the chip is the
      // account's logo (validated against the payload's available set, the
      // bank's rule) with the kind icon as fallback (the bank's "always
      // chip" rule). Plain rows carry neither field, so hasChip stays
      // false and their rendering is untouched (the byte-identity proof).
      const dressed = allocation.target_account_name != null;
      return {
        id: `allocation:${allocation.id}`,
        sourceId: allocation.id,
        nodeType: "allocation",
        account: allocation.account_id,
        kind: allocation.kind,
        column: allocationCol, // issue 8: 4 with pillars+subs, 3 without pillars+subs, 2 classic
        name: dressed ? allocation.target_account_name : allocation.name,
        // Round 25 (Item 2): the dressed account's chip slug — nil-safe,
        // the bank's rule (present on the row AND in the payload set).
        logoSlug:
          dressed &&
          typeof allocation.target_account_logo === "string" &&
          allocation.target_account_logo !== "" &&
          availableBankLogos.has(allocation.target_account_logo)
            ? allocation.target_account_logo
            : null,
        kindIcon: dressed ? this.constructor.kindIconKey(allocation.kind) : null,
        // Round 16 (owner note 5): the linked category's color wins when
        // present (the node fill AND the incoming band's gradient end —
        // #joinLinks stops run source.color -> target.color); nil / non-hex
        // falls back to the pre-round-16 kind colors exactly.
        color: this.constructor.validHex(allocation.category_color) ??
          (allocation.kind === "debt"
            ? COLORS.debt
            : allocation.kind === "savings"
              ? COLORS.savings // R4: savings is blue
              : allocation.kind === "fun_money"
                ? COLORS.fun_money // Round 31A (C7): the green default
                : COLORS.bill), // bill = spending amber
        // NOTE: the graph JSON's value_cents/got_month are DISPLAY dollars
        // (the planner runs money() on the raw cents) — do NOT re-divide.
        // Round 33 (spec 1): the settled figure in the Per Paycheck unit
        // (the source bank's per-paycheck inflow ratio — a bank with no
        // inflow rows, or an unassigned row with no source bank, keeps the
        // family scale).
        value: unassigned
          ? scale(allocation.value_cents || 0)
          : unit.fromBank(allocation.account_id, allocation.got_month),
        shortfall: unit.fromBank(allocation.account_id, allocation.shortfall_month),
        overPlanned: allocation.over_planned === true,
        unassigned,
        label: true,
      };
    });
    allocationNodes.forEach((node) => {
      node.displayValue = node.value;
    });

    // The surplus/savings line: one node per bank with a positive residual.
    const surplusNodes = [];
    bankNodes.forEach((bank) => {
      if (bank.surplus > 0) {
        const inflowRows = graphBanks.get(bank.sourceId)?.inflow || [];
        surplusNodes.push({
          id: `surplus:${bank.sourceId}`,
          sourceId: bank.sourceId,
          nodeType: "surplus",
          kind: "surplus",
          column: allocationCol, // issue 8: same column as the allocations
          name: this.labelsValue.surplus || "Surplus",
          color: COLORS.surplus,
          value: bank.surplus,
          displayValue: bank.surplus,
          inflowIncomeIds: [...new Set(inflowRows.map((row) => row.income_id))],
          label: true,
        });
      }
    });

    const links = [];

    // Income -> bank bands aggregated per (income, bank) pair.
    const pairTotals = new Map();
    (graph.banks || []).forEach((bank) => {
      (bank.inflow || []).forEach((row) => {
        const key = `${row.income_id}|${bank.id}`;
        pairTotals.set(key, (pairTotals.get(key) || 0) + Number(row.amount));
      });
    });
    pairTotals.forEach((amount, key) => {
      if (amount <= 0) return;
      const [incomeId, bankId] = key.split("|");
      // Round 33 (spec 1): the band is this income's resolved monthly inflow
      // over ITS occurrence count (income unit) — family composite
      // otherwise. Conservation holds: the income node and its bands share
      // the same per-income divisor.
      links.push({ source: `income:${incomeId}`, target: `bank:${bankId}`, value: unit.income(incomeId, amount) });
    });

    // Bank -> allocation (the source bank is the allocation's account_id).
    // Unassigned rows (R3) have no source bank -> no band. Round 9: every
    // assigned row's band carries the minBand flag so the post-layout floor
    // pass keeps it visible at MIN_BAND_WIDTH even when the flow is $0 (the
    // bank has no inflow yet) — the diagram always shows which bank feeds
    // which allocation.
    allocationNodes.forEach((allocation) => {
      if (allocation.account == null) return;
      // Round 26 (item 4): a dressed account (target allocation) no longer
      // holds a bank row — the planner excludes it from graph.banks, and the
      // in-plan list never synthesizes it (it has no plan marker of its own
      // beyond the allocation). A band into a bank node that does not exist
      // would dangle (d3-sankey throws on the unknown id -> the visible
      // fallback). Skip the band; the allocation's source keeps drawing its
      // other bands and the dressed node stays reachable through them.
      const sourceId = allocation.account;
      if (!graphBanks.has(sourceId) && !this.inPlanValue.includes(sourceId)) return;
      links.push({ source: `bank:${allocation.account}`, target: allocation.id, value: allocation.value, minBand: true });
    });

    // Bank -> surplus (the green line).
    surplusNodes.forEach((surplus) => {
      links.push({ source: `bank:${surplus.sourceId}`, target: surplus.id, value: surplus.value });
    });

    // Round 11 issue 8: the fan-out. ONE REAL SANKEY LINK per target:
    // parent -> sub-account, value = the child's scaled reservation base
    // (monthly transfer intent; same paycheck scaling as banks), minBand so
    // an unsatisfied / zero-base bucket still shows its wiring at the 3px
    // floor. The parent's right-edge band order = its target-array order =
    // the child ROW order (the sortKey below) -> no crossings. A target
    // that has no row (off-plan) draws nothing; a parent that is itself a
    // sub-account (a depth-2 chain, which the dialog cannot create but a
    // two-step save can) has no legal column to band across, so its child
    // renders a floor row in the sub-account column.
    const fanoutTargetChildren = new Set();
    if (hasSubAccounts) {
      bankNodes.forEach((parent) => {
        if (parent.subAccount) return; // only top-level banks are fan-out sources
        (parent.auto_transfer_target_ids || []).forEach((targetId) => {
          const child = bankNodes.find((bank) => bank.subAccount && bank.sourceId === targetId);
          if (!child) return;
          fanoutTargetChildren.add(targetId);
          // Round 33 (spec 1): same Per Paycheck unit as the child's node
          // value (the parent's per-paycheck inflow ratio).
          links.push({ source: parent.id, target: child.id, value: unit.fromBank(parent.id, fanoutBase.get(targetId) || 0), minBand: true });
        });
      });
    }

    // Un-Allocated: hatched ribbons, one per income, into its OWN pillar
    // node (round 10). The target-side order follows the RENDERED income
    // order (bigger income on top — the pillars stack in that same order),
    // so each ribbon runs from its income to the node at the same row and
    // the ribbons cannot cross each other or share a target (same rule as
    // the bank -> allocation fan-out).
    const hatchedLinks = [];
    if (fourCol) {
      incomeNodes.forEach((incomeNode) => {
        const row = (graph.incomes || []).find((income) => income.id === incomeNode.sourceId);
        const amount = Number(row?.unallocated_month || 0);
        if (amount > 0) {
          // Round 33 (spec 1): matches the pillar node's own value (the
          // income's per-paycheck leftover).
          hatchedLinks.push({ source: incomeNode.id, target: `unallocated:${incomeNode.sourceId}`, value: unit.income(incomeNode.sourceId, amount), hatched: true });
        }
      });
    }

    // Layer-count guarantee: d3-sankey derives the layer count from link
    // depths (r = maxDepth + 1) and nodeAlign pins each node to its `column`,
    // so zero-value links pin the depths. With the Un-Allocated pillar the
    // layout is 4 layers (incomes | unallocated | banks | allocations): a
    // hidden bridge at layer 1 (fed by a zero edge from the top income)
    // gives every bank a depth-2 path, and each bank's zero edge to a hidden
    // anchor pins depth 3. Without the pillar the classic 3-layer skeleton
    // applies: isolated banks take a zero edge from an income (or a
    // synthetic root when no income exists) plus a zero edge to the anchor.
    // Round 11 issue 8: with sub-accounts the right edge sits one layer
    // further (5 layers with the pillar, 4 without) — the fan-out bands give
    // each targeted child depth parent+1 and the bank->anchor zero edge
    // (children included, pushed below) lifts the anchor to allocationCol;
    // untargeted children get a zero-value placeholder from a top-level
    // bank (pushed after the loop) so the layer count still holds.
    let anchorNode = null;
    let rootNode = null;
    let bridgeNode = null;
    if (bankNodes.length > 0) {
      anchorNode = { id: "anchor", kind: "anchor", column: allocationCol, name: "", color: COLORS.bank, fixedValue: 0, label: false };
      if (incomeNodes.length === 0) {
        rootNode = { id: "root", kind: "root", column: 0, name: "", color: COLORS.bank, fixedValue: 0, label: false };
      }
      if (fourCol) {
        // The pillars imply at least one income; the root is the fallback
        // feeder if the data ever disagrees. Round 10: the bridge owns its
        // hidden slot (column 1 - the pillars' own layer, round 14) between
        // the incomes and the banks. Round 14 (issue 5b): the pillars need
        // no bridge zero link - the hatched income -> pillar link already
        // gives each pillar depth 1 (its layer, since nodeAlign pins the
        // column) and the round 11 bridge -> pillar links are dead weight.
        bridgeNode = { id: "bridge", kind: "bridge", column: 1, name: "", color: COLORS.bank, fixedValue: 0, label: false, sortKey: incomeNodes.length };
        links.push({ source: incomeNodes.length > 0 ? incomeNodes[0].id : "root", target: "bridge", value: 0 });
      }
      const bankHasFlow = (bank) =>
        [...pairTotals.entries()].some(([key, amount]) => key.endsWith(`|${bank.sourceId}`) && amount > 0);
      bankNodes.forEach((bank) => {
        if (fourCol) {
          // Every bank rides the depth-2 path through the bridge (zero
          // value: no band, no width — pure placement).
          links.push({ source: "bridge", target: bank.id, value: 0 });
        } else if (!bankHasFlow(bank)) {
          const spine = rootNode ? "root" : incomeNodes[0].id;
          links.push({ source: spine, target: bank.id, value: 0 });
        }
        links.push({ source: bank.id, target: "anchor", value: 0 });
      });
      // Round 11 issue 8: the depth pin for the sub-account column — one
      // zero-value placeholder per child its parent does NOT target (a
      // targeted child already has its real minBand band from the fan-out
      // pass above, and a second link on the same pair would collide the
      // #linkKey join). Source = the parent when it is a top-level bank
      // node, else the first top-level bank (parent row missing from the
      // payload — an off-plan parent), so the child's BFS depth is always
      // a top-level bank depth + 1 = the sub-account column.
      if (hasSubAccounts) {
        const topLevelBanks = bankNodes.filter((bank) => !bank.subAccount);
        bankNodes.forEach((child) => {
          if (!child.subAccount || fanoutTargetChildren.has(child.sourceId)) return;
          const parent = bankNodes.find((bank) => !bank.subAccount && bank.sourceId === child.parentAccount);
          const source = (parent || topLevelBanks[0])?.id;
          if (source) links.push({ source, target: child.id, value: 0 });
        });
      }
    }

    // --- Column ordering (owner review round 2, F1) ---------------------
    // Incomes keep the stable flow-weighted (amount desc) order. Banks are
    // placed by the value-weighted barycenter of their funding incomes, so a
    // bank fed only by the top income sits above a bank fed by the bottom
    // one (NAVY Auto Bills above NAVY Shared Save, not below it). Allocation
    // and surplus rows follow their source bank's position (enforced by the
    // barycenter sort below — owner follow-up 2026-10-30: the unsorted array
    // order let surplus blocks invert their source banks and cross bands).
    const incomeOrder = new Map(incomeNodes.map((node, index) => [node.id, index]));
    bankNodes.forEach((bank) => {
      let weight = 0;
      let sum = 0;
      pairTotals.forEach((amount, key) => {
        if (amount <= 0 || !key.endsWith(`|${bank.sourceId}`)) return;
        const incomeId = key.split("|")[0];
        const order = incomeOrder.get(`income:${incomeId}`);
        if (order === undefined) return;
        weight += amount;
        sum += amount * order;
      });
      bank.barycenter = weight > 0 ? sum / weight : incomeNodes.length / 2;
      bank.sortKey = bank.barycenter;
    });
    // Owner follow-up (2026-10-30, band overlap): bankOrder must reflect the
    // RENDERED bank order. d3-sankey applies nodeSort (barycenter, then name)
    // inside the layout, so indexing the array order (the graph's input
    // order) misplaces the allocation/surplus blocks whenever the two
    // orders differ — a misplaced block crosses its own source bands (the
    // Amex-surplus over Baby-Funds-surplus overlap in 2b-04). Sorting with
    // the exact nodeSort comparator keeps every column-2 block under its
    // source bank's row, so bands can no longer invert (and, with the
    // standard anchor ordering, no longer overlap).
    bankNodes.sort(
      (a, b) => a.barycenter - b.barycenter || String(a.name).localeCompare(String(b.name)),
    );
    // Round 11 issue 8: renderIndex = each bank's y-rank in its RENDER
    // layer. Top-level banks keep their barycenter order (integer ranks —
    // exactly the old bankOrder values when no sub-account exists, so the
    // classic layout stays byte-identical). A sub-account gets the exact
    // allocation-grouping formula off its parent's rank:
    //   sortKey = parentIdx + (childRank+1)/(childCount+1)
    // so the children stack directly under their parent row, in ROW ORDER
    // = the parent's target-array order (= the fan-out band order).
    // Using the rendered rank (not the merged bankNodes position, which
    // interleaves children by barycenter) keeps a child's allocation and
    // surplus blocks grouped under the child's own row.
    const renderIndex = new Map();
    let topLevelRank = 0;
    bankNodes.forEach((bank) => {
      if (!bank.subAccount) renderIndex.set(bank.id, topLevelRank++);
    });
    const childGroups = new Map();
    bankNodes.forEach((parent) => {
      if (parent.subAccount) return;
      const kids = (parent.auto_transfer_target_ids || [])
        .map((targetId) => bankNodes.find((bank) => bank.subAccount && bank.sourceId === targetId))
        .filter(Boolean);
      if (kids.length > 0) childGroups.set(parent.id, kids);
    });
    childGroups.forEach((kids, parentId) => {
      const parentIdx = renderIndex.get(parentId) ?? 0;
      kids.forEach((child, rank) => {
        const key = parentIdx + (rank + 1) / (kids.length + 1);
        child.sortKey = key;
        renderIndex.set(child.id, key);
      });
    });
    // Allocations: grouped under their source bank's row (the round-2
    // barycenter order) with VALUE-DESCENDING rank inside the bank, so the
    // bank -> allocation bands fan out without crossings (owner round 3,
    // R2: ordering that minimizes band crossings). Unassigned rows (R3)
    // sink below every bank's block in the allocations column.
    const perBank = new Map();
    allocationNodes.forEach((node) => {
      if (node.unassigned) return;
      const bankIdx = renderIndex.get(`bank:${node.account}`) ?? bankNodes.length;
      const list = perBank.get(bankIdx) || [];
      list.push(node);
      perBank.set(bankIdx, list);
    });
    perBank.forEach((list, bankIdx) => {
      list.sort((a, b) => b.value - a.value || String(a.name).localeCompare(String(b.name)));
      list.forEach((node, i) => {
        node.sortKey = bankIdx + (i + 1) / (list.length + 1); // < bankIdx + 1
      });
    });
    let unassignedIndex = 0;
    allocationNodes.forEach((node) => {
      if (node.unassigned) node.sortKey = bankNodes.length + 0.5 + unassignedIndex++;
    });
    // Surplus sits just past its bank's allocation block (frac < 1 always).
    surplusNodes.forEach((node) => {
      node.sortKey = (renderIndex.get(`bank:${node.sourceId}`) ?? bankNodes.length) + 1.0;
    });
    // Round 14 (issue 5b): the pillars stack in their OWN layer (column 1)
    // in rendered income order (Kurt above Sammi), so each hatched ribbon
    // keeps its own lane. The sortKey is the income index; the hidden
    // bridge (sortKey = incomeNodes.length) sits after the pillars in the
    // same layer (zero value, invisible). The d3 placement inside the layer
    // only needs a stable, crossing-free order - the tail y (top edge at
    // the source income's bottom edge) is applied post-flatten by
    // #placeUnallocatedTails, which is why the pre-flatten d3 y of the
    // pillars does not matter.
    unallocatedNodes.forEach((node, i) => {
      node.sortKey = i;
    });

    // Round 15 (owner note 1): the MANAGE value floors (the 1.5%
    // allocation/surplus sliver) are REMOVED — the manage minimums are the
    // label-supporting floors applied at the DRAW level (#applyManageFloors,
    // which covers every labelled node: incomes, banks, sub-accounts,
    // allocations, surplus, pillars).
    // A zero-value row would otherwise break the layout (d3 ky guard:
    // value 0 -> NaN heights); the $0.01 sliver keeps it placeable at a
    // true hairline — negligible, not a size floor. Round 16.7: applied in
    // BOTH modes — the MANAGE layout is the VIEW layout exactly (shared
    // path), so the graph must be mode-identical; the manage draw clamp
    // then lifts a zero-value row to its label floor (_fy0/_fy1/_fw).
    // Round 23 (note 2, owner reversal): real (value > 0) sub-pixel
    // allocation/surplus rows must stay VISIBLE rows (their label floor in
    // manage, a min drawn sliver in view) — but zero-value rows stay hidden
    // (the existing contract). d3 rewrites node.value to the 0.01 fixedValue
    // after layout, so `value <= 0` alone cannot distinguish them downstream
    // (same reason the banks carry _ghost, round 21 T5): mark the
    // pre-sliver zero rows here.
    allocationNodes.forEach((node) => {
      if (node.value <= 0) {
        node.fixedValue = VALUE_FLOOR;
        node._zeroRow = true;
      }
    });
    surplusNodes.forEach((node) => {
      if (node.value <= 0) {
        node.fixedValue = VALUE_FLOOR;
        node._zeroRow = true;
      }
    });
    // Round 21 T5: zero-flow banks got the same sliver (the 6c56edd bank-kind
    // clause was dropped in 1ef7aac). _ghost marks the pre-sliver zero banks
    // for #visibleNode: d3 rewrites node.value to the 0.01 fixedValue after
    // layout, so `value <= 0` alone would miss them downstream.
    bankNodes.forEach((node) => {
      if (node.value <= 0) {
        node.fixedValue = VALUE_FLOOR;
        node._ghost = true;
      }
    });

    const nodes = [
      ...incomeNodes,
      ...(rootNode ? [rootNode] : []),
      ...bankNodes,
      ...allocationNodes,
      ...surplusNodes,
      ...unallocatedNodes,
      ...(bridgeNode ? [bridgeNode] : []),
      ...(anchorNode ? [anchorNode] : []),
    ];

    return { nodes, links: [...links, ...hatchedLinks] };
  }

  #generateSankeyData(nodes, links, width, height) {
    const { EXTENT_MARGIN, HEADER_SPACE, NODE_WIDTH, NODE_PADDING, MIN_NODE_PADDING, MAX_PADDING_RATIO } = this.constructor;
    const availableHeight = height - HEADER_SPACE - EXTENT_MARGIN;
    const gaps = Math.max(nodes.length - 1, 1);
    const dynamicPadding = Math.min(NODE_PADDING, Math.floor((availableHeight * MAX_PADDING_RATIO) / gaps));

    // Algorithmic order: the hidden bridge shares the pillars' layer 1 slot
    // (sortKey = the income count, after the pillars) and the anchor sinks
    // to the bottom of its layer. Everything else uses the precomputed
    // sortKey (banks = barycenter of their funding incomes, allocations =
    // their source bank's position, incomes = flow-weighted, and the
    // Un-Allocated pillars = rendered income order inside their own layer —
    // round 14: the tail y is post-flatten), with a stable name tiebreak.
    const rank = (node) => (node.id === "anchor" ? 3 : 0);
    const nodeSort = (a, b) => {
      if (rank(a) !== rank(b)) return rank(a) - rank(b);
      const ak = a.sortKey ?? 0;
      const bk = b.sortKey ?? 0;
      if (ak !== bk) return ak - bk;
      return String(a.name).localeCompare(String(b.name));
    };

    const pad = Math.max(MIN_NODE_PADDING, dynamicPadding);
    // Round 16.8: the generator is a FACTORY parameterized by (W, Hh) —
    // both modes run the same d3-sankey pipeline once, at the container
    // size (the round 16/16.6 label-floor rescale and the round 16.7
    // min-width search are gone).
    const makeGenerator = (W, Hh) =>
      sankey()
        .nodeId((d) => d.id)
        .nodeWidth(NODE_WIDTH)
        .nodePadding(pad)
        .extent([
          [EXTENT_MARGIN, HEADER_SPACE],
          [W - EXTENT_MARGIN, Hh - EXTENT_MARGIN],
        ])
        .nodeAlign((node) => node.column)
        .nodeSort(nodeSort)
        .iterations(6);

    const runLayout = (W, Hh) => {
      const layout = makeGenerator(W, Hh)({ nodes: nodes.map((d) => ({ ...d })), links: links.map((d) => ({ ...d })) });
      layout.links.forEach((link, i) => { link.index = i; });
      return layout;
    };

    const layout = runLayout(width, height);

    // Contract history (rounds 15 -> 16.6 -> 16.7 -> 16.8): MANAGE
    // minimums = LABEL-SUPPORTING (owner verbatim A, round 15: "the flow
    // should be a minimum size that matches the minimum size of the labels
    // and then everything else just gets bigger so that it's all still
    // proportional..."). Round 16.6 retracted the grown height and locked
    // it to the container. Round 16.7: the label-floor rescale is GONE —
    // MANAGE layout = VIEW layout exactly (the strictly proportional d3
    // fit); the floors are a DRAW-level clamp only (#applyManageFloors at
    // the end of #flattenColumns). Round 16.8 (owner directive: "Let's
    // lock the Width again, just like the View"): the min-width search is
    // GONE — the MANAGE chart width is LOCKED at the container width,
    // exactly like VIEW (no horizontal scrolling; the wrapper's overflow-x
    // styles simply never trigger). Height stays locked at the container
    // (round 16.6). The manage layout IS the view layout (no rescale in
    // any mode); the node floors stay (drawn node height = max(layout, the
    // measured label floor) - the labels grow to the minimum size needed
    // so they are readable), the bands are STRICTLY PROPORTIONAL again
    // (drawn width = the layout width; the only surviving band floor is
    // the 3px Q3 visibility floor for zero-value minBand ribbons), and
    // labels may overlap where the container is tight (accepted per the
    // directive - the owner's reference screenshot has overlaps).
    const chartWidth = width;
    const chartHeight = height;
    // Round 16.8: the chart dimensions are the container size in BOTH
    // modes; the callers draw + flatten at these.
    this.lastChartWidth = chartWidth;
    this.lastChartHeight = chartHeight;
    // Round 10 issue 5's post-layout bottom shift lived here and is REMOVED
    // (round 11): #flattenColumns runs AFTER this method (both #doRedraw and
    // #graphUpdated call it) and re-anchors every column to the flat top, so
    // any pre-flatten pillar shift is undone on every draw (owner screenshot
    // 2026-11-01). Round 14 (issue 5b): the unallocated tail placement runs
    // at the END of #flattenColumns instead (#placeUnallocatedNearTails) - the
    // pillars keep their own layer by node ordering (see #buildGraph) and
    // the tail y is applied only after the flat-top re-anchoring it must
    // survive.
    return layout;
  }

  // ---- Drawing / animation (owner round 3, R1/R7) ------------------------
  // The SVG is PERSISTENT across mutations: one <path> per node id and one
  // band per (source -> target) pair, joined by key (no innerHTML reset —
  // the diagram is never destroyed or hidden). A mutation TWEENS the
  // geometry: a new node grows from zero height at its final position
  // (pushing the others, which slide), a removed node shrinks to zero, and
  // only AFTER the nodes settle do the new flow bands expand in. Any
  // render/animation exception surfaces as the visible #fallback.
  #draw(layout, width, height) {
    try {
      // A mid-flight tween hands off its live geometry as the new "from"
      // state BEFORE the anims are built (interrupted animations resume
      // seamlessly).
      const inFlight = this.rafId ? this.currentFrame : null;
      this.#cancelAnimation();
      if (inFlight) this.lastLayout = inFlight;

      const anims = this.#prepareDraw(layout, width, height);
      if (!this.lastLayout) {
        // First draw (fresh page load): render the final geometry directly.
        this.#applyGeometry(anims);
        this.#commitLayout(layout);
      } else {
        this.#animateTo(anims, layout);
      }
    } catch (error) {
      // Never leave the chart silently blank (owner rule, rounds 2+3).
      console.error("plan-flow diagram failed to render", error);
      this.#fallback(`${this.labelsValue.error || "Couldn't draw the diagram — refresh the page."} [${error.name}: ${error.message}${error.stack ? ` | ${String(error.stack).split("\n").slice(1, 2).join("")}` : ""}`);
    }
  }

  #prepareDraw(layout, width, height) {
    const { nodes, links } = layout;
    const { COLORS } = this.constructor;
    this.drawWidth = width;
    this.drawHeight = height;

    // Over-plan state (spec §6): RED on the flagged allocation (fun money)
    // or on the surplus line the flagged income feeds.
    const overTargets = new Set();
    (this.graph?.over_plans || []).forEach((over) => {
      if (over.target === "fun_money" && over.target_id) overTargets.add(`allocation:${over.target_id}`);
      if (over.target === "surplus") {
        nodes
          .filter((n) => n.kind === "surplus" && (n.inflowIncomeIds || []).includes(over.income_id))
          .forEach((n) => overTargets.add(n.id));
      }
    });
    nodes.forEach((node) => {
      if (overTargets.has(node.id) || node.overPlanned === true) {
        node.color = COLORS.over;
        node.over = true;
      }
    });

    this.#ensureSvg(width, height);
    if (!this.tooltip) {
      // Body-level like the house chart: absolute + pageX only lines up
      // with the document's origin.
      this.tooltip = createChartTooltip(document.body);
    }

    // ---- Anims: what moves from where to where --------------------------
    // Round 10: a per-income Un-Allocated pillar with a positive value gets
    // its label even as a sub-pixel sliver (the name must always show).
    const visible = nodes.filter((d) => this.#visibleNode(d));
    const visibleIds = new Set(visible.map((d) => d.id));
    const old = this.lastLayout;
    const dyingNodes = old ? old.nodes.filter((n) => n.drawn && !visibleIds.has(n.id)) : [];

    const nodeAnims = [
      ...visible.map((n) => {
        const o = old ? old.nodes.find((x) => x.id === n.id) : null;
        const cy = (n.y0 + n.y1) / 2;
        return {
          node: n,
          from: o ? { x0: o.x0, y0: o.y0, y1: o.y1 } : { x0: n.x0, y0: cy, y1: cy }, // new: grow from 0 at final y
          // Round 16.7: the tween target is the DRAWN rect (the manage
          // draw-level floor extension, _fy0/_fy1 — undefined in view, so
          // the view target is the plain layout geometry, byte-identical).
          to: { x0: n.x0, y0: n._fy0 ?? n.y0, y1: n._fy1 ?? n.y1 },
          dying: false,
          spawn: !o,
          el: null,
          labelEl: null,
          labelFinalOpacity: 1,
        };
      }),
      ...dyingNodes.map((o) => {
        const cy = (o.y0 + o.y1) / 2;
        return {
          node: o,
          from: { x0: o.x0, y0: o.y0, y1: o.y1 },
          to: { x0: o.x0, y0: cy, y1: cy }, // shrink to 0 at center
          dying: true,
          spawn: false,
          el: null,
          labelEl: null,
          labelFinalOpacity: 0,
        };
      }),
    ];

    const linkAnims = [];
    const currentKeys = new Set();
    links.forEach((l) => {
      const key = this.#linkKey(l);
      currentKeys.add(key);
      const o = old ? old.links.find((x) => x.key === key) : null;
      // Issue 10 (VIEW mode): a minBand hairline must survive its endpoint
      // going sub-pixel (e.g. the zero-base fan-out child row) — the band is
      // data the spec keeps visible. MANAGE is unaffected: no minBand link
      // has a dying endpoint there (every labelled row is floored to 22px).
      const endpointDying = dyingNodes.some((n) => n.id === l.source.id || n.id === l.target.id) && !l.minBand;
      linkAnims.push({
        link: l,
        key,
        sx1: l.source.x1,
        tx0: l.target.x0,
        from: o ? { y0: o.y0, y1: o.y1, width: o.width } : { y0: l.y0, y1: l.y1, width: 0 },
        // Round 16.7: the band tween target is the DRAWN thickness
        // (_fw, the manage draw-level floor — undefined in view, so the
        // view target is the plain layout width, byte-identical).
        to: { y0: l.y0, y1: l.y1, width: Math.max(1, l._fw ?? l.width) },
        dying: endpointDying,
        spawning: !o && !endpointDying, // fades in AFTER the nodes settle (R7)
        hatched: !!l.hatched,
        el: null,
      });
    });
    if (old) {
      old.links.forEach((o) => {
        if (currentKeys.has(o.key)) return;
        linkAnims.push({
          link: o,
          key: o.key,
          sx1: o.source?.x1 ?? 0,
          tx0: o.target?.x0 ?? 0,
          from: { y0: o.y0, y1: o.y1, width: o.width },
          to: { y0: o.y0, y1: o.y1, width: 0 },
          dying: true,
          removed: true, // not in the new layout: still in the DOM, fades out
          spawning: false,
          hatched: !!o.hatched,
          el: null,
        });
      });
    }

    this.#joinNodes(nodeAnims);
    this.#joinLinks(links, linkAnims);

    // Labels: name + mono amount (house typography) on the side facing the
    // chart middle; collision-hidden via the house label rule. Nodes with a
    // shortfall, over-plan, or the "No Assignment" marker keep their label
    // even when the bar is sub-pixel (error-state information, spec §6).
    const labelData = visible.filter((d) => this.#labelRule(d));
    const probe = this.labelLayer.append("g").style("visibility", "hidden");
    const labelBoxes = new Map();
    labelData.forEach((d) => {
      const g = probe.append("g");
      // Round 22 (N2): measure with the FINAL variant — a dense-column
      // allocation/surplus node is forced to the compact one-line label
      // (d._forceCompactLabel), so the box #placeLabel fits must be the
      // compact box.
      this.#writeLabelText(d, g.node(), (d.y0 + d.y1) / 2, d._forceCompactLabel === true ? true : null);
      // Round 19 (P2, owner round 18b): measure the <text> box ONLY — the
      // chip is drawn centered on the node bar (node geometry, not the
      // label's horizontal span), so it must not inflate the box that
      // #placeLabel's side-flip/scale and the view-mode hide set consume.
      const measured = g.node().querySelector("text") || g.node();
      const box = measured.getBBox();
      labelBoxes.set(d.index, box);
      // Round 10: measure the FULL label and place it so nothing clips —
      // the label flips to the opposite node side when the middle-facing
      // one overflows, and the font scales down as a last resort (sets
      // d._labelSide / d._labelScale for the final write in #joinLabels).
      this.#placeLabel(d, box.width, width);
    });
    probe.remove();
    // Round 10 issue 7 (owner permanent rule, 2026-11-01: "all labels show
    // unless I say otherwise"): MANAGE mode keeps NO collision-hide — every
    // real label draws; overlaps are accepted rather than hidden.
    // Issue 10 (View/Manage): VIEW mode is the exception the owner asked
    // for — the always-show rule yields to the dashboard-style
    // collision/value-threshold hide (the shared sankey_labels.mjs rule the
    // dashboard sankey uses; the measurement above feeds it, same shape as
    // the dashboard's own probe). Error-state labels (shortfall / over-plan
    // / No Assignment) still always show (the #isCritical exception below),
    // so nothing is hidden data-wise. The measurement also still runs in
    // MANAGE because #placeLabel consumes the box (side flip + 0.5x font
    // shrink keeps the full text inside the chart).
    const hidden = this.#hiddenLabelSet(labelData, labelBoxes, height);

    const labelledVisible = visible.filter((d) => this.#labelRule(d) || hidden.has(d.index));
    // Dying nodes that had a label get one to fade out with.
    const dyingLabelled = dyingNodes.filter((n) => n.drawn);
    const labelAnims = [
      ...labelledVisible.map((d) => {
        const anim = nodeAnims.find((a) => a.node.id === d.id);
        anim.labelFinalOpacity = hidden.has(d.index) && !this.#isCritical(d) ? 0 : 1;
        return anim;
      }),
      ...dyingLabelled.map((o) => nodeAnims.find((a) => a.node.id === o.id)),
    ];
    this.#joinLabels(labelAnims);

    // Amber limit badge on income nodes (spec §6: warning only).
    const badgeNodes = visible.filter((d) => d.limit && labelData.includes(d) && !hidden.has(d.index));
    const badgeDying = dyingNodes.filter((n) => n.limit);
    const badgeAnims = [...badgeNodes, ...badgeDying]
      .map((d) => nodeAnims.find((a) => a.node.id === d.id))
      .filter(Boolean);
    this.#joinBadges(badgeAnims);

    this.nodeSelection = this.nodeLayer.selectAll("path.planflow-node");
    this.linkSelection = this.linkLayer;

    return { nodeAnims, linkAnims, badgeAnims };
  }

  #labelRule(d) {
    // Round 10 issue 7 (owner permanent rule, 2026-11-01): every REAL node
    // shows its label regardless of pixel height; only the structural
    // nodes (root / bridge / anchor, label:false) stay silent. Sub-pixel
    // rows still go through the measured #placeLabel (side flip + 0.5x font
    // floor) so the full name + amount still fits.
    // Issue 10 (View/Manage): the rule itself is mode-independent — VIEW
    // mode hides via the dashboard-style collision set in #prepareDraw;
    // MANAGE via the always-show (empty) set.
    return d.label !== false;
  }

  // Error-state rows (spec §6): a shortfall, over-plan, or the "No
  // Assignment" marker. Their labels are never hidden, and issue 10 VIEW
  // mode keeps their sub-pixel node + hairline band drawn too.
  #isCritical(d) {
    return (
      (d.nodeType === "allocation" || d.nodeType === "surplus") &&
      (Number(d.shortfall || 0) > 0.005 || d.overPlanned || d.unassigned)
    );
  }

  // A node draws when it is labelled AND has a real pixel height — or when
  // it is an error-state row (issue 10 VIEW mode: shortfall / over-plan /
  // No Assignment rows keep their node + band + label even as sub-pixel
  // hairlines). MANAGE is unaffected: its floor passes already give every
  // such row a real height, so #isCritical is a no-op there.
  // Round 21 T5: zero-flow banks (sliver at layout, _ghost marker) draw as
  // hairlines in BOTH modes. _ghost, not a height test, carries them: d3
  // rewrites their value to the 0.01 sliver and the raw height stays
  // sub-pixel against the income-dominated scale, so in VIEW mode (where
  // _fy0/_fy1 are undefined) only the marker can gate them in. Real-flow
  // banks additionally pass when the manage label floor (_fy0/_fy1, set by
  // #applyManageFloors) lifts a sub-pixel height to >= 1.
  // Round 23 (note 2, owner reversal): REAL (value > 0) sub-pixel
  // allocation/surplus rows pass the same postFloor test — in MANAGE their
  // _fy label floor (set by #applyManageFloors for every labelled node)
  // lifts them to a visible ~20px row WITH its text label; in VIEW the
  // min drawn sliver (#applyViewRowSlivers, 3px symmetric around the
  // layout center) lifts them to a visible row while their text label
  // keeps following the existing view hide rule. _zeroRow (set next to the
  // 0.01 fixedValue, same pattern as _ghost) keeps ZERO-VALUE
  // allocation/surplus rows hidden — the unscoped post-floor test would
  // resurrect them in MANAGE (their _fy floors clear 1px) but not in
  // VIEW, an unrequested mode-visibility change. The label:false
  // root/bridge/anchor nodes stay excluded by the gate above.
  #visibleNode(d) {
    const postFloor = (d._fy1 ?? d.y1) - (d._fy0 ?? d.y0);
    return (
      d.label !== false &&
      (d.y1 - d.y0 >= 1 ||
        (d.kind === "bank" && (d._ghost || postFloor >= 1)) ||
        ((d.nodeType === "allocation" || d.nodeType === "surplus") &&
          !d._zeroRow && postFloor >= 1) ||
        this.#isCritical(d) ||
        (d.kind === "unallocated" && d.value > 0))
    );
  }

  // Issue 10 (View/Manage): the label-hide set. MANAGE keeps the round-10
  // issue-7 always-show rule — an empty set (every real label draws;
  // overlaps are accepted rather than hidden). VIEW yields to the
  // dashboard-style collision/value-threshold hide: the shared
  // sankey_labels.mjs rule the dashboard sankey uses, fed the measured
  // boxes (keyed by node.index, same shape as the dashboard's own probe)
  // and the draw height. #isCritical rows stay shown downstream.
  #hiddenLabelSet(labelData, labelBoxes, height) {
    return this.mode === "view"
      ? hiddenSankeyLabels(labelData, {
          height,
          minSpacing: this.constructor.MIN_LABEL_SPACING,
          labelBoxes,
        })
      : new Set();
  }

  // A solid band draws when it has real width, is a minBand link (issue 10
  // VIEW mode: zero-value unsatisfied-bucket hairlines — the floor pass is
  // skipped, so the stroke floors to the 1px hairline in #setLinkGeom /
  // #applyGeometry), or is a removed band fading out. MANAGE is unaffected:
  // its floor pass gives every minBand link a real width >= 3.
  #solidLink(l, isRemoved) {
    return !l.hatched && (l.width > 0 || l.minBand || isRemoved(l));
  }

  #ensureSvg(width, height) {
    let svg = this.svg;
    if (!svg) {
      svg = d3
        .select(this.element)
        .append("svg")
        .attr("role", "img")
        .attr("aria-label", "Paycheck flow planning diagram");
      this.svg = svg;
      this.defs = svg.append("defs");
      // Crosshatch for the Un-Allocated ribbon (spec §6: green -> half-tone).
      const pattern = this.defs
        .append("pattern")
        .attr("id", `planflow-${this.chartId}-hatch`)
        .attr("patternUnits", "userSpaceOnUse")
        .attr("width", 8)
        .attr("height", 8)
        .attr("patternTransform", "rotate(45)");
      pattern
        .append("line")
        .attr("x1", 0).attr("y1", 4).attr("x2", 8).attr("y2", 4)
        .attr("stroke", this.constructor.COLORS.bank).attr("stroke-width", 1.2).attr("opacity", 0.45);
      pattern
        .append("line")
        .attr("x1", 4).attr("y1", 0).attr("x2", 4).attr("y2", 8)
        .attr("stroke", this.constructor.COLORS.bank).attr("stroke-width", 1.2).attr("opacity", 0.45);
      this.hatchId = `planflow-${this.chartId}-hatch`;
      // Round 20 (T3, owner round 20 drawing): the Un-Allocated PILLAR
      // fades into transparency - a vertical grey fade (userSpaceOnUse,
      // y1/y2 track the drawn pillar in #setNodeGeom) under the same
      // crosshatch pattern: "the Cross-hatch, into transparency".
      const uaFade = this.defs
        .append("linearGradient")
        .attr("id", this.#uaFadeGradientId())
        .attr("gradientUnits", "userSpaceOnUse")
        .attr("x1", 0)
        .attr("x2", 0);
      uaFade
        .append("stop")
        .attr("offset", "0%")
        .attr("stop-color", this.constructor.COLORS.unallocated)
        .attr("stop-opacity", 0.5);
      uaFade
        .append("stop")
        .attr("offset", "100%")
        .attr("stop-color", this.constructor.COLORS.unallocated)
        .attr("stop-opacity", 0.05);
      this.linkLayer = svg.append("g").attr("fill", "none");
      this.nodeLayer = svg.append("g");
      this.labelLayer = svg.append("g");
    }
    svg.attr("width", width).attr("height", height);
  }

  #linkKey(link) {
    return `${link.source.id}__${link.target.id}`;
  }

  #gradientIdFor(key) {
    return `planflow-${this.chartId}-g-${key.replace(/[^a-zA-Z0-9]/g, "_")}`;
  }

  // Round 20 (T3): the Un-Allocated pillar fade-gradient id (pure - the
  // draw path AND the headless tests derive it without a live SVG).
  #uaFadeGradientId() {
    return `planflow-${this.chartId ?? 0}-uafade`;
  }

  // Round 20 (T3, owner round 20 drawing): the node fill - the Un-Allocated
  // pillar is the cross-hatch fading gradient (the solid #9E9E9E rect is
  // gone); every other node keeps its flat color.
  #nodeFill(d) {
    return d.kind === "unallocated" ? `url(#${this.#uaFadeGradientId()})` : d.color;
  }

  // Per-link gradient band (house pattern: userSpaceOnUse stops, 30% node
  // colors) — created/updated in place so bands keep their identity.
  #updateGradient(id, x1, x2, sourceColor, targetColor) {
    let gradient = this.defs.select(`#${id}`).node();
    if (!gradient) {
      const g = this.defs.append("linearGradient").attr("id", id).attr("gradientUnits", "userSpaceOnUse");
      g.append("stop").attr("offset", "0%");
      g.append("stop").attr("offset", "100%");
      gradient = g.node();
    }
    d3.select(gradient).attr("x1", x1).attr("x2", x2);
    d3.select(gradient).select("stop[offset='0%']").attr("stop-color", d3.color(sourceColor).copy({ opacity: 0.3 }));
    d3.select(gradient).select("stop[offset='100%']").attr("stop-color", d3.color(targetColor).copy({ opacity: 0.3 }));
  }

  #joinNodes(nodeAnims) {
    const isInteractive = (d) =>
      d.id.startsWith("income:") || d.id.startsWith("bank:") || d.id.startsWith("allocation:");
    const sel = this.nodeLayer
      .selectAll("path.planflow-node")
      .data(nodeAnims.map((a) => a.node), (d) => d.id)
      .join("path")
      .attr("class", "planflow-node")
      // Round 20 (T3): the Un-Allocated pillar fill is the cross-hatch
      // fading gradient (see #nodeFill); every other node keeps its color.
      .attr("fill", (d) => this.#nodeFill(d))
      .attr("stroke", (d) => (d.overPlanned ? this.constructor.COLORS.over : "none"))
      .attr("stroke-width", (d) => (d.overPlanned ? 2.5 : 0))
      .attr("cursor", (d) => (isInteractive(d) ? "pointer" : "default"))
      .attr("tabindex", (d) => (isInteractive(d) ? 0 : -1))
      .attr("role", "button")
      .on("click", (event, d) => this.#openNodeDialog(d))
      .on("keydown", (event, d) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          this.#openNodeDialog(d);
        }
      })
      // Round 20 (T2): the tooltip shows IMMEDIATELY on enter (previously
      // only on the first mousemove) and hides on leave via #hover.
      .on("mouseenter", (event, d) => {
        this.#hover(d, true);
        this.#moveTooltip(event, d);
      })
      .on("mousemove", (event, d) => this.#moveTooltip(event, d))
      .on("mouseleave", () => this.#hover(null, false));
    const els = sel.nodes();
    nodeAnims.forEach((a, i) => {
      a.el = els[i];
      // Round 20 (T3): the Un-Allocated pillar carries a SECOND path -
      // the existing crosshatch pattern over the fading gradient fill
      // ("the Cross-hatch, into transparency"). The overlay is a
      // sibling AFTER the node path (same <d>, pointer-events none) and
      // is re-used across draws (it is not part of the planflow-node
      // join, so the d3 join never retires it).
      a.hatchEl = null;
      if (a.node.kind !== "unallocated") return;
      const prev = els[i].nextSibling;
      if (prev && prev.nodeType === 1 && prev.classList && prev.classList.contains("planflow-node-ua-hatch")) {
        a.hatchEl = prev;
      } else {
        const overlay = document.createElementNS("http://www.w3.org/2000/svg", "path");
        overlay.setAttribute("class", "planflow-node-ua-hatch");
        overlay.setAttribute("fill", `url(#${this.hatchId})`);
        overlay.setAttribute("pointer-events", "none");
        els[i].parentNode.insertBefore(overlay, els[i].nextSibling);
        a.hatchEl = overlay;
      }
    });
    // Round 21 T6: an invisible enlarged hit target sits BEHIND the bars
    // of the interactive nodes (min 22 x 28px, centered on the bar, set in
    // #setNodeGeom) so sub-pixel bars (ghost zero-flow banks) stay
    // clickable. Each rect is inserted immediately before its node path,
    // so the bar (topmost) wins the hit test wherever they overlap; the
    // Un-Allocated hatch overlay (pointer-events none) never blocks either.
    const interactiveAnims = nodeAnims.filter((a) => isInteractive(a.node));
    const hitSel = this.nodeLayer
      .selectAll("rect.planflow-node-hit")
      .data(interactiveAnims.map((a) => a.node), (d) => d.id)
      .join("rect")
      .attr("class", "planflow-node-hit")
      .attr("fill", "transparent")
      .attr("stroke", "none")
      .style("cursor", "pointer")
      .on("click", (event, d) => this.#openNodeDialog(d))
      .on("mouseenter", (event, d) => {
        this.#hover(d, true);
        this.#moveTooltip(event, d);
      })
      .on("mousemove", (event, d) => this.#moveTooltip(event, d))
      .on("mouseleave", () => this.#hover(null, false));
    const hitEls = hitSel.nodes();
    interactiveAnims.forEach((a, i) => {
      a.hitEl = hitEls[i];
      if (a.el && hitEls[i] && hitEls[i].parentElement === a.el.parentElement) {
        a.el.parentNode.insertBefore(hitEls[i], a.el);
      }
    });
  }

  // Solid bands (house .sankey-link) + the hatched Un-Allocated ribbons.
  // Data = current links PLUS removed links (still in the DOM) so they can
  // shrink out; d3's join retires them from the DOM after the tween.
  #joinLinks(links, linkAnims) {
    const animByKey = new Map(linkAnims.map((a) => [a.key, a]));
    // Data = the current links PLUS the removed ones (still in the DOM from
    // the previous draw) so they can shrink out; d3's join retires them.
    const allLinks = [...links, ...linkAnims.filter((a) => a.removed).map((a) => a.link)];
    const COLORS = this.constructor.COLORS;
    const isRemoved = (l) => animByKey.get(this.#linkKey(l))?.removed === true;

    const solid = allLinks.filter((l) => this.#solidLink(l, isRemoved));
    solid.forEach((l) => {
      if (isRemoved(l)) return; // a dead band keeps its last gradient
      this.#updateGradient(this.#gradientIdFor(this.#linkKey(l)), l.source.x1, l.target.x0, l.source.color, l.target.color);
    });
    const solidSel = this.linkLayer
      .selectAll("path.sankey-link")
      .data(solid, (d) => this.#linkKey(d))
      .join("path")
      .attr("class", "sankey-link")
      .attr("stroke", (d) => `url(#${this.#gradientIdFor(this.#linkKey(d))})`);
    // d3 .each passes (d, i) — the element is NOT an argument; keep the
    // node list to bind anim.el in datum order.
    const solidEls = solidSel.nodes();
    solidSel.each((d, i) => {
      const anim = animByKey.get(this.#linkKey(d));
      if (anim) anim.el = solidEls[i];
    });

    const hatched = allLinks.filter((l) => l.hatched && (l.width > 0 || isRemoved(l)));
    hatched.forEach((l) => {
      if (isRemoved(l)) return;
      l._hatchGrad = `planflow-${this.chartId}-hg-${this.#linkKey(l).replace(/[^a-zA-Z0-9]/g, "_")}`;
      this.#updateGradient(l._hatchGrad, l.source.x1, l.target.x0, COLORS.income, COLORS.unallocated);
    });
    const ribbonSel = this.linkLayer
      .selectAll("g.planflow-ribbon")
      .data(hatched, (d) => this.#linkKey(d))
      .join((enter) => {
        const g = enter.append("g").attr("class", "planflow-ribbon");
        g.append("path").attr("class", "sankey-hatched ribbon-fill");
        g.append("path").attr("class", "sankey-hatched ribbon-hatch");
        return g;
      });
    ribbonSel
      .select("path.ribbon-fill")
      .attr("fill", (d) => `url(#${d._hatchGrad || this.#gradientIdFor(this.#linkKey(d))})`);
    ribbonSel
      .select("path.ribbon-hatch")
      .attr("fill", `url(#${this.hatchId})`);
    const ribbonEls = ribbonSel.nodes();
    ribbonSel.each((d, i) => {
      const anim = animByKey.get(this.#linkKey(d));
      if (anim) anim.el = ribbonEls[i];
    });
  }

  #joinLabels(labelAnims) {
    const uniq = [...new Map(labelAnims.map((a) => [a.node.id, a])).values()];
    const sel = this.labelLayer
      .selectAll("g.planflow-label")
      .data(uniq.map((a) => a.node), (d) => d.id)
      .join("g")
      .attr("class", "planflow-label")
      .attr("data-node", (d) => d.id);
    // Round 20 (T2): the LABEL is a hover target too - the owner's stuck
    // tooltip happened on the labels (the node shapes alone hid nothing).
    // Enter/move show the same node tooltip; leave hides it IMMEDIATELY
    // via #hover(null,false) -> #hideTooltip. Hidden labels (the view-mode
    // hide path sets the group opacity to 0 in #setLabelGeoms) are never
    // hover targets: the guard reads the live opacity attribute at event
    // time, so it follows the fade/spawn/dying tweens too.
    const labelVisible = (event) =>
      Number(event.currentTarget.getAttribute("opacity") ?? "1") > 0.01;
    sel
      .on("mouseenter", (event, d) => {
        if (!labelVisible(event)) return;
        this.#hover(d, true);
        this.#moveTooltip(event, d);
      })
      .on("mousemove", (event, d) => {
        if (!labelVisible(event)) return;
        this.#moveTooltip(event, d);
      })
      .on("mouseleave", () => this.#hover(null, false))
      // Round 21 T6: the label text is a first-class hit target for the
      // interactive node kinds (mirrors the #joinNodes bar binding); the
      // labelVisible guard keeps hidden/fading labels inert.
      .on("click", (event, d) => {
        if (!labelVisible(event)) return;
        if (
          !d.id.startsWith("income:") &&
          !d.id.startsWith("bank:") &&
          !d.id.startsWith("allocation:")
        ) {
          return;
        }
        this.#openNodeDialog(d);
      });
    const els = sel.nodes();
    uniq.forEach((a, i) => {
      a.labelEl = els[i];
      // Content is static per node — rebuild in place (cheap at these
      // counts) with the final geometry; position animates per frame.
      // Round 22 (N2): the forced compact one-line variant (dense-column
      // allocation/surplus labels — d._forceCompactLabel) wins over the
      // layout-height default.
      this.#writeLabelText(a.node, els[i], (a.node.y0 + a.node.y1) / 2, a.node._forceCompactLabel === true ? true : null);
    });
  }

  #joinBadges(badgeAnims) {
    const uniq = [...new Map(badgeAnims.map((a) => [a.node.id, a])).values()];
    const sel = this.labelLayer
      .selectAll("g.planflow-badge")
      .data(uniq.map((a) => a.node), (d) => d.id)
      .join("g")
      .attr("class", "planflow-badge");
    const els = sel.nodes();
    uniq.forEach((a, i) => {
      const d = a.node;
      const text = `Linked to ${d.limit.linked_count} of ${d.limit.limit} accounts`;
      const badgeWidth = text.length * 5.6 + 12;
      const el = els[i];
      el.innerHTML =
        `<rect width="${badgeWidth}" height="16" rx="8" fill="${this.constructor.COLORS.amber}"></rect>` +
        `<text x="6" y="11.5" style="font-size: 0.6rem; font-weight: 500; fill: ${this.constructor.COLORS.badgeText}">${this.#esc(text)}</text>`;
      a.badgeEl = el;
    });
    // Positioning is applied per frame (see #setBadgeGeoms).
  }

  #labelPosition(d) {
    // Round 10: the measured-width placement decided in #prepareDraw wins
    // (d._labelSide, so a long label sits on the side that has the room);
    // the old middle-facing rule stays the default. Round 20 (T1): the
    // gutter is the reference-dashboard 8px LABEL_GUTTER (was 6).
    const { LABEL_GUTTER } = this.constructor;
    if (d._labelSide === "start") return { x: d.x1 + LABEL_GUTTER, anchor: "start" };
    if (d._labelSide === "end") return { x: d.x0 - LABEL_GUTTER, anchor: "end" };
    const leftColumn = d.x0 < (this.drawWidth || 0) / 2;
    return { x: leftColumn ? d.x1 + LABEL_GUTTER : d.x0 - LABEL_GUTTER, anchor: leftColumn ? "start" : "end" };
  }

  // Round 15 (owner note 1) + Round 16 (owner note A): the MANAGE floor
  // input — the height of this node's REAL label box in the variant the
  // draw pass renders at d's current geometry (compact single-line for
  // < 24px rows, full two-line otherwise), measured with the same shared
  // measure probe the view-mode hide consumes: #writeLabelText (the exact
  // label the draw pass writes, same tspans / font sizes / marker rules)
  // into a hidden probe <g>, read with getBBox. Headless environments
  // without a live getBBox (harnesses) fall back to the deterministic
  // mirror of #writeLabelText's line geometry, so the mechanism (not just
  // the pixels) is exercised identically. Both variants are measured once
  // per node (cached on _labelBoxes) and reused by the draw-level floor
  // pass (#applyManageFloors via #labelFloorHeight) and the draw pass's
  // own measure probe.
  #labelFloorHeight(d) {
    const isCompact = d.y1 - d.y0 < 24 && d.nodeType !== "income";
    // biome-ignore lint/suspicious/noAssignInExpressions: deliberate check-or-init cache idiom — read the cached value, or compute and store it, in one expression.
    const boxes = d._labelBoxes || (d._labelBoxes = this.#labelBoxHeights(d));
    return (isCompact ? boxes.compact : boxes.full).h;
  }

  // Round 20 (T3, owner round 20 drawing), re-anchored by Round 23
  // (note 3, owner round 23 drawing): the Un-Allocated label is now
  // BOTTOM-ANCHORED on its pillar (2px clearance ABOVE the pillar bottom
  // - the stub's bottom edge, symmetric to the old 2px top clearance)
  // instead of centered on it; it was TOP-ANCHORED in round 20 (2px below
  // the pillar top, the income bottom edge where the hatched ribbon
  // enters). The owner's round 20 spec ("much closer to the Income label,
  // so that its number label is there before the other Sankey Flow
  // Visuals start to move up or down. So it never overlaps") pinned the
  // label to a fixed pre-fan-out point independent of where the flow
  // ribbons curve, in BOTH modes; the round 23 note keeps that pinned,
  // fixed-point contract but at the stub's BOTTOM so the label hugs the
  // stub bottom (both stubs are floored to the label floor, so at 1754px
  // paycheck manage the box centers moved down by the box height and the
  // new bottom clearance is exactly 2px).
  #unallocLabelCenterY(d) {
    const k = Math.min(d._labelScale ?? 1, d._manageScale ?? 1);
    return d._y1 - 2 - (this.#labelFloorHeight(d) * k) / 2;
  }

  // Round 16.7 (owner directive): the MANAGE minimums, applied WITHOUT
  // rescaling the layout. The layout is the view's strictly-proportional
  // fit (shared path — see #generateSankeyData); this pass only extends
  // the DRAWN geometry:
  //   * every labelled node's drawn rect is extended SYMMETRICALLY about
  //     its layout center to at least its measured label floor
  //     (#labelFloorHeight + LABEL_FLOOR_PADDING, the variant the layout
  //     height renders) — the symmetric extension keeps the label center
  //     and every band's y anchor on the layout geometry that
  //     #setLabelGeoms / #setLinkGeom consume, so only the rect grows
  //     (equal up/down; at a phone height the bottom rows would otherwise
  //     draw past the svg and the top rows would eat the header room —
  //     symmetric keeps both inside the canvas);
  //   * every band is STRICTLY PROPORTIONAL again (round 16.8): the drawn
  //     thickness = the layout width (d3's single scale), no label floor —
  //     the round 16.7 "labelled bands at the target's label floor" is
  //     GONE (it made the zero-value unsatisfied-bucket ribbons fat; the
  //     small lines just go into the larger labels). The ONLY surviving
  //     band floor: the round-9 Q3 3px visibility floor (MIN_BAND_WIDTH)
  //     for ZERO-VALUE minBand ribbons (max(layout width, 3px) as a FLOOR,
  //     not a forced value) so the unsatisfied bucket stays visible as a
  //     small line;
  //   * hatched Un-Allocated ribbons and the unlabelled scaffolding
  //     (bridge/anchor) keep their layout width (the manage stub-band width comes from #placeUnallocatedNearTails).
  // When a node's floor exceeds the room between its neighbours at the
  // view scale the extended rect overlaps its neighbours vertically —
  // accepted per the owner's directive (the view geometry wins; the
  // minimums are the only change). No rescaling to avoid it, ever.
  // VIEW mode is a no-op here (byte-identical view rendering).
  #applyManageFloors(layout) {
    if (this.mode === "view") return;
    const { LABEL_FLOOR_PADDING, MIN_BAND_WIDTH } = this.constructor;
    const floorOf = (n) => this.#labelFloorHeight(n) + LABEL_FLOOR_PADDING;
    // Round 16.8: bands are strictly proportional — drawn width = layout
    // width, no label floor. The only floor: the 3px Q3 visibility floor
    // for zero-value minBand ribbons. (Round 19: the _fw loop runs FIRST so
    // the node floor below can size the drawn body against the DRAWN band
    // stack — see #realignManageBands.)
    layout.links.forEach((l) => {
      l._fw = l.minBand && l.value <= 1e-9 ? Math.max(l.width, MIN_BAND_WIDTH) : l.width;
    });
    layout.nodes.forEach((n) => {
      if (n.label === false) return;
      const h = n.y1 - n.y0;
      // Round 19 (B): the drawn body must also cover the incoming AND
      // outgoing DRAWN band stack (sums of _fw). A node whose d3 height
      // covers only part of its inflow (the sub-account child: fixedValue
      // = the fan-out base only, while the income inflow band AND the
      // fan-out band both enter it) would otherwise let the re-stacked
      // anchors spill past the body and miss the label.
      const inSum = (n.targetLinks || []).reduce((s, l) => s + (l._fw ?? l.width), 0);
      const outSum = (n.sourceLinks || []).reduce((s, l) => s + (l._fw ?? l.width), 0);
      const ext = Math.max(0, Math.max(floorOf(n), inSum, outSum) - h) / 2;
      n._fy0 = n.y0 - ext;
      n._fy1 = n.y1 + ext;
    });
  }

  // Round 24 (owner directive): the manage-mode row-gap re-stack.
  // The owner's round-24 spec (r24-notes.md, 2026-11-03): visible padding
  // between EVERY DRAWN row in the bank column AND the allocation/surplus
  // column (fixed ROW_GAP), the individual drawn block heights
  // (_fy1-_fy0) UNCHANGED — no Freedom-Mortgage-style ballooning — and the
  // overall diagram height ALLOWED to grow to accommodate the padding.
  // This pass (MANAGE only; view returns early and stays byte-identical):
  //   1. re-stacks the bank column and the allocation/surplus column
  //      top-down, DRAWN-anchored: the drawn rect of row 0 starts at
  //      HEADER_SPACE and the drawn rect of row i+1 starts exactly
  //      ROW_GAP below the DRAWN bottom of row i (top_{i+1} = top_i +
  //      drawnH_i + ROW_GAP) — the DRAWN heights (read-only: the owner's
  //      block-size constraint) are the row pitch, so the VISIBLE block
  //      gap between every two adjacent drawn rows is the fixed ROW_GAP.
  //      The node y0/y1 layout heights are preserved (h = y1-y0) and
  //      CENTERED on the drawn center (y0 = top + (drawnH-h)/2), so every
  //      downstream consumer that reads the layout center (labels, the
  //      sub-account pass, #commitLayout's sub-pixel filter) sees a center
  //      identical to the drawn center. (Slot-anchoring the layout rect
  //      instead leaves the drawn gap at ROW_GAP only when h == drawnH;
  //      for sub-pixel rows (h << drawnH) the visible gap degrades to
  //      ~4-8px, which the owner's spec forbids.)
  //   2. grows this.lastChartHeight to
  //      HEADER_SPACE + EXTENT_MARGIN + max(allocSpan, bankSpan,
  //      incomeSpan) when the re-stacked span exceeds the design canvas.
  //      Incomes (column 0) keep their d3 positions (top-anchored at
  //      HEADER_SPACE by the flat-top re-anchoring; their span = 420 on the
  //      live plan) — NOT re-stacked, because #resolveManageLinkOrder's
  //      column-0 income outgoing re-stack assumes the income-side anchors
  //      span their d3 span; the Un-Allocated pillars bottom-anchor on the
  //      income bottoms, so they need no extra room. Pillars (column 1)
  //      are likewise excluded.
  // Column sets are discovered from the layout, not hardcoded (the live
  // plan: banks col 2 / allocations col 3; a four-column sub-account plan:
  // banks col 2 / children col 3 / allocations col 4). Sub-account
  // children (kind "bank" + subAccount) are NOT re-stacked here: their
  // group was centered on the PRE-re-stack parent centers by the earlier
  // #placeSubAccountRows call, so when any exist the pass re-runs it on
  // the FINAL parent centers + grown extent (idempotent: the children are
  // unmoved between the two calls, so the group gap/total recompute to
  // the same values; the re-centered #restackAnchors results are
  // superseded by #realignManageBands / #resolveManageLinkOrder anyway).
  // This pass runs AFTER #applyManageFloors (the drawn _fy0/_fy1 are
  // final) and BEFORE #realignManageBands / #resolveManageLinkOrder, which
  // re-derive every band anchor from these FINAL centers, so the flow
  // ribbons stay attached to their rows. The old tiling pass
  // (#resolveManageLabelOverlaps — 0.01px gaps + 0.7682x font shrink +
  // overlapping 20px rects) is retired by removing its call site (round
  // 24): its label-clearance goal is now met by the grown canvas itself,
  // and #ensureAllocationLabelGaps runs afterwards against the GROWN
  // height as a no-op safety net (8px block gaps + 16px label boxes leave
  // >= 12px between every pair of label boxes -> all _labelDy stay 0 ->
  // the typed label + color block + ribbons center-align to the row).
  #manageRowGapsAndExtent(layout, height) {
    if (this.mode === "view") return;
    const { ROW_GAP, HEADER_SPACE, EXTENT_MARGIN } = this.constructor;
    const bankCols = new Set();
    const allocCols = new Set();
    const incomeNodes = [];
    layout.nodes.forEach((n) => {
      if (n.column === undefined || n.label === false) return;
      if (n.kind === "bank" && !n.subAccount) bankCols.add(n.column);
      if (n.nodeType === "allocation" || n.nodeType === "surplus") allocCols.add(n.column);
      if ((n.column ?? 0) === 0) incomeNodes.push(n);
    });
    if (bankCols.size === 0 && allocCols.size === 0) return;
    const spans = [];
    const restackCol = (col) => {
      const rows = layout.nodes
        .filter((n) => n.column === col && this.#visibleNode(n))
        .sort((a, b) => a.y0 - b.y0);
      if (rows.length === 0) return;
      // R32: the restack math is the pure restackManageRows in
      // utils/plan_flow_sankey_layout (unit-tested: expected label-center ==
      // band-center, label pitch == band pitch). rows are the live d3
      // bindings, mutated in place; the drawn rect occupies
      // [top, top+hDrawn) with exactly ROW_GAP to the next drawn row, and the
      // label + flow anchors derive from the SAME _fy0/_fy1 pair — the
      // coupling the pre-R24 label tiling broke (owner's drift screenshot).
      spans.push(restackManageRows(rows, { rowGap: ROW_GAP, headerSpace: HEADER_SPACE }));
    };
    bankCols.forEach((col) => restackCol(col));
    allocCols.forEach((col) => restackCol(col));
    if (incomeNodes.length > 0) {
      spans.push(Math.max(...incomeNodes.map((n) => n.y1)) - HEADER_SPACE);
    }
    const needExtent = Math.max(...spans);
    const usableNow = height - HEADER_SPACE - EXTENT_MARGIN;
    if (needExtent > usableNow + 1e-9) {
      this.lastChartHeight = HEADER_SPACE + EXTENT_MARGIN + needExtent;
    }
    if (layout.nodes.some((n) => n.subAccount)) {
      this.#placeSubAccountRows(layout, this.lastChartHeight ?? height);
      // #placeSubAccountRows moves the children's LAYOUT rects (y0/y1) but
      // not their DRAWN rects (_fy0/_fy1 — set by #applyManageFloors
      // symmetric about the PRE-move centers): re-center each child's drawn
      // rect (drawn height preserved — the owner's block-size constraint
      // extends to the children) on its new layout center so the labels and
      // the fan-out bands stay aligned with the blocks.
      layout.nodes.forEach((c) => {
        if (!c.subAccount) return;
        const hDrawn = (c._fy1 ?? c.y1) - (c._fy0 ?? c.y0);
        c._fy0 = (c.y0 + c.y1) / 2 - hDrawn / 2;
        c._fy1 = c._fy0 + hDrawn;
      });
    }
    // The LAST pipeline pass (#placeUnallocatedNearTails, guarded: not
    // touched here) re-stacks each income's outgoing bands in the d3
    // sourceLinks ARRAY order — which was the target-y order of d3's
    // PRE-pass positions. Round 24 re-orders the bank/child drawn centers
    // (this re-stack + the sub-account re-centering above), so that d3
    // order can be stale — e.g. a child's col-3 d3 slot sits above its
    // parent's col-2 row while the child's final center lands BELOW the
    // parent's re-stacked center — and stacking the income solid bands in
    // the stale order breaks the round-20 T4 invariant (the anchor stack
    // must be ordered by far-endpoint drawn center) and adds crossings.
    // Pre-sorting each income's sourceLinks by the FINAL target drawn
    // center (stable; the hatched Un-Allocated tail's anchor is set by
    // #placeUnallocatedNearTails itself, not by array position) hands the
    // last pass the final order. ARRAY reorder only: node geometry, the
    // layout.links order, and view mode (early return above) are
    // untouched, and #resolveManageLinkOrder's col-0 re-stack (the same
    // final-center order) stays idempotent.
    layout.nodes.forEach((n) => {
      if ((n.column ?? 0) !== 0 || !Array.isArray(n.sourceLinks)) return;
      const cOf = (l) => {
        const t = l.target;
        if (!t || !Number.isFinite(t.y0) || !Number.isFinite(t.y1)) return 0;
        return t._fy0 != null ? (t._fy0 + t._fy1) / 2 : (t.y0 + t.y1) / 2;
      };
      n.sourceLinks = [...n.sourceLinks].sort((a, b) => cOf(a) - cOf(b));
    });
  }

  // Round 23 (note 2, owner reversal): VIEW-mode minimum drawn height for
  // REAL (value > 0) sub-pixel allocation/surplus rows. In VIEW the manage
  // label floors do not run (#applyManageFloors early-returns), so a 0.4-
  // 0.7px raw rect is not "visible". These rows get a small 3px sliver,
  // SYMMETRIC around the layout center (_fy0 = c - 1.5, _fy1 = c + 1.5), so
  // the layout center — where their bands land — sits inside the drawn
  // row. The sliver only touches rows currently HIDDEN by the raw-height
  // gate (h < 1) and never: zero-value rows (_zeroRow — the existing
  // stay-hidden contract), #isCritical rows (already visible at their true
  // size), or rows already drawn >= 1px (their true size is kept). The
  // text label in VIEW still follows the existing hide rule — only the
  // color block is forced visible here (owner: "prevent the color block
  // label and text label from being hidden in Managed View, and the Color
  // Block Label from being hidden in the View mode").
  #applyViewRowSlivers(layout) {
    if (this.mode !== "view") return;
    const MIN_SLIVER = 3;
    layout.nodes.forEach((n) => {
      if (n.label === false) return;
      if (n.nodeType !== "allocation" && n.nodeType !== "surplus") return;
      if (n._zeroRow) return; // zero-value rows stay hidden
      if (this.#isCritical(n)) return; // already visible at true size
      const h = n.y1 - n.y0;
      if (h >= 1) return; // already visible at its true size
      const c = (n.y0 + n.y1) / 2;
      n._fy0 = c - MIN_SLIVER / 2;
      n._fy1 = c + MIN_SLIVER / 2;
    });
  }

  // Round 19 (A, owner round 19): the allocation / surplus label
  // de-overlap pass, MANAGE mode only (the view hide path is untouched).
  // The round-16 side-flip + font-floor machinery is kept; MANAGE keeps
  // every label FULLY READABLE (no truncation, no hiding) and no two
  // allocation/surplus labels may overlap each other (or spill
  // off-canvas) at the locked container width.
  //
  // Round 20 (T1, owner round 20): the trigger is no longer collision-only
  // — consecutive label blocks must also keep the reference-dashboard
  // inter-label padding (LABEL_BLOCK_PADDING = 15px at scale 1, scaled
  // with the column font scale; measured from the Main Front-Dashboard
  // reference chart). A padding shortfall tiles the column exactly like a
  // collision does.
  //
  // Mechanism (order-preserving, NO band rescale): within each
  // allocation/surplus column the nodes keep their d3 order and their
  // proportional ROW heights; when the measured label boxes collide (or
  // spill the canvas edge, or fall short of the reference inter-label
  // padding) the column gets ONE uniform font scale
  // (d._manageScale, consumed by #writeLabelText as
  // min(_labelScale, _manageScale); the round-16 0.5x font floor
  // applies) found by bisection on the slot span, and a compact
  // top-down SLOT tiling places the nodes.
  //
  // The SLOT of a node is max(label box, row) at the current scale: the
  // box is centred on the row, so the union extends slot/2 from the row
  // center. Tiling the slots with a 0.01px clearance keeps BOTH the
  // label boxes AND the drawn rows non-overlapping - the box-only
  // tiling (first attempt) piled the small bottom rows into the tall
  // rows above them (the node bodies must stay disjoint too). A
  // non-colliding, on-canvas column is left byte-identical. Shifting the
  // row keeps every band attached to its own node: the round-19 B pass
  // re-derives the anchors from the drawn geometry afterwards. If even
  // the 0.5x slots do not fit (canvas too short for the label count),
  // the residual collision is accepted - the labels stay fully
  // readable, nothing is hidden or truncated.
  #resolveManageLabelOverlaps(layout, height) {
    if (this.mode === "view") return;
    const { EXTENT_MARGIN, HEADER_SPACE, LABEL_FLOOR_PADDING, LABEL_BLOCK_PADDING } = this.constructor;
    const canvasBottom = height - EXTENT_MARGIN;
    const scaleOf = (n) => Math.min(n._labelScale ?? 1, n._manageScale ?? 1);
    const floorOf = (n) => this.#labelFloorHeight(n) + LABEL_FLOOR_PADDING;
    const cols = new Map();
    layout.nodes.forEach((n) => {
      if (n.label === false) return;
      if (n.nodeType !== "allocation" && n.nodeType !== "surplus") return;
      const list = cols.get(n.column) || [];
      list.push(n);
      cols.set(n.column, list);
    });
    cols.forEach((list) => {
      list.sort((a, b) => a.y0 - b.y0);
      const n = list.length;
      const floors = list.map((x) => floorOf(x));
      const hs = list.map((x) => x.y1 - x.y0);
      const scales = list.map(scaleOf);
      const slot = (i, s) => Math.max(floors[i] * s, hs[i]);
      const cOf = (x) => (x.y0 + x.y1) / 2;
      // 1. Scan at the current scales: label-box overlap, a shortfall of
      //    the reference inter-label padding (round 20 T1), OR a box past
      //    the canvas bottom / header line.
      let triggered = false;
      for (let i = 1; i < n; i += 1) {
        const prevBot = cOf(list[i - 1]) + (floors[i - 1] * scales[i - 1]) / 2;
        const curTop = cOf(list[i]) - (floors[i] * scales[i]) / 2;
        const need = LABEL_BLOCK_PADDING * Math.min(scales[i - 1], scales[i]);
        if (curTop - prevBot < need - 0.01) {
          triggered = true;
          break;
        }
      }
      if (!triggered) {
        for (let i = 0; i < n; i += 1) {
          const c = cOf(list[i]);
          const h = (floors[i] * scales[i]) / 2;
          if (c + h > canvasBottom + 0.01 || c - h < HEADER_SPACE - 0.01) {
            triggered = true;
            break;
          }
        }
      }
      if (!triggered) return; // byte-identical: the d3 geometry already
      // keeps every label box clear and on-canvas.
      // 2. The uniform column scale: compact slot tiling from the first
      //    node's (header-clamped) center; the span below it,
      //    sum_{i>=2} ((slot_{i-1} + slot_i) / 2 + 0.01) + slot_n / 2,
      //    is monotone in s, so a bisection finds the largest s in
      //    [0.5, 1] whose slots fit the canvas (the per-node draw-level
      //    caps, e.g. the round-16 off-canvas _labelScale, bound the
      //    scale too).
      const cap = Math.min(1, ...scales);
      const firstCenterAt = (s) => {
        const c0 = cOf(list[0]);
        return Math.max(c0, HEADER_SPACE + slot(0, s) / 2);
      };
      const slotSpanAt = (s, scalesArr) => {
        let span = 0;
        for (let i = 1; i < n; i += 1) {
          span += (slot(i - 1, scalesArr[i - 1]) + slot(i, scalesArr[i])) / 2;
        }
        return span + slot(n - 1, scalesArr[n - 1]) / 2;
      };
      const spanAt = (s) => {
        let span = 0;
        for (let i = 1; i < n; i += 1) {
          span += (slot(i - 1, s) + slot(i, s)) / 2 + 0.01;
        }
        return span + slot(n - 1, s) / 2;
      };
      const fits = (s) => firstCenterAt(s) + spanAt(s) <= canvasBottom;
      let sCol;
      if (fits(1)) {
        sCol = 1;
      } else if (fits(Math.max(0.5, cap))) {
        sCol = Math.max(0.5, cap);
      } else {
        let lo = 0.5;
        let hi = 1;
        if (!fits(lo)) {
          sCol = 0.5; // residual: even the 0.5x slots do not fit.
        } else {
          for (let it = 0; it < 40; it += 1) {
            const mid = (lo + hi) / 2;
            if (fits(mid)) lo = mid;
            else hi = mid;
          }
          sCol = lo;
        }
      }
      const finalS = list.map((x, i) => {
        const s = Math.min(scales[i], Math.max(0.5, sCol));
        if (s < scales[i] - 1e-9) x._manageScale = s;
        return s;
      });
      // 3. Compact top-down slot tiling: node i sits (slot_{i-1} +
      //    slot_i) / 2 + the inter-label gap below node i-1. Round 20
      //    (T1): the gap targets the reference-dashboard padding
      //    (LABEL_BLOCK_PADDING, scaled to the column scale); when the
      //    canvas cannot hold the full padding at the 0.5x font floor
      //    (the round-19 residual case - canvas too short for the label
      //    count), the gap degrades toward the 0.01px no-overlap floor
      //    instead of breaking row order: slot >= row and >= box, so
      //    rows AND label boxes stay disjoint and on-canvas (the final
      //    clamp is a float safety net for the residual 0.5x case).
      let gap = LABEL_BLOCK_PADDING * sCol;
      {
        const slotSpan = slotSpanAt(0, finalS);
        const avail = canvasBottom - firstCenterAt(finalS[0]) - slotSpan;
        gap = Math.min(gap, Math.max(0.01, avail / (n - 1)));
      }
      let center = firstCenterAt(finalS[0]);
      const d0 = center - cOf(list[0]);
      list[0].y0 += d0;
      list[0].y1 += d0;
      for (let i = 1; i < n; i += 1) {
        center += (slot(i - 1, finalS[i - 1]) + slot(i, finalS[i])) / 2 + gap;
        if (center + slot(i, finalS[i]) / 2 > canvasBottom) {
          center = canvasBottom - slot(i, finalS[i]) / 2;
        }
        const d = center - cOf(list[i]);
        list[i].y0 += d;
        list[i].y1 += d;
      }
    });
  }

  // Round 19 (B, owner round 19): the band re-alignment onto the DRAWN
  // geometry, MANAGE mode only. The d3 link anchors (l.y0/l.y1) sit at
  // the pre-floor LAYOUT geometry (and the sub-account child's d3 height
  // covers only its fixedValue = fan-out base, so its incoming stack
  // overflows the node); the labels, by contrast, sit at the DRAWN
  // centers (the round-16.7 symmetric floors). This pass re-derives every
  // anchor for every labelled node EXCEPT income and the Un-Allocated
  // pillars (ROUND 32b: kind-based exclusion, not column >= 2 — the bank
  // column is column 1 in the classic 3-slot layout, so the column guard
  // skipped the bank column entirely there): incoming anchors (l.y1) are
  // re-stacked inside
  // the drawn body (_fy0.._fy1) ordered by the SOURCE's drawn center-y,
  // outgoing anchors (l.y0) by the TARGET's drawn center-y — the d3
  // reorderNodeLinks rule, the same convention as #restackAnchors. Band
  // WIDTHS are the strictly-proportional drawn widths (l._fw; the ONLY
  // floor is the 3px Q3 visibility floor for zero-value minBand ribbons)
  // and are untouched. Income and the pillars are excluded by KIND
  // (Round 32b), root/bridge/anchor via label === false, so
  // the pillar-tail contract (G) and the tail anchoring stay untouched.
  #realignManageBands(layout) {
    if (this.mode === "view") return;
    const centerOf = (n) => (n._fy0 != null ? (n._fy0 + n._fy1) / 2 : (n.y0 + n.y1) / 2);
    layout.nodes.forEach((n) => {
      if (n.label === false) return;
      // Round 32b: kind-based, not column-based (see the pass comment):
      // the bank column is column 1 in the classic 3-slot layout, so the
      // old `column < 2` guard skipped it and left its anchors at the
      // pre-restack d3 positions after the row restack moved the bands.
      // Income (col 0) and the Un-Allocated pillars stay excluded by kind
      // (the pillar-tail contract G); root/bridge/anchor via label===false.
      if (n.kind === "income" || n.kind === "unallocated") return;
      const top = n._fy0 ?? n.y0;
      const widthOf = (l) => l._fw ?? l.width;
      const bodyH = (n._fy1 ?? n.y1) - top;
      // When the stack is narrower than the drawn body (a labelled node
      // floored above its band sum — the allocation/surplus slivers), the
      // stack is CENTERED in the body: a single band then lands exactly on
      // the label center (the round-16.7 symmetric floor keeps the label
      // center == the body center). A stack that fills the body (banks,
      // sub-account children floored by their band sums) is unchanged —
      // centering is a no-op there.
      const stackOffset = (links) =>
        Math.max(0, (bodyH - links.reduce((s, l) => s + widthOf(l), 0)) / 2);
      const ins = [...(n.targetLinks || [])].sort((a, b) => centerOf(a.source) - centerOf(b.source));
      let e = top + stackOffset(ins);
      ins.forEach((l) => {
        const w = widthOf(l);
        l.y1 = e + w / 2;
        e += w;
      });
      const outs = [...(n.sourceLinks || [])].sort((a, b) => centerOf(a.target) - centerOf(b.target));
      e = top + stackOffset(outs);
      outs.forEach((l) => {
        const w = widthOf(l);
        l.y0 = e + w / 2;
        e += w;
      });
    });
  }

  // Round 20 (T4, owner round 20): the LINK-ANCHOR stacking contract,
  // enforced AFTER the final layout/floor/realign passes. Within every
  // labelled node's edge (Round 32b: every labelled node except income
  // and the Un-Allocated pillars, excluded by KIND — the old column >= 2
  // guard skipped the bank column in the classic 3-slot layout; income/
  // pillar/bridge stay excluded; the pillar-tail contract G owns columns 0/1 and the hatched-last
  // income stacking is #placeUnallocatedNearTails' contract) the bands must
  // leave/enter in the order of their FAR ENDPOINT's drawn y position
  // (incoming: the source node's drawn center; outgoing: the target's).
  // #realignManageBands already derives that order; this pass re-derives
  // it over the CURRENT anchor span as the formal idempotent enforcement
  // - byte-identical when the order holds (it always does after
  // realign, so the no-sub-account cases stay byte-identical - J S6a-d
  // verifies) and a fix-up if a future pass reorders the anchors.
  // Bands that share an edge in this order cannot cross inside that
  // edge; a crossing that remains (the REAL fixture's income->subaccount
  // x bank->allocation braid, 1 pair at both 1200px and 998px) is
  // data-induced: the two bands share NO edge, and untangling them
  // requires re-ordering a NODE (Sammi Parent Loan to the bottom), which
  // the owner's contract forbids (node geometry unchanged).
  #resolveManageLinkOrder(layout) {
    if (this.mode === "view") return;
    const centerOf = (n) => (n._fy0 != null ? (n._fy0 + n._fy1) / 2 : (n.y0 + n.y1) / 2);
    const widthOf = (l) => l._fw ?? l.width;
    const restack = (links, far, anchor) => {
      if (links.length < 2) return;
      const spanTop = Math.min(...links.map((l) => l[anchor] - widthOf(l) / 2));
      const sorted = [...links].sort((a, b) => centerOf(a[far]) - centerOf(b[far]));
      let e = spanTop;
      sorted.forEach((l) => {
        const w = widthOf(l);
        l[anchor] = e + w / 2;
        e += w;
      });
    };
    layout.nodes.forEach((n) => {
      if (n.label === false) return;
      // Round 32b: kind-based, not column-based (see #realignManageBands):
      // the bank column is column 1 in the classic 3-slot layout, so the
      // old `column < 2` guard never enforced the far-endpoint order on
      // the bank edges. The separate col-0 income restack below is
      // unchanged.
      if (n.kind === "income" || n.kind === "unallocated") return;
      restack(n.targetLinks || [], "source", "y1");
      restack(n.sourceLinks || [], "target", "y0");
    });
    // Round 20 (T4, owner round 20): the income (column 0) outgoing gets
    // the same treatment. d3's original order (the #placeUnallocatedNearTails
    // comment: "the bank bands keep d3's (target-y ordered,
    // crossing-free) relative order") goes STALE in manage: the passes
    // after d3 (the T1 slot tiling, the sub-account stagger) shift the
    // target centers, and the income re-stack (column 0 - excluded from
    // #realignManageBands) keeps the pre-shift order. This pass runs
    // LAST, so it re-sorts the SOLID income outgoing by the FINAL target
    // drawn centers. The hatched Un-Allocated tail is excluded: its
    // source anchor is the income's bottom sliver set by
    // #placeUnallocatedNearTails (the G pillar contract) and the solid stack
    // sum leaves exactly its width below (d3 value conservation).
    layout.nodes.forEach((n) => {
      if ((n.column ?? 0) !== 0) return;
      // The SOLID value-carrying bands only. The hatched Un-Allocated
      // tail is the income's bottom sliver (fixed by
      // #placeUnallocatedNearTails - the G pillar contract), and the
      // zero-width scaffolding (bridge/anchor) links keep their d3 /
      // round-14 positions: they carry no value and no visual, and
      // moving them would perturb the manage==view scaffolding
      // byte-identity ((f) checks the bridge/anchor links too).
      const solid = (n.sourceLinks || []).filter(
        (x) => !x.hatched && x.value > 1e-9 && (x._fw ?? x.width) > 0.01);
      if (solid.length < 2) return;
      restack(solid, "target", "y0");
    });
  }

  // Round 16 (owner notes A/B): BOTH label boxes for this node's label
  // text — the compact single-line box (< 24px rows render) and the full
  // two-line box — measured with the shared probe (#writeLabelText with a
  // forced variant into a hidden probe <g>, getBBox) or the deterministic
  // mirror (headless). The box is geometry-independent (the label text
  // never changes with layout), so it is cached on _labelBoxes (inherited
  // by the layout copies through the shallow spread in runLayout).
  #labelBoxHeights(d) {
    const { NODE_WIDTH } = this.constructor;
    const probeNode = { ...d, x0: 0, x1: NODE_WIDTH, _labelScale: 1 };
    const measure = (variant) => {
      try {
        const g = this.#labelProbeHost().append("g");
        const el = typeof g.node === "function" ? g.node() : g;
        this.#writeLabelText(probeNode, el, 0, variant);
        let box = null;
        if (el && typeof el.getBBox === "function") {
          const b = el.getBBox();
          if (Number.isFinite(b.height) && b.height > 0) box = { w: b.width, h: b.height };
        }
        if (typeof g.remove === "function") g.remove();
        return box;
      } catch {
        return null; // no live layout engine (harness) -> the mirror below
      }
    };
    let compact = measure(true);
    let full = measure(false);
    if (!compact || !full) {
      const mirror = this.#mirrorLabelBoxHeights(probeNode);
      const widths = this.#mirrorLabelWidths(probeNode);
      if (!compact) compact = { w: widths.compact, h: mirror.compact };
      if (!full) full = { w: widths.full, h: mirror.full };
    }
    return { compact, full };
  }

  // The deterministic mirror of #writeLabelText's line geometry (k = 1),
  // BOTH variants: one 12px line (compact), or the 12px name line + 10.4px
  // amount line (+ a 9.6px shortfall / marker line when present), with
  // sans-serif ascent/descent (0.93em / 0.25em) and the tspan dy offsets
  // (name -0.2em, second line +1.2em of the previous font).
  #mirrorLabelBoxHeights(d) {
    const compact = 12 * (0.93 + 0.25); // one 12px line
    const top = 2.4 + 12 * 0.93; // name line baseline 0.2em above center
    let bottom = 2.4 + 12 * 1.2 + 10.4 * 0.25; // amount line below it
    if (Number(d.shortfall || 0) > 0.005 || d.unassigned) {
      bottom = 2.4 + 12 * 1.2 + 10.4 * 1.2 + 9.6 * 0.25;
    }
    return { compact, full: top + bottom };
  }

  // The deterministic width mirror of #writeLabelText's text (headless
  // label floors): 12px sans ~6.6px/char (text-xs), 10.4px mono
  // ~7.2px/char; compact is one single line, full the wider of the name
  // line and the amount line.
  #mirrorLabelWidths(d) {
    const shortText = Number(d.shortfall || 0) > 0.005 ? ` · short ${this.#format(d.shortfall)}` : "";
    const marker = d.unassigned ? ` · ${this.labelsValue.unassigned || "No Assignment"}` : "";
    // Round 16 (owner note 4): the FINAL label text (the last4 suffix via
    // #displayName) is PART of the measured box — the floors adapt to the
    // suffix automatically. Round 19 (P2, owner round 18b): the chip is
    // drawn OVERLAPPING the node bar (centered on the bar midline — node
    // geometry, not label space), so it no longer adds to the HORIZONTAL
    // label footprint: the chip term is dropped from both variants
    // (LOGO_CHIP_SIZE/GAP constants stay for the draw path). Round 19
    // (P2, owner round 18a): the single-line $ portion renders at the
    // two-line $ size, so the compact line prices the amount at the
    // 10.4px mono ~7.2px/char (this mirror's own mono constant) instead
    // of the 12px sans 6.6px/char.
    const baseName = this.#displayName(d) || "";
    const name = d.labelPrefix ? `${d.labelPrefix}${baseName}` : baseName;
    const amount = this.#format(d.displayValue ?? d.value ?? 0);
    return {
      // 6.6 = the single space between name and $ on the compact line.
      compact: name.length * 6.6 + 6.6 + amount.length * 7.2 + shortText.length * 6.6 + marker.length * 6.6,
      full: Math.max((name.length + shortText.length + marker.length) * 6.6, amount.length * 7.2),
    };
  }

  // The legacy single-variant estimate (kept for API stability): the
  // draw-time variant of the mirrored box.
  #estimateLabelHeight(d) {
    const boxes = this.#mirrorLabelBoxHeights(d);
    const compact = d.y1 - d.y0 < 24 && d.nodeType !== "income";
    return compact ? boxes.compact : boxes.full;
  }

  // The hidden probe <svg> that carries the label measure-probe <g> (the
  // real shared measure box behind #labelFloorHeight AND the view-mode
  // small-label hide in #prepareDraw). Created once per instance;
  // visibility:hidden keeps it out of the page while getBBox still works
  // (display:none would not lay the text out).
  #labelProbeHost() {
    if (!this._labelProbe) {
      this._labelProbe = d3
        .select(this.element)
        .append("svg")
        .attr("width", 1)
        .attr("height", 1)
        .style("position", "absolute")
        .style("left", "-9999px")
        .style("visibility", "hidden")
        .style("pointer-events", "none");
    }
    return this._labelProbe;
  }

  // Round 10 (owner: "keep the names always"): the FULL label (name +
  // amount + short) must always be visible — no ellipsis, no clip at the
  // SVG edge, at any data scale (including the round-9 3px-floor bands,
  // whose 22px floor nodes carry the compact single-line label). The
  // default side faces the chart middle (the house rule); when the
  // measured width overflows it, the label flips to the opposite node side
  // if that has room, and as a last resort the font scales down to
  // EXACTLY the available space (round 16.7: the old 0.5x floor could push
  // the box past the canvas edge — the label then scaled to the room
  // instead, so it stays on-canvas, drawn against the node) so the full
  // name still fits on-screen.
  #placeLabel(d, measuredWidth, width) {
    const { EXTENT_MARGIN, LABEL_GUTTER } = this.constructor;
    const gap = LABEL_GUTTER; // Round 20 (T1): the reference-dashboard gutter
    const availStart = width - EXTENT_MARGIN - (d.x1 + gap); // label right of the node
    const availEnd = d.x0 - gap - EXTENT_MARGIN; // label left of the node

    // Round 22 (N4): an owner-locked label side (the bank column — see
    // #pinBankColumn) keeps its side no matter what the heuristic below
    // would derive; the last-resort scale-to-fit still applies, for the
    // locked side.
    if (d._labelSideLocked) {
      const lockedAvail = d._labelSide === "start" ? availStart : availEnd;
      d._labelScale = lockedAvail >= measuredWidth ? 1 : Math.max(0.1, lockedAvail / measuredWidth);
      return;
    }

    const defaultSide = d.x0 < width / 2 ? "start" : "end";
    const defaultAvail = defaultSide === "start" ? availStart : availEnd;
    let side = defaultSide;
    if (defaultAvail < measuredWidth) {
      const otherSide = defaultSide === "start" ? "end" : "start";
      const otherAvail = otherSide === "start" ? availStart : availEnd;
      side = otherAvail >= measuredWidth ? otherSide : availStart >= availEnd ? "start" : "end";
    }
    const avail = side === "start" ? availStart : availEnd;
    d._labelSide = side;
    // Round 16.7 off-canvas guard: `avail < measuredWidth` is only reached
    // when the default side AND the flip are both too short, so scale to
    // EXACTLY the available space (no 0.5x font floor — that floor let the
    // box run past the canvas edge and clip at the svg boundary, the bank
    // names the owner saw cut off at the left edge). The box then always
    // stays inside [EXTENT_MARGIN, width - EXTENT_MARGIN]; against the node
    // it renders at the reduced scale (drawn "inside" the node's side).
    d._labelScale = avail >= measuredWidth ? 1 : Math.max(0.1, avail / measuredWidth);
  }

  // Round 16.8: the round 16/16.7 min-width overlap probe (the label-gap
  // gutter probe and its one-candidate helper) is REMOVED with the
  // min-width search: the manage chart is locked at the container width,
  // labels may overlap where the container is tight (owner directive).

  // Round 16 (owner note 4): the LABEL-visible name — the bank rows'
  // "Name [last4]" suffix (labelName, set in #buildGraph), plain d.name
  // for everything else (and for banks without a last4). The label text,
  // the <title>, the tooltip and the headless width mirror all consume
  // this; d.name itself stays plain for the sorts, the dialog lookups and
  // the planner identity.
  #displayName(d) {
    return d.labelName ?? d.name;
  }

  // Small bars get a compact single-line label (name · amount · short) so
  // neighbouring labels do not stack into each other (owner round 2, F1);
  // unassigned rows (R3) append the red "No Assignment" marker. Round 10:
  // the FULL name always renders (no ellipsis, no clipping) — placement is
  // measured in #prepareDraw via #placeLabel, and d._labelScale is the
  // last-resort font shrink (1 = the house sizes below).
  // Round 34c (owner): the icon<->name gap matches the name<->dollar-amount
  // gap of the single-line (compact) label run — "the same amount of Gap
  // that you have between the Text and the Dollar Amount". Measured from the
  // DRAWN tspans (getExtentOfChar, user units at the current label scale k):
  // name end -> first non-space char of the amount tspan (the compact run
  // starts the amount with one space). Returns null when it cannot be
  // measured (two-line variant: the amount resets x on its own line, so the
  // measured gap is ~0; short DOM; probe context) and the caller falls back
  // to LEFTOVER_ICON_CLEARANCE. DOM-only (the unit test covers the pure
  // placement math with an explicit clearance instead).
  #leftoverNameAmountGap(textNode) {
    try {
      const tspans = Array.from(textNode.querySelectorAll("tspan"));
      if (tspans.length < 2) return null;
      const nameT = tspans[0];
      const amountT = tspans.find((t) => t.classList && t.classList.contains("text-secondary"));
      if (!amountT) return null;
      if (
        typeof nameT.getExtentOfChar !== "function" ||
        typeof amountT.getExtentOfChar !== "function"
      ) {
        return null;
      }
      const nChars = nameT.getNumberOfChars();
      if (nChars === 0) return null;
      const nameEnd = nameT.getExtentOfChar(nChars - 1);
      const aText = amountT.textContent || "";
      let i = 0;
      while (i < aText.length && aText[i] === " ") i += 1;
      if (i >= aText.length) return null;
      const amountStart = amountT.getExtentOfChar(i);
      const gap = amountStart.x - (nameEnd.x + nameEnd.width);
      // Clamp to the 4px spec floor (the round-34b guardrail); the owner's
      // "same as the name->amount gap" is the spacing, never under 4px.
      return gap > 0.5 ? Math.max(gap, this.constructor.LEFTOVER_ICON_CLEARANCE) : null;
    } catch {
      return null;
    }
  }

  #writeLabelText(d, g, centerY, compactOverride = null) {
    const { x, anchor } = this.#labelPosition(d);
    // Round 16 (owner note A): compactOverride forces the label variant for
    // the measure probes (both boxes are measured BEFORE the layout exists,
    // so the draw-time y-decision cannot apply yet); the draw path passes
    // nothing and keeps the original decision, byte-identical.
    const compact = compactOverride === null
      ? d.y1 - d.y0 < 24 && d.nodeType !== "income"
      : compactOverride;
    const shortText = Number(d.shortfall || 0) > 0.005 ? ` · short ${this.#format(d.shortfall)}` : "";
    const marker = d.unassigned ? ` · ${this.labelsValue.unassigned || "No Assignment"}` : "";
    // Round 11 issue 8: the sub-account rows carry a LABEL-ONLY indent
    // prefix ("↳ ") — the full name (owner always-show rule) stays in
    // d.name for the tooltip, the dialog lookups and the over-plan chrome.
    // Round 16 (owner note 4): the label shows the FINAL display name —
    // the bank's last4 suffix via #displayName when present.
    const name = d.labelPrefix ? `${d.labelPrefix}${this.#displayName(d)}` : this.#displayName(d);
    // Round 19 (P2, owner round 18b): the chip OVERLAPS the node bar — it
    // is centered on the bar's vertical midline (chipX below), NOT in the
    // gutter between the bar and the text. The text keeps the plain
    // #labelPosition x (bar edge + 6px gutter) and every x-reset tspan
    // keeps it too: the chip no longer adds to the HORIZONTAL label
    // footprint (#mirrorLabelWidths dropped the chip term; the DOM probe
    // measures the <text> box only). NODE_WIDTH (15) > CHIP (14), so the
    // chip sits fully on the bar and the text never touches it.
    const { LOGO_CHIP_SIZE: CHIP } = this.constructor;
    // Round 16.6: logo OR the default kind icon — a bank always chips.
    const hasChip = d.logoSlug != null || d.kindIcon != null;
    const textX = x;
    const chipX = (d.x0 + d.x1) / 2 - CHIP / 2;
    // Round 19 (A): the vertical de-overlap scale (d._manageScale, set by
    // #resolveManageLabelOverlaps when a bottom-clamped label still
    // collides) stacks UNDER the round-16 horizontal fit (_labelScale);
    // both honor the round-16 0.5x font floor.
    const k = Math.min(d._labelScale ?? 1, d._manageScale ?? 1);
    // A label g survives across re-renders (keyed join) — drop the previous
    // <text> AND the chip (image or kind-icon g) before writing the fresh
    // ones, or every draw stacks another.
    d3.select(g).selectAll(
      ":scope > text, :scope > image.planflow-logo, :scope > g.planflow-kind-icon, :scope > g.planflow-leftover-icon, :scope > rect.planflow-ua-outline"
    ).remove();
    // Round 20 (T3, owner round 20 drawing): the Un-Allocated label is a
    // DOTTED outline instead of the solid grey fill it had - a dashed
    // rectangle frame around the measured label box (transparent fill,
    // dash/scale tracking the label scale k). Appended BEFORE the <text>
    // so the frame sits behind the text. #setLabelGeoms re-positions it
    // on every draw (the box is geometry-independent, only the center
    // moves).
    // Round 20 (T3) + hang fix: the dotted frame is DRAW-path only. The
    // measure probes (#labelBoxHeights -> #writeLabelText with
    // compactOverride != null) must measure the TEXT box only: drawing the
    // frame inside a probe re-entered #labelBoxHeights on a fresh copy that
    // never carries _labelBoxes, an unbounded recursion that froze the tab
    // (owner report: the Paycheck Flow tab dies on open).
    if (d.kind === "unallocated" && compactOverride === null) {
      // biome-ignore lint/suspicious/noAssignInExpressions: deliberate check-or-init cache idiom — read the cached value, or compute and store it, in one expression.
      const boxes = d._labelBoxes || (d._labelBoxes = this.#labelBoxHeights(d));
      const bw = (compact ? boxes.compact.w : boxes.full.w) * k;
      const bh = (compact ? boxes.compact.h : boxes.full.h) * k;
      const pad = 4 * k;
      const rx = anchor === "end" ? x - bw - pad * 2 : x - pad;
      d3.select(g)
        .append("rect")
        .attr("class", "planflow-ua-outline privacy-sensitive")
        .attr("fill", "none")
        .attr("stroke", this.constructor.COLORS.unallocated)
        .attr("stroke-width", 1.2)
        .attr("stroke-dasharray", `${3 * k} ${3 * k}`)
        .attr("rx", 2 * k)
        .attr("x", rx)
        .attr("y", centerY - bh / 2 - pad)
        .attr("width", bw + pad * 2)
        .attr("height", bh + pad * 2);
    }
    const text = d3.select(g)
      .append("text")
      .attr("x", textX)
      .attr("y", centerY)
      .attr("text-anchor", anchor)
      // Round 10 issue 6: the house privacy-mode rule (app/assets/tailwind/
      // privacy-mode.css: html.privacy-mode .privacy-sensitive) blurs every
      // sankey label (name + amount + shortfall/marker tspans share the
      // element) while the band paths stay visible — they carry no class.
      // planflow-value-label: the round 33 value morph hook (the
      // Per Paycheck <-> Per Month / unit toggle blur-fades the NEW
      // numbers in — see application.css .plan-flow-sankey--morphing).
      .attr("class", "planflow-value-label text-xs font-medium text-primary fill-current select-none privacy-sensitive")
      .attr("dy", compact ? "0.35em" : "-0.2em");
    if (k < 1) text.style("font-size", `${12 * k}px`); // text-xs = 0.75rem
    if (compact) {
      text.append("tspan").text(name);
      // Round 19 (P2, owner round 18a): the single-line $ portion gets the
      // EXACT two-line $ style — the grey "font-mono text-secondary" fill
      // and the smaller font-size (0.65rem at scale 1, 10.4 * k px when
      // scaled, same as the two-line amount line) — on the SAME baseline
      // (no x/dy reset; it flows after the name with one space).
      text
        .append("tspan")
        .attr("class", "font-mono text-secondary")
        .style("font-size", k < 1 ? `${10.4 * k}px` : "0.65rem")
        .text(` ${this.#format(d.displayValue ?? d.value ?? 0)}`);
      if (shortText) text.append("tspan").attr("class", "text-destructive").text(shortText);
      if (marker) text.append("tspan").attr("class", "text-destructive").text(marker);
    } else {
      text.append("tspan").text(name);
      text
        .append("tspan")
        .attr("x", textX)
        .attr("dy", "1.2em")
        .attr("class", "font-mono text-secondary")
        .style("font-size", k < 1 ? `${10.4 * k}px` : "0.65rem")
        .text(this.#format(d.displayValue ?? d.value ?? 0));
      if (Number(d.shortfall || 0) > 0.005) {
        text
          .append("tspan")
          .attr("x", textX)
          .attr("dy", "1.2em")
          .attr("class", "font-mono text-destructive")
          .style("font-size", k < 1 ? `${9.6 * k}px` : "0.6rem")
          .text(`short ${this.#format(d.shortfall)}`);
      }
      if (marker) {
        text
          .append("tspan")
          .attr("x", textX)
          .attr("dy", "1.2em")
          .attr("class", "text-destructive")
          .style("font-size", k < 1 ? `${10.4 * k}px` : "0.65rem")
          .text(marker);
      }
    }
    // Round 16 (owner note 3b) + round 19 (P2): the bank favicon chip —
    // INSIDE the label group (it blurs with the label under the house
    // privacy rule via the shared privacy-sensitive class). Round 19 (P2,
    // owner round 18b): it is drawn OVERLAPPING the node bar — centered on
    // the bar midline (chipX), both the logo <image> and the kind-icon <g>
    // (identical placement rule, parity kept) — and no longer occupies the
    // gutter between bar and text. Omitted entirely when the slug is absent
    // or not in the payload's available set — never a broken <img>.
    if (hasChip) {
      if (d.logoSlug != null) {
        d3
          .select(g)
          .append("image")
          .attr("class", "planflow-logo privacy-sensitive")
          .attr("href", `/images/bank-logos/${d.logoSlug}.svg`)
          .attr("width", CHIP)
          .attr("height", CHIP)
          .attr("x", chipX)
          .attr("y", centerY - CHIP / 2)
          .attr("preserveAspectRatio", "xMidYMid meet");
      } else {
        // Round 16.6: the default kind icon — a stroked lucide path in 24x24
        // space, scaled to the chip footprint, tinted with the node's kind
        // fill. INSIDE the label group like the logo (privacy blur + measured
        // box cover it identically; round 19 (P2): same chipX on the bar).
        d3
          .select(g)
          .append("g")
          .attr("class", "planflow-kind-icon privacy-sensitive")
          .attr("transform", `translate(${chipX}, ${centerY - CHIP / 2}) scale(${CHIP / 24})`)
          .attr("fill", "none")
          .attr("stroke", d.color || "currentColor")
          .attr("stroke-width", 2)
          .attr("stroke-linecap", "round")
          .attr("stroke-linejoin", "round")
          .html(this.constructor.KIND_ICONS[d.kindIcon] || this.constructor.KIND_ICONS.other);
      }
    }
    // Round 34 (spec 4) + Round 34b (T1): the LEFTOVER icon on a bank node
    // whose inflow is a leftover. Round 34b: the slot is OUTSIDE the label
    // text run — #leftoverIconPlacement measures the WHOLE <text> box (the
    // single-line "Name [last4] $amount" run) and picks the slot: between
    // the label text end and the bank band edge when that gap is >= 18px,
    // else LEFT of the name text with a 4px clearance; the slot is vertically
    // centered on the band center. #setLabelGeoms re-applies the same math
    // every frame (same box, only the center/anchor move). DRAW-path only
    // (the measure probes must measure the text box only — the same
    // compactOverride guard as the Un-Allocated outline above). The glyph
    // inherits the dollar-amount text color: stroke = the amount tspan's
    // computed fill (currentColor fallback).
    if (compactOverride === null && d.kind === "bank" && d.leftover) {
      const textNode = text.node();
      if (textNode && typeof textNode.getBBox === "function") {
        let labelBox = null;
        try { labelBox = textNode.getBBox(); } catch { labelBox = null; }
        if (labelBox && labelBox.width > 0) {
          const boxSize = this.constructor.LEFTOVER_ICON_SIZE * k;
          const { anchor } = this.#labelPosition(d);
          // Round 34c: measure the name<->amount gap of the drawn run and
          // cache it on d for the per-frame path (#setLabelGeoms); null ->
          // the 4px default clearance.
          const iconClearance = this.#leftoverNameAmountGap(textNode);
          d._leftoverIconClearance = iconClearance;
          const slot = this.constructor.leftoverIconPlacement({
            anchor,
            labelBox,
            bandX0: d.x0,
            bandX1: d.x1,
            boxSize,
            centerY,
            clearance: iconClearance,
          });
          const amountTspan = text.select("tspan.text-secondary").node();
          const amountColor =
            amountTspan && typeof getComputedStyle === "function"
              ? getComputedStyle(amountTspan).fill
              : null;
          d3.select(g)
            .append("g")
            .attr("class", "planflow-leftover-icon privacy-sensitive")
            .attr("transform", `translate(${slot.x}, ${slot.y}) scale(${k})`)
            .attr("fill", "none")
            .attr("stroke", amountColor || "currentColor")
            .attr("stroke-width", 1.4)
            .attr("stroke-linecap", "round")
            .html(this.constructor.LEFTOVER_ICON);
        }
      }
    }
    // Round 11 issue 8: the sub-account tooltip names its parent.
    const subAccountNote = d.subAccount && d.parentName ? ` · Sub-account of ${d.parentName}` : "";
    text.append("title").text(`${this.#displayName(d)} — ${this.#format(d.displayValue ?? d.value ?? 0)}${subAccountNote}`);
  }

  // ---- Geometry application ----------------------------------------------

  #setNodeGeom(anim, opacity = 1) {
    if (!anim.el) return;
    const d = anim.node;
    const path = this.#nodePath(d._x0, d._y0, d._x0 + (d.x1 - d.x0), d._y1, d);
    anim.el.setAttribute("d", path || "M0,0");
    anim.el.setAttribute("opacity", opacity.toFixed(3));
    if (anim.hatchEl) {
      // Round 20 (T3): the crosshatch overlay follows the pillar's
      // tweened shape (same <d>, same fade-out), and the fading gradient
      // tracks the drawn pillar's y extent (userSpaceOnUse stops).
      anim.hatchEl.setAttribute("d", path || "M0,0");
      anim.hatchEl.setAttribute("opacity", (opacity * 0.55).toFixed(3));
      const grad =
        typeof document !== "undefined" ? document.getElementById(this.#uaFadeGradientId()) : null;
      if (grad) {
        grad.setAttribute("y1", d._y0);
        grad.setAttribute("y2", d._y1);
      }
    }
    if (anim.hitEl) {
      // Round 21 T6: the hit target centers on the bar's DRAWN extent and
      // never collapses below 22 x 28px, so a sub-pixel bar keeps a real
      // click target; the fade follows the bar's opacity.
      const w = 28;
      const h = Math.max(22, d._y1 - d._y0);
      const x = d._x0 + (d.x1 - d.x0 - w) / 2;
      const y = (d._y0 + d._y1) / 2 - h / 2;
      anim.hitEl.setAttribute("x", x.toFixed(3));
      anim.hitEl.setAttribute("y", y.toFixed(3));
      anim.hitEl.setAttribute("width", w);
      anim.hitEl.setAttribute("height", h.toFixed(3));
      anim.hitEl.setAttribute("opacity", opacity.toFixed(3));
    }
  }

  #setLinkGeom(anim) {
    if (!anim.el) return;
    const l = anim.link;
    const w = Math.max(0.5, l._width ?? 0);
    if (anim.hatched) {
      // Round 21 (T1): nearTail stubs (empty plans only) draw a straight
      // band; every other hatched ribbon keeps the cubic #ribbonPath
      // byte-identical (allocating plans never set nearTail).
      const path = l.nearTail
        ? this.#straightRibbonPath(anim.sx1, anim.tx0, l._y0, l._y1, l._width ?? 0)
        : this.#ribbonPath(anim.sx1, anim.tx0, l._y0, l._y1, l._width ?? 0);
      anim.el.querySelector("path.ribbon-fill")?.setAttribute("d", path);
      anim.el.querySelector("path.ribbon-hatch")?.setAttribute("d", path);
      anim.el.setAttribute("opacity", (l._opacity ?? 1).toFixed(3));
    } else {
      // d3-shape: the link factory is called WITH the datum; .source()/.target()
      // store accessors invoked via Function#apply, so pass [x, y] through a
      // synthetic datum, not the accessors.
      const d = d3.linkHorizontal()({ source: [anim.sx1, l._y0], target: [anim.tx0, l._y1] });
      anim.el.setAttribute("d", d || "");
      anim.el.setAttribute("stroke-width", Math.max(1, w));
      anim.el.setAttribute("opacity", (l._opacity ?? 0.9).toFixed(3));
    }
  }

  #setLabelGeoms(nodeAnims, e) {
    nodeAnims.forEach((a) => {
      if (!a.labelEl) return;
      const d = a.node;
      const { x, anchor } = this.#labelPosition(d);
      // Round 20 (T3), re-anchored by Round 23 (note 3): the Un-Allocated
      // label BOTTOM-anchors on its stub (the pre-fan-out fixed point, see
      // #unallocLabelCenterY); every other label centers on the drawn
      // rect.
      // Round 22 (N2): + the label-only min-padding offset (see
      // #ensureAllocationLabelGaps — the label shifts, the bar does not).
      const y = d.kind === "unallocated"
        ? this.#unallocLabelCenterY(d)
        : (d._y0 + d._y1) / 2 + (d._labelDy ?? 0);
      const text = a.labelEl.querySelector("text");
      if (!text) return;
      // Round 19 (P2, owner round 18b): the text keeps the plain gutter x
      // from #labelPosition (bar edge + 6) — the chip no longer offsets it.
      // The chip (logo image OR kind-icon g, identical rule as
      // #writeLabelText) is centered on the node bar's midline and tracks
      // the bar as the node animates.
      const { LOGO_CHIP_SIZE: CHIP } = this.constructor;
      const textX = x;
      const chipX = (d.x0 + d.x1) / 2 - CHIP / 2;
      text.setAttribute("x", textX);
      text.setAttribute("y", y);
      text.querySelectorAll("tspan").forEach((ts) => {
        if (ts.getAttribute("x")) ts.setAttribute("x", textX);
      });
      const chip = a.labelEl.querySelector("image.planflow-logo, g.planflow-kind-icon");
      if (chip) {
        if (chip.localName === "g")
          chip.setAttribute("transform", `translate(${chipX}, ${y - CHIP / 2}) scale(${CHIP / 24})`);
        else {
          chip.setAttribute("x", chipX);
          chip.setAttribute("y", y - CHIP / 2);
        }
      }
      // Round 20 (T3), re-anchored by Round 23 (note 3): the Un-Allocated
      // dotted outline re-centers on the (bottom-anchored) label y every
      // draw frame - same box as #writeLabelText, only the center moves.
      const outline = a.labelEl.querySelector("rect.planflow-ua-outline");
      if (outline) {
        const k = Math.min(d._labelScale ?? 1, d._manageScale ?? 1);
        // biome-ignore lint/suspicious/noAssignInExpressions: deliberate check-or-init cache idiom — read the cached value, or compute and store it, in one expression.
        const boxes = d._labelBoxes || (d._labelBoxes = this.#labelBoxHeights(d));
        const compact = d.y1 - d.y0 < 24 && d.nodeType !== "income";
        const bw = (compact ? boxes.compact.w : boxes.full.w) * k;
        const bh = (compact ? boxes.compact.h : boxes.full.h) * k;
        const pad = 4 * k;
        outline.setAttribute("x", anchor === "end" ? x - bw - pad * 2 : x - pad);
        outline.setAttribute("y", y - bh / 2 - pad);
        outline.setAttribute("width", bw + pad * 2);
        outline.setAttribute("height", bh + pad * 2);
      }
      // Round 34b (T1): the leftover icon re-applies the SAME slot math
      // every frame (same #leftoverIconPlacement the draw path used — the
      // label box only moves with the label during the entrance tween).
      // Round 34c-fix: the label box is the LIVE text getBBox, not the
      // cached d._labelBoxes probe width — the probe box is a different
      // text variant and can be WIDER than the rendered run (measured
      // 191.20 vs 168.53 on the live plan), which pushed the fallback
      // slot ~23px left of the real text start. Only nodes that actually
      // carry an icon measure here (at most 2 per plan), so the frame
      // path stays allocation-light.
      const icon = a.labelEl.querySelector("g.planflow-leftover-icon");
      if (icon) {
        const k = Math.min(d._labelScale ?? 1, d._manageScale ?? 1);
        const boxSize = this.constructor.LEFTOVER_ICON_SIZE * k;
        let labelBox = null;
        const iconTextEl = a.labelEl.querySelector("text");
        if (iconTextEl && typeof iconTextEl.getBBox === "function") {
          try {
            const liveBox = iconTextEl.getBBox();
            if (liveBox.width > 0) labelBox = { x: liveBox.x, width: liveBox.width };
          } catch { labelBox = null; }
        }
        if (!labelBox) {
          const boxes = d._labelBoxes || (d._labelBoxes = this.#labelBoxHeights(d));
          const compact = d.y1 - d.y0 < 24 && d.nodeType !== "income";
          const labelW = (compact ? boxes.compact.w : boxes.full.w) * k;
          labelBox = anchor === "end" ? { x: x - labelW, width: labelW } : { x, width: labelW };
        }
        const slot = this.constructor.leftoverIconPlacement({
          anchor,
          labelBox,
          bandX0: d.x0,
          bandX1: d.x1,
          boxSize,
          centerY: y,
          // Round 34c: the name<->amount gap the draw path measured and
          // cached (null -> the 4px default).
          clearance: d._leftoverIconClearance ?? null,
        });
        icon.setAttribute("transform", `translate(${slot.x}, ${slot.y}) scale(${k})`);
      }
      const fade = a.dying ? 1 - e : a.spawn ? e : 1;
      a.labelEl.setAttribute("opacity", (fade * (a.labelFinalOpacity ?? 1)).toFixed(3));
    });
  }

  #setBadgeGeoms(badgeAnims, e) {
    badgeAnims.forEach((a) => {
      if (!a.badgeEl) return;
      const d = a.node;
      const { x, anchor } = this.#labelPosition(d);
      const badgeWidth = Number(a.badgeEl.querySelector("rect")?.getAttribute("width") || 0);
      const y = (d._y0 + d._y1) / 2 + 24;
      a.badgeEl.setAttribute("transform", `translate(${anchor === "start" ? x : x - badgeWidth}, ${y})`);
      const fade = a.dying ? 1 - e : a.spawn ? e : 1;
      a.badgeEl.setAttribute("opacity", fade.toFixed(3));
    });
  }

  // Instant draw (first load / post-fallback): final geometry, no tween.
  #applyGeometry(anims) {
    anims.nodeAnims.forEach((a) => {
      const d = a.node;
      d._x0 = d.x0;
      // Round 16.7: the drawn rect (_fy0/_fy1) carries the manage
      // draw-level floor extension; view nodes have none (?? falls back
      // to the layout geometry, byte-identical).
      d._y0 = d._fy0 ?? d.y0;
      d._y1 = d._fy1 ?? d.y1;
      this.#setNodeGeom(a, 1);
    });
    anims.linkAnims.forEach((a) => {
      const l = a.link;
      l._y0 = l.y0;
      l._y1 = l.y1;
      l._width = Math.max(1, l._fw ?? l.width);
      l._opacity = a.dying ? 0 : 1;
      this.#setLinkGeom(a);
    });
    this.#setLabelGeoms(anims.nodeAnims, 1);
    this.#setBadgeGeoms(anims.badgeAnims, 1);
  }

  #commitLayout(layout) {
    const { nodes, links } = layout;
    this.lastLayout = {
      nodes: nodes
        .filter((d) => d.label !== false && d.y1 - d.y0 >= 1)
        .map((d) => ({ ...d, drawn: true })),
      links: links
        .filter((l) => l.width > 0)
        .map((l) => ({ ...l, key: this.#linkKey(l), y0: l.y0, y1: l.y1, width: l.width, drawn: true })),
    };
    this.currentFrame = null;
  }

  // ---- The tween (R7) ------------------------------------------------------

  #animateTo(anims, layout) {
    const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);
    const easeOut = (t) => 1 - (1 - t) ** 3;
    const token = ++this.animationToken;

    const { nodeAnims, linkAnims, badgeAnims } = anims;
    const spawning = linkAnims.filter((a) => a.spawning);

    const step = (now) => {
      if (this.animationToken !== token) return;
      const t1 = Math.min(1, (now - this.phase1Start) / this.constructor.ANIM_NODE_MS);
      const e1 = easeInOut(t1);
      try {
        // Phase 1: nodes grow / shrink / slide; existing bands follow.
        nodeAnims.forEach((a) => {
          const d = a.node;
          d._x0 = a.from.x0 + (a.to.x0 - a.from.x0) * e1;
          d._y0 = a.from.y0 + (a.to.y0 - a.from.y0) * e1;
          d._y1 = a.from.y1 + (a.to.y1 - a.from.y1) * e1;
          this.#setNodeGeom(a, a.dying ? 1 - e1 : 1);
        });
        linkAnims.forEach((a) => {
          const l = a.link;
          l._y0 = a.from.y0 + (a.to.y0 - a.from.y0) * e1;
          l._y1 = a.from.y1 + (a.to.y1 - a.from.y1) * e1;
          l._width = a.spawning ? 0 : a.from.width + (a.to.width - a.from.width) * e1;
          if (a.dying) l._opacity = 0.9 * (1 - e1);
          this.#setLinkGeom(a);
        });
        this.#setLabelGeoms(nodeAnims, e1);
        this.#setBadgeGeoms(badgeAnims, e1);
      } catch (error) {
        console.error("plan-flow diagram animation failed", error);
        this.#fallback(`${this.labelsValue.error || "Couldn't draw the diagram — refresh the page."} [${error.name}: ${error.message}${error.stack ? ` | ${String(error.stack).split("\n").slice(1, 2).join("")}` : ""}`);
        return;
      }
      // Live geometry snapshot: lets a faster mutation hand off mid-tween.
      this.currentFrame = {
        nodes: nodeAnims.filter((a) => !a.dying).map((a) => ({ ...a.node, x0: a.node._x0, y0: a.node._y0, y1: a.node._y1, drawn: true })),
        links: linkAnims.filter((a) => !a.dying && !a.spawning).map((a) => ({ ...a.link, key: a.key, y0: a.link._y0, y1: a.link._y1, width: a.link._width ?? 0, drawn: true })),
      };

      if (t1 < 1) {
        this.rafId = requestAnimationFrame(step);
        return;
      }
      if (this.animationToken !== token) return;

      // Nodes settled: retire what is dying, then expand the new bands in.
      nodeAnims.filter((a) => a.dying).forEach((a) => {
        a.el?.remove();
        a.labelEl?.remove();
      });
      badgeAnims.filter((a) => a.dying).forEach((a) => a.badgeEl?.remove());
      linkAnims.filter((a) => a.dying).forEach((a) => a.el?.remove());
      if (spawning.length === 0) {
        this.#commitLayout(layout);
        this.rafId = null;
        return;
      }

      // Phase 2: new flow bands grow out from the source bank + fade in.
      this.phase2Start = now;
      const step2 = (now2) => {
        if (this.animationToken !== token) return;
        const t2 = Math.min(1, (now2 - this.phase2Start) / this.constructor.ANIM_LINK_MS);
        const e2 = easeOut(t2);
        try {
          spawning.forEach((a) => {
            const l = a.link;
            l._width = a.to.width * e2;
            l._opacity = 0.9 * e2;
            this.#setLinkGeom(a);
          });
        } catch (error) {
          console.error("plan-flow diagram animation failed", error);
          this.#fallback(`${this.labelsValue.error || "Couldn't draw the diagram — refresh the page."} [${error.name}: ${error.message}${error.stack ? ` | ${String(error.stack).split("\n").slice(1, 2).join("")}` : ""}`);
          return;
        }
        if (t2 < 1) {
          this.rafId = requestAnimationFrame(step2);
          return;
        }
        if (this.animationToken !== token) return;
        this.#commitLayout(layout);
        this.rafId = null;
      };
      this.rafId = requestAnimationFrame(step2);
    };

    // Defer the first frame so the browser has painted the joined DOM.
    this.phase1Start = null;
    this.rafId = requestAnimationFrame((now) => {
      this.phase1Start = now;
      step(now);
    });
  }

  #cancelAnimation() {
    if (this.rafId) cancelAnimationFrame(this.rafId);
    this.rafId = null;
    this.animationToken++;
  }

  // R6 (owner round 3): a FLAT top across all columns. d3-sankey centers
  // each column in the extent, so a shorter column sits LOWER than the
  // tallest one and its top overhangs. Compute one shared top edge = the
  // TALLEST column's top (the HIGHEST top line = the MINIMUM y0) and shift
  // every other column UP to it: nothing extends above the flat top, and a
  // column that only moves upward can never overflow the extent bottom.
  // (Owner round 6: this was Math.max, i.e. the SHORTEST column's top —
  // every tall column got shifted DOWN, overflowed the bottom, and the
  // safety-net compression below then shrank the NODES while the band
  // widths kept their pre-compression thickness. Bands oversize past their
  // nodes, stick out above the top and overlap each other.)
  // The compression stays as a safety net only; if it ever fires, band
  // widths are scaled too, so bands can never outgrow their nodes again.
  #flattenColumns(layout, width, height) {
    const { EXTENT_MARGIN } = this.constructor;
    const extentBottom = height - EXTENT_MARGIN;
    const columns = new Map();
    layout.nodes.forEach((n) => {
      if (n.column === undefined) return;
      const list = columns.get(n.column) || [];
      list.push(n);
      columns.set(n.column, list);
    });
    const tops = [];
    columns.forEach((list) => {
      const drawn = list.filter((n) => n.label !== false);
      if (drawn.length > 0) tops.push(Math.min(...drawn.map((n) => n.y0)));
    });
    if (tops.length === 0) return;
    // Tallest column = highest top line = smallest y0. (Math.max picked the
    // shortest column's top and pushed every tall column past the bottom.)
    const flatTop = Math.min(...tops);

    const transforms = new Map();
    columns.forEach((list, col) => {
      const drawn = list.filter((n) => n.label !== false);
      if (drawn.length === 0) return;
      const colTop = Math.min(...drawn.map((n) => n.y0));
      const colBottom = Math.max(...drawn.map((n) => n.y1));
      const shift = flatTop - colTop;
      let s = 1;
      if (colBottom + shift > extentBottom) {
        s = (extentBottom - flatTop) / Math.max(1e-6, colBottom + shift - flatTop);
      }
      transforms.set(col, { shift, s });
    });
    if (transforms.size === 0) return;

    const map = (y, t) => (t.s === 1 ? y + t.shift : flatTop + (y + t.shift - flatTop) * t.s);
    transforms.forEach((t, col) => {
      columns.get(col).forEach((n) => {
        n.y0 = map(n.y0, t);
        n.y1 = map(n.y1, t);
      });
    });
    // A band's source side follows its source column, its target side its
    // target column.
    layout.links.forEach((l) => {
      const ts = transforms.get(l.source.column);
      const tt = transforms.get(l.target.column);
      if (ts) l.y0 = map(l.y0, ts);
      if (tt) l.y1 = map(l.y1, tt);
      // If the safety-net compression ever engages (s < 1), the band must
      // shrink with the columns it spans, or it outgrows its nodes (the
      // exact defect of round 6). Geometric mean: exact when both ends share
      // a scale, minimal error when they differ.
      const sw = Math.sqrt((ts ? ts.s : 1) * (tt ? tt.s : 1));
      if (sw !== 1) l.width *= sw;
    });
    // Round 15 (owner note 2): sub-account rows sit IN-LINE with their
    // parent bank row (each parent's child group centered on the parent's
    // vertical center) - the same post-flatten pattern on purpose: the
    // flat-top re-anchoring above would undo any pre-flatten shift.
    this.#placeSubAccountRows(layout, height);
    // Round 24 (owner): the #resolveManageLabelOverlaps call is RETIRED
    // here (defect factory: 0.01px-gap re-tiling + 0.7682x font shrink +
    // overlapping drawn rects). The method body below stays dead/inert
    // until a future round explicitly re-activates it. Its label-clearance
    // goal is now met by #manageRowGapsAndExtent's grown canvas plus the
    // #ensureAllocationLabelGaps no-op safety net further below.
    // Round 16.7: the manage draw-level floors (label-floor node rects +
    // band thicknesses) — the layout above is already the view's
    // strictly-proportional geometry; this extends the DRAWN rect/band
    // only. No-op in view mode.
    this.#applyManageFloors(layout);
    // Round 24 (owner): the MANAGE-only row-gap re-stack — fixed ROW_GAP
    // between every DRAWN row of the bank and allocation/surplus columns,
    // drawn heights (_fy1-_fy0) unchanged, overall height allowed to grow
    // (lastChartHeight is grown in place; the callers re-read it AFTER
    // this pass, so #draw sizes the svg to the grown canvas). Runs AFTER
    // the floors (drawn _fy0/_fy1 are final) and BEFORE the band
    // re-derivation so #realignManageBands / #resolveManageLinkOrder
    // re-derive anchors from the FINAL centers. View mode returns early.
    this.#manageRowGapsAndExtent(layout, height);
    // Round 23 (note 2, owner reversal): the VIEW-mode 3px sliver for real
    // sub-pixel allocation/surplus rows (VIEW only; #applyManageFloors is
    // the no-op in view that this complements — after this line _fy0/_fy1
    // exist in BOTH modes for those rows).
    this.#applyViewRowSlivers(layout);
    // Round 19 (B): re-derive the band anchors from the DRAWN geometry
    // (MANAGE only) — LAST, after the floors set the drawn bodies.
    this.#realignManageBands(layout);
    // Round 20 (T4): the link-anchor stacking contract (far-endpoint y
    // order per edge) enforced AFTER the final passes — idempotent, so the
    // no-sub-account cases stay byte-identical (J S6a-d verifies).
    this.#resolveManageLinkOrder(layout);
    // Round 22 (N2, owner): the allocation/surplus label min-padding pass
    // (MANAGE only; LABEL-ONLY — it never moves a node or a band: it
    // enforces the visible inter-label gap by shifting label y only, and
    // forces the compact one-line variant in dense columns). Round 24:
    // runs against the GROWN canvas height (this.lastChartHeight — grown
    // in place by #manageRowGapsAndExtent in manage, the design height in
    // view) so the 8px block gaps + 16px boxes leave >= 12px of label
    // clearance everywhere and the pass degrades to a no-op safety net
    // (all _labelDy stay 0; labels center exactly on the block centers).
    this.#ensureAllocationLabelGaps(layout, this.lastChartHeight);
    // Round 21 (T1) + Round 22 (N3, owner): the Un-Allocated stubs sit a
    // short STRAIGHT stub flush at their income's right edge (bottom-anchored,
    // gap 0) instead of sweeping the full chart width. Round 22: ONE rule
    // for EVERY plan (allocating AND empty — the round-21 empty-plan gate
    // and the round-14/15 #placeUnallocatedTails pass are unified into this
    // one). LAST on purpose: it overrides the pillar x/y and the hatched
    // band anchors after every pass that could have moved them (it also
    // runs after #applyManageFloors, so its _fy0/_fy1 win for the manage
    // rect).
    this.#placeUnallocatedNearTails(layout);
    // Round 22 (N4, owner): the bank column is pinned dead-center on the
    // diagram (mode-independent x override — node.column is unchanged).
    this.#pinBankColumn(layout, width);
  }

  // Round 15 (owner note 2, 2026-11-07): a sub-account row belongs IN-LINE
  // with its parent bank row - the owner's "smooth fan out from the Account
  // to the Sub-Account to the Savings Item". d3-sankey stacks the dedicated
  // sub-account column (column 3) top-down from the extent top, so the
  // children would otherwise land at the CHART TOP no matter where the
  // parent bank row sits (round-15 screenshots: top-stacked children, the
  // long crossing fan-out band, child labels spilling into the bank column
  // and overlapping the bank labels). This pass re-centers each parent's
  // child group on the parent's vertical center:
  //   - the children keep their laid-out heights, the laid-out inter-child
  //     gap (the column padding d3 used between them), and their ROW ORDER
  //     = the fan-out target order, so band order = row order (no crossing
  //     inside the group, and the child -> allocation bands keep grouping
  //     under the child row);
  //   - the group is clamped inside the extent (an extreme parent slides
  //     the group; nothing clips);
  //   - two different parents' groups that would collide are pushed
  //     apart (first group keeps its in-line position);
  //   - the PARENT's outgoing anchors (its own allocation/surplus/anchor
  //     bands + the fan-out bands) and each child's incoming/outgoing
  //     anchors are re-stacked in d3's crossing-free order (ascending
  //     counterpart center-y, the reorderNodeLinks invariant), so every
  //     band stays attached after the move.
  // Runs at the end of #flattenColumns (after #placeUnallocatedNearTails): the
  // flat-top re-anchoring undoes pre-flatten shifts (G's lesson), and the
  // two post-flatten passes touch disjoint node sets (pillars/incomes vs
  // children/parents), so their order is safe.
  #placeSubAccountRows(layout, height) {
    const { EXTENT_MARGIN, HEADER_SPACE } = this.constructor;
    const top = HEADER_SPACE;
    const bottom = height - EXTENT_MARGIN;
    const nodeById = new Map(layout.nodes.map((n) => [n.id, n]));
    const groups = new Map();
    layout.nodes.forEach((n) => {
      if (!n.subAccount || !n.parentAccount) return;
      const list = groups.get(n.parentAccount) || [];
      list.push(n);
      groups.set(n.parentAccount, list);
    });
    if (groups.size === 0) return;
    // Row order = fan-out order = target order (the order d3 already laid
    // the column out in: sortKey = parentIdx + (rank+1)/(count+1)).
    const placed = [];
    groups.forEach((children, parentId) => {
      const parent = nodeById.get(`bank:${parentId}`);
      if (!parent) return;
      children.sort((a, b) => (a.sortKey ?? 0) - (b.sortKey ?? 0));
      // The gap d3 left between the children in their (old, top-stacked)
      // column: preserve it so the group keeps its laid-out spacing.
      let gap = 0;
      for (let i = 1; i < children.length; i += 1) {
        gap = Math.max(gap, children[i].y0 - children[i - 1].y1);
      }
      // Round 19 (C, MANAGE only): the sibling labels stand taller than
      // the rows — widen the inter-row gap to the label clearance so the
      // child labels (which sit LEFT of the col-3 nodes, in the same
      // x-zone as the parent labels right of the col-2 nodes) never stack
      // into each other. The view path keeps the legacy gap (byte-identity).
      // Round 19 (C, MANAGE only): the sibling labels stand taller than
      // the rows (label = row center +/- floor/2, floor > row height).
      const labelFloorOf = (n) =>
        this.#labelFloorHeight(n) + this.constructor.LABEL_FLOOR_PADDING;
      const overhang = (n) =>
        Math.max(0, labelFloorOf(n) - (n.y1 - n.y0)) / 2;
      if (this.mode !== "view") {
        for (let i = 1; i < children.length; i += 1) {
          const a = children[i - 1];
          const b = children[i];
          const need =
            labelFloorOf(a) / 2 + labelFloorOf(b) / 2 -
            (a.y1 - a.y0) / 2 - (b.y1 - b.y0) / 2 + 2;
          gap = Math.max(gap, need);
        }
      }
      const totalH =
        children.reduce((s, c) => s + (c.y1 - c.y0), 0) + gap * (children.length - 1);
      let y = (parent.y0 + parent.y1) / 2 - totalH / 2;
      if (y < top) y = top;
      if (y + totalH > bottom) y = Math.max(top, bottom - totalH);
      // Round 19 (C, MANAGE only): stagger the group off the parent's
      // label band. The child labels (left of the col-3 nodes, x ~ the
      // col2/col3 gap) and the parent bank labels (right of the col-2
      // nodes) share an x-zone, so a child row centered on the parent
      // makes the texts overlap (owner round 19: "slightly move down the
      // sub-account"). The group therefore starts BELOW the parent's
      // label box (clearance: the FIRST child's label stands above its
      // row by overhang(first)); only when that overflows the canvas
      // bottom does the group alternate ABOVE the parent's label box
      // (clearance: the LAST child's label stands below its row by
      // overhang(last)). The VIEW path keeps the exact legacy centered
      // placement (byte-identity contract).
      let overTop = 0;
      if (this.mode !== "view") {
        const first = children[0];
        const last = children[children.length - 1];
        overTop = overhang(first);
        const overBot = overhang(last);
        const lf = labelFloorOf(parent);
        const pc = (parent.y0 + parent.y1) / 2;
        const pBoxBot = pc + lf / 2;
        const pBoxTop = pc - lf / 2;
        const downY = Math.max(pBoxBot + 2 + overTop, top);
        if (downY + totalH > bottom) {
          // Alternating pattern: place ABOVE the parent's label box
          // instead (still off its y-band), then clamp to the canvas.
          y = Math.max(top, Math.min(pBoxTop - 2 - overBot - totalH, bottom - totalH));
        } else {
          y = downY;
        }
      }
      // De-overlap: a later group may not cover an earlier one (the child
      // rows share the column). Round 19 (manage): the clearance is the
      // previous group's LABEL-box bottom (the child labels are taller
      // than the rows) plus this group's own upward label overhang; the
      // view keeps the legacy row-bottom clearance.
      let clash = false;
      placed.forEach((p) => {
        const need =
          this.mode === "view" ? p.end + 0.5 : p.endLabel + 2 + overTop;
        if (y < need) {
          y = need;
          clash = true;
        }
      });
      if (clash && y + totalH > bottom) y = Math.max(top, bottom - totalH);
      children.forEach((c) => {
        const h = c.y1 - c.y0;
        c.y0 = y;
        c.y1 = y + h;
        y += h + gap;
      });
      let endLabel = children[0].y0 + totalH;
      if (this.mode !== "view") {
        // The bottom-most child's label box bottom (its box stands taller
        // than its row) is the group's label clearance for the next group.
        const last = children[children.length - 1];
        const lf = this.#labelFloorHeight(last) + this.constructor.LABEL_FLOOR_PADDING;
        endLabel = last.y0 + (last.y1 - last.y0) / 2 + lf / 2;
      }
      placed.push({ end: children[0].y0 + totalH, endLabel });
      this.#restackAnchors(parent);
      children.forEach((c) => this.#restackAnchors(c));
    });
  }

  // The d3 reorderNodeLinks invariant applied to one node after a
  // post-layout y move (same anchor convention as the Un-Allocated
  // outflow re-stack: cumulative widths from the node top, each band's
  // anchor at the middle
  // of its slice): outgoing links ordered by target center-y, incoming
  // links ordered by source center-y. Zero-width pins order by the same
  // key; their width 0 adds no space.
  #restackAnchors(node) {
    const centerOf = (n) => (n.y0 + n.y1) / 2;
    const outgoing = [...(node.sourceLinks || [])].sort((a, b) => centerOf(a.target) - centerOf(b.target));
    let e = node.y0;
    outgoing.forEach((l) => {
      l.y0 = e + l.width / 2;
      e += l.width;
    });
    const incoming = [...(node.targetLinks || [])].sort((a, b) => centerOf(a.source) - centerOf(b.source));
    e = node.y0;
    incoming.forEach((l) => {
      l.y1 = e + l.width / 2;
      e += l.width;
    });
  }

  // Round 22 (N3, owner): ONE Un-Allocated stub rule for EVERY plan —
  // allocating AND empty (the round-21 `allocations.length === 0` gate and
  // the round-14/15 #placeUnallocatedTails view/deficit passes are GONE;
  // this is the only Un-Allocated pass left). Owner intent: "it shouldn't
  // move down or bend. It should be straight out and stop super early."
  // Per income (income order, top first):
  //   h = (pillar.value / income.value) * incomeH — value-proportional on
  //       d3's single global scale (= the pillar's natural height at the
  //       income's post-flatten height), FLOORED at the label height
  //       (#labelFloorHeight + LABEL_FLOOR_PADDING) so the always-show
  //       label fits. NO 0.25·incomeH cap (the round-21 T1 cap is removed:
  //       value-proportional IS the "stop super early" intent — the live
  //       plan renders Kurt 55.01px / Sammi 129.06px).
  //   bottom-anchored: pillar.y1 = income.y1, pillar.y0 = y1 - h (stub
  //       bottoms align with the income bottoms). Collision-safe: stub_i
  //       ⊆ [income_i.y0, income_i.y1] and the d3 incomes are disjoint
  //       with >= 5px padding, so the stubs never overlap each other.
  //   flush, gap 0: pillar.x0 = income.x1 (the stub touches the income's
  //       right edge; UA_GAP is now 0), x1 = x0 + NODE_WIDTH. The label
  //       stays right of the stub (#placeLabel default for x0 < W/2).
  //   straight band: l.nearTail -> #straightRibbonPath (4-point M/L, no
  //       bend). l.width = l._fw = h — set BOTH (manage's
  //       #applyManageFloors read the old _fw earlier, view leaves _fw
  //       undefined). With gap 0 the band is a zero-span straight sliver;
  //       the visible unallocated mark is the hatched stub node itself
  //       (the hatched pattern stays — it is the unallocated visual).
  //   the income-outflow re-stack is kept: the solid bank bands keep d3's
  //       (target-y ordered, crossing-free) relative order from
  //       income.y0, the hatched band is LAST (the income's bottom
  //       sliver), anchors l.y0 = income.y1 - l.width/2 (source),
  //       l.y1 = pillar.y0 + l.width/2 (stub top).
  // Runs LAST in #flattenColumns on purpose: it overrides the pillar x/y
  // and the hatched band anchors after every pass that could have moved
  // them, and after #applyManageFloors so its _fy0/_fy1 win the manage
  // drawn rect (view mode: _fy0/_fy1 equal the layout geometry, so the
  // same stub renders in view too). #ribbonPath (the cubic) and the
  // #placeLabel probe guard stay byte-untouched; every hatched
  // income->pillar link sets nearTail, so the cubic is no longer
  // reachable for them.
  #placeUnallocatedNearTails(layout) {
    const tails = [];
    layout.links.forEach((l) => {
      if (!l.hatched || !l.target || l.target.kind !== "unallocated") return;
      tails.push(l);
    });
    if (tails.length === 0) return;
    const { NODE_WIDTH, LABEL_FLOOR_PADDING } = this.constructor;
    // hatched links are built in income order by #buildGraph -> income
    // order here (top income first).
    tails.forEach((l) => {
      const income = l.source;
      const pillar = l.target;
      const incomeH = income.y1 - income.y0;
      const naturalH = (pillar.value / income.value) * incomeH;
      const labelFloorH = this.#labelFloorHeight(pillar) + LABEL_FLOOR_PADDING;
      const h = Math.max(naturalH, labelFloorH);
      const y1 = income.y1; // bottom-anchored: stub bottoms align with
      const y0 = y1 - h; // the income bottoms
      const x0 = income.x1; // flush at the income's right edge (gap 0)
      const x1 = x0 + NODE_WIDTH;
      // 1) Re-stack the income's outgoing anchors: the bank bands keep
      // d3's (target-y ordered, crossing-free) relative order, the
      // hatched band is LAST so its source anchor is the bottom sliver
      // of the outflow stack.
      const outgoing = (income.sourceLinks || []).filter((x) => x !== l);
      let e = income.y0;
      outgoing.forEach((x) => {
        x.y0 = e + x.width / 2;
        e += x.width;
      });
      pillar.y0 = y0;
      pillar.y1 = y1;
      pillar.x0 = x0;
      pillar.x1 = x1;
      // The manage drawn rect follows the stub: #applyManageFloors ran
      // earlier, so these (this pass is LAST in #flattenColumns) win.
      // View mode is unaffected — _fy0/_fy1 equal the layout geometry.
      pillar._fy0 = y0;
      pillar._fy1 = y1;
      // 2) Straight band, flush at the income edge: source anchor = the
      // income's bottom sliver, target anchor = the stub top sliver.
      l.width = h;
      l._fw = h;
      l.y0 = income.y1 - l.width / 2;
      l.y1 = pillar.y0 + l.width / 2;
      l.nearTail = true;
    });
  }

  // Round 22 (N4, owner): the bank (accounts) column is pinned dead-center
  // on the diagram — center-x == width/2 — in BOTH modes. Owner ask:
  // "Accounts are not Center Aligned properly, they should be dead center,
  // aligned with the 'Add Account' button." The button sits top-center at
  // the container center, so pinning at width/2 aligns both, and the
  // income->bank / bank->allocation ribbon spans become symmetric
  // ((bank.x0 - income.x1) == (allocation.x0 - bank.x1)).
  // Mode-independent on purpose: both modes run the same #flattenColumns
  // pipeline, so the manage==view byte-identity holds. node.column is
  // UNCHANGED (an x override, not a column reassignment), so the d3
  // column-index asserts keep passing; labels, logo chips, hit rects,
  // node paths and link gradients/anchors all derive from x0/x1 every
  // frame and follow automatically.
  // Label side: the owner asked only for centering; the labels stay where
  // they were (toward the income side, the 'end' side as before the pin).
  // At the new x the #placeLabel heuristic would flip them to 'start'
  // (right of the bar), so _labelSide is locked here and #placeLabel
  // keeps the locked side (still fitting _labelScale for it).
  // Sub-account children keep their own d3 column x (only top-level
  // banks are pinned).
  #pinBankColumn(layout, width) {
    const { NODE_WIDTH } = this.constructor;
    const x0 = width / 2 - NODE_WIDTH / 2;
    layout.nodes.forEach((n) => {
      if (n.kind !== "bank" || n.subAccount) return;
      n.x0 = x0;
      n.x1 = x0 + NODE_WIDTH;
      n._labelSide = "end";
      n._labelSideLocked = true;
    });
  }

  // Round 22 (N2, owner): the allocation/surplus/bank label min-padding
  // pass, MANAGE mode only, LABEL-ONLY — it never moves a node or a band
  // (the bands must stay strictly proportional), it shifts the LABEL y
  // only. Owner ask: "the Labels on the right for Allocations ... are
  // still overlapping, they should have some padding between each
  // colored label." Round 23 (note 1, owner): the BANK column now also
  // runs the pass — the 6 small bank rows drew 20px rects carrying 16px
  // label boxes only 10-14px apart (measured minGap -5.93px, 5 of 7
  // adjacent pairs overlapping) — and the minimum gap grew from 4px to
  // 8px. Fit budget (verified at the owner's 1754px viewport, ~430px
  // canvas): the bank column fits (353 + 28 < 430) and the allocation
  // column's extra +60px over the old 4px floor is absorbed by the
  // existing bottom clamp.
  // Root cause: #resolveManageLabelOverlaps tiles the NODES with
  // a gap that degrades to the 0.01px floor when the canvas can't hold
  // the 15px reference padding, so the drawn label boxes end up touching
  // (and at the owner's window size, two-line 27px boxes collide) while
  // the node bars keep the tiling grid.
  //   1. Dense columns — the two-line box budget n*fullH + (n-1)*MIN_GAP
  //      at the final column scale exceeds the canvas — get the COMPACT
  //      one-line label variant forced (d._forceCompactLabel, consumed
  //      by #writeLabelText's compactOverride at the draw + measure
  //      probes): 16 one-line boxes fit with room to spare, 16 two-line
  //      boxes cannot (16*27 + 15*8 = 552 > ~430).
  //   2. A 1-D order-preserving pass over the column's label boxes
  //      (drawn centers on the post-floor _fy0/_fy1, measured box
  //      heights at the final scale) enforces a MINIMUM 8px gap between
  //      adjacent boxes by shifting the label y only (d._labelDy,
  //      consumed by #setLabelGeoms ON TOP of the drawn _fy0/_fy1
  //      centering — labels stay centered on their band except as far as
  //      the padding forces), with a final bottom clamp so the last box
  //      stays on-canvas. The gap is a hard 8px (not 15px * scale): the
  //      tiling grid (15.36px pitch on the live 16-allocation column)
  //      plus the column's natural group gaps fit the ~8px minimum —
  //      demanding the 15px reference padding makes the stack ~120px
  //      taller than the canvas and pushes the bottom labels off it.
  #ensureAllocationLabelGaps(layout, height) {
    if (this.mode === "view") return;
    const { EXTENT_MARGIN, HEADER_SPACE } = this.constructor;
    const canvasTop = HEADER_SPACE;
    const canvasBottom = height - EXTENT_MARGIN;
    // Round 23 (note 1, owner): 8px minimum (was 4px) — the owner wants
    // visible padding, and the fit budget at 1754px holds (see the pass
    // comment above).
    const MIN_GAP = 8;
    const cols = new Map();
    layout.nodes.forEach((n) => {
      if (n.label === false) return;
      // Round 23 (note 1, owner): the bank column now runs the pass too.
      // Banks (incl. sub-accounts) have kind:"bank" and no nodeType, so
      // the old allocation/surplus filter excluded them — that was the
      // overlap root cause (20px rows, 16px label boxes 10-14px apart).
      if (n.nodeType !== "allocation" && n.nodeType !== "surplus" && n.kind !== "bank") return;
      const list = cols.get(n.column) || [];
      list.push(n);
      cols.set(n.column, list);
    });
    cols.forEach((list) => {
      list.sort((a, b) => a.y0 - b.y0);
      const n = list.length;
      if (n === 0) return;
      const kOf = (x) => Math.min(x._labelScale ?? 1, x._manageScale ?? 1);
      const boxesOf = (x) => x._labelBoxes || (x._labelBoxes = this.#labelBoxHeights(x));
      // 1) Dense columns render the compact one-line variant instead.
      const fullBudget =
        list.reduce((s, x) => s + boxesOf(x).full.h * kOf(x), 0) + (n - 1) * MIN_GAP;
      if (fullBudget > canvasBottom - canvasTop) {
        list.forEach((x) => {
          x._forceCompactLabel = true;
        });
      }
      // 2) Label-only min-gap pass (order-preserving, top to bottom).
      const compactOf = (x) =>
        x._forceCompactLabel === true || (x.y1 - x.y0 < 24 && x.nodeType !== "income");
      const hOf = (x) => (compactOf(x) ? boxesOf(x).compact : boxesOf(x).full).h * kOf(x);
      const cOf = (x) => ((x._fy0 ?? x.y0) + (x._fy1 ?? x.y1)) / 2;
      const hs = list.map(hOf);
      const cs = list.map(cOf);
      const dys = [0];
      for (let i = 1; i < n; i += 1) {
        const gapNow = cs[i] - cs[i - 1] - (hs[i] + hs[i - 1]) / 2;
        // Hard 8px minimum (owner R23 note 1): anything larger does not
        // fit the 16-label column (see the pass comment above).
        dys[i] = dys[i - 1] + Math.max(0, MIN_GAP - gapNow);
      }
      // Final extent clamp: the last box may not run past the canvas
      // bottom (shift the whole column's labels up — label y only).
      const lastBottom = cs[n - 1] + dys[n - 1] + hs[n - 1] / 2;
      const overflow = Math.max(0, lastBottom - canvasBottom);
      if (overflow > 0) {
        for (let i = 0; i < n; i += 1) dys[i] -= overflow;
      }
      // Top clamp (the pass only pushes down; a clamped column moves up,
      // so the first box top stays on-canvas — verified, not re-clamped).
      const firstTop = cs[0] + dys[0] - hs[0] / 2;
      if (firstTop < canvasTop && canvasTop > 0) {
        // defensive: shift back down if the up-shift crossed the header
        list.forEach((x, i) => {
          x._labelDy = dys[i] + (canvasTop + hs[0] / 2 - firstTop);
        });
        return;
      }
      list.forEach((x, i) => {
        if (dys[i] !== 0) x._labelDy = dys[i];
      });
    });
  }

  // House rounded node path (left column rounded left, right column rounded
  // right), 8px radius clamped by half the height.
  #nodePath(x0, y0, x1, y1, d) {
    if (y1 - y0 < 1) return null;
    const radius = Math.min(this.constructor.CORNER_RADIUS, (y1 - y0) / 2);
    const isSource = d.sourceLinks?.length > 0;
    const isTarget = d.targetLinks?.length > 0;
    if (isSource && !isTarget) return this.#roundedLeftPath(x0, y0, x1, y1, radius);
    if (isTarget && !isSource) return this.#roundedRightPath(x0, y0, x1, y1, radius);
    return this.#rectPath(x0, y0, x1, y1);
  }

  // Hatched Un-Allocated ribbon: a filled area (gradient + pattern).
  #ribbonPath(sx, tx, sy, ty, w) {
    const sy0 = sy - w / 2;
    const sy1 = sy + w / 2;
    const ty0 = ty - w / 2;
    const ty1 = ty + w / 2;
    const mx = (sx + tx) / 2;
    return `M ${sx},${sy0} C ${mx},${sy0} ${mx},${ty0} ${tx},${ty0} L ${tx},${ty1} C ${mx},${ty1} ${mx},${sy1} ${sx},${sy1} Z`;
  }

  // Round 21 (T1): the straight Un-Allocated stub band (empty plans only,
  // l.nearTail): a 4-point M/L polygon. The stub sits a fixed gap off the
  // income edge with the SAME center-y on both ends, so a cubic bezier
  // would just bulge — the straight band is the owner's intent.
  #straightRibbonPath(sx, tx, sy, ty, w) {
    const sy0 = sy - w / 2;
    const sy1 = sy + w / 2;
    const ty0 = ty - w / 2;
    const ty1 = ty + w / 2;
    return `M ${sx},${sy0} L ${tx},${ty0} L ${tx},${ty1} L ${sx},${sy1} Z`;
  }

  #roundedLeftPath(x0, y0, x1, y1, r) {
    return `M ${x1},${y0} L ${x0 + r},${y0} Q ${x0},${y0} ${x0},${y0 + r} L ${x0},${y1 - r} Q ${x0},${y1} ${x0 + r},${y1} L ${x1},${y1} Z`;
  }

  #roundedRightPath(x0, y0, x1, y1, r) {
    return `M ${x0},${y0} L ${x1 - r},${y0} Q ${x1},${y0} ${x1},${y0 + r} L ${x1},${y1 - r} Q ${x1},${y1} ${x1 - r},${y1} L ${x0},${y1} Z`;
  }

  #rectPath(x0, y0, x1, y1) {
    return `M ${x0},${y0} H ${x1} V ${y1} H ${x0} Z`;
  }

  #format(value) {
    return formatCashFlowCurrency(value, this.currencyValue);
  }

  #openNodeDialog(d) {
    const dialog = document.querySelector(`dialog[data-node-id="${d.id}"]`);
    dialog?.showModal();
  }

  // Round 20 (T2, owner round 20): the shared house tooltip is hidden
  // HERE - nothing else touches it. The round-19 defect: #moveTooltip
  // showed the tooltip on node enter/move but the leave path
  // (#hover(null,false)) only reset the highlight, so the floating label
  // stuck until the next item's enter replaced its content.
  #hideTooltip() {
    if (this.tooltip) this.tooltip.style.display = "none";
  }

  #hover(d, entering) {
    const { HOVER_OPACITY, HOVER_FILTER } = this.constructor;
    const nodeSel = this.nodeSelection;
    const linkSel = this.linkSelection;
    if (!entering || !d) {
      // Round 20 (T2): the hide is INDEPENDENT of the d3 selections so it
      // fires even when no draw is attached (and before any reset work).
      this.#hideTooltip();
      if (!nodeSel || !linkSel) return;
      linkSel.selectAll("path.sankey-link").attr("opacity", 0.9).attr("filter", null);
      nodeSel.attr("opacity", 1).attr("filter", null);
      return;
    }
    if (!nodeSel || !linkSel) return;
    const connected = new Set([d]);
    d.sourceLinks.forEach((l) => connected.add(l.target));
    d.targetLinks.forEach((l) => connected.add(l.source));
    linkSel
      .selectAll("path.sankey-link")
      .attr("opacity", (l) => (connected.has(l.source) && connected.has(l.target) ? 0.9 : HOVER_OPACITY));
    nodeSel
      .attr("opacity", (n) => (connected.has(n) ? 1 : HOVER_OPACITY))
      .attr("filter", (n) => (n === d ? HOVER_FILTER : null));
  }

  #esc(s) {
    return String(s).replace(
      /[&<>"']/g,
      (c) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;",
        })[c],
    );
  }

  #moveTooltip(event, d) {
    if (!this.tooltip) return;
    const isNode = d.sourceLinks !== undefined;
    if (isNode) {
      // displayValue: the currency figure. d.value is the d3-sankey layout
      // value, which the min-height floor scales for short allocation nodes.
      // Round 11 issue 8: the sub-account tooltip names its parent.
      const subAccountLine =
        d.subAccount && d.parentName
          ? `<div class="${CHART_TOOLTIP_CONTEXT_CLASSES} text-xs font-normal mt-1">Sub-account of ${this.#esc(d.parentName)}</div>`
          : "";
      this.tooltip.innerHTML = `
        <div class="${CHART_TOOLTIP_CONTEXT_CLASSES}">${this.#esc(this.#displayName(d))}</div>
        <div class="${CHART_TOOLTIP_VALUE_CLASSES}">${this.#format(d.displayValue ?? d.value ?? 0)}</div>${subAccountLine}`;
    } else {
      const pct = d.source.value > 0 ? ((d.value / d.source.value) * 100).toFixed(0) : "0";
      this.tooltip.innerHTML = `
        <div class="${CHART_TOOLTIP_CONTEXT_CLASSES}">${this.#esc(this.#displayName(d.source))} → ${this.#esc(this.#displayName(d.target))}</div>
        <div class="${CHART_TOOLTIP_VALUE_CLASSES}">${this.#format(d.value)} (${pct}%)</div>`;
    }
    this.tooltip.style.display = "block";
    this.tooltip.style.left = `${event.pageX + 10}px`;
    this.tooltip.style.top = `${event.pageY - 10}px`;
  }
}
