import { Controller } from "@hotwired/stimulus";

// Paycheck Flow page (M2 PR#2b): the Sankey page's dialog wiring. The page
// embeds the recommendation list (for the Recommended click-prefills) and
// the in-plan account ids (source-bank scope for prefills); every other
// plan state lives server-side behind GET /plan/flow/graph — the page holds
// no client-side plan state.
//
// Dialogs are inline <dialog> elements (house DS::Dialog, disable_frame)
// opened with showModal() — the budget_categories move-dialog pattern.
//
// Owner review round 3 (R1/R7): every plan mutation form (allocation
// add/edit/delete, bank add/config/remove, income config) submits IN PLACE
// — a fetch (Accept: application/json) instead of a full reload, so the
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
  }

  disconnect() {
    document.removeEventListener("submit", this._inPlaceSubmitHandler, true);
  }

  // One shared submit path for every plan-flow mutation form. On 200 +
  // graph JSON: close the dialog / clear the modal frame, swap the stale
  // server-rendered chrome fragments, and hand the fresh graph to the
  // Sankey controller (it tweens — R7). On 422: render the model's field
  // errors inline in the dialog (no full-page flash — there is no reload).
  async #inPlaceSubmit(event) {
    const target = event.target;
    if (!(target instanceof HTMLFormElement)) return;
    if (!target.hasAttribute("data-plan-flow-inplace")) return;
    const form = target;
    if (event.defaultPrevented || form.dataset.busy === "1") return;

    // Bank removal (R3): confirm when allocations are attached to the bank.
    if (form.dataset.removeConfirm === "true" && Number(form.dataset.allocatedCount || 0) > 0) {
      if (!window.confirm(form.dataset.removeMessage || "Remove this bank from the plan?")) {
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
      try { data = await response.json(); } catch { data = null; }

      if (response.status === 422) {
        if (data?.errors) {
          showErrors(
            Object.entries(data.errors)
              .map(([, messages]) => `<p class="text-xs text-destructive">${messages.map(this.#esc).join(" ")}</p>`)
              .join(""),
          );
        }
        return;
      }
      if (!response.ok || !data?.graph) throw new Error(`plan-flow in-place update failed (${response.status})`);

      errors?.classList.add("hidden");

      // Swap the server-rendered chrome that can go stale (over-plan
      // lines, empty states, the dialog's Known Allocations list).
      const chrome = data.chrome || {};
      if (chrome.top) this.#swapFragment("[data-flow-chrome='top']", chrome.top);
      if (chrome.overlays) this.#swapFragment("[data-flow-chrome='overlays']", chrome.overlays);
      if (chrome.known) this.#swapFragment("[data-plan-flow-target='knownSection']", chrome.known);

      // Round 21 T8: the allocation dialog's BANK SOURCE rows render once
      // at page load, so an in-place account add/remove leaves them stale.
      // Swap the fresh fragment into every allocation dialog (allocation:new
      // and allocation:<id>) that carries the holder, then re-check the
      // radio the dialog's form currently holds (radio names are unchanged;
      // the #checkAccountRadio contract stays intact). A closed dialog keeps
      // its form in the DOM, so the live checked state is readable either
      // way; nil-safe: no allocation dialog in the DOM -> nothing to swap.
      if (chrome.allocation_bank_rows) {
        for (const dlg of document.querySelectorAll("dialog[data-node-id^='allocation:']")) {
          const holder = dlg.querySelector("[data-flow-chrome='allocation-bank-rows']");
          if (!holder) continue;
          const current =
            dlg.querySelector("input[name='plan_allocation[account_id]']:checked")?.value ?? "";
          const tpl = document.createElement("template");
          tpl.innerHTML = chrome.allocation_bank_rows.trim();
          const node = tpl.content.firstElementChild;
          if (!node) continue;
          holder.replaceWith(node);
          // If the form held the account that just left the plan, fall
          // back to the unassigned radio (value="") rather than leaving
          // the form with no checked source.
          const radio =
            dlg.querySelector(`input[name='plan_allocation[account_id]'][value="${current}"]`) ??
            dlg.querySelector("input[name='plan_allocation[account_id]'][value='']");
          if (radio) radio.checked = true;
        }
      }

      // Round 4 (ghost banks): in-place bank adds/edits ship the affected
      // banks' config dialogs — inject or refresh them so the (new) bank
      // node is operable without a reload; a removed bank's dialog is
      // dropped.
      if (Array.isArray(chrome.bank_dialogs)) {
        for (const entry of chrome.bank_dialogs) this.#syncDialog(entry.node_id, entry.html);
      }
      if (chrome.bank_removed) {
        document.querySelector(`dialog[data-node-id="${chrome.bank_removed}"]`)?.remove();
      }

      // Round 7: the Sankey's in-plan / account-name values are page-load
      // state — after an in-place add/delete they are stale, and a removed
      // bank gets re-synthesized as a phantom floor node until reload.
      // Refresh them from the response before the diagram re-renders.
      if (chrome.sankey) {
        const sankeyEl = document.querySelector("[data-controller~='plan-flow-sankey']");
        if (sankeyEl) {
          if (chrome.sankey.accounts) {
            sankeyEl.dataset.planFlowSankeyAccountsValue = JSON.stringify(chrome.sankey.accounts);
          }
          if (Array.isArray(chrome.sankey.in_plan)) {
            sankeyEl.dataset.planFlowSankeyInPlanValue = JSON.stringify(chrome.sankey.in_plan);
          }
        }
      }

      // The Sankey controller tweens to the fresh graph (R7).
      document.querySelector("[data-controller~='plan-flow-sankey']")?.dispatchEvent(
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
      showErrors("<p class='text-xs text-destructive'>The update didn't go through — refresh the page.</p>");
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

  // Round 4 (ghost banks): ensure a <dialog> element for the node id —
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

  // ---- Allocation dialog (round 20 U: two-stack rework) -----------------
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
  // (owner round 2, F3); the custom form stays hidden until a row click or
  // the "New Allocation" button.
  openNewAllocation() {
    this.#openAllocationDialog(null);
  }

  // A "Known Allocations" row (detected bill / subscription): prefill the
  // SELECTED-allocation window's form with the bill details LOCKED to
  // read-only context (round 20 U) and open it as a separate window
  // (round 21 T4 — the allocation:new dialog does NOT expand in place; the
  // prefill runs against the selected dialog's form, then showModal()).
  openKnownAllocation(event) {
    const row = event.currentTarget;
    if (!row) return;
    const dialog = document.querySelector('dialog[data-node-id="allocation:selected"]');
    const form = dialog?.querySelector("form");
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
    this.#setFieldLocked(form, "value", true, cents > 0 ? (cents / 100).toFixed(2) : "", cents > 0 ? this.#currencyText(form, cents) : "");
    this.#setFieldLocked(form, "cadence", true, row.dataset.knownCadence || "", row.dataset.knownCadence ? this.#cadenceText(form, row.dataset.knownCadence) : "");
    this.#checkAccountRadio(form, row.dataset.knownAccount);
    this.#applyAllocationVisibility(form);
    this.#allocationCategorySummary(form);
    dialog.showModal();
  }

  // "Add New Allocation" (header CTA, round 21 T3): the custom input form,
  // blank.
  openBlankAllocation() {
    const form = this.#allocationDialog()?.querySelector("form");
    if (!form) return;
    form.reset();
    this.#setAllocationMode(form, "required");
    this.#applyAllocationVisibility(form);
    this.#allocationCategorySummary(form);
    this.#showAllocationForm(form);
  }

  #showAllocationForm(form) {
    form.classList.remove("hidden");
    // Round 21 T7: scroll ONLY the dialog's inner scroll container to the
    // form — never form.scrollIntoView(), which walks every ancestor and
    // shoves the document (the page behind the dialog) when it is
    // scrollable. .overflow-auto matches the dialog's inner div uniquely
    // (the inner list caps use overflow-y-auto).
    const inner = form.closest("dialog")?.querySelector(".overflow-auto");
    if (!inner) return;
    const top = form.getBoundingClientRect().top - inner.getBoundingClientRect().top + inner.scrollTop;
    inner.scrollTo({ top: Math.max(0, top), behavior: "smooth" });
  }

  // Round 21 T4: the Category disclosure summary mirrors the checked radio
  // (each radio carries data-allocation-category-name). The data-action
  // fires on change inside the radio list; the private form-scoped variant
  // also runs after form.reset() prefills (the radios snap to their
  // server-rendered checked state).
  syncAllocationCategory(event) {
    const form = (event.target || event.currentTarget)?.closest?.("form");
    this.#allocationCategorySummary(form);
  }

  #allocationCategorySummary(form) {
    const sel = form?.querySelector("[data-allocation-category-selection]");
    const radio = form?.querySelector('input[name="plan_allocation[category_id]"]:checked');
    if (sel && radio) sel.textContent = radio.dataset.allocationCategoryName || "";
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

  #openAllocationDialog(rec) {
    const dialog = this.#allocationDialog();
    if (!dialog) return;
    const form = dialog.querySelector("form");
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
      // No prefill: land on the Known Allocations list (F3), form hidden.
      this.#setAllocationMode(form, "required");
      this.#applyAllocationVisibility(form);
      form.classList.add("hidden");
      this.#allocationCategorySummary(form);
      dialog.showModal();
      return;
    }
    if (rec.type === "recurring_transaction") {
      // A detected bill / subscription: the bill details land LOCKED to
      // read-only context (round 20 U).
      set("kind", rec.kind || "bill");
      set("recurring_transaction_id", rec.recurring_transaction_id);
      this.#setAllocationMode(form, "required");
      const cents = Number(rec.amount_cents || 0);
      this.#setFieldLocked(form, "name", true, rec.name || "");
      this.#setFieldLocked(form, "value", true, cents > 0 ? (cents / 100).toFixed(2) : "", cents > 0 ? this.#currencyText(form, cents) : "");
      this.#setFieldLocked(form, "cadence", true, rec.cadence || "", rec.cadence ? this.#cadenceText(form, rec.cadence) : "");
      this.#checkAccountRadio(form, rec.source_account_id);
    } else {
      // The "bank as allocation" row: a savings bucket (kind "savings") or
      // a debt payoff (kind "debt") with the account associated; the form
      // reshapes to the kind below (name + monthly amount stay editable).
      set("name", rec.name);
      set("kind", rec.kind);
      this.#setAllocationMode(form, "required");
      this.#checkAccountRadio(form, rec.account_id);
    }
    this.#applyAllocationVisibility(form);
    this.#allocationCategorySummary(form);
    this.#showAllocationForm(form);
    dialog.showModal();
  }

  // Check the Bank-source radio for a known account id (the list is radios,
  // so a set() on the first element would corrupt the unassigned row).
  #checkAccountRadio(form, accountId) {
    if (!accountId || !this.inPlanValue.includes(accountId)) return;
    const radio = form.querySelector(`[name="plan_allocation[account_id]"][value="${accountId}"]`);
    if (radio) radio.checked = true;
  }

  // One pass that reshapes the dialog to the current kind + RT-link state.
  // Every open/prefill path and every kind/mode/RT change funnels through
  // here because form.reset() does NOT reset the hidden class or the
  // disabled attribute, so re-applying is mandatory.
  #applyAllocationVisibility(form) {
    if (!form) return;
    const kind = this.#allocationKind(form);
    const billish = this.#isBillish(kind);
    const linked = this.#allocationRtLinked(form);
    form.querySelectorAll("[data-allocation-kinds]").forEach((el) => {
      const kinds = (el.dataset.allocationKinds || "").split(",").map((s) => s.trim());
      el.classList.toggle("hidden", !kinds.includes(kind));
    });
    this.#setFieldLocked(form, "name", linked);
    this.#setFieldLocked(form, "value", linked);
    this.#setFieldLocked(form, "cadence", linked);
    const modeGroup = form.querySelector("[data-allocation-mode-group]");
    if (modeGroup) modeGroup.classList.toggle("hidden", !billish || linked);
    this.#relabelAllocationKind(form, kind);
  }

  #allocationKind(form) {
    return form?.querySelector('[name="plan_allocation[kind]"]')?.value || "bill";
  }

  #isBillish(kind) {
    return kind === "bill" || kind === "debt";
  }

  #allocationRtLinked(form) {
    return Boolean(form?.querySelector('[name="plan_allocation[recurring_transaction_id]"]')?.value);
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
    const editable = group?.querySelector('[data-allocation-field-state="editable"]');
    const lockedBox = group?.querySelector('[data-allocation-field-state="locked"]');
    if (!editable || !lockedBox) return; // the linked form has no state boxes
    const input = editable.querySelector("input, select");
    if (input) {
      // "leftover" mode takes no value: the value input stays disabled even
      // while editable (the mode select is hidden when linked, so this only
      // bites a custom Bill / Debt).
      const leftover = field === "value" && form.querySelector('[name="plan_allocation[mode]"]')?.value === "leftover";
      input.disabled = locked || leftover;
    }
    const hidden = lockedBox.querySelector("input[type='hidden']");
    if (hidden) {
      hidden.disabled = !locked;
      if (value !== undefined) hidden.value = value;
      else if (!locked) hidden.value = "";
    }
    const displayEl = lockedBox.querySelector("[data-allocation-locked-value]");
    if (displayEl && value !== undefined) displayEl.textContent = display ?? value;
    editable.classList.toggle("hidden", locked);
    lockedBox.classList.toggle("hidden", !locked);
  }

  // The kind relabels (the label strings come from the server-rendered
  // data attributes, i18n): Bill / Debt share the bill copy, Savings and
  // Fun Money have their own.
  #relabelAllocationKind(form, kind) {
    const key = kind === "savings" ? "savings" : kind === "fun_money" ? "fun" : "bill";
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
    return group?.querySelector('[data-allocation-field-state="editable"] input, [data-allocation-field-state="editable"] select');
  }

  // Currency text for the read-only rows (the family currency is on the
  // form; Intl formatting, plain 0.00 fallback).
  #currencyText(form, cents) {
    const currency = form?.dataset.familyCurrency;
    const amount = Number(cents) / 100;
    if (!currency) return amount.toFixed(2);
    try {
      return new Intl.NumberFormat(undefined, { style: "currency", currency }).format(amount);
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

  // Mode change inside the allocation dialog (custom Bill / Debt only):
  // required/specific take plan_allocation[value] (required = MONTHLY
  // figure, deviation 1), percent takes plan_allocation[value_percent]
  // (0-100), leftover takes no value. The single visible input is renamed
  // in place.
  syncAllocationMode(event) {
    const form = event.target.closest("form");
    this.#setAllocationMode(form, event.target.value);
    this.#applyAllocationVisibility(form);
  }

  // Kind change (round 20 U): the form reshapes to the kind. Leaving
  // Bill / Debt drops the bill-only state (the stale RT link / cadence
  // could not be edited while hidden) and forces the required mode,
  // because a bucket is a typed MONTHLY figure.
  syncAllocationKind(event) {
    const form = event.target.closest("form");
    const kind = event.target.value;
    if (!this.#isBillish(kind)) {
      const rt = form.querySelector('[name="plan_allocation[recurring_transaction_id]"]');
      if (rt) rt.value = "";
      const cadence = this.#editableInput(form, "cadence");
      if (cadence) cadence.value = "";
      this.#setAllocationMode(form, "required");
      const value = this.#editableInput(form, "value");
      if (value && value.type !== "hidden") value.value = "";
    }
    this.#applyAllocationVisibility(form);
  }

  #setAllocationMode(form, mode) {
    if (!form) return;
    const input = form.querySelector('[name="plan_allocation[value]"], [name="plan_allocation[value_percent]"]');
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

  // Link-to-detected-bill/debt (round 20 U): picking an RT pulls the bill
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
      (r) => r.type === "recurring_transaction" && r.recurring_transaction_id === rtId,
    );
    if (!rec) {
      this.#applyAllocationVisibility(form);
      return;
    }
    const cents = Number(rec.amount_cents || 0);
    this.#setFieldLocked(form, "name", true, rec.name || "");
    this.#setFieldLocked(form, "value", true, cents > 0 ? (cents / 100).toFixed(2) : "", cents > 0 ? this.#currencyText(form, cents) : "");
    this.#setFieldLocked(form, "cadence", true, rec.cadence || "", rec.cadence ? this.#cadenceText(form, rec.cadence) : "");
    // The linked bill's kind, and it is always a required (monthly) figure.
    const kindEl = form.querySelector('[name="plan_allocation[kind]"]');
    if (kindEl && rec.kind) kindEl.value = rec.kind;
    const mode = form.querySelector('[name="plan_allocation[mode]"]');
    if (mode && mode.value !== "required") {
      mode.value = "required";
      this.#setAllocationMode(form, "required");
    }
    this.#checkAccountRadio(form, rec.source_account_id);
    this.#applyAllocationVisibility(form);
  }

  // ---- Bank dialog ------------------------------------------------------

  // One action for both the enable checkbox and the mode select: unchecked
  // rows disable their mode/value inputs; value inputs are enabled only for
  // the specific and percent modes.
  syncBankRow(event) {
    const row = event.target.closest("[data-bank-row]");
    if (!row) return;
    const checkbox = row.querySelector('input[type="checkbox"]');
    const select = row.querySelector("select");
    const valueInput = row.querySelector('input[type="text"]');
    // Round 20a: the rule select + value live in a wrapper that is hidden
    // until the row is checked (least information shown first).
    const details = row.querySelector("[data-bank-row-details]");
    if (event.target === checkbox) {
      const enabled = checkbox.checked;
      if (details) details.classList.toggle("hidden", !enabled);
      select.disabled = !enabled;
      valueInput.disabled = !(enabled && ["specific", "percent"].includes(select.value));
    }
    if (event.target === select) {
      valueInput.disabled = !["specific", "percent"].includes(select.value);
      valueInput.placeholder = select.value === "percent" ? "0-100" : "0.00";
    }
  }
}
