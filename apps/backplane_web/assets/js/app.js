import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import * as DuskmoonHooks from "phoenix_duskmoon/hooks"

// Register DuskMoon custom elements
import {registerAll} from "@duskmoon-dev/elements"
import {registerAll as registerAllArt} from "@duskmoon-dev/art-elements"
registerAll()
registerAllArt()

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: DuskmoonHooks
})

liveSocket.connect()

window.liveSocket = liveSocket
