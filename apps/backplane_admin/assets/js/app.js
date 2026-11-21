import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import * as DuskmoonHooks from "duskmoon_phoenix/hooks"
import {AdminSidebarSession, SessionLeftMenu} from "./hooks/sidebar_session.js"
import {OpenAIServiceModal} from "./hooks/openai_service_modal.js"

import "@duskmoon-dev/el-alert/register"

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
    return ["datetime", "format", "data-datetime", "data-format"]
  }

  connectedCallback() {
    this.render()
  }

  attributeChangedCallback() {
    this.render()
  }

  render() {
    // LiveView updates data attributes on ignored nodes; native attributes and
    // localized text remain owned by this element.
    const datetime = this.dataset.datetime ?? this.getAttribute("datetime")
    if (datetime && this.getAttribute("datetime") !== datetime) {
      this.setAttribute("datetime", datetime)
    }
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

      const format = this.dataset.format ?? this.getAttribute("format")
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

const darkQuery = window.matchMedia("(prefers-color-scheme: dark)")

function resolveAutoTheme() {
  return darkQuery.matches ? "moonlight" : "sunshine"
}

function applyAdminTheme(theme) {
  const resolved = (!theme || theme === "default") ? resolveAutoTheme() : theme
  document.documentElement.setAttribute("data-theme", resolved)
}

// Restore theme from localStorage on page load
applyAdminTheme(localStorage.getItem("theme") || "default")
darkQuery.addEventListener("change", () => {
  const current = localStorage.getItem("theme") || "default"
  if (current === "default") applyAdminTheme("default")
})

const ThemeSegmentControl = {
  mounted() {
    let theme = localStorage.getItem("theme") || "default"
    applyAdminTheme(theme)

    const buttons = this.el.querySelectorAll("button[data-theme-value]")

    const updateActive = (activeTheme) => {
      buttons.forEach(btn => {
        const isActive = btn.dataset.themeValue === activeTheme
        btn.classList.toggle("segment-item-active", isActive)
        btn.setAttribute("aria-checked", isActive ? "true" : "false")
        btn.setAttribute("aria-pressed", isActive ? "true" : "false")
      })
    }

    updateActive(theme)

    this._mediaListener = () => {
      const current = localStorage.getItem("theme") || "default"
      if (current === "default") applyAdminTheme("default")
    }
    darkQuery.addEventListener("change", this._mediaListener)

    this._buttonListeners = []
    buttons.forEach(btn => {
      const listener = (event) => {
        event.preventDefault()
        theme = btn.dataset.themeValue
        requestAnimationFrame(() => {
          applyAdminTheme(theme)
          localStorage.setItem("theme", theme)
          updateActive(theme)
          this.pushEvent("theme_changed", {theme: theme})
        })
      }
      btn.addEventListener("click", listener)
      this._buttonListeners.push({element: btn, listener})
    })
  },

  updated() {
    const currentTheme = localStorage.getItem("theme") || "default"
    const buttons = this.el.querySelectorAll("button[data-theme-value]")
    buttons.forEach(btn => {
      const isActive = btn.dataset.themeValue === currentTheme
      btn.classList.toggle("segment-item-active", isActive)
      btn.setAttribute("aria-checked", isActive ? "true" : "false")
      btn.setAttribute("aria-pressed", isActive ? "true" : "false")
    })
  },

  destroyed() {
    if (this._buttonListeners) {
      this._buttonListeners.forEach(({element, listener}) => {
        element.removeEventListener("click", listener)
      })
      this._buttonListeners = null
    }
    if (this._mediaListener) {
      darkQuery.removeEventListener("change", this._mediaListener)
      this._mediaListener = null
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...DuskmoonHooks, DuskmoonLeftMenu: SessionLeftMenu, AdminSidebarSession, ReplayKeyboard, ThemeSegmentControl, OpenAIServiceModal}
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
