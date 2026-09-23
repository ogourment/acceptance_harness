import { LiveSocket } from "/assets/phoenix_live_view.esm.js"
import { Socket } from "/assets/phoenix.mjs"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}})

liveSocket.connect()
window.liveSocket = liveSocket
