import { Controller } from "@hotwired/stimulus";

// Paycheck Flow page: the Sankey page's dialog wiring. The page
// embeds the recommendation list (for the Recommended click-prefills) and
// the in-plan account ids (source-bank scope for prefills); every other
// plan state lives server-side behind GET /plan/flow/graph — the page holds
// no client-side plan state.
//
// Dialogs are inline <dialog> elements (house DS::Dialog, disable_frame)
// opened with showModal — the budget_categories move-dialog pattern.
//
// Every plan mutation form (allocation
// add/edit/delete, bank add/config/remove, income config) submits IN PLACE
// a fetch (Accept: application/json) instead of a full reload, so the
// Sankey can TWEEN to the new layout. A document-level capture listener
// handles the forms: the Add Account modal's form lives in a turbo-frame at
// the body level, outside this controller's element, where a data-action
// could not resolve. Forms opt in with data-plan-flow-inplace.
export default class extends Controller {
  static values = {
    recommendations: Array, // graph JSON recommendations
    inPlan: Array, // account ids on the plan
  };

  connect() {
    this._inPlaceSubmitHandler = (event) => this.#inPlaceSubmit(event);
    document.addEventListener("submit", this._inPlaceSubmitHandler, true);
    // the bank-source dropdown's close behavior — a
    // document mousedown outside the trigger + panel, and Escape, close
    // the open panel(s). The allocation dialogs are static per page load
    // (the in-place swap keeps their node ids), so one document listener +
    // a close-event cleanup per dialog covers every instance.
    this._bankOutsideMouseDown = (event) => this.#bankPanelOutside(event);
    document.addEventListener("mousedown", this._bankOutsideMouseDown, true);
    this._bankEscape = (event) => this.#bankPanelEscape(event);
    document.addEventListener("keydown", this._bankEscape, true);
    this._bankCloseUnwatchers = new Map();
    this.#watchBankPanels();
    // the chrome-top amber "Re-apply" — re-opens the
    // fun_money row's dialog (a fresh save re-pins the input snapshot).
    this._fmStaleReapply = (event) => {
      const button = event.target.closest("[data-fm-stale-reapply]");
      if (!button) return;
      event.preventDefault();
      const allocationId = button.dataset.fmStaleAllocation;
      const dialog = document.querySelector(
        `dialog[data-node-id="allocation:${allocationId}"]`,
      );
      if (dialog) dialog.showModal();
    };
    document.addEventListener("click", this._fmStaleReapply, true);
    // the value-box pencils (data-allocation-pencil)
    // are hover-only. The compiled group-hover:opacity-100 rule
    // (.group-hover\:opacity-100:is(:where(.group):hover *)) does not win
    // the cascade against .opacity-0 in this Chromium build, so the reveal
    // is driven by delegated mouse/focus listeners that toggle the pencil's
    // inline opacity over its enclosing value box (div.relative.group).
    // The CSS classes stay on the markup (they work in engines that apply
    // the :is rule) — this is belt-and-braces.
    this._pencilOver = (event) => this.#pencilReveal(event, true);
    this._pencilOut = (event) => this.#pencilReveal(event, false);
    document.addEventListener("mouseover", this._pencilOver, true);
    document.addEventListener("mouseout", this._pencilOut, true);
    document.addEventListener("focusin", this._pencilOver, true);
    document.addEventListener("focusout", this._pencilOut, true);
  }

