import { Controller } from "@hotwired/stimulus";

// Round 20 (owner: condense the bank config dialog): the kebab + popups
// (Make a Sub-Account / Configure Auto-Transfer) and the top-left avatar
// (logo popup: Upload Custom / Remove custom / built-in list).
//
// The popups live in the dialog HEADER, outside the main form, so their
// widgets live-sync the form's hidden inputs:
//   - sub-account select  -> account[parent_account_id]
//   - auto-transfer rows  -> the data-auto-transfer-tid hidden inputs
//     (the "0" sentinel stays, so all-unchecked clears server-side)
//   - logo pick           -> account[bank_logo_slug]
// and their Save buttons submit the form via the HTML `form=` attribute
// (one shared save path, in-place, as the rest of the page).
//
// The dialog re-renders fully on every save (#inPlaceSubmit), so all of
// this is DOM-only state: nothing survives a round trip.
export default class extends Controller {
  static targets = [
    "avatar", "avatarImg", "neutral",
    "logoPopup", "fileInput", "removeCustom", "uploadError",
    "kebab", "kebabMenu", "subAccountPopup", "subAccountSelect",
    "autoTransferPopup", "autoTransferBox"
  ];

  static values = {
    // Built-in logo list: [{ slug, label, url }, ...] (data-driven; the
    // built-in set is swapped for favicons in a later round).
    logos: Array,
    slug: String,
    customUrl: String,
    avatarUrl: String,
    uploadUrl: String,
    removeUrl: String
  };

  connect() {
    this._outsideClick = (event) => this.#onOutsideClick(event);
    this._escapeKey = (event) => { if (event.key === "Escape") this.closePopups(); };
    document.addEventListener("mousedown", this._outsideClick, true);
    document.addEventListener("keydown", this._escapeKey);
  }

  disconnect() {
    document.removeEventListener("mousedown", this._outsideClick, true);
    document.removeEventListener("keydown", this._escapeKey);
  }

  // ---- kebab + popups ---------------------------------------------------

  toggleKebab() {
    this.kebabMenuTarget.classList.toggle("hidden");
    this.kebabTarget.setAttribute("aria-expanded", String(!this.kebabMenuTarget.classList.contains("hidden")));
  }

  openSubAccount() {
    this.#onlyPopup(this.subAccountPopupTarget);
  }

  openAutoTransfer() {
    this.#onlyPopup(this.autoTransferPopupTarget);
  }

  openLogo() {
    this.#onlyPopup(this.logoPopupTarget);
  }

  closePopups() {
    for (const target of ["kebabMenu", "subAccountPopup", "autoTransferPopup", "logoPopup"]) {
      this[target + "Target"].classList.add("hidden");
    }
    this.kebabTarget.setAttribute("aria-expanded", "false");
  }

  // Show exactly one popup, hide the rest.
  #onlyPopup(popup) {
    this.closePopups();
    popup.classList.remove("hidden");
    this.kebabTarget.setAttribute("aria-expanded", "false");
  }

  #onOutsideClick(event) {
    const root = this.el;
    if (root.contains(event.target)) return;
    const open = ["kebabMenu", "subAccountPopup", "autoTransferPopup", "logoPopup"]
      .some((target) => !this[target + "Target"].classList.contains("hidden"));
    if (open) this.closePopups();
  }

  // ---- header popups -> form hidden inputs ------------------------------

  // The sub-account popup's select syncs the form's hidden
  // account[parent_account_id]; its Save button (form=) submits the main
  // form. Blank = "Not a sub-account" (un-sub-accounting).
  syncSubAccount() {
    const input = this.#hiddenInput("account[parent_account_id]");
    if (input) input.value = this.subAccountSelectTarget.value;
  }

  // The auto-transfer popup's checkboxes rebuild the form's
  // data-auto-transfer-tid hidden inputs in row order (the "0" sentinel
  // input is untouched, so an all-unchecked save clears the fan-out).
  syncAutoTransfer() {
    const form = this.#form();
    if (!form) return;
    form.querySelectorAll("input[data-auto-transfer-tid]").forEach((input) => input.remove());
    this.autoTransferBoxTarget.querySelectorAll("input[type='checkbox']").forEach((checkbox) => {
      if (!checkbox.checked || checkbox.disabled) return;
      const input = document.createElement("input");
      input.type = "hidden";
      input.name = "account[auto_transfer_target_ids][]";
      input.value = checkbox.dataset.otherId;
      input.dataset.autoTransferTid = "1";
      form.appendChild(input);
    });
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
      this.#fetchJson(this.removeUrlValue, { method: "DELETE" }).then((response) => {
        if (!response.ok) throw new Error("remove failed");
        this.customUrlValue = "";
        this.#setAvatar(logoUrl);
        this.removeCustomTarget.classList.add("hidden");
      }).catch(() => {
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
      .then((response) => response.json().then((data) => ({ ok: response.ok, data })))
      .then(({ ok, data }) => {
        if (!ok) {
          this.#showUploadError(Array.isArray(data.errors) ? data.errors.join(" ") : "Upload failed. Try again.");
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
      .catch(() => this.#showUploadError("Couldn't remove the custom logo. Try again."));
  }

  // ---- helpers ------------------------------------------------------------

  #fetchJson(url, init) {
    const headers = Object.assign({ Accept: "application/json" }, init.headers || {});
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
    const anchor = this.el.querySelector("input[name='account[parent_account_id]']");
    return anchor ? anchor.closest("form") : null;
  }

  #hiddenInput(name) {
    return this.el.querySelector(`input[name='${name}']`);
  }
}
