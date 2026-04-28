import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

export default class extends Controller {
  static targets = ["input"]
  static values = {
    connectionToken: String,
    url: String
  }

  connect() {
    if (!this.connectionTokenValue) return

    this.unreadCount = 0
    this._reconnectAttempts = 0

    this.consumer = createConsumer(`/cable?customer_token=${this.connectionTokenValue}`)
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
    if (this.channel) this.channel.unsubscribe()
    if (this.consumer) this.consumer.disconnect()
  }

  submitMessage(event) {
    if (event.type === "keydown" && !event.shiftKey) {
      event.preventDefault()
    } else if (event.type === "keydown") {
      return
    }

    const textarea = this.inputTarget
    const content = textarea.value.trim()
    if (!content) return

    const formData = new FormData()
    formData.append("content", content)

    fetch(this.urlValue, {
      method: "POST",
      headers: { "X-CSRF-Token": this.csrfToken },
      body: formData
    })
    .then(response => {
      if (!response.ok) {
        console.error("[Deskbolic] Message send failed:", response.status)
        this.showError()
      }
    })
    .catch(error => {
      console.error("[Deskbolic] Network error:", error)
      this.showError()
    })

    this.appendOutgoingMessage(content)
    textarea.value = ""
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
  }

  onDisconnected() {
    // ActionCable handles auto-reconnection, but we track it for UI feedback
    this._reconnectAttempts++
  }

  onRejected() {
    console.error("[Deskbolic] WebSocket connection rejected. Invalid token.")
  }

  // --- Message handling ---

  handleReceived(data) {
    if (data.event === "typing") {
      this.showTypingIndicator(data.status)
      return
    }

    // Ensure the message is actually an outgoing one from an agent, and unwrap the payload object
    if (data.event === "message.created" && data.object && !data.object.incoming) {
      this.appendIncomingMessage(data.object.content)

      // Notify parent frame (embed script) about unread messages
      this.unreadCount++
      this.notifyParent("deskbolic:unread", { count: this.unreadCount })
    }
  }

  appendIncomingMessage(content) {
    const list = document.getElementById("messages-list")
    if (!list) return

    const messageEl = document.createElement("div")
    messageEl.classList.add("agent-msg")
    messageEl.innerHTML = `<img src="/assets/human.png" class="person-img"><div class="agent-reply">${this.escapeHtml(content)}</div>`
    list.appendChild(messageEl)
    list.scrollTop = list.scrollHeight
  }

  appendOutgoingMessage(content) {
    const list = document.getElementById("messages-list")
    if (!list) return

    const messageEl = document.createElement("div")
    messageEl.classList.add("client-reply")
    messageEl.textContent = content
    list.appendChild(messageEl)
    list.scrollTop = list.scrollHeight
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

  showError() {
    // Brief visual feedback that something went wrong
    const input = this.inputTarget
    input.classList.add("error")
    setTimeout(() => input.classList.remove("error"), 2000)
  }

  // --- Communication with parent frame (embed script) ---

  notifyParent(type, data) {
    if (window.parent !== window) {
      window.parent.postMessage(
        Object.assign({ type: type }, data),
        "*"
      )
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
