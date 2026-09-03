import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import * as DuskmoonHooks from "../../../../deps/phoenix_duskmoon/assets/js/hooks/index.js"

// Register only the DuskMoon custom elements used by the admin UI.
// Avoid registerAll() from @duskmoon-dev/elements because it imports
// el-code-engine whose CodeMirror sunshine theme has a circular-dependency
// bug that crashes the entire JS bundle before LiveSocket connects.
import {register as registerButton} from "@duskmoon-dev/el-button"
import {register as registerCard} from "@duskmoon-dev/el-card"
import {register as registerBadge} from "@duskmoon-dev/el-badge"
import {register as registerDialog} from "@duskmoon-dev/el-dialog"
import {register as registerAlert} from "@duskmoon-dev/el-alert"
registerButton()
registerCard()
registerBadge()
registerDialog()
registerAlert()

const replayShortcutKeys = new Set(["ArrowLeft", "ArrowRight", "Home", "End", " ", "Spacebar"])

function isEditableReplayTarget(target) {
  if (!(target instanceof Element)) return false

  return Boolean(
    target.closest("input, textarea, select, [contenteditable]:not([contenteditable='false'])")
  )
}

const ReplayKeyboard = {
  mounted() {
    this.onKeydown = (event) => {
      if (
        event.defaultPrevented ||
        !replayShortcutKeys.has(event.key) ||
        isEditableReplayTarget(event.target)
      ) {
        return
      }

      if (event.key === " " || event.key === "Spacebar") event.preventDefault()
      this.pushEvent("keyboard", {key: event.key})
    }

    window.addEventListener("keydown", this.onKeydown)
    this.restoreReplayState()
  },

  updated() {
    if (!this.replayStateBeforeDisconnect) this.storeReplayState()
  },

  disconnected() {
    this.replayStateBeforeDisconnect = this.currentReplayState()
    this.storeReplayState(this.replayStateBeforeDisconnect)
  },

  reconnected() {
    this.restoreReplayState(this.replayStateBeforeDisconnect)
    this.replayStateBeforeDisconnect = null
  },

  destroyed() {
    this.storeReplayState()
    window.removeEventListener("keydown", this.onKeydown)
  },

  restoreReplayState(savedState = null) {
    if (!this.el.dataset.stateKey) return

    const storageKey = `backplane:memory-replay:${this.el.dataset.stateKey}`

    try {
      const state = savedState || JSON.parse(sessionStorage.getItem(storageKey))
      if (state) this.pushEvent("restore_view", state)
    } catch (_error) {
      sessionStorage.removeItem(storageKey)
    }
  },

  currentReplayState() {
    if (!this.el.dataset.selectedEventId) return null

    return {
      selected_event_id: this.el.dataset.selectedEventId,
      active_kinds: JSON.parse(this.el.dataset.activeKinds),
      speed: this.el.dataset.speed
    }
  },

  storeReplayState(state = this.currentReplayState()) {
    if (!this.el.dataset.stateKey || !state) return

    sessionStorage.setItem(
      `backplane:memory-replay:${this.el.dataset.stateKey}`,
      JSON.stringify(state)
    )
  }
}

class LocalTime extends HTMLElement {
  static get observedAttributes() {
    return ["datetime", "format"]
  }

  connectedCallback() {
    this.render()
  }

  attributeChangedCallback() {
    this.render()
  }

  render() {
    const datetime = this.getAttribute("datetime")
    if (!datetime) {
      this.textContent = ""
      return
    }

    try {
      const date = new Date(datetime)
      if (isNaN(date.getTime())) {
        this.textContent = datetime
        return
      }

      const format = this.getAttribute("format")
      if (format === "time") {
        this.textContent = date.toLocaleTimeString(undefined, {
          hour: "2-digit",
          minute: "2-digit",
          second: "2-digit",
          hour12: false
        })
      } else if (format === "short") {
        this.textContent = date.toLocaleString(undefined, {
          month: "2-digit",
          day: "2-digit",
          hour: "2-digit",
          minute: "2-digit",
          hour12: false
        })
      } else {
        const pad = (n) => String(n).padStart(2, '0')
        const year = date.getFullYear()
        const month = pad(date.getMonth() + 1)
        const day = pad(date.getDate())
        const hours = pad(date.getHours())
        const minutes = pad(date.getMinutes())
        const seconds = pad(date.getSeconds())
        this.textContent = `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`
      }
    } catch (e) {
      this.textContent = datetime
    }
  }
}

if (!customElements.get("local-time")) {
  customElements.define("local-time", LocalTime)
}

const themeColorMeta = document.querySelector('meta[name="theme-color"]')
const themeColors = {
  moonlight: "#d6d6d6",
  sunshine: "#d1a644"
}

function syncThemeColor() {
  const color = themeColors[document.documentElement.dataset.theme]
  if (themeColorMeta && color) themeColorMeta.setAttribute("content", color)
}

// DuskMoon owns data-theme; mirror it only to the browser chrome color.
const themeColorObserver = new MutationObserver(syncThemeColor)
themeColorObserver.observe(document.documentElement, {
  attributes: true,
  attributeFilter: ["data-theme"]
})
syncThemeColor()

window.addEventListener("phx:open_external_oauth", (e) => {
  window.open(e.detail.url, "_blank");
})

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...DuskmoonHooks, ReplayKeyboard}
})

// Close dialogs when buttons inside dialog forms are clicked
document.addEventListener("click", (event) => {
  const btn = event.target.closest("el-dm-button")
  if (btn) {
    const dialogForm = btn.closest("form[method='dialog']")
    if (dialogForm) {
      const dialog = dialogForm.closest("el-dm-dialog")
      if (dialog && typeof dialog.close === "function") {
        dialog.close()
      }
    }
  }
})

liveSocket.connect()

window.liveSocket = liveSocket

window.addEventListener("phx:copy-to-clipboard", (e) => {
  if (e.detail?.text) navigator.clipboard.writeText(e.detail.text)
})

window.addEventListener("phx:download", (e) => {
  const {content, filename, content_type} = e.detail
  const blob = new Blob([content], {type: content_type || "application/octet-stream"})
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = filename || "download"
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
})