  #pencilReveal(event, show) {
    const target = event.target instanceof Element ? event.target : null;
    const group = target ? target.closest("div.relative.group") : null;
    if (!group) return;
    const pencil = group.querySelector("[data-allocation-pencil]");
    if (!pencil) return;
    const next =
      event.relatedTarget instanceof Element ? event.relatedTarget : null;
    if (!show && next && group.contains(next)) return; // still inside the box
    pencil.style.opacity = show ? "1" : "";
  }

  disconnect() {
    document.removeEventListener("submit", this._inPlaceSubmitHandler, true);
    document.removeEventListener("mousedown", this._bankOutsideMouseDown, true);
    document.removeEventListener("keydown", this._bankEscape, true);
    document.removeEventListener("mouseover", this._pencilOver, true);
    document.removeEventListener("mouseout", this._pencilOut, true);
    document.removeEventListener("focusin", this._pencilOver, true);
    document.removeEventListener("focusout", this._pencilOut, true);
    document.removeEventListener("click", this._fmStaleReapply, true);
    if (this._bankCloseUnwatchers) {
      this._bankCloseUnwatchers.forEach((unwatch) => unwatch());
      this._bankCloseUnwatchers.clear();
    }
  }

  // pick the panel radio value to re-check after an in-place
  // bank-rows swap. The carrier's value wins if the fresh fragment still
  // offers it; otherwise the unassigned row (value="") — never a value the
  // panel no longer renders (a departed bank), and never an empty carrier
  // re-offering an old bank.
  static bankRowsSwapValue(current, offered) {
    return current !== "" && offered.includes(current) ? current : "";
  }

  // One shared submit path for every plan-flow mutation form. On 200 +
  // graph JSON: close the dialog / clear the modal frame, swap the stale
  // server-rendered chrome fragments, and hand the fresh graph to the
  // Sankey controller (it tweens — ). On 422: render the model's field
  // errors inline in the dialog (no full-page flash — there is no reload).
  async #inPlaceSubmit(event) {
    const target = event.target;
    if (!(target instanceof HTMLFormElement)) return;
    if (!target.hasAttribute("data-plan-flow-inplace")) return;
    const form = target;
    if (event.defaultPrevented || form.dataset.busy === "1") return;

    // Bank removal: confirm when allocations are attached to the bank.
    if (
      form.dataset.removeConfirm === "true" &&
      Number(form.dataset.allocatedCount || 0) > 0
    ) {
      if (
        !window.confirm(
          form.dataset.removeMessage || "Remove this bank from the plan?",
        )
      ) {
        event.preventDefault();
        return;
      }
    }
    event.preventDefault();
    form.dataset.busy = "1";

    const dialog = form.closest("dialog");
    const errors = dialog?.querySelector("[data-in-place-errors]");
    const showErrors = (html) => {
      if (!errors) return;
      errors.innerHTML = html;
      errors.classList.remove("hidden");
    };

    try {
      const hasFields = [...form.elements].some((el) => el.name);
      const response = await fetch(form.action, {
        method: (form.method || "get").toUpperCase(),
        body: hasFields ? new FormData(form) : undefined,
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });
      let data = null;
      try {
        data = await response.json();
      } catch {
        data = null;
      }

      if (response.status === 422) {
        const entries = Object.entries(data?.errors || {});
        // fix: a rejected save used to render NOTHING when the
        // server sent {"errors":{}} — zero user feedback. The server now
        // fills real field messages (see error_messages / save_bank_links);
        // this fallback covers any other empty 422. Dialog stays open,
        // nothing persisted.
        showErrors(
          entries.length
            ? entries
                .map(
                  ([, messages]) =>
                    `<p class="text-xs text-destructive">${messages.map(this.#esc).join(" ")}</p>`,
                )
                .join("")
            : "<p class='text-xs text-destructive'>Could not save — check the values and try again.</p>",
        );
        return;
      }
      if (!response.ok || !data?.graph)
        throw new Error(
          `plan-flow in-place update failed (${response.status})`,
        );

      errors?.classList.add("hidden");

      // Swap the server-rendered chrome that can go stale (over-plan
      // lines, empty states, the dialog's Known Allocations list).
      const chrome = data.chrome || {};
      if (chrome.top)
        this.#swapFragment("[data-flow-chrome='top']", chrome.top);
      if (chrome.overlays)
        this.#swapFragment("[data-flow-chrome='overlays']", chrome.overlays);
      if (chrome.known)
        this.#swapFragment(
          "[data-plan-flow-target='knownSection']",
          chrome.known,
        );

      // the red PLAN ISSUES icon — swap the
      // holder's contents in place (a save can clear OR introduce the red
      // lines; an empty fragment = the icon is gone). The holder span is
      // always present in the top bar (show.html.erb), so no insertion
      // fallback is needed and a cleared icon leaves a zero-size holder.
      const issuesHolder = document.querySelector(
        "[data-flow-chrome='issues-icon']",
      );
      if (issuesHolder)
        issuesHolder.innerHTML = (chrome.issues_icon || "").trim();

      // the allocation dialog's BANK SOURCE rows render once
      // at page load, so an in-place account add/remove leaves them stale.
      // Swap the fresh fragment into every allocation dialog (allocation:new
      // and allocation:<id>) that carries the holder, then re-check the
      // radio the dialog's form currently holds (radio names are unchanged;
      // the #checkAccountRadio contract stays intact). A closed dialog keeps
      // its form in the DOM, so the live checked state is readable either
      // way; nil-safe: no allocation dialog in the DOM -> nothing to swap.
      if (chrome.allocation_bank_rows) {
        for (const dlg of document.querySelectorAll(
          "dialog[data-node-id^='allocation:']",
        )) {
          const holder = dlg.querySelector(
            "[data-flow-chrome='allocation-bank-rows']",
          );
          if (!holder) continue;
          // the per-dialog state is the form's HIDDEN
          // plan_allocation[account_id] carrier (the submit carrier), NOT
          // the panel's checked radio — the bank radios of EVERY allocation
          // dialog share one name in one document, so the browser's
          // radio-button-group constraint leaves only the last-rendered
          // dialog's radio natively checked; every other assigned dialog
          // reads "nothing checked" and would be reset to the unassigned
          // row ("None Selected") after every swap.
          const carrier = dlg.querySelector(
            'input[type="hidden"][name="plan_allocation[account_id]"]',
          );
          const current = carrier ? carrier.value : "";
          const tpl = document.createElement("template");
          tpl.innerHTML = chrome.allocation_bank_rows.trim();
          const node = tpl.content.firstElementChild;
          if (!node) continue;
          holder.replaceWith(node);
          // Re-check the panel's radio for the carrier's value (PANEL-
          // SCOPED: a dialog-wide [value=...] query matches the hidden
          // carrier first and would leave the radio group — the UI source
          // of truth — unchecked). If the carrier points at an account the
          // fragment no longer offers (it left the plan), fall back to the
          // unassigned radio (value="") rather than leaving the form with
          // no checked source.
          const offered = [
            ...node.querySelectorAll(
              "input[name='plan_allocation[account_id]']",
            ),
          ].map((r) => r.value);
          const target = this.constructor.bankRowsSwapValue(current, offered);
          const panel = dlg.querySelector("[data-allocation-bank-panel]");
          const radio = panel?.querySelector(
            `input[name='plan_allocation[account_id]'][value="${target}"]`,
          );
          if (radio) {
            radio.checked = true;
            // the radio group lives in the dropdown
            // panel (outside the form); re-sync the form's hidden
            // plan_allocation[account_id] carrier + the trigger after the
            // swap — the value="" fallback would otherwise leave the
            // hidden input holding the departed account's id.
            this.#applyBankSelection(dlg, radio.value);
          }
        }
      }

      // (ghost banks): in-place bank adds/edits ship the affected
      // banks' config dialogs — inject or refresh them so the (new) bank
      // node is operable without a reload; a removed bank's dialog is
      // dropped.
      if (Array.isArray(chrome.bank_dialogs)) {
        for (const entry of chrome.bank_dialogs)
          this.#syncDialog(entry.node_id, entry.html);
      }
      if (chrome.bank_removed) {
        document
          .querySelector(`dialog[data-node-id="${chrome.bank_removed}"]`)
          ?.remove();
      }

      // the Sankey's in-plan / account-name values are page-load
      // state — after an in-place add/delete they are stale, and a removed
      // bank gets re-synthesized as a phantom floor node until reload.
      // Refresh them from the response before the diagram re-renders.
      if (chrome.sankey) {
        const sankeyEl = document.querySelector(
          "[data-controller~='plan-flow-sankey']",
        );
        if (sankeyEl) {
          if (chrome.sankey.accounts) {
            sankeyEl.dataset.planFlowSankeyAccountsValue = JSON.stringify(
              chrome.sankey.accounts,
            );
          }
          if (Array.isArray(chrome.sankey.in_plan)) {
            sankeyEl.dataset.planFlowSankeyInPlanValue = JSON.stringify(
              chrome.sankey.in_plan,
            );
          }
        }
      }

      // The Sankey controller tweens to the fresh graph.
      document
        .querySelector("[data-controller~='plan-flow-sankey']")
        ?.dispatchEvent(
          new CustomEvent("plan-flow:graph", { detail: { graph: data.graph } }),
        );

      // Close the open dialog / clear the Add Account modal frame.
      dialog?.close();
      const frame = form.closest("turbo-frame");
      if (frame) {
        frame.removeAttribute("src");
        frame.innerHTML = "";
      }
    } catch (error) {
      console.error("plan-flow in-place update failed", error);
      showErrors(
        "<p class='text-xs text-destructive'>The update didn't go through — refresh the page.</p>",
      );
    } finally {
      delete form.dataset.busy;
    }
  }

  // Replace a server-rendered fragment in place (the JSON responses ship
  // the re-rendered wrapper element).
  #swapFragment(selector, html) {
    const el = document.querySelector(selector);
    if (!el) return;
    const tpl = document.createElement("template");
    tpl.innerHTML = html.trim();
    const node = tpl.content.firstElementChild;
    if (node) el.replaceWith(node);
  }

  // (ghost banks): ensure a <dialog> element for the node id —
  // replace the existing one (the server re-renders it with the fresh
  // linked-income rows) or append it to the page (Stimulus connects
  // appended elements automatically).
  #syncDialog(nodeId, html) {
    const existing = document.querySelector(`dialog[data-node-id="${nodeId}"]`);
    const tpl = document.createElement("template");
    tpl.innerHTML = html.trim();
    const node = tpl.content.firstElementChild;
    if (!node) return;
    if (existing) existing.replaceWith(node);
    else this.element.appendChild(node);
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

  // ---- Allocation dialog ( U: two-stack rework) -----------------
  //
  // The dialog is two disclosure stacks ("Configure the allocation",
  // "Bank source") and reshapes dynamically:
  //   - kind Bill / Debt with a detected-bill link (recurring_transaction)
  //     selected: name / amount / cadence become READ-ONLY context (the
  //     hidden inputs carry the values, so the save contract is unchanged)
  //     and the Mode field does not appear; the type options are Bill /
  //     Debt only (the linked form is server-rendered that way).
  //   - kind Savings / Fun Money: the bill-only fields (Mode / cadence /
  //     detected-bill link) hide; name + monthly amount stay.
  // Progressive disclosure: the least information is shown until needed,
  // and a locked field shows the pulled value as a read-only row.

  // "+ Add Allocation" opens the dialog on the Known Allocations list
  // ; the custom form stays hidden until a row click or
  // the "New Allocation" button.: the CTAs no longer wire this
  // up — the Add Allocation buttons are kind pickers (their menu items
  // call openAllocationKind below). Kept as the known-list + blank-form
  // fallback.
  openNewAllocation() {
    this.#openAllocationDialog(null);
  }

  // (Direct Deposit): the bottom action row's "Direct Deposit
  // Review" button opens the paycheck-config dialog (one tab per existing
  // member). Plain showModal — the dialog's own Stimulus controller
  // (plan-flow-paycheck-config) drives the derived readouts in place.
  openPaycheckConfig() {
    const dialog = document.querySelector(
      'dialog[data-node-id="paycheck-config"]',
    );
    if (dialog) dialog.showModal();
  }

  // A "Known Allocations" row (detected bill / subscription): prefill the
  // SELECTED-allocation window's form with the bill details LOCKED to
  // read-only context ( U) and open it as a separate window
  // ( — the allocation:new dialog does NOT expand in place; the
  // prefill runs against the selected dialog's form, then showModal).
  openKnownAllocation(event) {
    const row = event.currentTarget;
    if (!row) return;
    const dialog = document.querySelector(
      'dialog[data-node-id="allocation:selected"]',
    );
    const form = this.#allocationForm(dialog);
    if (!form) return;
    form.reset();
    const set = (field, value) => {
      const el = form.querySelector(`[name="plan_allocation[${field}]"]`);
      if (el) el.value = value;
    };
    set("kind", "bill");
    set("recurring_transaction_id", row.dataset.knownId || "");
    this.#setAllocationMode(form, "required");
    const cents = Number(row.dataset.knownAmountCents || 0);
    this.#setFieldLocked(form, "name", true, row.dataset.knownName || "");
    this.#setFieldLocked(
      form,
      "value",
      true,
      cents > 0 ? (cents / 100).toFixed(2) : "",
      cents > 0 ? this.#currencyText(form, cents) : "",
    );
    this.#setFieldLocked(
      form,
      "cadence",
      true,
      row.dataset.knownCadence || "",
      row.dataset.knownCadence
        ? this.#cadenceText(form, row.dataset.knownCadence)
        : "",
    );
    this.#checkAccountRadio(form, row.dataset.knownAccount);
    // the known_allocations payload carries the
    // bill's category (data-known-category) — preselect it so the trigger
    // mirrors the popup's checked radio.
    this.#checkCategoryRadio(form, row.dataset.knownCategory);
    this.#applyAllocationVisibility(form);
    this.#allocationCategorySummary(form);
    dialog.showModal();
  }

  // "Add New Allocation" (header CTA): the custom input form,
  // blank.: the header CTA now opens the kind picker (it is a
  // DS::Menu trigger; its items call openAllocationKind below), so this
  // method is no longer CTA-wired — it stays as the blank-form opener: it
  // resets the form and reshapes it, but does NOT showModal (the
  // allocation:new dialog is already open when its header CTA is
  // visible).
  openBlankAllocation() {
    const form = this.#allocationForm(this.#allocationDialog());
    if (!form) return;
    this.#resetAllocationForm(form);
    this.#applyAllocationVisibility(form);
    this.#allocationCategorySummary(form);
    this.#showAllocationForm(form);
  }

  // a kind-picker item (the CTAs' DS::Menu: Bill / Debt /
  // Savings / Fun Money — see _allocation_kind_picker.erb): opens the
  // allocation:new dialog on a blank form pre-set to the picked kind.
  // The item is a real <button> (DS::MenuItem's button variant renders via
  // button_to with a dead "#" action — there is no URL to submit), but the
  // native implicit form submission is still killed with preventDefault.
  // The kind is set AFTER the reset (form.reset restores the
  // server-rendered default, bill) and the reshape runs after it, so a
  // non-bill kind hides the detected-bill box and, for the buckets, the
  // cadence group (#applyAllocationVisibility's kind loop).
  openAllocationKind(event) {
    const kind = event.currentTarget?.dataset.allocationKind;
    if (!["bill", "debt", "savings", "fun_money"].includes(kind)) return;
    event.preventDefault();
    this.#closeKindMenu(event.currentTarget);
    const dialog = this.#allocationDialog();
    const form = this.#allocationForm(dialog);
    if (!form) return;
    this.#resetAllocationForm(form);
    const kindEl = form.querySelector('[name="plan_allocation[kind]"]');
    if (kindEl) kindEl.value = kind;
    // the fun_money row's Name stays the constant kind
    // label (ownership is never written into name) — the picker path
    // presets it on the blank form.
    if (kind === "fun_money") {
      const nameEl = form.querySelector('[name="plan_allocation[name]"]');
      if (nameEl && !nameEl.value) {
        nameEl.value = form.dataset.funMoneyDefaultName || "Fun money";
      }
    }
    this.#applyAllocationVisibility(form);
    this.#allocationCategorySummary(form);
    this.#showAllocationForm(form);
    dialog.showModal();
  }

  // The shared blank-form reset (form.reset() + mode "required"), used by
  // openBlankAllocation and openAllocationKind.
  #resetAllocationForm(form) {
    form.reset();
    this.#setAllocationMode(form, "required");
  }

  // close the DS::Menu an item was clicked from. The DS--menu
  // controller toggles on trigger click and would otherwise leave the
  // menu open on top of the freshly opened dialog, so the item action
  // closes it itself: hidden class on the content target (the controller
  // derives its show state from that classList) + aria-expanded off on
  // the trigger.
  #closeKindMenu(item) {
    const root = item?.closest?.('div[data-controller~="DS--menu"]');
    if (!root) return;
    root
      .querySelector('[data-ds--menu-target="content"]')
      ?.classList.add("hidden");
    root
      .querySelector('[data-ds--menu-target="button"]')
      ?.setAttribute("aria-expanded", "false");
  }

  #showAllocationForm(form) {
    form.classList.remove("hidden");
    // scroll ONLY the dialog's inner scroll container to the
    // form — never form.scrollIntoView, which walks every ancestor and
    // shoves the document (the page behind the dialog) when it is
    // scrollable. .overflow-auto matches the dialog's inner div uniquely
    // (the inner list caps use overflow-y-auto).
    const inner = form.closest("dialog")?.querySelector(".overflow-auto");
    if (!inner) return;
    const top =
      form.getBoundingClientRect().top -
      inner.getBoundingClientRect().top +
      inner.scrollTop;
    inner.scrollTo({ top: Math.max(0, top), behavior: "smooth" });
  }

  // the Category disclosure summary mirrors the checked radio
  // (each radio carries data-allocation-category-name). The data-action
  // fires on change inside the radio list; the private form-scoped variant
  // also runs after form.reset prefills (the radios snap to their
  // server-rendered checked state).
  syncAllocationCategory(event) {
    const form = (event.target || event.currentTarget)?.closest?.("form");
    this.#allocationCategorySummary(form);
  }

  #allocationCategorySummary(form) {
    const sel = form?.querySelector("[data-allocation-category-selection]");
    const chip = form?.querySelector("[data-allocation-category-icon-chip]");
    const radio = form?.querySelector(
      'input[name="plan_allocation[category_id]"]:checked',
    );
    if (!form || !radio) return;
    if (sel) sel.textContent = radio.dataset.allocationCategoryName || "";
    // mirror the checked row's colored icon chip
    // into the trigger. The row chips carry data-allocation-cat-row-chip
    // (the no-category row a neutral ? chip) — cloning the span avoids
    // re-implementing the server icon markup in JS.
    if (chip) {
      const rowChip = radio
        .closest("label")
        ?.querySelector("[data-allocation-cat-row-chip]");
      if (rowChip) chip.replaceChildren(rowChip.cloneNode(true));
    }
  }

  // preselect the category radio for an id (the
  // known-allocation rows and the budget-category recommendations carry
  // it), so #allocationCategorySummary mirrors it into the trigger. No-op
  // when the id is blank or the radio is absent — a custom row with no
  // category stays on "No category".
  #checkCategoryRadio(form, categoryId) {
    if (!form || !categoryId) return;
    const radio = form.querySelector(
      `input[name="plan_allocation[category_id]"][value="${categoryId}"]`,
    );
    if (radio) radio.checked = true;
  }

  openRecommended(event) {
    const recId = event.currentTarget?.dataset.recId;
    if (!recId) return;
    const rec = this.recommendationsValue.find((r) =>
      r.type === "recurring_transaction"
        ? r.recurring_transaction_id === recId
        : r.account_id === recId || r.category_id === recId,
    );
    this.#openAllocationDialog(rec || null);
  }

  #allocationDialog() {
    return document.querySelector('dialog[data-node-id="allocation:new"]');
  }

  // the allocation dialogs' header CTA is now the kind picker
  // (a DS::Menu whose items render button_to <form>s), so a bare
  // dialog.querySelector("form") matches the first MENU form, not the
  // allocation form. Scope to the main allocation form — the open/prefill
  // paths (blank form, kind pick, graph-node click) all funnel through here.
  #allocationForm(dialog) {
    return (
      dialog?.querySelector('form[data-plan-flow-target="allocationForm"]') ||
      null
    );
  }

  #openAllocationDialog(rec) {
    const dialog = this.#allocationDialog();
    if (!dialog) return;
    const form = this.#allocationForm(dialog);
    if (!form) {
      dialog.showModal();
      return;
    }
    form.reset();
    const set = (field, value) => {
      const el = form.querySelector(`[name="plan_allocation[${field}]"]`);
      if (el) el.value = value;
    };
    if (!rec) {
      // No prefill: land on the Known Allocations list , form hidden.
      this.#setAllocationMode(form, "required");
      this.#applyAllocationVisibility(form);
      form.classList.add("hidden");
      this.#allocationCategorySummary(form);
      dialog.showModal();
      return;
    }
    if (rec.type === "recurring_transaction") {
      // A detected bill / subscription: the bill details land LOCKED to
      // read-only context ( U).
      set("kind", rec.kind || "bill");
      set("recurring_transaction_id", rec.recurring_transaction_id);
      this.#setAllocationMode(form, "required");
      const cents = Number(rec.amount_cents || 0);
      this.#setFieldLocked(form, "name", true, rec.name || "");
      this.#setFieldLocked(
        form,
        "value",
        true,
        cents > 0 ? (cents / 100).toFixed(2) : "",
        cents > 0 ? this.#currencyText(form, cents) : "",
      );
      this.#setFieldLocked(
        form,
        "cadence",
        true,
        rec.cadence || "",
        rec.cadence ? this.#cadenceText(form, rec.cadence) : "",
      );
      this.#checkAccountRadio(form, rec.source_account_id);
      // preselect the category the rec carries
      // (budget-category recs do; the recurring-transaction rec payload is
      // graph-locked without it, so a no-op there by design).
      this.#checkCategoryRadio(form, rec.category_id);
    } else {
      // The "bank as allocation" row: a savings bucket (kind "savings") or
      // a debt payoff (kind "debt") with the account associated; the form
      // reshapes to the kind below (name + monthly amount stay editable).
      set("name", rec.name);
      set("kind", rec.kind);
      this.#setAllocationMode(form, "required");
      this.#checkAccountRadio(form, rec.account_id);
      this.#checkCategoryRadio(form, rec.category_id);
    }
    this.#applyAllocationVisibility(form);
    this.#allocationCategorySummary(form);
    this.#showAllocationForm(form);
    dialog.showModal();
  }

  // Check the Bank-source radio for a known account id (the list is radios,
  // so a set on the first element would corrupt the unassigned row).
  // the radio group lives in the dropdown panel,
  // OUTSIDE the form — scope the query to the dialog, then sync the form's
  // hidden plan_allocation[account_id] carrier + the trigger display
  // (#applyBankSelection).
  #checkAccountRadio(form, accountId) {
    if (!accountId || !this.inPlanValue.includes(accountId)) return;
    const dialog = form.closest("dialog");
    if (!dialog) return;
    const radio = dialog.querySelector(
      `input[name="plan_allocation[account_id]"][value="${accountId}"]`,
    );
    if (radio) radio.checked = true;
    this.#applyBankSelection(dialog, accountId);
  }

  // One pass that reshapes the dialog to the current kind + RT-link state.
  // Every open/prefill path and every kind/mode/RT change funnels through
  // here because form.reset does NOT reset the hidden class or the
  // disabled attribute, so re-applying is mandatory.
  #applyAllocationVisibility(form) {
    if (!form) return;
    const kind = this.#allocationKind(form);
    const linked = this.#allocationRtLinked(form);
    form.querySelectorAll("[data-allocation-kinds]").forEach((el) => {
      const kinds = (el.dataset.allocationKinds || "")
        .split(",")
        .map((s) => s.trim());
      el.classList.toggle("hidden", !kinds.includes(kind));
    });
    this.#setFieldLocked(form, "name", linked);
    this.#setFieldLocked(form, "value", linked);
    this.#setFieldLocked(form, "cadence", linked);
    // The cadence editable box carries BOTH a kind gate (bill,debt) and the
    // lock state: the lock pass above force-shows the editable box for
    // unlinked rows, so re-assert the kind gate after it — a bucket kind
    // (savings / fun_money) keeps the cadence hidden whether or not the row
    // is linked. classList.add (never remove): linked bill/debt rows keep
    // the lock pass's hidden editable box + read-only display.
    form.querySelectorAll("[data-allocation-kinds]").forEach((el) => {
      const kinds = (el.dataset.allocationKinds || "")
        .split(",")
        .map((s) => s.trim());
      if (!kinds.includes(kind)) el.classList.add("hidden");
    });
    // the mode group is hidden ONLY when the row is linked to a
    // detected recurring transaction — it is visible + functional for all
    // four kinds (Bill / Debt / Savings / Fun Money). The div carries no
    // data-allocation-kinds (the loop above never touches it), so the kind
    // can no longer hide it.
    const modeGroup = form.querySelector("[data-allocation-mode-group]");
    if (modeGroup) modeGroup.classList.toggle("hidden", linked);
    this.#relabelAllocationKind(form, kind);
  }

  #allocationKind(form) {
    return (
      form?.querySelector('[name="plan_allocation[kind]"]')?.value || "bill"
    );
  }

  #isBillish(kind) {
    return kind === "bill" || kind === "debt";
  }

  #allocationRtLinked(form) {
    return Boolean(
      form?.querySelector('[name="plan_allocation[recurring_transaction_id]"]')
        ?.value,
    );
  }

  // Lock / unlock one bill-detail field (name / value / cadence). Locked =
  // read-only context: the editable control is disabled (disabled controls
  // do not submit) and the hidden input carries the value, so the save
  // contract is unchanged; the locked box shows the value as a styled row.
  // Pass value/display on an explicit lock (prefill / RT link); a bare
  // state toggle (no value) keeps the current hidden value, and unlocking
  // clears it so stale bill data never saves.
  #setFieldLocked(form, field, locked, value, display) {
    const group = form.querySelector(`[data-allocation-field="${field}"]`);
    const editable = group?.querySelector(
      '[data-allocation-field-state="editable"]',
    );
    const lockedBox = group?.querySelector(
      '[data-allocation-field-state="locked"]',
    );
    if (!editable || !lockedBox) return; // the linked form has no state boxes
    const input = editable.querySelector("input, select");
    if (input) {
      // "leftover" mode takes no value: the value input stays disabled even
      // while editable ( : this bites every unlinked kind — the
      // mode select is hidden when linked, so linked rows are covered by
      // `locked`).
      const leftover =
        field === "value" &&
        form.querySelector('[name="plan_allocation[mode]"]')?.value ===
          "leftover";
      input.disabled = locked || leftover;
    }
    const hidden = lockedBox.querySelector("input[type='hidden']");
    if (hidden) {
      hidden.disabled = !locked;
      if (value !== undefined) hidden.value = value;
      else if (!locked) hidden.value = "";
    }
    const displayEl = lockedBox.querySelector("[data-allocation-locked-value]");
    if (displayEl && value !== undefined)
      displayEl.textContent = display ?? value;
    editable.classList.toggle("hidden", locked);
    lockedBox.classList.toggle("hidden", !locked);
  }

  // The kind relabels (the label strings come from the server-rendered
  // data attributes, i18n): Bill / Debt share the bill copy, Savings and
  // Fun Money have their own.
  #relabelAllocationKind(form, kind) {
    const key =
      kind === "savings" ? "savings" : kind === "fun_money" ? "fun" : "bill";
    form.querySelectorAll("[data-allocation-kind-label]").forEach((el) => {
      const text = el.dataset[`${key}Label`] || el.dataset.billLabel;
      if (text) el.textContent = text;
    });
    form.querySelectorAll("[data-allocation-kind-hint]").forEach((el) => {
      const text = el.dataset[`${key}Hint`] || el.dataset.billHint;
      if (text) el.textContent = text;
    });
  }

  // The editable control of a bill-detail field (inside its state box, so
  // the hidden inputs of the locked box are never matched by name).
  #editableInput(form, field) {
    const group = form.querySelector(`[data-allocation-field="${field}"]`);
    return group?.querySelector(
      '[data-allocation-field-state="editable"] input, [data-allocation-field-state="editable"] select',
    );
  }

  // Currency text for the read-only rows (the family currency is on the
  // form; Intl formatting, plain 0.00 fallback).
  #currencyText(form, cents) {
    const currency = form?.dataset.familyCurrency;
    const amount = Number(cents) / 100;
    if (!currency) return amount.toFixed(2);
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency,
      }).format(amount);
    } catch {
      return amount.toFixed(2);
    }
  }

  // The cadence select's option text for the read-only row (the i18n comes
  // from the server-rendered options).
  #cadenceText(form, cadence) {
    const select = this.#editableInput(form, "cadence");
    const option = select?.options?.namedItem(cadence);
    return option ? option.text : cadence;
  }

  // Mode change inside the allocation dialog ( : all four kinds,
  // custom — i.e. unlinked — rows only): required/specific take
  // plan_allocation[value] (required = MONTHLY
  // figure, deviation 1), percent takes plan_allocation[value_percent]
  // (0-100), leftover takes no value. The single visible input is renamed
  // in place.
  syncAllocationMode(event) {
    const form = event.target.closest("form");
    this.#setAllocationMode(form, event.target.value);
    this.#applyAllocationVisibility(form);
  }

  // Kind change ( U): the form reshapes to the kind. Leaving
  // Bill / Debt drops the bill-only state (the stale RT link / cadence
  // could not be edited while hidden).: bucket kinds (Savings /
  // Fun Money) keep the user's mode + value — all four modes are functional
  // for every kind, so there is no forced reset here. A fresh form lands on
  // "required" (the server-rendered default); nothing is pre-set the user
  // did not pick. The hidden RT link + cadence are still cleared for
  // buckets: those controls stay hidden for them, and the server sanitize
  // is the backstop.
  syncAllocationKind(event) {
    const form = event.target.closest("form");
    const kind = event.target.value;
    if (!this.#isBillish(kind)) {
      const rt = form.querySelector(
        '[name="plan_allocation[recurring_transaction_id]"]',
      );
      if (rt) rt.value = "";
      const cadence = this.#editableInput(form, "cadence");
      if (cadence) cadence.value = "";
    }
    this.#applyAllocationVisibility(form);
  }

  #setAllocationMode(form, mode) {
    if (!form) return;
    const input = form.querySelector(
      '[name="plan_allocation[value]"], [name="plan_allocation[value_percent]"]',
    );
    if (!input) return;
    if (mode === "percent") {
      input.name = "plan_allocation[value_percent]";
    } else {
      input.name = "plan_allocation[value]";
    }
    const hint = form.querySelector("[data-allocation-required-hint]");
    if (mode === "required") {
      input.disabled = false;
      input.placeholder = "0.00";
      if (hint) hint.style.display = "";
    } else if (mode === "specific" || mode === "percent") {
      input.disabled = false;
      input.placeholder = mode === "percent" ? "0-100" : "0.00";
      if (hint) hint.style.display = "none";
    } else {
      input.disabled = true;
      input.value = "";
      if (hint) hint.style.display = "none";
    }
  }

  // Link-to-detected-bill/debt ( U): picking an RT pulls the bill
  // details in and LOCKS them to read-only context (name / amount /
  // cadence; the source bank when it is on the plan); the rec payload
  // comes from the page (no second fetch). "None" unlocks them again.
  syncAllocationRt(event) {
    const rtId = event.target.value;
    const form = event.target.closest("form");
    if (!form) return;
    if (!rtId) {
      this.#applyAllocationVisibility(form);
      return;
    }
    const rec = this.recommendationsValue.find(
      (r) =>
        r.type === "recurring_transaction" &&
        r.recurring_transaction_id === rtId,
    );
    if (!rec) {
      this.#applyAllocationVisibility(form);
      return;
    }
    const cents = Number(rec.amount_cents || 0);
    this.#setFieldLocked(form, "name", true, rec.name || "");
    this.#setFieldLocked(
      form,
      "value",
      true,
      cents > 0 ? (cents / 100).toFixed(2) : "",
      cents > 0 ? this.#currencyText(form, cents) : "",
    );
    this.#setFieldLocked(
      form,
      "cadence",
      true,
      rec.cadence || "",
      rec.cadence ? this.#cadenceText(form, rec.cadence) : "",
    );
    // The linked bill's kind, and it is always a required (monthly) figure.
    const kindEl = form.querySelector('[name="plan_allocation[kind]"]');
    if (kindEl && rec.kind) kindEl.value = rec.kind;
    const mode = form.querySelector('[name="plan_allocation[mode]"]');
    if (mode && mode.value !== "required") {
      mode.value = "required";
      this.#setAllocationMode(form, "required");
    }
    this.#checkAccountRadio(form, rec.source_account_id);
    // preselect the rec's category (see
    // #openAllocationDialog) and mirror it into the trigger — the RT link
    // reshapes the dialog, and the trigger must not go stale.
    this.#checkCategoryRadio(form, rec.category_id);
    this.#applyAllocationVisibility(form);
    this.#allocationCategorySummary(form);
  }

  // ---- Bank source dropdown (item 6) -----------------------
  //
  // The dropdown panel ([data-allocation-bank-panel]) sits OUTSIDE the
  // form — a same-name radio group + the form's hidden
  // plan_allocation[account_id] input in one <form> would serialize as an
  // array and break the controller's sanitize — but stays a descendant of
  // the dialog's content target, so a click inside it never looks like a
  // backdrop click (the clickOutside lesson). The radio group in
  // the panel is the UI source of truth; the hidden input is the submit
  // carrier. Close behavior: mousedown outside trigger + panel, Escape
  // (the dialog also closes natively — the hotkey — and its close event
  // cleans the panel up), and a row click (select + sync + close).

  toggleBankSource(event) {
    const trigger = event.currentTarget;
    const dialog = trigger?.closest("dialog");
    if (!dialog) return;
    const panel = dialog.querySelector("[data-allocation-bank-panel]");
    if (!panel) return;
    if (panel.dataset.bankOpen === "1") this.#closeBankPanel(dialog);
    else this.#openBankPanel(trigger, panel);
  }

  syncBankSource(event) {
    const radio = event.target;
    const dialog = radio?.closest("dialog");
    if (!dialog) return;
    this.#applyBankSelection(dialog, radio.value);
    this.#closeBankPanel(dialog);
  }

  #openBankPanel(trigger, panel) {
    // The bank radios of ALL dialog instances share one name and one
    // document scope: the panels sit OUTSIDE the forms by design (a same-name
    // radio group plus the form's hidden carrier inside one form would
    // serialize as an array), so there is no per-dialog owning form to
    // partition the group — only the last radio per value on the page is
    // natively checked. Re-sync THIS dialog's checked state from its hidden
    // input (the submit carrier) whenever the panel opens.
    const dialog = panel.closest("dialog");
    const form = dialog?.querySelector(
      '[data-plan-flow-target="allocationForm"]',
    );
    const hidden = form?.querySelector(
      'input[type="hidden"][name="plan_allocation[account_id]"]',
    );
    const targetValue = hidden ? hidden.value : "";
    const radio = panel.querySelector(
      `input[name="plan_allocation[account_id]"][value="${targetValue}"]`,
    );
    if (radio) radio.checked = true;
    panel.classList.remove("hidden");
    panel.dataset.bankOpen = "1";
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const rect = trigger.getBoundingClientRect();
    // Clamp the width to the viewport before measuring (a narrow viewport
    // would otherwise push the fixed panel off-screen to the right).
    panel.style.maxWidth = `${Math.min(288, vw - 16)}px`;
    const pw = panel.offsetWidth;
    const ph = panel.offsetHeight;
    // Place under the trigger, viewport-clamped (8px margins); the panel's
    // max-h-64 overflow-y-auto scroll window keeps a tall list inside.
    let top = rect.bottom + 4;
    let left = rect.left;
    if (top + ph > vh - 8) top = Math.max(8, vh - 8 - ph);
    left = Math.max(8, Math.min(left, vw - 8 - pw));
    panel.style.left = `${left}px`;
    panel.style.top = `${top}px`;
  }

  #closeBankPanel(dialog) {
    const panel = dialog?.querySelector("[data-allocation-bank-panel]");
    if (!panel) return;
    panel.classList.add("hidden");
    delete panel.dataset.bankOpen;
  }

  // (Fun Money v2): the Distribution floating radio panel — the
  // same trigger/panel/close machinery as the bank-source dropdown (the
  // panel sits OUTSIDE the form: the radios carry their own names and the
  // form's hidden plan_allocation[distribution] input is the submit
  // carrier, synced by #syncFunDistribution).
  toggleFunDistribution(event) {
    const trigger = event.currentTarget;
    const dialog = trigger?.closest("dialog");
    if (!dialog) return;
    const panel = dialog.querySelector(
      "[data-allocation-fm-distribution-panel]",
    );
    if (!panel) return;
    if (panel.dataset.fmOpen === "1") this.#closeFunPanel(dialog);
    else this.#openFunPanel(trigger, panel);
  }

  syncFunDistribution(event) {
    const radio = event.target;
    const dialog = radio?.closest("dialog");
    const form = dialog?.querySelector(
      '[data-plan-flow-target="allocationForm"]',
    );
    if (!dialog || !form) return;
    const value = radio.value;
    const carrier = form.querySelector(
      'input[type="hidden"][name="plan_allocation[distribution]"]',
    );
    if (carrier) carrier.value = value;
    const trigger = dialog.querySelector("[data-fm-distribution-trigger]");
    const label = trigger?.querySelector("[data-fm-distribution-label]");
    if (label) {
      const text =
        radio.closest("label")?.querySelector("span")?.textContent || value;
      label.textContent =
        value === "" ? trigger.dataset.fmDistributionNone || "—" : text;
      label.classList.toggle("text-primary", value !== "");
      label.classList.toggle("text-secondary", value === "");
    }
    // "Percentage of Pooled" reveals the per-member percent inputs and
    // arms the hidden percent carriers (the visible inputs are the value
    // source; the disabled carriers never submit — the sanitizer + model
    // are the backstops).
    const inputsBox = dialog.querySelector(
      "[data-allocation-fm-percent-inputs]",
    );
    if (inputsBox) inputsBox.classList.toggle("hidden", value !== "percent");
    const percentsArmed = value === "percent";
    form
      .querySelectorAll('input[name^="plan_allocation[distribution_percents]"]')
      .forEach((input) => {
        const member = input.name
          .slice("plan_allocation[distribution_percents][".length)
          .replace("]", "");
        const visible = dialog.querySelector(
          `[data-fm-percent-member="${member}"]`,
        );
        input.value = percentsArmed && visible ? visible.value : "";
        input.disabled = !percentsArmed;
      });
    this.#syncFunMatching(form);
    this.#closeFunPanel(dialog);
  }

  // a percent input change flows into the member's hidden carrier.
  syncFunPercent(event) {
    const input = event.target;
    const member = input.dataset.fmPercentMember;
    if (!member) return;
    const dialog = input.closest("dialog");
    const form = dialog?.querySelector(
      '[data-plan-flow-target="allocationForm"]',
    );
    const carrier = form?.querySelector(
      `input[name="plan_allocation[distribution_percents][${member}]"]`,
    );
    if (carrier) carrier.value = input.value;
  }

  // Ownership = Household disables per-user matching (the planner
  // ignores matching for the Household shared pool; the select is display
  // only until the next server render).
  syncFunOwnership(event) {
    const form = event.target.closest("form");
    if (!form) return;
    this.#syncFunMatching(form);
  }

  #openFunPanel(trigger, panel) {
    const dialog = panel.closest("dialog");
    const form = dialog?.querySelector(
      '[data-plan-flow-target="allocationForm"]',
    );
    const hidden = form?.querySelector(
      'input[type="hidden"][name="plan_allocation[distribution]"]',
    );
    const targetValue = hidden ? hidden.value : "";
    const radio = panel.querySelector(`input[value="${targetValue}"]`);
    if (radio) radio.checked = true;
    const inputsBox = panel.querySelector(
      "[data-allocation-fm-percent-inputs]",
    );
    if (inputsBox)
      inputsBox.classList.toggle("hidden", targetValue !== "percent");
    panel.classList.remove("hidden");
    panel.dataset.fmOpen = "1";
    // Same viewport-clamped placement as the bank-source panel.
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const rect = trigger.getBoundingClientRect();
    panel.style.maxWidth = `${Math.min(288, vw - 16)}px`;
    const pw = panel.offsetWidth;
    const ph = panel.offsetHeight;
    let top = rect.bottom + 4;
    let left = rect.left;
    if (top + ph > vh - 8) top = Math.max(8, vh - 8 - ph);
    left = Math.max(8, Math.min(left, vw - 8 - pw));
    panel.style.left = `${left}px`;
    panel.style.top = `${top}px`;
  }

  #closeFunPanel(dialog) {
    const panel = dialog?.querySelector(
      "[data-allocation-fm-distribution-panel]",
    );
    if (!panel) return;
    panel.classList.add("hidden");
    delete panel.dataset.fmOpen;
  }

  // / : the Matching select's lock states — Household ownership
  // disables it ; Distribution "Individual Leftover by Allocations"
  // forces Per Income (own-leftover funding IS the per income semantics),
  // remembering the prior value so leaving the option restores it.
  #syncFunMatching(form) {
    const select = form.querySelector('[name="plan_allocation[matching]"]');
    if (!select) return;
    const ownership = form.querySelector('[name="plan_allocation[ownership]"]');
    const distribution = form.querySelector(
      'input[type="hidden"][name="plan_allocation[distribution]"]',
    );
    const household = ownership?.value === "household";
    const individual = distribution?.value === "individual_leftover";
    if (household) {
      select.disabled = true;
      return;
    }
    if (individual) {
      if (!select.dataset.fmPrev) select.dataset.fmPrev = select.value;
      if (
        select.value !== "per_income" &&
        select.querySelector('option[value="per_income"]')
      ) {
        select.value = "per_income";
      }
      select.disabled = true;
      return;
    }
    select.disabled = false;
    if (select.dataset.fmPrev && select.dataset.fmPrev !== "per_income") {
      select.value = select.dataset.fmPrev;
      delete select.dataset.fmPrev;
    }
  }

  #bankPanelOutside(event) {
    document
      .querySelectorAll(
        "[data-allocation-bank-panel][data-bank-open='1'], [data-allocation-fm-distribution-panel][data-fm-open='1']",
      )
      .forEach((panel) => {
        const dialog = panel.closest("dialog");
        const trigger = dialog?.querySelector("[data-allocation-bank-trigger]");
        const fmTrigger = dialog?.querySelector(
          "[data-fm-distribution-trigger]",
        );
        const inside =
          panel.contains(event.target) ||
          trigger?.contains(event.target) ||
          fmTrigger?.contains(event.target);
        if (!inside) {
          this.#closeBankPanel(dialog);
          this.#closeFunPanel(dialog);
        }
      });
  }

  #bankPanelEscape(event) {
    if (event.key !== "Escape") return;
    document
      .querySelectorAll(
        "[data-allocation-bank-panel][data-bank-open='1'], [data-allocation-fm-distribution-panel][data-fm-open='1']",
      )
      .forEach((panel) => {
        this.#closeBankPanel(panel.closest("dialog"));
        this.#closeFunPanel(panel.closest("dialog"));
      });
  }

  // One close-listener per allocation dialog: however the dialog closes
  // (backdrop click, Escape, X), the panel is hidden so a reopen starts
  // clean (the popup-persistence quirk, applied to the new
  // dropdown).
  #watchBankPanels() {
    document
      .querySelectorAll('dialog[data-node-id^="allocation:"]')
      .forEach((dialog) => {
        // (Fun Money v2): the Distribution panel closes with the
        // dialog too (same popup-persistence lesson as the bank panel).
        const onclose = () => {
          this.#closeBankPanel(dialog);
          this.#closeFunPanel(dialog);
        };
        dialog.addEventListener("close", onclose);
        this._bankCloseUnwatchers.set(dialog, () =>
          dialog.removeEventListener("close", onclose),
        );
      });
  }

  // Sync the form's hidden plan_allocation[account_id] input + the trigger
  // display to a bank radio value (the panel's radio group is the UI
  // source of truth; this is the submit carrier + the labeled row). The
  // row's avatar chip is cloned into the trigger (cloning keeps the
  // letter+logo markup server-defined; onerror-dead <img>s re-clone
  // fresh).
  #applyBankSelection(dialog, value) {
    const form = this.#allocationForm(dialog);
    const hidden = form?.querySelector(
      'input[type="hidden"][name="plan_allocation[account_id]"]',
    );
    if (hidden) hidden.value = value;
    const trigger = dialog?.querySelector("[data-allocation-bank-trigger]");
    if (!trigger) return;
    // scope to THIS dialog's bank panel. A dialog-wide
    // [value=...] query matches the form's HIDDEN carrier input first
    // (same name + value, earlier in the DOM), whose dataset is empty —
    // so the trigger label/chip/last4 all fell back to "None Selected"
    // for every assigned allocation. The data-bank-* attributes live on
    // the panel's radios only.
    const panel = dialog?.querySelector("[data-allocation-bank-panel]");
    const radio = panel?.querySelector(
      `input[name="plan_allocation[account_id]"][value="${value}"]`,
    );
    const isNone = value === "" || radio?.dataset.bankNone === "true";
    const nameEl = trigger.querySelector("[data-allocation-bank-name]");
    if (nameEl) {
      nameEl.textContent = isNone
        ? trigger.dataset.allocationBankNone || "None Selected"
        : radio?.dataset.bankName || "";
      nameEl.classList.toggle("text-primary", !isNone);
      nameEl.classList.toggle("text-secondary", isNone);
    }
    const chip = trigger.querySelector("[data-allocation-bank-chip]");
    const noneIcon = trigger.querySelector("[data-allocation-bank-none-icon]");
    if (chip) {
      chip.classList.toggle("hidden", isNone);
      if (!isNone) {
        const rowChip = radio
          ?.closest("label")
          ?.querySelector("[data-bank-row-chip]");
        if (rowChip) chip.replaceChildren(rowChip.cloneNode(true));
      }
    }
    if (noneIcon) noneIcon.classList.toggle("hidden", !isNone);
    const last4El = trigger.querySelector("[data-allocation-bank-last4]");
    if (last4El) {
      const last4 = isNone ? "" : radio?.dataset.bankLast4 || "";
      last4El.textContent = last4 ? `****${last4}` : "";
      last4El.classList.toggle("hidden", !last4);
    }
  }

  // the bank dialog's Pull-From-Incomes sync (syncBankRow) moved
  // to the bank_config_dialog controller with the trigger-button
  // restyle — the visible controls are nameless and the dialog controller
  // live-syncs the per-income hidden inputs it submits.

  // the picker's row operations. The
  // browser dialogs (window.confirm / window.prompt) are user-gesture APIs
  // not document-level listeners; every query is scoped to the picker
  // container (data-scenario-picker), per the rule.
  #scenarioPicker(btn) {
    return btn.closest("[data-scenario-picker]");
  }

  async #scenarioRequest(url, method, payload = null) {
    const headers = { Accept: "application/json" };
    const token = document.querySelector('meta[name="csrf-token"]')?.content;
    if (token) headers["X-CSRF-Token"] = token; // house pattern (application.js)
    const options = { method, credentials: "same-origin", headers };
    if (payload !== null) {
      options.headers["Content-Type"] = "application/json";
      options.body = JSON.stringify(payload);
    }
    const res = await fetch(url, options);
    let body = {};
    try {
      body = await res.json();
    } catch {
      body = {};
    }
    return { ok: res.ok, body };
  }

  // Reset (the design decision ): the scenario's snapshot is rebuilt from its
  // source; on success the page reloads INTO the rebuilt scenario (the
  // house full-reload navigation for a mode change).
  resetScenario(event) {
    const btn = event.currentTarget;
    if (!window.confirm(btn.dataset.scenarioResetConfirm)) return;
    const rowId = btn.closest("[data-scenario-row]")?.dataset.scenarioRowId;
    this.#scenarioRequest(btn.dataset.scenarioResetUrl, "POST")
      .then(({ ok, body }) => {
        if (!ok) {
          window.alert((body.errors?.scenario || ["Reset failed"]).join(" "));
          return;
        }
        const picker = this.#scenarioPicker(btn);
        window.location.href = `${picker.dataset.scenarioFlowPath}?scenario=${rowId}`;
      })
      .catch(() => window.alert("Reset failed"));
  }

  // Rename: window.prompt -> the rename endpoint -> the row's label updates
  // in place (the row id is unchanged, so no graph re-plan is needed).
  renameScenario(event) {
    const btn = event.currentTarget;
    const current = btn.dataset.scenarioRenameName;
    const name = window.prompt(btn.dataset.scenarioRenameTitle, current);
    if (name === null || !name.trim() || name.trim() === current) return;
    this.#scenarioRequest(btn.dataset.scenarioRenameUrl, "PATCH", {
      name: name.trim(),
    })
      .then(({ ok, body }) => {
        if (!ok) {
          window.alert((body.errors?.name || ["Rename failed"]).join(" "));
          return;
        }
        const row = btn.closest("[data-scenario-row]");
        if (!row) return;
        row.dataset.scenarioRowName = body.scenario.name;
        const label = row.querySelector("[data-scenario-row-name-label]");
        if (label) label.textContent = body.scenario.name;
      })
      .catch(() => window.alert("Rename failed"));
  }

  // Delete: the scenario row is removed from the picker; if it was the
  // ACTIVE scenario the page reloads back to the live plan (the 422
  // backstop in the API prevents a live delete, but the picker is the
  // house's switch-first flow — a deleted active row would otherwise
  // strand the page on a ?scenario= with no row).
  deleteScenario(event) {
    const btn = event.currentTarget;
    if (!window.confirm(btn.dataset.scenarioDeleteConfirm)) return;
    const row = btn.closest("[data-scenario-row]");
    this.#scenarioRequest(btn.dataset.scenarioDeleteUrl, "DELETE")
      .then(({ ok, body }) => {
        if (!ok) {
          window.alert((body.errors?.scenario || ["Delete failed"]).join(" "));
          return;
        }
        const picker = this.#scenarioPicker(btn);
        if (btn.dataset.scenarioDeleteActive === "true") {
          window.location.href = picker.dataset.scenarioFlowPath;
        } else if (row) {
          row.remove();
        }
      })
      .catch(() => window.alert("Delete failed"));
  }

  // Open the Create-New-Scenario dialog (the DS::Dialog the picker partial
  // renders; the query is scoped to the picker container).
  openScenarioNew(event) {
    const picker = this.#scenarioPicker(event.currentTarget);
    picker.querySelector('dialog[data-node-id="scenario-new"]')?.showModal();
  }
}
