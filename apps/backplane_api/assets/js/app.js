import "phoenix_html"

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
