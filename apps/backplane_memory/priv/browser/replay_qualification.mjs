import {spawn} from "node:child_process"
import {existsSync, mkdtempSync, rmSync, writeFileSync} from "node:fs"
import {tmpdir} from "node:os"
import {join} from "node:path"

const [url, reportPath, debuggingPort, requestedBrowser] = process.argv.slice(2)
const startedAt = new Date().toISOString()
const profile = mkdtempSync(join(tmpdir(), "backplane-replay-browser-"))
let chrome

function browserExecutable() {
  const candidates = [
    requestedBrowser,
    process.env.CHROME_BIN,
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/run/current-system/sw/bin/google-chrome",
    "/run/current-system/sw/bin/chromium",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser"
  ].filter(Boolean)

  const executable = candidates.find(existsSync)
  if (!executable) throw new Error("Chrome/Chromium not found; pass --browser or set CHROME_BIN")
  return executable
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function eventually(operation, description, timeout = 15_000) {
  const deadline = Date.now() + timeout
  let last

  while (Date.now() < deadline) {
    try {
      const value = await operation()
      if (value) return value
    } catch (error) {
      last = error
    }
    await delay(100)
  }

  throw new Error(`Timed out waiting for ${description}${last ? `: ${last.message}` : ""}`)
}

async function debuggerSocket() {
  const version = await eventually(async () => {
    const response = await fetch(`http://127.0.0.1:${debuggingPort}/json/version`)
    return response.ok ? response.json() : null
  }, "Chrome debugger")

  const response = await fetch(
    `http://127.0.0.1:${debuggingPort}/json/new?${encodeURIComponent(url)}`,
    {method: "PUT"}
  )
  if (!response.ok) throw new Error(`Cannot create browser target: HTTP ${response.status}`)
  return (await response.json()).webSocketDebuggerUrl || version.webSocketDebuggerUrl
}

class Cdp {
  constructor(socket) {
    this.socket = socket
    this.nextId = 1
    this.pending = new Map()
    socket.onmessage = ({data}) => {
      const message = JSON.parse(data)
      if (!message.id) return
      const pending = this.pending.get(message.id)
      if (!pending) return
      this.pending.delete(message.id)
      message.error ? pending.reject(new Error(message.error.message)) : pending.resolve(message.result)
    }
  }

  send(method, params = {}) {
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      this.pending.set(id, {resolve, reject})
      this.socket.send(JSON.stringify({id, method, params}))
    })
  }

  async evaluate(expression) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true
    })
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text)
    return result.result.value
  }
}

async function connectCdp(webSocketUrl) {
  const socket = new WebSocket(webSocketUrl)
  await new Promise((resolve, reject) => {
    socket.onopen = resolve
    socket.onerror = () => reject(new Error("CDP websocket connection failed"))
  })
  return new Cdp(socket)
}

