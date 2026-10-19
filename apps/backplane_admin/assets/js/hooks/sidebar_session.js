import {DuskmoonLeftMenu} from "phoenix_duskmoon/hooks"

// TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#204
// WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#204
// Bridge session state until the menu exposes public collapse change/restore events.
export const SessionLeftMenu = {
  ...DuskmoonLeftMenu,

  mounted() {
    DuskmoonLeftMenu.mounted.call(this)

    this.restoreSessionState = ({detail: {collapsed}}) => {
      if ((this.el.dataset.collapsed === "true") === collapsed) return

      this.restoringSessionState = true
      this.el.querySelector("[data-left-menu-toggle]").click()
      this.restoringSessionState = false
    }
    this.notifySessionState = (event) => {
      const toggle = event.target.closest?.("[data-left-menu-toggle]")
      if (!toggle || !this.el.contains(toggle) || this.restoringSessionState) return

      this.el.dispatchEvent(new CustomEvent("backplane:sidebar-changed", {
        bubbles: true,
        detail: {collapsed: this.el.dataset.collapsed === "true"}
      }))
    }

    this.el.addEventListener("backplane:sidebar-restore", this.restoreSessionState)
    this.el.addEventListener("click", this.notifySessionState)
    this.el.dispatchEvent(new CustomEvent("backplane:sidebar-ready", {bubbles: true}))
  },

  destroyed() {
    this.el.removeEventListener("backplane:sidebar-restore", this.restoreSessionState)
    this.el.removeEventListener("click", this.notifySessionState)
    DuskmoonLeftMenu.destroyed.call(this)
  }
}

export const AdminSidebarSession = {
  mounted() {
    this.updateId = 0
    this.pendingCollapsed = null
    this.onSidebarReady = () => this.restoreState()
    this.onSidebarChanged = ({detail: {collapsed}}) => {
      const updateId = ++this.updateId
      this.pendingCollapsed = collapsed
      this.pushEvent("sidebar_collapsed", {collapsed}).then(
        () => {
          if (this.updateId === updateId) this.pendingCollapsed = null
        },
        () => {
          if (this.updateId !== updateId) return

          this.pendingCollapsed = null
          this.restoreState()
        }
      )
    }
    this.el.addEventListener("backplane:sidebar-ready", this.onSidebarReady)
    this.el.addEventListener("backplane:sidebar-changed", this.onSidebarChanged)
    this.restoreState()
  },

  updated() {
    this.restoreState()
  },

  reconnected() {
    const updateId = this.updateId
    this.pushEvent("sidebar_state", {}, ({collapsed}) => {
      if (this.updateId !== updateId || this.pendingCollapsed !== null) return

      this.pendingCollapsed = null
      this.restoreState(collapsed)
    })
  },

  restoreState(collapsed = this.pendingCollapsed ?? this.el.dataset.sidebarCollapsed === "true") {
    this.el.querySelector("#admin-sidebar")?.dispatchEvent(new CustomEvent(
      "backplane:sidebar-restore", {detail: {collapsed}}
    ))
  },

  destroyed() {
    this.el.removeEventListener("backplane:sidebar-ready", this.onSidebarReady)
    this.el.removeEventListener("backplane:sidebar-changed", this.onSidebarChanged)
  }
}
