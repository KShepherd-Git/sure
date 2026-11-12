import { Controller } from "@hotwired/stimulus";

// Round 16 (owner note 3b): the bank config dialog's logo picker. The usable
// logo list (vendored file + label) arrives as a value — no endpoint; the
// search box filters it CLIENT-SIDE, a click writes the slug into the hidden
// account[bank_logo_slug] input (the in-place PATCH flow_account save
// persists it: presence keeps / assigns, blank clears), and the Clear button
// empties it. The dialog re-renders on every save, so the selection is
// always re-seeded server-side — no client state survives a save.
export default class extends Controller {
  static values = { slug: String, logos: Array };
  static targets = ["search", "clear", "current", "list", "empty", "choice"];

  connect() {
    this._noneLabel = this.currentTarget.textContent;
    this._applySelection(this.slugValue);
    this.filter();
  }

  // Client-side filter over label + slug (the list is small — a plain loop).
  filter() {
    const query = this.searchTarget.value.toLowerCase().trim();
    let visible = 0;

    this.choiceTargets.forEach((choice) => {
      const label = choice.dataset.label ?? "";
      const slug = choice.dataset.slug ?? "";
      const match = `${label} ${slug}`.toLowerCase().includes(query);
      choice.style.display = match ? "" : "none";
      if (match) visible += 1;
    });

    this.emptyTarget.classList.toggle("hidden", visible > 0);
  }

  // Click-to-assign: write the slug into the hidden input the form submits.
  pick(event) {
    const slug = event.currentTarget.dataset.slug ?? "";
    this._hiddenInput().value = slug;
    this._applySelection(slug);
    this.clearTarget.classList.remove("invisible");
  }

  // Clear: blank the hidden input (the save persists blank = nil) and reset
  // the selection display.
  clear() {
    this._hiddenInput().value = "";
    this._applySelection("");
    this.clearTarget.classList.add("invisible");
  }

  _hiddenInput() {
    return this.element.querySelector('input[name="account[bank_logo_slug]"]');
  }

  _applySelection(slug) {
    const logo = this.logosValue.find((item) => item.slug === slug);
    this.currentTarget.textContent = logo ? logo.label : this._noneLabel;
    this.choiceTargets.forEach((choice) => {
      choice.classList.toggle("bg-subdued/60", slug !== "" && choice.dataset.slug === slug);
    });
  }
}