async function main() {
  chrome = spawn(browserExecutable(), [
    "--headless=new",
    "--no-sandbox",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    `--remote-debugging-port=${debuggingPort}`,
    `--user-data-dir=${profile}`,
    "about:blank"
  ], {stdio: ["ignore", "ignore", "pipe"]})

  let chromeError = ""
  chrome.stderr.on("data", (data) => { chromeError = (chromeError + data).slice(-4000) })

  const cdp = await connectCdp(await debuggerSocket())
  await cdp.send("Page.enable")
  await cdp.send("Runtime.enable")
  await cdp.send("Network.enable")

  const evaluate = (expression) => cdp.evaluate(expression)
  const waitFor = (expression, description, timeout) =>
    eventually(() => evaluate(expression), description, timeout)
  const click = async (selector) => {
    const point = await evaluate(`(() => {
      const el = document.querySelector(${JSON.stringify(selector)})
      if (!el) return null
      el.scrollIntoView({block: 'center', inline: 'center'})
      const rect = el.getBoundingClientRect()
      return {x: rect.left + rect.width / 2, y: rect.top + rect.height / 2}
    })()`)
    if (!point) throw new Error(`Missing element ${selector}`)
    await cdp.send("Input.dispatchMouseEvent", {type: "mousePressed", x: point.x, y: point.y, button: "left", clickCount: 1})
    await cdp.send("Input.dispatchMouseEvent", {type: "mouseReleased", x: point.x, y: point.y, button: "left", clickCount: 1})
  }

  await waitFor("document.querySelectorAll('[id^=replay-event-]').length >= 121", "121 replay rows")
  await waitFor("document.querySelector('[data-phx-main]')?.classList.contains('phx-connected')", "LiveView join")
  await waitFor("document.querySelector('#replay-event-1')?.getAttribute('aria-current') === 'true'", "initial cursor")

  await click("#replay-next")
  await waitFor("document.querySelector('#replay-event-2')?.getAttribute('aria-current') === 'true'", "Next control")

  await click("#replay-speed-4")
  await waitFor("document.querySelector('#replay-speed-4')?.getAttribute('aria-pressed') === 'true'", "4x speed")

  await evaluate(`(() => {
    const input = document.querySelector('#replay-scrubber')
    input.value = '101'
    input.dispatchEvent(new Event('input', {bubbles: true}))
    input.dispatchEvent(new Event('change', {bubbles: true}))
    input.blur()
    return true
  })()`)
  await waitFor("document.querySelector('#replay-event-101')?.getAttribute('aria-current') === 'true'", "scrubber cursor")

  await cdp.send("Input.dispatchKeyEvent", {type: "keyDown", key: "Home", code: "Home"})
  await cdp.send("Input.dispatchKeyEvent", {type: "keyUp", key: "Home", code: "Home"})
  await waitFor("document.querySelector('#replay-event-1')?.getAttribute('aria-current') === 'true'", "Home keyboard control")

  await click("#replay-play-pause")
  await waitFor("document.querySelector('#replay-event-2')?.getAttribute('aria-current') === 'true'", "playback cursor", 5_000)
  await click("#replay-play-pause")
  await waitFor("document.querySelector('#replay-play-pause')?.getAttribute('aria-pressed') === 'false'", "playback pause")

  await click("#replay-event-101")
  await waitFor("document.querySelector('#replay-event-101')?.getAttribute('aria-current') === 'true'", "pre-disconnect cursor")

  await cdp.send("Network.emulateNetworkConditions", {
    offline: true,
    latency: 0,
    downloadThroughput: 0,
    uploadThroughput: 0,
    connectionType: "none"
  })
  await waitFor("Object.keys(sessionStorage).some(k => k.startsWith('backplane:memory-replay:') && sessionStorage.getItem(k).includes(document.querySelector('#memory-replay').dataset.selectedEventId))", "disconnect hook state", 12_000)

  await cdp.send("Network.emulateNetworkConditions", {
    offline: false,
    latency: 0,
    downloadThroughput: -1,
    uploadThroughput: -1,
    connectionType: "wifi"
  })
  await waitFor("document.querySelector('#replay-event-101')?.getAttribute('aria-current') === 'true' && document.querySelector('[data-phx-main]')?.classList.contains('phx-connected')", "reconnected cursor", 20_000)

  console.log("READY_FOR_PUBSUB")
  await waitFor("document.querySelector('#replay-event-122') !== null", "live PubSub event", 20_000)

  const browserVersion = await cdp.send("Browser.getVersion")
  const report = {
    suite: "memory-v2-replay-browser-qualification",
    passed: true,
    started_at: startedAt,
    completed_at: new Date().toISOString(),
    browser: browserVersion.product,
    seeded_events: 122,
    assertions: {
      paginated_render_over_100: true,
      controls: true,
      cursor: true,
      disconnect_reconnect_state: true,
      live_pubsub_update: true
    },
    content_exposed: false
  }
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`)
  console.log(JSON.stringify(report))
  cdp.socket.close()
}

try {
  await main()
} catch (error) {
  const report = {
    suite: "memory-v2-replay-browser-qualification",
    passed: false,
    started_at: startedAt,
    completed_at: new Date().toISOString(),
    error: error.message,
    content_exposed: false
  }
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`)
  console.error(error.stack)
  process.exitCode = 1
} finally {
  if (chrome && !chrome.killed) chrome.kill("SIGTERM")
  await delay(500)
  rmSync(profile, {recursive: true, force: true, maxRetries: 10, retryDelay: 100})
}
