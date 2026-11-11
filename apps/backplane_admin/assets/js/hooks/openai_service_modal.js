// LiveView owns whether the form exists; the native dialog owns focus and dismissal.
export const OpenAIServiceModal = {
  mounted() {
    this.onClose = () => this.pushEvent("cancel", {})
    this.el.addEventListener("close", this.onClose)
    this.el.showModal()
  },

  destroyed() {
    this.el.removeEventListener("close", this.onClose)
    if (this.el.open) this.el.close()
  }
}
