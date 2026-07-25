import { Controller } from "@hotwired/stimulus"

// Copies the snippet in one click, because the alternative is a buyer
// hand-selecting a script tag and losing half of it.
export default class extends Controller {
  static targets = ["source", "button"]

  static values = { confirmedFor: { type: Number, default: 1500 } }

  copy() {
    navigator.clipboard
      .writeText(this.sourceTarget.textContent.trim())
      .then(() => this.confirm())
      .catch(() => this.report("Press ⌘C to copy"))
  }

  confirm() {
    this.report("Copied ✓")
  }

  report(message) {
    if (!this.hasButtonTarget) return

    const original = this.originalLabel || this.buttonTarget.textContent
    this.originalLabel = original
    this.buttonTarget.textContent = message

    clearTimeout(this.resetTimer)
    this.resetTimer = setTimeout(() => {
      this.buttonTarget.textContent = original
    }, this.confirmedForValue)
  }

  disconnect() {
    clearTimeout(this.resetTimer)
  }
}
