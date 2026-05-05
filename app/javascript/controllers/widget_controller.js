import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { DeskbolicEditor } from "../lib/deskbolic_editor"

export default class extends Controller {
  static targets = ["editorContainer"]
  static values = {
    connectionToken: String,
    url: String,
    avatarUrl: String,
    cableUrl: String
  }

  connect() {
    console.log("[Deskbolic] Widget Stimulus controller connected!")

    // Initialize Lexical editor if container exists
    const editorContainer = this.element.querySelector('.de-container')
    if (editorContainer) {
      let i18n = {}
      try { i18n = JSON.parse(editorContainer.dataset.editorI18n || '{}') } catch(e) {}

      this.deskbolicEditor = new DeskbolicEditor(editorContainer, {
        onSubmit: (text, files) => this._sendMessage(text, files),
        onFileSelect: (files) => console.log('[Deskbolic] Files selected:', files.length),
        csrfToken: this.csrfToken,
        i18n: i18n
      })
    }

    // Auto-scroll to bottom on page load
    this.scrollToBottom()

    if (!this.connectionTokenValue) {
      console.warn("[Deskbolic] No connection token — ActionCable will NOT connect")
      return
    }

    this.unreadCount = 0
    this._reconnectAttempts = 0

    const metaUrl = document.querySelector("meta[name='action-cable-url']")?.content
    const cableUrl = metaUrl 
      ? `${metaUrl}?customer_token=${this.connectionTokenValue}`
      : `/cable?customer_token=${this.connectionTokenValue}`

    console.log('[Deskbolic] Connecting to ActionCable:', cableUrl.substring(0, 50) + '...')
    this.consumer = createConsumer(cableUrl)
    this.channel = this.consumer.subscriptions.create(
      {
        channel: "WebWidgetChannel",
        connection_token: this.connectionTokenValue
      },
      {
        connected: () => this.onConnected(),
        disconnected: () => this.onDisconnected(),
        rejected: () => this.onRejected(),
        received: (data) => this.handleReceived(data)
      }
    )
  }

  disconnect() {
    if (this.deskbolicEditor) this.deskbolicEditor.destroy()
    if (this.channel) this.channel.unsubscribe()
    if (this.consumer) this.consumer.disconnect()
  }

  // --- Message sending (called by DeskbolicEditor onSubmit) ---
  _sendMessage(text, files = []) {
    if (!text && files.length === 0) return

    const formData = new FormData()
    if (text) formData.append("content", text)
    files.forEach((file, i) => formData.append(`attachments[${i}]`, file))

    fetch(this.urlValue, {
      method: "POST",
      headers: { "X-CSRF-Token": this.csrfToken },
      body: formData
    })
    .then(response => {
      if (!response.ok) {
        console.error("[Deskbolic] Message send failed:", response.status)
      }
    })
    .catch(error => {
      console.error("[Deskbolic] Network error:", error)
    })

    // Show outgoing message immediately
    if (text) this.appendOutgoingMessage(text)
    // Show image previews for file attachments
    files.forEach(file => {
      if (file.type.startsWith('image/')) {
        this.appendOutgoingImage(file)
      } else {
        this.appendOutgoingMessage(`📎 ${file.name}`)
      }
    })
  }

  search(event) {
    const query = event.target.value
    if (query.length > 0 && query.length < 3) return

    clearTimeout(this._searchTimeout)
    this._searchTimeout = setTimeout(() => {
      const url = new URL(event.target.dataset.url, window.location.origin)
      url.searchParams.set("q", query)

      fetch(url, {
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "X-CSRF-Token": this.csrfToken
        }
      })
      .then(response => response.text())
      .then(html => {
        if (typeof Turbo !== "undefined") {
          Turbo.renderStreamMessage(html)
        }
      })
    }, 300)
  }

  // --- WebSocket lifecycle ---

  onConnected() {
    this._reconnectAttempts = 0
    console.log("[Deskbolic] WebSocket connected")
  }

  onDisconnected() {
    this._reconnectAttempts++
    console.log("[Deskbolic] WebSocket disconnected, attempt:", this._reconnectAttempts)
  }

  onRejected() {
    console.error("[Deskbolic] WebSocket connection rejected. Invalid token.")
  }

  // --- Message handling ---

  handleReceived(data) {
    console.log("[Deskbolic] Received WebSocket data:", data)

    if (data.event === "typing") {
      this.showTypingIndicator(data.status)
      return
    }

    if (data.event === "message.created") {
      let message = data.object
      if (typeof message === "string") {
        try { message = JSON.parse(message) } catch(e) { return }
      }

      // Only render agent messages (outgoing = not incoming)
      if (message && !message.incoming && message.content) {
        const sender = message.sender || {}
        this.appendIncomingMessage(message.content, sender.avatar_url, sender.display_name || sender.name)

        this.unreadCount++
        this.notifyParent("deskbolic:unread", { count: this.unreadCount })
      }
    }
  }

  appendIncomingMessage(content, agentAvatarUrl, agentName) {
    const list = document.getElementById("messages-list")
    if (!list) return

    const messageEl = document.createElement("div")
    messageEl.classList.add("agent-msg")
    const avatarSrc = agentAvatarUrl || this.avatarUrlValue || '/assets/human.png'
    messageEl.innerHTML = `<img src="${avatarSrc}" class="person-img" alt="${this.escapeHtml(agentName || 'Agent')}" title="${this.escapeHtml(agentName || 'Agent')}"><div class="agent-reply">${this.escapeHtml(content)}</div>`
    list.appendChild(messageEl)
    this.scrollToBottom()
  }

  appendOutgoingMessage(content) {
    const list = document.getElementById("messages-list")
    if (!list) return

    const messageEl = document.createElement("div")
    messageEl.classList.add("client-reply")
    messageEl.textContent = content
    list.appendChild(messageEl)
    this.scrollToBottom()
  }

  appendOutgoingImage(file) {
    const list = document.getElementById("messages-list")
    if (!list) return

    const messageEl = document.createElement("div")
    messageEl.classList.add("client-reply")
    const img = document.createElement("img")
    img.src = URL.createObjectURL(file)
    img.classList.add("attachment-image")
    img.onload = () => this.scrollToBottom()
    messageEl.appendChild(img)
    list.appendChild(messageEl)
    this.scrollToBottom()
  }

  scrollToBottom() {
    requestAnimationFrame(() => {
      const list = document.getElementById("messages-list")
      if (list) list.scrollTop = list.scrollHeight
    })
  }

  showTypingIndicator(status) {
    let indicator = document.getElementById("typing-indicator")
    if (status === "start") {
      if (!indicator) {
        indicator = document.createElement("div")
        indicator.id = "typing-indicator"
        indicator.classList.add("typing-indicator")
        indicator.innerHTML = '<span></span><span></span><span></span>'
        const list = document.getElementById("messages-list")
        if (list) list.appendChild(indicator)
      }
    } else if (indicator) {
      indicator.remove()
    }
  }

  // --- Communication with parent frame ---
  notifyParent(type, data) {
    if (window.parent !== window) {
      window.parent.postMessage(Object.assign({ type: type }, data), "*")
    }
  }

  // --- Utilities ---
  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  get csrfToken() {
    const meta = document.querySelector("[name='csrf-token']")
    return meta ? meta.content : ""
  }
}
