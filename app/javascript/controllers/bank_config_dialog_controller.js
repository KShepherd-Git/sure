import { Controller } from "@hotwired/stimulus";

// the kebab + popups
// (Make a Sub-Account / Configure Auto-Transfer) and the top-left avatar
// (logo popup: Upload Custom / Remove custom / built-in list).
//
// The popups live in the dialog HEADER, outside the main form, so their
// widgets live-sync the form's hidden inputs:
// - sub-account select -> account[parent_account_id]
// - auto-transfer rows -> the data-auto-transfer-tid hidden inputs
//     (the "0" sentinel stays, so all-unchecked clears server-side)
// - logo pick -> account[bank_logo_slug]
// and their Save buttons submit the form via the HTML `form=` attribute
// (one shared save path, in-place, as the rest of the page).
//
// The dialog re-renders fully on every save (#inPlaceSubmit), so all of
// this is DOM-only state: nothing survives a round trip.
//
// the five header popups render INSIDE the
// dialog's single overflow-auto scroll surface, so a tall popup (the
// 644px allocatedSubPopup measured 411.5px clipped on the 297px
// Bills-dialog surface) is trapped + clipped. On open, each popup is
// re-parented into a lazily-created floating layer — a direct child of
// the <dialog> (top-layer box == the viewport, outside the clipper) —
// and positioned from its trigger's rect with a viewport clamp
// (maxHeight + overflow-y-auto: long popups scroll, never clip). The
// layer is pointer-events-none; the floated popup is pointer-events-auto.
// Outside-click is unaffected: the layer is inside the dialog subtree,
// so #onOutsideClick's root.contains(target) still covers popup clicks.
// On the dialog's `close` event every popup is restored to its original
// parent and hidden, so a close/reopen round trip starts clean.
export default class extends Controller {
  static targets = [
    "avatar",
    "avatarImg",
    "neutral",
    "logoPopup",
    "fileInput",
    "removeCustom",
    "uploadError",
    "kebab",
    "kebabMenu",
    "subAccountPopup",
    "subAccountSelect",
    "autoTransferPopup",
    "autoTransferBox",
    // the "Make Allocated Sub-Account" popup (a
    // self-contained form — see the ERB) and the value input its mode
    // select renames.
    "allocatedSubPopup",
    "allocatedValue",
    // the main-section "Parent Account" picker
    // (ABSENT for an account without a parent link — guard accesses with
    // the has* predicate, same as allocatedSubPopup).
    "mainParentSelect",
    // the "Pull From Incomes" section (the
    // mode/ratio trigger panels + the shared two-income control set live
    // inside it — everything is queried off this element).
    "pullFrom",
  ];

  static values = {
    // Built-in logo list: [{ slug, label, url }, ...] (data-driven; the
    // built-in set is swapped for favicons in a later round).
    logos: Array,
    slug: String,
    customUrl: String,
    avatarUrl: String,
    uploadUrl: String,
    removeUrl: String,
    // the read-only per-income amounts —
    // { seriesId: { paycheck: "2700.00", occurrences: 2 } } — for the
    // dialog's client-side auto-fill and ratio re-derivation.
    incomeAmounts: Object,
  };

  connect() {
    this._outsideClick = (event) => this.#onOutsideClick(event);
    this._escapeKey = (event) => {
      if (event.key === "Escape") this.closePopups();
    };
    // every close path (X / backdrop / Escape / Save) fires
    // the dialog's `close` event — start the next open from a clean
    // header (a popup left open must not survive the round trip).
    this._dialogClose = () => this.closePopups();
    this.element.addEventListener("close", this._dialogClose);
    document.addEventListener("mousedown", this._outsideClick, true);
    document.addEventListener("keydown", this._escapeKey);
    // start from the server-rendered state (locked inputs,
    // readouts, ratio label, single-vs-split visibility) — the ERB's
    // initial text is the source of truth; this only normalizes the
    // disabled/hidden state from it.
    if (this.hasPullFromTarget) this.#recalcPullFrom();
  }

  disconnect() {
    this.element.removeEventListener("close", this._dialogClose);
    document.removeEventListener("mousedown", this._outsideClick, true);
    document.removeEventListener("keydown", this._escapeKey);
  }

  // ---- kebab + popups ---------------------------------------------------

  toggleKebab() {
    const menu = this.kebabMenuTarget;
    const open = !menu.classList.toggle("hidden");
    this.kebabTarget.setAttribute("aria-expanded", String(open));
    if (open) this.#floatPopup(menu, this.kebabTarget.parentElement);
    else this.#unfloat(menu);
  }

  openSubAccount() {
    this.#onlyPopup(this.subAccountPopupTarget, this.kebabTarget.parentElement);
  }

