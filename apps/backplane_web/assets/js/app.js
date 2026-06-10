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

const themeColors = {
  moonlight: "#d6d6d6",
  sunshine: "#d1a644"
}

function applyTheme(theme) {
  if (theme && theme !== "default") {
    document.documentElement.setAttribute("data-theme", theme)
  } else {
    document.documentElement.removeAttribute("data-theme")
  }

  const meta = document.querySelector('meta[name="theme-color"]')
  if (meta) {
    const resolvedTheme = theme === "default" ? "moonlight" : theme
    const color = themeColors[resolvedTheme] || "#d6d6d6"
    meta.setAttribute("content", color)
  }
}

function initThemeSwitchers(root = document) {
  root.querySelectorAll(".theme-controller-dropdown").forEach((switcher) => {
    if (switcher.dataset.themeSwitcherBound === "true") return

    switcher.dataset.themeSwitcherBound = "true"

    let theme = switcher.dataset.theme || localStorage.getItem("theme") || "default"
    applyTheme(theme)

    switcher.querySelectorAll(".theme-controller-item").forEach((input) => {
      input.checked = theme === input.value

      input.addEventListener("change", (event) => {
        theme = event.target.value
        applyTheme(theme)
        localStorage.setItem("theme", theme)
        switcher.removeAttribute("open")
      })
    })
  })
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => initThemeSwitchers())
} else {
  initThemeSwitchers()
}

window.addEventListener("phx:page-loading-stop", () => initThemeSwitchers())

window.addEventListener("phx:open_external_oauth", (e) => {
  window.open(e.detail.url, "_blank");
})

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: DuskmoonHooks
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