  openAutoTransfer() {
    this.#onlyPopup(
      this.autoTransferPopupTarget,
      this.kebabTarget.parentElement,
    );
  }

  // the "Make Allocated Sub-Account" popup — the
  // self-contained allocation form (its own POST; no hidden-input sync).
  openAllocatedSub() {
    this.#onlyPopup(
      this.allocatedSubPopupTarget,
      this.kebabTarget.parentElement,
    );
  }

  openLogo() {
    this.#onlyPopup(this.logoPopupTarget, this.avatarTarget.parentElement);
  }

  closePopups() {
    for (const target of [
      "kebabMenu",
      "subAccountPopup",
      "autoTransferPopup",
      "logoPopup",
    ]) {
      const popup = this[`${target}Target`];
      popup.classList.add("hidden");
      this.#unfloat(popup);
    }
    // the allocated-sub popup target is ABSENT for a
    // dressed account (the dialog renders the REVERSE instead) — a missing
    // target throws on access, so guard with the has* predicate.
    if (this.hasAllocatedSubPopupTarget) {
      this.allocatedSubPopupTarget.classList.add("hidden");
      this.#unfloat(this.allocatedSubPopupTarget);
    }
    // the mode/ratio trigger panels (same floatLayer machinery).
    this.#closePullPanels();
    this.kebabTarget.setAttribute("aria-expanded", "false");
  }

  // Show exactly one popup, hide the rest, and float the survivor above
  // the window ( — see #floatPopup).
  #onlyPopup(popup, trigger) {
    this.closePopups();
    this.#floatPopup(popup, trigger);
  }

  // ---- floating layer ---------------------------------------

  // The one shared layer per dialog element: a direct child of the
  // <dialog> (top-layer box == the viewport) that sits OUTSIDE the
  // dialog's overflow-auto scroll surface, so children of the layer are
  // never clipped by it. Lazy + idempotent; it self-heals after
  // #syncDialog replaces the whole <dialog> on an in-place save (the
  // fresh element + controller recreate it on the next open).
  #floatLayer() {
    let layer = this.element.querySelector(":scope > [data-bank-float-layer]");
    if (!layer) {
      layer = document.createElement("div");
      layer.setAttribute("data-bank-float-layer", "true");
      layer.className = "absolute inset-0 z-50 pointer-events-none";
      // The DS dialog's own clickOutside is bound on the <dialog> and treats
      // any click whose target is outside the CONTENT target as a backdrop
      // click (close). Floated popups live in THIS layer (a sibling of the
      // content target), so their clicks would otherwise close the whole
      // dialog. The layer only ever holds floated popups (it is
      // pointer-events-none itself), so every click that bubbles through it
      // is a popup click — swallow it before it reaches the dialog.
      layer.addEventListener("click", (event) => event.stopPropagation());
      this.element.appendChild(layer);
    }
    return layer;
  }

  // Re-parent the popup into the floating layer and position it from the
  // trigger's rect with a viewport clamp: the popup's bottom may never
  // exceed the viewport — the excess becomes its own scroll instead of
  // the dialog's clip (the pre-fix failure). Kebab popups right-align to
  // the trigger's right edge (their original `right-0` anchor); the logo
  // popup left-aligns (its original `left-0` anchor).
  #floatPopup(popup, trigger) {
    const layer = this.#floatLayer();
    popup.classList.remove("hidden");
    // Remember the in-header home once — restored by #unfloat on
    // closePopups. The dialog re-renders fully on every save, so no state
    // leaks across round trips.
    if (!popup.__bankHome)
      popup.__bankHome = [popup.parentElement, popup.nextSibling];
    layer.appendChild(popup);
    const rect = trigger.getBoundingClientRect();
    const gap = Number.parseFloat(getComputedStyle(popup).marginTop) || 0;
    const width = popup.offsetWidth;
    const height = popup.offsetHeight;
    // the mode/ratio trigger panels carry their own `left-0`
    // anchor (data-bank-pull-panel) and left-align like the logo popup;
    // the header popups keep the right-aligned `right-0` anchor.
    const left0 =
      popup === this.logoPopupTarget ||
      popup.dataset.bankPullPanel !== undefined
        ? rect.left
        : rect.right - width;
    const left = Math.max(8, Math.min(left0, innerWidth - 8 - width));
    const bottom = innerHeight - 8;
    let top = Math.max(8, rect.bottom + gap);
    if (top > bottom - 160) top = Math.max(8, bottom - 160);
    const maxHeight = bottom - top;
    // All five popups carry the `absolute` class in their markup, so only
    // the float overrides need inline styles (top/left/right/max-height/
    // overflow-y/pointer-events); position stays class-driven. margin-top is
    // ZEROED while floating: `top` above already includes the gap, and the
    // in-flow mt-1/mt-2 class would otherwise add a second offset that
    // pushes the bottom past the clamp (a 4px slip on the tall popup).
    // #unfloat removes it, restoring the class-driven margin.
    for (const [prop, value] of [
      ["top", `${top}px`],
      ["left", `${left}px`],
      ["right", "auto"],
      ["margin-top", "0"],
      ["pointer-events", "auto"],
    ])
      popup.style.setProperty(prop, value);
    if (height > maxHeight) {
      popup.style.setProperty("max-height", `${maxHeight}px`);
      popup.style.setProperty("overflow-y", "auto");
    }
  }

  // Restore the popup to its original parent (so a reopen starts with the
  // server-rendered layout) and drop the float overrides.
  #unfloat(popup) {
    if (popup.__bankHome) {
      const [parent, sibling] = popup.__bankHome;
      if (parent?.isConnected) parent.insertBefore(popup, sibling || null);
      popup.__bankHome = null;
    }
    for (const prop of [
      "top",
      "left",
      "right",
      "max-height",
      "overflow-y",
      "pointer-events",
      "margin-top",
    ]) {
      popup.style.removeProperty(prop);
    }
  }

  #onOutsideClick(event) {
    // the vendored Stimulus build (stimulus-rails 1.3.4) exposes
    // only the `element` getter — the old `el` property was undefined, so
    // every path touching it threw a TypeError ("Make a Sub-Account" no-op).
    const root = this.element;
    // allocatedSubPopup is ABSENT for a dressed account
    // (REVERSE dialog) — guard the access (a missing target throws).
    const open =
      ["kebabMenu", "subAccountPopup", "autoTransferPopup", "logoPopup"].some(
        (target) => !this[`${target}Target`].classList.contains("hidden"),
      ) ||
      (this.hasAllocatedSubPopupTarget &&
        !this.allocatedSubPopupTarget.classList.contains("hidden"));
    if (open) {
      // A mousedown inside an open header popup is a popup interaction —
      // never preempt the popup's own click (the pre-round
      // root.contains early-return gave this for free).
      const insidePopup =
        ["kebabMenu", "subAccountPopup", "autoTransferPopup", "logoPopup"].some(
          (target) => {
            const popup = this[`${target}Target`];
            return (
              !popup.classList.contains("hidden") &&
              popup.contains(event.target)
            );
          },
        ) ||
        (this.hasAllocatedSubPopupTarget &&
          !this.allocatedSubPopupTarget.classList.contains("hidden") &&
          this.allocatedSubPopupTarget.contains(event.target));
      if (insidePopup) return;
      if (!root.contains(event.target)) this.closePopups();
      return;
    }
    // ( -2): the mode/behavior trigger panels dismiss on a
    // mousedown OUTSIDE the panel + its trigger (the plan_flow bank-panel
    // exemplar) — a click on blank dialog space dismisses, not only a
    // click outside the whole dialog. #floatPopup re-parents an open panel
    // into the dialog's float layer (outside the pullFrom section), so the
    // open check must be dialog-scoped to see it at all (the
    // pattern) — the pre-round section-scoped query found nothing while a
    // panel was open, so the panel never closed.
    if (!this.hasPullFromTarget) return;
    for (const panel of Array.from(
      this.element.querySelectorAll("[data-bank-pull-panel]"),
    )) {
      if (panel.classList.contains("hidden")) continue;
      const group = panel.dataset.bankPullPanelGroup;
      const trigger = group
        ? this.element.querySelector(
            `button[data-bank-pull-panel-group="${group}"]`,
          )
        : null;
      if (panel.contains(event.target) || trigger?.contains(event.target))
        continue;
      this.#closePullPanels();
      return;
    }
  }

  // ---- header popups -> form hidden inputs ------------------------------

  // The sub-account popup's select syncs the form's hidden
  // account[parent_account_id]; its Save button (form=) submits the main
  // form. Blank = "Not a sub-account" (un-sub-accounting).
  syncSubAccount() {
    const input = this.#hiddenInput("account[parent_account_id]");
    if (input) input.value = this.subAccountSelectTarget.value;
  }

  // the main-section "Parent Account" picker —
  // the SAME hidden-input sync as the sub-account popup's select (both
  // write account[parent_account_id]; the dialog's Save submits it through
  // the validate_parent_change 422 contract). The target is ABSENT for an
  // account without a parent link (a missing target throws on access, so
  // guard with the has* predicate).
  syncMainParent() {
    if (!this.hasMainParentSelectTarget) return;
    const input = this.#hiddenInput("account[parent_account_id]");
    if (input) input.value = this.mainParentSelectTarget.value;
  }

  // the "Make Allocated Sub-Account" popup is its OWN
  // form (not the main bank form), so its mode select renames the value
  // input within that form — the same plan_allocation[value] /
  // [value_percent] swap as the allocation dialog's #setAllocationMode,
  // scoped to this popup's form (no hidden-input sync to the main form).
  syncAllocatedMode(event) {
    const input = this.hasAllocatedValueTarget
      ? this.allocatedValueTarget
      : null;
    if (!input) return;
    const mode = event.target.value;
    if (mode === "percent") {
      input.name = "plan_allocation[value_percent]";
      input.disabled = false;
      input.placeholder = "0-100";
    } else if (mode === "leftover") {
      input.name = "plan_allocation[value]";
      input.disabled = true;
      input.value = "";
      input.placeholder = "0.00";
    } else {
      input.name = "plan_allocation[value]";
      input.disabled = false;
      input.placeholder = "0.00";
    }
  }

  // The auto-transfer popup's checkboxes rebuild the form's
  // data-auto-transfer-tid hidden inputs in row order (the "0" sentinel
  // input is untouched, so an all-unchecked save clears the fan-out).
  syncAutoTransfer() {
    const form = this.#form();
    if (!form) return;
    form
      .querySelectorAll("input[data-auto-transfer-tid]")
      .forEach((input) => input.remove());
    this.autoTransferBoxTarget
      .querySelectorAll("input[type='checkbox']")
      .forEach((checkbox) => {
        if (!checkbox.checked || checkbox.disabled) return;
        const input = document.createElement("input");
        input.type = "hidden";
        input.name = "account[auto_transfer_target_ids][]";
        input.value = checkbox.dataset.otherId;
        input.dataset.autoTransferTid = "1";
        form.appendChild(input);
      });
  }

  // ---- Pull From Incomes -------------------------------------
  // The trigger pattern applied to the income rows: the visible
  // controls (mode/ratio trigger buttons, the value inputs) are NAMELESS;
  // the per-income hidden inputs
  // links[<series.id>][mode] (required|specific|percent|leftover)
  // links[<series.id>][value] (specific: per-paycheck dollars,
  //                               percent: 0-100, else "")
  // are what submits — the save_bank_links param contract is
  // byte-identical. This controller live-syncs them from the visible
  // controls and derives the greyed readouts/labels/locked states. With
  // 2+ incomes checked the per-row details collapse into the shared
  // control set (mode trigger, then the Ratio trigger, then the amount
  // input — the exact placement). The Ratio is NEVER submitted:
  // it is derived client-side (re-derived server-side from the stored
  // values on every render) — decision (a).
  // Stored units: specific = per-paycheck major units; percent = 0-100
  // (view-independent). Display unit = the active view: paycheck ->
  // as stored, monthly -> x the income's occurrence count.

  // The row enable checkbox: toggles the row details + the shared block
  // (recalc reads the DOM; the sentinel hidden input submits the
  // uncheck and destroys the edge on save — behavior kept).
  syncBankRow(event) {
    if (event.target.type !== "checkbox") return;
    this.#recalcPullFrom();
  }

  // Trigger button click: float the matching option panel (the dialog's
  // own #floatLayer/#floatPopup machinery — click-outside + Escape safe).
  openPullPanel(event) {
    const section = this.pullFromTarget;
    const group = event.currentTarget.dataset.bankPullPanelGroup;
    if (!section || !group) return;
    const panel = section.querySelector(
      `[data-bank-pull-panel][data-bank-pull-panel-group="${group}"]`,
    );
    if (!panel) return;
    const wasOpen = !panel.classList.contains("hidden");
    this.#closePullPanels();
    if (!wasOpen) this.#floatPopup(panel, event.currentTarget);
  }

  // A mode radio changed (a row panel or the shared-mode panel). Shared:
  // unify every checked row (picking a mode resolves the mixed state);
  // specific/percent default the ratio to Rational (the default).
  // Per-row: just the row's hidden mode input.
  setPullMode(event) {
    const section = this.pullFromTarget;
    const panel = event.target.closest("[data-bank-pull-panel]");
    if (!section || !panel) return;
    const group = panel.dataset.bankPullPanelGroup;
    const mode = event.target.value;
    if (group === "shared-mode") {
      section.querySelectorAll("[data-bank-row]").forEach((row) => {
        if (row.querySelector('input[type="checkbox"]').checked)
          this.#setRowMode(row, mode);
      });
      if (mode === "specific" || mode === "percent") {
        section.dataset.bankPullFromRatio = "rational";
        // ( -2): dialog-scoped — the ratio panel may sit in
        // the float layer while another panel was open ( pattern).
        const radio = this.element.querySelector(
          '[data-bank-pull-panel-group="shared-ratio"] input[value="rational"]',
        );
        if (radio) radio.checked = true;
      }
    } else if (group.startsWith("row-")) {
      const row = section.querySelector(
        `[data-bank-row][data-bank-series-id="${group.slice(4)}"]`,
      );
      if (row) this.#setRowMode(row, mode);
    }
    this.#recalcPullFrom();
    // ( -2): close-on-selection — the selected radio's visual
    // state (checked + has-[:checked]:bg-surface-inset) is final; the
    // panel un-floats back to its home position (hidden).
    this.#closePullPanels();
  }

  // The shared-ratio radio changed: record the ratio + recompute.
  setSharedRatio(event) {
    const section = this.pullFromTarget;
    if (!section) return;
    // A LIVE behavior transition INTO Fixed Amounts is the
    // one path that must prefill the per-row split inputs from the
    // derivation the user is leaving (required: overwriting
    // the stale server-seeded values). Remember the previous ratio as a
    // one-shot flag consumed by #recalcPullFrom; value edits, income
    // toggles and the initial render never set it, so they never
    // clobber inputs.: the persisted required split (Fixed
    // Amounts / Percent under Required) prefills from the SAME leaving
    // percents — the carriers already hold them.
    const entering = event.target.value;
    const rowModes = Array.from(section.querySelectorAll("[data-bank-row]"))
      .filter((row) => row.querySelector('input[type="checkbox"]').checked)
      .map((row) => {
        const h = row.querySelector('input[type="hidden"][name$="[mode]"]');
        return h ? h.value : "required";
      });
    const sharedMode =
      rowModes.length >= 2 && new Set(rowModes).size === 1 ? rowModes[0] : null;
    if (
      entering === "fixed_amounts" ||
      (sharedMode === "required" && entering === "percent")
    ) {
      section.dataset.bankSplitPrefillFrom =
        section.dataset.bankPullFromRatio || "hidden";
    }
    section.dataset.bankPullFromRatio = event.target.value;
    this.#recalcPullFrom();
    // ( -2): close-on-selection (same as setPullMode).
    this.#closePullPanels();
  }

  // Every visible value input (row input, shared single input, split
  // inputs) calls in on `input`: re-derive the hidden submit values + the
  // greyed readouts/labels/locked states.
  recalcPullFrom() {
    this.#recalcPullFrom();
  }

  #setRowMode(row, mode) {
    const hiddenMode = row.querySelector(
      'input[type="hidden"][name$="[mode]"]',
    );
    if (hiddenMode) hiddenMode.value = mode;
    // Dialog-scoped (the pattern) — the row panel is
    // re-parented into the dialog's float layer by #floatPopup when open,
    // so a row-scoped option query is null once floated and the label
    // write is silently skipped (the selection only happens from the
    // floated panel). The row panel's group is "row-<series-id>" (ERB);
    // the trigger button carries the same group attr but contains no
    // input, so this cannot false-match.
    const groupId = row.dataset.bankSeriesId;
    const option = groupId
      ? this.element.querySelector(
          `[data-bank-pull-panel][data-bank-pull-panel-group="row-${groupId}"] input[value="${mode}"]`,
        )
      : null;
    const label = row.querySelector("[data-bank-pull-mode-label]");
    const span = option?.closest("label")?.querySelector("span");
    if (label && span) label.textContent = span.textContent;
    const valueInput = row.querySelector("[data-bank-pull-row-value]");
    if (valueInput) {
      if (mode === "specific" || mode === "percent") {
        valueInput.disabled = false;
        valueInput.placeholder = mode === "percent" ? "0-100" : "0.00";
      } else {
        valueInput.disabled = true;
      }
    }
  }

  #rowMode(row) {
    const hiddenMode = row.querySelector(
      'input[type="hidden"][name$="[mode]"]',
    );
    return hiddenMode ? hiddenMode.value : "required";
  }

  #closePullPanels() {
    // ( -2): dialog-scoped, not section-scoped — #floatPopup
    // re-parents an OPEN panel into the dialog's float layer (outside
    // the section), so a section query never saw the panel it had to
    // close (and #unfloat was never called, leaking the panel in the
    // float layer). Same reason as the dialog-scoped queries in
    // #recalcPullFrom.
    this.element.querySelectorAll("[data-bank-pull-panel]").forEach((panel) => {
      panel.classList.add("hidden");
      this.#unfloat(panel);
    });
  }

  // Round-half-up to 2 decimals (dollars or percent).
  #cents(x) {
    return Math.round(x * 100) / 100;
  }

  // fix: dollar formatting for the GREY LABELS ONLY. The
  // stored required display (data-bank-required-display) and the value
  // inputs stay plain numbers — the server and the JS math parse those —
  // while the labels get the "$" + thousands separator the design wants
  // ("$1,250.00", never the raw cents "12500.00").
  #money(value) {
    const x = Number.parseFloat(value);
    if (Number.isNaN(x)) return String(value);
    return x.toLocaleString("en-US", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
  }

  #recalcPullFrom() {
    const section = this.pullFromTarget;
    if (!section) return;
    const view = section.dataset.bankView || "paycheck";
    const reqDisplay = section.dataset.bankRequiredDisplay || "";
    const reqPositive = Number.parseFloat(reqDisplay) > 0;
    // One-shot flag set by setSharedRatio on a live
    // transition into Fixed Amounts — the ratio the user was leaving
    // (the prefill source derivation). Consumed unconditionally here.
    const splitPrefillFrom = section.dataset.bankSplitPrefillFrom || "";
    delete section.dataset.bankSplitPrefillFrom;
    const amounts = this.incomeAmountsValue || {};
    const rows = Array.from(section.querySelectorAll("[data-bank-row]"));
    const checked = rows.filter(
      (row) => row.querySelector('input[type="checkbox"]').checked,
    );
    const n = checked.length;
    const shared = n >= 2;

    // Per-checked-income math inputs (stored units): pp = the
    // per-paycheck amount, count = the month's occurrence count.
    const I = checked.map((row) => {
      const entry = amounts[row.dataset.bankSeriesId] || {};
      return {
        row,
        id: row.dataset.bankSeriesId,
        pp: Number.parseFloat(entry.paycheck) || 0,
        count: Number.parseInt(entry.occurrences, 10) || 0,
      };
    });
    const ppSum = I.reduce((sum, e) => sum + e.pp, 0);
    const totalEvents = I.reduce((sum, e) => sum + e.count, 0);
    const combined = totalEvents > 0 ? totalEvents / n : 1; // combined paychecks per month
    const disp = (e, v) => (view === "monthly" ? v * e.count : v);

    // Per-row details + the shared block visibility.
    rows.forEach((row) => {
      const cb = row.querySelector('input[type="checkbox"]');
      const details = row.querySelector("[data-bank-row-details]");
      // ( -3): in the shared (2+ checked) state the per-row
      // details are hidden — the between-row shared block replaces the
      // per-row mode triggers (the hidden mode/value carriers inside
      // still submit: type=hidden ignores the class).
      if (details) details.classList.toggle("hidden", !cb.checked || shared);
      const readout = row.querySelector("[data-bank-per-income-readout]");
      if (readout) {
        readout.textContent = "";
        readout.classList.add("hidden");
      }
    });
    const sharedBlock = section.querySelector("[data-bank-pull-from-shared]");
    if (sharedBlock) sharedBlock.classList.toggle("hidden", !shared);

    if (!shared) {
      // State A: each checked row keeps its own mode trigger + value input.
      checked.forEach((row) => {
        const mode = this.#rowMode(row);
        const valueInput = row.querySelector("[data-bank-pull-row-value]");
        if (valueInput) {
          if (mode === "required") {
            valueInput.disabled = true;
            valueInput.value = reqDisplay || "—";
          } else if (mode === "leftover") {
            valueInput.disabled = true;
            valueInput.value = "";
          } else {
            valueInput.disabled = false;
            valueInput.placeholder = mode === "percent" ? "0-100" : "0.00";
          }
        }
        const label = row.querySelector("[data-bank-required-label]");
        if (label) {
          const show =
            reqPositive && (mode === "specific" || mode === "percent");
          label.classList.toggle("hidden", !show);
          if (show)
            label.textContent = (
              section.dataset.bankRequiredAmountLabel || ""
            ).replace("%{amount}", `$${this.#money(reqDisplay)}`);
        }
        // fix (latent gap): the hidden submit carrier
        // links[<id>][value] was never synced in State A, so edits made
        // in the single-income view never reached the server. Mirror the
        // State B sync: specific/percent echo the visible input;
        // required/leftover store nothing.
        const hiddenValue = row.querySelector(
          'input[type="hidden"][name$="[value]"]',
        );
        if (hiddenValue) {
          hiddenValue.value =
            (mode === "specific" || mode === "percent") && valueInput
              ? valueInput.value.trim()
              : "";
        }
      });
      return;
    }

    // --- State B ---------------------------------------------------------
    const modes = I.map((e) => this.#rowMode(e.row));
    const mixed = new Set(modes).size > 1;
    const mode = mixed ? "mixed" : modes[0];
    if (mixed) section.dataset.bankPullFromRatio = "fixed_amounts";
    const ratio = mixed
      ? "fixed_amounts"
      : section.dataset.bankPullFromRatio || "hidden";

    // The behavior trigger is greyed (visible,
    // non-interactive) under Required / Leftover / mixed, showing the
    // LAST-selected behavior — a fresh required/leftover render holds
    // "hidden" in the dataset (the ratio is never submitted), so the
    // greyed label falls back to the default behavior (rational — the
    // same default setPullMode applies when switching into Fixed/
    // Percent).: the Percent behavior is a Required-mode-only
    // option — a dataset holding "percent" under any other mode (stale
    // state) is treated as Fixed Amounts (mirrors the hidden -> rational
    // display fallback).
    const effRatio =
      ratio === "percent" && mode !== "required" ? "fixed_amounts" : ratio;
    const displayRatio = effRatio === "hidden" ? "rational" : effRatio;
    // fix: restore the dataset<->radio invariant. Without it a
    // stale checked radio (e.g. "Equal" left checked while the stored
    // state forces "Fixed Amounts") swallowed the next click as a no-op —
    // a native radio group fires no change event when the click does not
    // move the checked state. With the invariant, the checked radio
    // always matches the effective ratio, so any different click lands.
    // ( -2): dialog-scoped (the panel may sit in the float
    // layer — the pattern).
    this.element
      .querySelectorAll(
        '[data-bank-pull-panel-group="shared-ratio"] input[type="radio"]',
      )
      .forEach((r) => {
        r.checked = r.value === displayRatio;
      });
    // the 4th behavior option (Percent of the required amount)
    // is a Required-mode-only control — the radio is disabled + its
    // wrapper hidden whenever the effective mode is not required (the
    // ERB seeds the same state; the recalc mirrors it on every live
    // mode change, the same invariant discipline as the block above).
    const percentOption = this.element.querySelector(
      '[data-bank-pull-panel-group="shared-ratio"] input[value="percent"]',
    );
    if (percentOption) {
      const showPercent = mode === "required" && !mixed;
      percentOption.disabled = !showPercent;
      const percentWrap = percentOption.closest("label");
      if (percentWrap) percentWrap.classList.toggle("hidden", !showPercent);
    }

    // fix: restore the shared-mode radio invariant over the
    // DIALOG, not the section. When the shared-mode panel is open it is
    // re-parented into the dialog's float layer (outside the section, by
    // #floatPopup), so a section-scoped query cannot see its radios — the
    // checked radio then desyncs from the effective mode. Same pattern as
    // the block above: the checked radio always matches the
    // effective mode, and the mixed state checks none (the label reads
    // "Mixed"). Programmatic .checked sets fire no change event, so this
    // cannot recurse or swallow a user click.
    this.element
      .querySelectorAll(
        '[data-bank-pull-panel-group="shared-mode"] input[type="radio"]',
      )
      .forEach((r) => {
        r.checked = !mixed && r.value === mode;
      });

    // Shared mode label (greyed "Mixed" for the mixed stored-modes state).
    // fix: dialog-scoped — the label's source (the checked
    // radio's <span> text) lives in the panel, which #floatPopup re-parents
    // into the dialog's float layer when the panel is open; section-scoped
    // it returned null while floated and the label update was skipped.
    const sharedLabel = this.element.querySelector(
      "[data-bank-pull-shared-mode-label]",
    );
    if (sharedLabel) {
      if (mixed) {
        sharedLabel.textContent = section.dataset.bankMixedLabel || "Mixed";
        sharedLabel.classList.remove("text-primary");
        sharedLabel.classList.add("text-secondary");
      } else {
        // fix: dialog-scoped — the radio inputs live in the
        // panel, which is re-parented into the dialog's float layer when
        // the panel is open (the button itself carries the group attr but
        // contains no input, so this cannot false-match).
        const option = this.element.querySelector(
          `[data-bank-pull-panel-group="shared-mode"] input[value="${mode}"]`,
        );
        const span = option?.closest("label")?.querySelector("span");
        if (span) sharedLabel.textContent = span.textContent;
        sharedLabel.classList.remove("text-secondary");
        sharedLabel.classList.add("text-primary");
      }
    }

    // Ratio wrap (the Split Behavior trigger): visible for EVERY mode in
    // the shared state. The trigger is
    // ENABLED under Required (the split is persisted — percents of the
    // required amount) and under Leftover (clickable, display-only —
    // the panel opens, the label updates, nothing is persisted); only the
    // mixed state disables it (invariant preserved).
    const ratioWrap = section.querySelector("[data-bank-pull-ratio-wrap]");
    if (ratioWrap) ratioWrap.classList.remove("hidden");
    const ratioTrigger = ratioWrap?.querySelector("button");
    if (ratioTrigger) ratioTrigger.disabled = mixed;
    const ratioLabel = ratioWrap?.querySelector("[data-bank-pull-ratio-label]");
    if (ratioLabel) {
      const text =
        displayRatio === "equal"
          ? section.dataset.bankRatioEqual
          : displayRatio === "rational"
            ? section.dataset.bankRatioRational
            : displayRatio === "percent"
              ? section.dataset.bankRatioPercent
              : section.dataset.bankRatioFixedAmounts;
      ratioLabel.textContent = text;
    }

    // Note line (the required/leftover explanations; absent otherwise).
    const note = section.querySelector("[data-bank-pull-mode-note]");
    if (note) {
      const text =
        mode === "required"
          ? section.dataset.bankRequiredNote
          : mode === "leftover"
            ? section.dataset.bankLeftoverNote
            : "";
      note.textContent = text || "";
      note.classList.toggle("hidden", !text);
    }

    // Required label (specific: "(total)" variant; percent: plain; only
    // when X > 0).
    const reqLabel = section.querySelector("[data-bank-pull-required-label]");
    if (reqLabel) {
      const show = reqPositive && (mode === "specific" || mode === "percent");
      reqLabel.classList.toggle("hidden", !show);
      if (show) {
        const tpl =
          mode === "specific"
            ? section.dataset.bankRequiredAmountTotalLabel
            : section.dataset.bankRequiredAmountLabel;
        reqLabel.textContent = (tpl || "").replace(
          "%{amount}",
          `$${this.#money(reqDisplay)}`,
        );
      }
    }

    // Single input vs the per-row split inputs (the split
    // inputs replace the single input ONLY under Fixed Amount + Fixed
    // Amounts and the mixed state — Percent keeps the single total-%
    // input for every behavior, with no per-row % inputs; impl note 2).
    // under Required the split inputs show for the Fixed
    // Amounts / Percent behaviors (the required split is PERSISTED —
    // percents of the required amount); the locked required display
    // input stays visible (its wrap is never hidden for required).
    const useSplit =
      mixed || (mode === "specific" && ratio === "fixed_amounts");
    const requiredSplit =
      mode === "required" &&
      (effRatio === "fixed_amounts" || effRatio === "percent");
    const singleWrap = section.querySelector("[data-bank-pull-single-wrap]");
    if (singleWrap)
      singleWrap.classList.toggle("hidden", useSplit && mode !== "required");

    const sharedValue = singleWrap?.querySelector(
      "[data-bank-pull-shared-value]",
    );
    if (sharedValue) {
      if (mode === "required") {
        sharedValue.disabled = true;
        sharedValue.value = reqDisplay || "—";
        // Mirror the State A row sync (L565-566) — the
        // per-row value inputs are hidden in shared state but must not
        // hold stale single-income values; State A re-runs on uncheck.
        I.forEach((e) => {
          const rv = e.row.querySelector("[data-bank-pull-row-value]");
          if (rv) {
            rv.disabled = true;
            rv.value = reqDisplay || "—";
          }
        });
      } else if (mode === "leftover") {
        sharedValue.disabled = true;
        sharedValue.value = "";
      } else {
        sharedValue.disabled = false;
        sharedValue.placeholder = mode === "percent" ? "0-100" : "0.00";
      }
    }
    const hint = section.querySelector("[data-bank-percent-hint]");
    if (hint) {
      const show = !useSplit && mode === "percent";
      hint.classList.toggle("hidden", !show);
      if (show) hint.textContent = section.dataset.bankPercentHint || "";
    }

    // Per-income mode tags (the mixed state only).
    I.forEach((e) => {
      const tag = section.querySelector(`[data-bank-mode-tag="${e.id}"]`);
      if (!tag) return;
      if (mixed) {
        const m = this.#rowMode(e.row);
        const option = e.row.querySelector(
          `[data-bank-pull-panel] input[value="${m}"]`,
        );
        const span = option?.closest("label")?.querySelector("span");
        tag.textContent = span ? span.textContent : m;
        tag.classList.remove("hidden");
      } else {
        tag.textContent = "";
        tag.classList.add("hidden");
      }
    });

    // Superseding the allEmpty gate: a LIVE behavior
    // transition into Fixed Amounts (specific + fixed_amounts, non-mixed)
    // must prefill the per-row split inputs from the CURRENT derivation —
    // the split the greyed readouts showed under the ratio the user is
    // leaving (equal → /n; rational or hidden → proportional to income,
    // the last income absorbing the cents remainder so the values sum
    // exactly). The acceptance criterion overrides the
    // "never overwrite" guard (edge case 9): at this moment the
    // inputs hold the stale server-seeded stored values, and a live
    // transition must replace them. Fire ONLY on that transition path —
    // the one-shot setSharedRatio flag: value edits, income toggles and
    // the initial render (stored Fixed Amounts shows the stored values)
    // never clobber inputs. Percent never enters useSplit; mixed keeps
    // its server-seeded inputs. The prefilled values ride in the
    // carriers via the read below, so the save lands 200 with the
    // derived values.
    if (
      splitPrefillFrom &&
      (useSplit || requiredSplit) &&
      !mixed &&
      sharedValue
    ) {
      const splitInputs = I.map((e) =>
        e.row.querySelector(`[data-bank-split-input="${e.id}"]`),
      );
      if (requiredSplit) {
        // a live transition into the persisted required split —
        // the per-row inputs take dollars (Fixed Amounts) or percents
        // (Percent) from the percents the carriers already hold (the
        // leaving behavior's stored/derived percents; the values block
        // never clears them for required), the last income absorbing so
        // the values sum exactly (dollars to the required display,
        // percents to 100.00).
        const req = Number.parseFloat(reqDisplay) || 0;
        let acc = 0;
        I.forEach((e, i) => {
          const carrier = e.row.querySelector(
            'input[type="hidden"][name$="[value]"]',
          );
          const stored = carrier
            ? Number.parseFloat(carrier.value)
            : Number.NaN;
          const pct = Number.isNaN(stored) ? this.#cents(100 / n) : stored;
          const dollars =
            effRatio === "fixed_amounts"
              ? this.#cents((pct / 100) * req)
              : this.#cents(pct);
          const scale = effRatio === "fixed_amounts" ? req : 100;
          const v = i < n - 1 ? dollars : this.#cents(scale - acc);
          if (i < n - 1) acc += v;
          const input = splitInputs[i];
          if (input) input.value = v.toFixed(2);
        });
      } else {
        const totalValue = Number.parseFloat(sharedValue.value);
        if (!Number.isNaN(totalValue)) {
          const totalStored =
            view === "monthly" ? totalValue / combined : totalValue;
          let acc = 0;
          I.forEach((e, i) => {
            const w =
              splitPrefillFrom === "equal"
                ? 1 / n
                : ppSum > 0
                  ? e.pp / ppSum
                  : 1 / n;
            const v =
              i < n - 1
                ? this.#cents(totalStored * w)
                : this.#cents(totalStored - acc);
            if (i < n - 1) acc += v;
            const input = splitInputs[i];
            if (input) input.value = v.toFixed(2);
          });
        }
      }
    }

    // The per-income stored values (the hidden submit inputs).
    // mixed / split -> the split inputs' own text
    // required -> the percents of the bank's required
    //                             amount (2 dp major units; blank = nil =
    //                             the equal split): the live split inputs
    //                             when shown (Fixed Amounts / Percent),
    //                             else the behavior-derived percents
    //                             (equal/hidden: 100/n; rational: strict
    //                             income-proportional), the last income
    //                             absorbing so the sum is exactly 100.00
    // leftover -> "" ( : display-only; the planner
    //                             derives)
    // specific single -> the ratio split of the entered total
    //                             (equal: /n; rational: x the income share;
    //                             the last income absorbs the cents
    //                             remainder so the stored values sum
    //                             exactly)
    // percent single -> rational: P for both (each income pays
    //                             P% of its own paycheck); equal: the
    //                             equal-DOLLAR per-paycheck share, the
    //                             per-income % derived
    const values = I.map(() => "");
    // fix: the UNROUNDED equal-dollar per-paycheck share per
    // income (percent-Equal only). The readout displays this; the
    // STORED percent still comes from the 2-dp rounded value.
    const equalShare = I.map(() => null);
    if (mixed || useSplit) {
      I.forEach((e, i) => {
        // the split inputs live inline in the income rows (the
        // old bottom-center split wrap is gone).
        const input = e.row.querySelector(`[data-bank-split-input="${e.id}"]`);
        values[i] = input ? input.value.trim() : "";
      });
    } else if (mode === "required" && sharedValue) {
      // the required split is PERSISTED — the carriers carry the
      // percents of the required amount (blank = nil = the equal split).
      // Live split inputs win when shown (Fixed Amounts: typed dollars ->
      // dollars/required*100; Percent: typed percents); otherwise the
      // behavior derives the percents (equal/hidden: 100/n; rational:
      // strict income-proportional), the last income absorbing so the sum
      // is exactly 100.00. D-UNDER: typed percents under 100 stay as-is —
      // the shortfall is visible, never renormalized. The percents ride
      // the carriers even with an empty required display (base 0: the
      // split is inert until the base becomes non-zero — survival).
      if (requiredSplit) {
        const req = Number.parseFloat(reqDisplay) || 0;
        I.forEach((e, i) => {
          const input = e.row.querySelector(
            `[data-bank-split-input="${e.id}"]`,
          );
          const text = input ? input.value.trim() : "";
          const v = Number.parseFloat(text);
          if (text === "" || Number.isNaN(v)) {
            values[i] = "";
            return;
          }
          // The carrier stores the PERCENT of the required amount:
          // Fixed Amounts converts typed dollars (dollars / required *
          // 100 — view-unit invariant; a zero base cannot be converted
          // -> nil = the equal split); Percent takes the typed percents.
          const pct =
            effRatio === "fixed_amounts"
              ? req > 0
                ? this.#cents((v / req) * 100)
                : ""
              : this.#cents(v);
          values[i] = pct === "" ? "" : pct.toFixed(2);
        });
      } else {
        let acc = 0;
        I.forEach((e, i) => {
          const w = effRatio === "rational" && ppSum > 0 ? e.pp / ppSum : 1 / n;
          const pct = i < n - 1 ? this.#cents(100 * w) : this.#cents(100 - acc);
          if (i < n - 1) acc += pct;
          values[i] = pct.toFixed(2);
        });
      }
    } else if (mode !== "required" && mode !== "leftover" && sharedValue) {
      if (mode === "specific") {
        const V = Number.parseFloat(sharedValue.value);
        if (!Number.isNaN(V)) {
          // The input is the total in VIEW units; stored values are per
          // paycheck: V_pp = V / combined paychecks per month (monthly)
          // or V (paycheck view: per combined paycheck).
          const totalStored = view === "monthly" ? V / combined : V;
          let acc = 0;
          I.forEach((e, i) => {
            const w = ratio === "rational" && ppSum > 0 ? e.pp / ppSum : 1 / n;
            if (i < n - 1) {
              const v = this.#cents(totalStored * w);
              acc += v;
              values[i] = v.toFixed(2);
            } else {
              const v = this.#cents(totalStored - acc);
              values[i] = v.toFixed(2);
            }
          });
        }
      } else {
        const P = Number.parseFloat(sharedValue.value);
        if (!Number.isNaN(P)) {
          if (ratio === "rational") {
            // Each income stores the same percent (P% of its own paycheck).
            I.forEach((e, i) => {
              values[i] = this.#cents(P).toFixed(2);
            });
          } else {
            // Equal: equal dollar contributions. T_pp = P% of the combined
            // paycheck (the sum of the per-paycheck amounts); each income
            // pays T_pp/n per combined paycheck -> per paycheck:
            // T_pp/n / (events per income per combined paycheck).
            const tpp = (P / 100) * ppSum;
            I.forEach((e, i) => {
              const perEvent = tpp / n / Math.max(1, e.count / combined);
              equalShare[i] = perEvent; // R5 (BUG-4): unrounded share for the readout
              const f = e.pp > 0 ? perEvent / e.pp : 0;
              values[i] = this.#cents(f * 100).toFixed(2);
            });
          }
        }
      }
    }
    I.forEach((e, i) => {
      const hidden = e.row.querySelector(
        'input[type="hidden"][name$="[value]"]',
      );
      if (hidden) hidden.value = values[i];
    });

    // Per-income readouts (view unit). The readout and the
    // inline split input are mutually exclusive per row:
    // Leftover -> nothing (the block's greyed note explains)
    // split input shown -> the editable input is the source; the
    //                          readout stays hidden
    // Required -> the greyed proration share = the required
    //                          per-paycheck amount, each
    //   Fixed/Percent other -> the greyed computed share; Percent shows
    //                          the derived per-income % for ALL three
    // behaviors (impl note 2: the greyed
    //                          derived readouts kept).
    I.forEach((e, i) => {
      const readout = e.row.querySelector("[data-bank-per-income-readout]");
      const splitInput = e.row.querySelector(
        `[data-bank-split-input="${e.id}"]`,
      );
      const rowMode = this.#rowMode(e.row);
      if (splitInput)
        splitInput.classList.toggle(
          "hidden",
          !(mixed || useSplit || requiredSplit),
        );
      if (!readout) return;
      // under Required the $ readouts stay visible for the 50/50,
      // Proportional and Percent behaviors ($ readouts next to the %
      // inputs); only Fixed Amounts hides them (its $ inputs are the
      // source there).
      if (
        rowMode === "leftover" ||
        mixed ||
        useSplit ||
        (requiredSplit && effRatio === "fixed_amounts")
      ) {
        readout.textContent = "";
        readout.classList.add("hidden");
        return;
      }
      const nameEl = e.row.querySelector("[data-bank-row-name]");
      const name = nameEl ? nameEl.textContent : e.id;
      if (rowMode === "required") {
        // the greyed split of the displayed required (percents
        // of the required amount, view unit — reqDisplay is already
        // view-scaled, so no disp): the percents from the carriers (the
        // values block above always carries a concrete split for
        // required), the last income absorbing so the readouts sum
        // exactly to the displayed required (the UI invariant). No
        // absorb when a carrier is blank (D-UNDER: the shortfall stays
        // visible).
        const req = Number.parseFloat(reqDisplay) || 0;
        const pcts = I.map((ee) => {
          const hidden = ee.row.querySelector(
            'input[type="hidden"][name$="[value]"]',
          );
          const v = hidden ? Number.parseFloat(hidden.value) : Number.NaN;
          return Number.isNaN(v) ? 0 : v;
        });
        const sumPct = pcts.reduce((s, p) => s + p, 0);
        const full = pcts.every((p) => p > 0) && Math.abs(sumPct - 100) < 0.005;
        let acc = 0;
        const dollars = pcts.map((p, j) => {
          const d =
            full && j === pcts.length - 1
              ? req - acc
              : this.#cents((p / 100) * req);
          if (j < pcts.length - 1) acc += d;
          return d;
        });
        readout.textContent = (section.dataset.bankPerIncomeReadout || "")
          .replace("%{name}", name)
          .replace("%{amount}", `$${dollars[i].toFixed(2)}`);
        readout.classList.remove("hidden");
        return;
      }
      const v = Number.parseFloat(values[i]);
      if (Number.isNaN(v)) return;
      // fix: the percent-Equal readout shows the UNROUNDED
      // equal dollar share (the design's 205.00 / 205.00 for the 410.00
      // total), not the dollars back-derived from the 2-dp rounded
      // stored percent (which gave 204.93 / 204.96, total 409.89).
      let dollars;
      if (rowMode === "percent" && ratio === "equal" && equalShare[i] != null) {
        dollars = disp(e, equalShare[i]);
      } else {
        dollars =
          rowMode === "percent" ? disp(e, (v / 100) * e.pp) : disp(e, v);
      }
      const tpl =
        rowMode === "percent"
          ? section.dataset.bankPerIncomeReadoutPercent
          : section.dataset.bankPerIncomeReadout;
      let text = (tpl || "")
        .replace("%{name}", name)
        .replace("%{amount}", `$${dollars.toFixed(2)}`);
      if (rowMode === "percent") {
        text = text.replace("%{percent}", `${v.toFixed(2)}%`);
      }
      readout.textContent = text;
      readout.classList.remove("hidden");
    });

    // The split running total (view unit; per-income $ or % by the row's
    // own mode — matters for the mixed state).: the total moved
    // into the between-row control row (the old split wrap is gone) — the
    // section-scoped query is position-independent.
    const totalEl = section.querySelector("[data-bank-split-total]");
    if (totalEl) {
      if (!useSplit && !requiredSplit) {
        totalEl.textContent = "";
        totalEl.classList.add("hidden");
      } else if (requiredSplit) {
        // the required split's running total — Percent behavior:
        // the sum of the typed percents (vs 100%); Fixed Amounts: the
        // running $ against the required display (view unit).
        if (mode === "required" && effRatio === "percent") {
          const sumPct = I.reduce((s, e, i) => {
            const v = Number.parseFloat(values[i]);
            return Number.isNaN(v) ? s : s + v;
          }, 0);
          totalEl.textContent = `${section.dataset.bankTotalLabel || "Total"}: ${sumPct.toFixed(2)}%`;
        } else {
          const req = Number.parseFloat(reqDisplay) || 0;
          const sum = I.reduce((s, e, i) => {
            const v = Number.parseFloat(values[i]);
            if (Number.isNaN(v)) return s;
            return s + this.#cents((v / 100) * req);
          }, 0);
          totalEl.textContent = `${section.dataset.bankTotalLabel || "Total"}: $${sum.toFixed(2)}`;
        }
        totalEl.classList.remove("hidden");
      } else {
        const sum = I.reduce((s, e, i) => {
          const v = Number.parseFloat(values[i]);
          if (Number.isNaN(v)) return s;
          const rowMode = this.#rowMode(e.row);
          const dollars = rowMode === "percent" ? (v / 100) * e.pp : v;
          return s + disp(e, dollars);
        }, 0);
        totalEl.textContent = `${section.dataset.bankTotalLabel || "Total"}: $${sum.toFixed(2)}`;
        totalEl.classList.remove("hidden");
      }
    }
  }

  // ---- avatar + logo popup ----------------------------------------------

  pickLogo(event) {
    const slug = event.currentTarget.dataset.slug || "";
    const input = this.#hiddenInput("account[bank_logo_slug]");
    if (input) input.value = slug;
    const logoUrl = this.#logoUrl(slug);
    if (this.customUrlValue) {
      // A custom upload wins in the avatar; picking a built-in (or None)
      // removes it so the pick is actually what the avatar shows.
      this.#fetchJson(this.removeUrlValue, { method: "DELETE" })
        .then((response) => {
          if (!response.ok) throw new Error("remove failed");
          this.customUrlValue = "";
          this.#setAvatar(logoUrl);
          this.removeCustomTarget.classList.add("hidden");
        })
        .catch(() => {
          this.#showUploadError("Couldn't remove the custom logo. Try again.");
        });
    } else {
      this.#setAvatar(logoUrl);
    }
    this.closePopups();
  }

  uploadLogo() {
    const file = this.fileInputTarget.files[0];
    if (!file) return;
    const body = new FormData();
    body.append("image", file);
    this.#fetchJson(this.uploadUrlValue, { method: "POST", body })
      .then((response) =>
        response.json().then((data) => ({ ok: response.ok, data })),
      )
      .then(({ ok, data }) => {
        if (!ok) {
          this.#showUploadError(
            Array.isArray(data.errors)
              ? data.errors.join(" ")
              : "Upload failed. Try again.",
          );
          return;
        }
        this.customUrlValue = data.logo_url;
        this.#setAvatar(data.logo_url);
        this.removeCustomTarget.classList.remove("hidden");
        this.uploadErrorTarget.classList.add("hidden");
        this.fileInputTarget.value = "";
      })
      .catch(() => this.#showUploadError("Upload failed. Try again."));
  }

  removeCustom() {
    this.#fetchJson(this.removeUrlValue, { method: "DELETE" })
      .then((response) => {
        if (!response.ok) throw new Error("remove failed");
        this.customUrlValue = "";
        this.#setAvatar(this.#logoUrl(this.slugValue));
        this.removeCustomTarget.classList.add("hidden");
      })
      .catch(() =>
        this.#showUploadError("Couldn't remove the custom logo. Try again."),
      );
  }

  // ---- helpers ------------------------------------------------------------

  #fetchJson(url, init) {
    const headers = Object.assign(
      { Accept: "application/json" },
      init.headers || {},
    );
    return fetch(url, Object.assign({}, init, { headers }));
  }

  #setAvatar(url) {
    this.avatarUrlValue = url || "";
    this.avatarImgTarget.src = url || "";
    this.avatarImgTarget.classList.toggle("hidden", !url);
    this.neutralTarget.classList.toggle("hidden", Boolean(url));
  }

  #logoUrl(slug) {
    const entry = this.logosValue.find((logo) => logo.slug === slug);
    return entry ? entry.url : null;
  }

  #showUploadError(message) {
    this.uploadErrorTarget.textContent = message;
    this.uploadErrorTarget.classList.remove("hidden");
  }

  #form() {
    // switched to `this.element` (the vendored Stimulus build has
    // no `el` alias); the anchor input keeps the original name.
    const anchor = this.element.querySelector(
      "input[name='account[parent_account_id]']",
    );
    return anchor ? anchor.closest("form") : null;
  }

  #hiddenInput(name) {
    // switched to `this.element` (no `el` alias in this build).
    return this.element.querySelector(`input[name='${name}']`);
  }
}
