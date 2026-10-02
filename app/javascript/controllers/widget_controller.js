import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { DeskbolicEditor } from "../lib/deskbolic_editor"
import { PLAY_ICON, VOLUME_ICON } from "../lib/icons"

const cableConnections = new Map()
const CABLE_DISCONNECT_DELAY = 30000

function cableConnectionKey(cableUrl, connectionToken) {
  return `${cableUrl}|${connectionToken}`
}

export default class extends Controller {
  static targets = ["editorContainer"]
  static values = {
    connectionToken: String,
    conversationId: String,
    accountId: String,
    widgetId: String,
    customerSessionToken: String,
    conversationData: String,
    url: String,
    cableUrl: String,
    unreadCount: { type: Number, default: 0 }
  }

  connect() {
    this.persistResumeToken()

    // Initialize Lexical editor if container exists
    const editorContainer = this.element.querySelector('.de-container')
    if (editorContainer) {
      let i18n = {}
      try { i18n = JSON.parse(editorContainer.dataset.editorI18n || '{}') } catch(e) {}

      this.deskbolicEditor = new DeskbolicEditor(editorContainer, {
        onSubmit: (text, files) => this._sendMessage(text, files),
        csrfToken: this.csrfToken,
        i18n: i18n
      })
    }

    // Auto-scroll to bottom on page load
    this.scrollToBottom()

    // Setup click-to-expand on chat images
    this.setupImagePreview()

    if (!this.connectionTokenValue) return

    this._visibilityHandler = () => {
      if (typeof document !== "undefined" && !document.hidden) {
        this.markCurrentConversationAsRead()
        this.sendActivityPing()
        this.unreadCount = 0
        this.notifyParent("deskbolic:unread", { count: 0 })
      }
    }
    document.addEventListener("visibilitychange", this._visibilityHandler)

    this.unreadCount = this.unreadCountValue
    this.notifyParent("deskbolic:unread", { count: this.unreadCount })

    this._reconnectAttempts = 0

    const metaUrl = document.querySelector("meta[name='action-cable-url']")?.content
    const cableUrl = metaUrl 
      ? `${metaUrl}?customer_token=${this.connectionTokenValue}`
      : `/cable?customer_token=${this.connectionTokenValue}`

    this.subscribeToCable(cableUrl)
  }

  disconnect() {
    if (this._visibilityHandler) {
      document.removeEventListener("visibilitychange", this._visibilityHandler)
      this._visibilityHandler = null
    }
    this.stopActivityHeartbeat()
    if (this.deskbolicEditor) this.deskbolicEditor.destroy()
    if (this._imagePreviewHandler) {
      const list = document.getElementById("messages-list")
      if (list) list.removeEventListener("click", this._imagePreviewHandler)
      this._imagePreviewHandler = null
    }
    this.releaseCable()
  }

  // --- Message sending (called by DeskbolicEditor onSubmit) ---
  async _sendMessage(text, files = []) {
    if (!text && files.length === 0) return

    const formData = new FormData()
    if (text) formData.append("content", text)
    files.forEach((file, i) => formData.append(`attachments[${i}]`, file))
    if (this.hasConversationDataValue && this.conversationDataValue) {
      formData.append("conversation_data", this.conversationDataValue)
    }

    const headers = {
      "Accept": "text/vnd.turbo-stream.html",
      "X-CSRF-Token": this.csrfToken
    }
    if (this.customerSessionTokenValue) {
      headers["X-Customer-Session-Token"] = this.customerSessionTokenValue
    }

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: headers,
        body: formData
      })

      if (!response.ok) {
        throw new Error(`Message send failed: ${response.status}`)
      }

      await this.renderTurboStreamResponse(response)
      this.scrollToBottom()
      this.notifyParent("deskbolic:sound:sent")
      this.conversationDataValue = ""
    } catch (error) {
      console.error("[Deskbolic] Network error:", error)
      this.showInlineError("Message failed to send. Please try again.")
      throw error
    }
  }

  search(event) {
    const query = event.target.value

    clearTimeout(this._searchTimeout)
    this._searchTimeout = setTimeout(() => {
      this.performSearch(query, event.target.dataset.url)
    }, 300)
  }

  submitSearch(event) {
    event.preventDefault()

    const input = event.target.querySelector(".widget-search-input")
    if (!input) return

    clearTimeout(this._searchTimeout)
    this.performSearch(input.value, input.dataset.url)
  }

  performSearch(query, searchUrl) {
    const normalizedQuery = query.trim()
    this.setSearchActive(normalizedQuery.length > 0)
    this.setSearching(true)
    const url = new URL(searchUrl, window.location.origin)
    url.searchParams.set("q", normalizedQuery)

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
    .catch(error => {
      console.error("[Deskbolic] Search failed:", error)
    })
    .finally(() => this.setSearching(false))
  }

  // --- WebSocket lifecycle ---

  subscribeToCable(cableUrl) {
    this.releaseCable()

    const key = cableConnectionKey(cableUrl, this.connectionTokenValue)
    let connection = cableConnections.get(key)

    if (!connection) {
      const handlers = new Set()
      const consumer = createConsumer(cableUrl)
      const channel = consumer.subscriptions.create(
        {
          channel: "WebWidgetChannel",
          connection_token: this.connectionTokenValue
        },
        {
          connected: () => handlers.forEach((controller) => controller.onConnected()),
          disconnected: () => handlers.forEach((controller) => controller.onDisconnected()),
          rejected: () => handlers.forEach((controller) => controller.onRejected()),
          received: (data) => handlers.forEach((controller) => controller.handleReceived(data))
        }
      )

      connection = { key, consumer, channel, handlers, disconnectTimer: null }
      cableConnections.set(key, connection)
    }

    clearTimeout(connection.disconnectTimer)
    connection.disconnectTimer = null
    connection.handlers.add(this)
    this.cableConnection = connection
  }

  releaseCable() {
    this.stopActivityHeartbeat()
    const connection = this.cableConnection
    if (!connection) return

    connection.handlers.delete(this)
    this.cableConnection = null

    if (connection.handlers.size > 0) return

    connection.disconnectTimer = setTimeout(() => {
      if (connection.handlers.size > 0) return

      connection.channel.unsubscribe()
      connection.consumer.disconnect()
      cableConnections.delete(connection.key)
    }, CABLE_DISCONNECT_DELAY)
  }

  onConnected() {
    this._reconnectAttempts = 0
    this.startActivityHeartbeat()
    this.sendActivityPing()
    this.markCurrentConversationAsRead()
  }

  onDisconnected() {
    this._reconnectAttempts++
    this.stopActivityHeartbeat()
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

    if (data.event === "message.created") {
      const message = this.parseCableObject(data.object)

      if (message && message.visibility === 'personal') return

      if (message) {
        const messageId = message.id || message.message_id || message.uuid
        if (messageId && this.messageRenderedCorrectly(messageId)) return

        if (!this.renderCableMessage(message, messageId)) {
          console.error("[Deskbolic] Message payload was not renderable:", message)
          return
        }

        if (!this.isIncomingMessage(message)) {
          const isHidden = typeof document !== "undefined" && (document.hidden || (typeof document.hasFocus === "function" && !document.hasFocus()))
          if (isHidden) {
            this.unreadCount++
            this.notifyParent("deskbolic:unread", { count: this.unreadCount })
          } else {
            this.markCurrentConversationAsRead(messageId)
            this.sendActivityPing()
            this.unreadCount = 0
            this.notifyParent("deskbolic:unread", { count: 0 })
          }
          this.notifyParent("deskbolic:sound:play")
        }
      }
    }
  }

  markCurrentConversationAsRead(messageId = null) {
    const channel = this.cableConnection?.channel
    if (!channel) return

    const payload = {}
    if (messageId) payload.message_id = messageId
    if (this.hasConversationIdValue && this.conversationIdValue) {
      payload.conversation_id = this.conversationIdValue
    }

    try {
      channel.perform("read", payload)
    } catch (e) {}
  }

  sendActivityPing() {
    const channel = this.cableConnection?.channel
    if (!channel) return

    try {
      channel.perform("activity")
    } catch (e) {}
  }

  startActivityHeartbeat() {
    this.stopActivityHeartbeat()
    this._activityInterval = setInterval(() => {
      this.sendActivityPing()
    }, 20000)
  }

  stopActivityHeartbeat() {
    if (this._activityInterval) {
      clearInterval(this._activityInterval)
      this._activityInterval = null
    }
  }

  async renderTurboStreamResponse(response) {
    const html = await response.text()
    if (!html || typeof Turbo === "undefined") return

    Turbo.renderStreamMessage(html)
  }

  parseCableObject(object) {
    if (!object) return null
    if (typeof object !== "string") return object

    try {
      return JSON.parse(object)
    } catch(e) {
      console.error("[Deskbolic] Failed to parse cable message:", e)
      return null
    }
  }

  renderCableMessage(message, messageId) {
    const list = document.getElementById("messages-list")
    const content = message.content || ""
    const attachments = Array.isArray(message.attachments) ? message.attachments : []
    if (!list || (!content && attachments.length === 0)) return false

    const existingMessage = messageId ? document.getElementById(`message_${messageId}`) : null
    if (existingMessage && !this.messageRenderedCorrectly(messageId)) existingMessage.remove()

    const messageEl = this.buildMessageElement(message, messageId, content, attachments.length > 0)
    if (!messageEl) return false

    const bubbleEl = messageEl.querySelector(".agent-reply") || messageEl
    this.appendCableAttachments(bubbleEl, attachments)
    this.appendCableContent(bubbleEl, message, content)
    this.appendCableMessageTime(messageEl, message)
    list.appendChild(messageEl)
    this.scrollToBottom()
    return true
  }

  isIncomingMessage(message) {
    return message.incoming === true || message.incoming === "true"
  }

  buildMessageElement(message, messageId, content, hasAttachments) {
    const messageEl = document.createElement("div")
    if (messageId) messageEl.id = `message_${messageId}`

    if (this.isIncomingMessage(message)) {
      messageEl.classList.add("client-reply")
      if (!hasAttachments && this.isSingleEmojiMessage(content)) messageEl.classList.add("single-emoji-message")
      return messageEl
    }

    messageEl.classList.add("agent-msg")
    const replyEl = document.createElement("div")
    replyEl.classList.add("agent-reply")

    if (!hasAttachments && this.isSingleEmojiMessage(this.sanitizeMessageContent(content))) replyEl.classList.add("single-emoji-message")

    messageEl.appendChild(replyEl)
    return messageEl
  }

  appendCableContent(container, message, content) {
    if (!container || !content) return

    const contentEl = document.createElement("div")
    contentEl.classList.add("msg-content")

    if (this.isIncomingMessage(message)) {
      contentEl.textContent = content
      container.appendChild(contentEl)
      return
    }

    const sanitizedContent = this.sanitizeMessageContent(content)
    if (this.isSingleEmojiMessage(sanitizedContent)) {
      contentEl.textContent = this.stripHtml(content).trim()
    } else {
      contentEl.innerHTML = sanitizedContent
    }

    container.appendChild(contentEl)
  }

  sanitizeMessageContent(content) {
    const template = document.createElement("template")
    template.innerHTML = content

    template.content.querySelectorAll("script, iframe, object, embed").forEach((node) => node.remove())
    template.content.querySelectorAll("*").forEach((node) => {
      Array.from(node.attributes).forEach((attribute) => {
        const name = attribute.name.toLowerCase()
        const value = attribute.value.trim().toLowerCase()
        if (name.startsWith("on") || (["href", "src"].includes(name) && value.startsWith("javascript:"))) {
          node.removeAttribute(attribute.name)
        }
      })
    })

    return template.innerHTML
  }

  stripHtml(content) {
    const div = document.createElement("div")
    div.innerHTML = content || ""
    return div.textContent || div.innerText || ""
  }

  appendCableAttachments(container, attachments) {
    if (!container || !attachments.length) return

    const attachmentsEl = document.createElement("div")
    attachmentsEl.classList.add("msg-attachments")

    attachments.forEach((attachment) => {
      const attachmentEl = this.buildCableAttachmentElement(attachment)
      if (attachmentEl) attachmentsEl.appendChild(attachmentEl)
    })

    if (attachmentsEl.childElementCount) container.appendChild(attachmentsEl)
  }

  buildCableAttachmentElement(attachment) {
    const url = attachment.url || attachment.file_url || attachment.download_url || attachment.direct_download_url
    if (!url) return null

    const type = (attachment.attachment_type || attachment.type || "").toLowerCase()

    if (type === "audio") {
      return this.buildAudioAttachment(url)
    }

    if (type === "image") {
      return this.buildImageAttachment(url, attachment.filename)
    }

    return this.buildFileAttachment(url, attachment.filename)
  }

  buildAudioAttachment(url) {
    const wrapper = document.createElement("div")
    wrapper.classList.add("msg-attachment-audio")
    wrapper.dataset.controller = "audio-player"

    const audio = document.createElement("audio")
    audio.dataset.audioPlayerTarget = "audio"
    audio.preload = "metadata"
    audio.src = url

    const controls = document.createElement("div")
    controls.classList.add("audio-player-controls")

    const playButton = document.createElement("button")
    playButton.type = "button"
    playButton.classList.add("audio-btn")
    playButton.dataset.action = "audio-player#toggle"
    playButton.dataset.audioPlayerTarget = "playButton"

    const playIcon = document.createElement("span")
    playIcon.classList.add("audio-icon-wrap")
    playIcon.dataset.audioPlayerTarget = "playIcon"
    playIcon.innerHTML = PLAY_ICON
    playButton.appendChild(playIcon)

    const waveform = document.createElement("div")
    waveform.classList.add("audio-waveform")
    waveform.dataset.audioPlayerTarget = "waveform"

    const muteButton = document.createElement("button")
    muteButton.type = "button"
    muteButton.classList.add("audio-btn", "audio-mute-btn")
    muteButton.dataset.action = "audio-player#toggleMute"
    muteButton.dataset.audioPlayerTarget = "muteButton"

    const muteIcon = document.createElement("span")
    muteIcon.classList.add("audio-icon-wrap")
    muteIcon.dataset.audioPlayerTarget = "muteIcon"
    muteIcon.innerHTML = VOLUME_ICON
    muteButton.appendChild(muteIcon)

    controls.appendChild(playButton)
    controls.appendChild(waveform)
    controls.appendChild(muteButton)

    const timeDisplay = document.createElement("div")
    timeDisplay.classList.add("audio-time")
    timeDisplay.dataset.audioPlayerTarget = "timeDisplay"
    timeDisplay.textContent = "0:00"

    wrapper.appendChild(audio)
    wrapper.appendChild(controls)
    wrapper.appendChild(timeDisplay)
    return wrapper
  }

  buildImageAttachment(url, filename) {
    const wrapper = document.createElement("div")
    wrapper.classList.add("msg-attachment-img")

    const img = document.createElement("img")
    img.src = url
    img.classList.add("attachment-image")
    img.alt = filename || "Image attachment"
    img.onload = () => this.scrollToBottom()

    wrapper.appendChild(img)
    return wrapper
  }

  buildFileAttachment(url, filename) {
    const link = document.createElement("a")
    link.href = url
    link.target = "_blank"
    link.rel = "noopener"
    link.classList.add("msg-attachment-file")

    const icon = document.createElement("span")
    icon.classList.add("file-icon")
    icon.textContent = "📄"

    const name = document.createElement("span")
    name.classList.add("file-name")
    name.textContent = filename || "Attachment"

    link.appendChild(icon)
    link.appendChild(name)
    return link
  }

  appendCableMessageTime(messageEl, message) {
    const timeEl = document.createElement("div")
    timeEl.classList.add("msg-time")

    if (this.isIncomingMessage(message)) {
      timeEl.textContent = this.formatMessageTime(message.created_at)
      messageEl.appendChild(timeEl)
      return
    }

    const timeText = document.createElement("span")
    timeText.textContent = this.formatMessageTime(message.created_at)
    timeEl.appendChild(timeText)

    const replyEl = messageEl.querySelector(".agent-reply")
    if (replyEl) replyEl.appendChild(timeEl)
  }

  formatMessageTime(value) {
    const date = value ? new Date(value) : new Date()
    if (Number.isNaN(date.getTime())) return ""

    return date.toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
      hour12: true
    })
  }

  isSingleEmojiMessage(content) {
    const text = this.stripHtml(content).trim()
    if (!text) return false

    const segmenter = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null
    const clusters = segmenter ? Array.from(segmenter.segment(text)) : Array.from(text)
    return clusters.length === 1 && /\p{Emoji}/u.test(text)
  }

  messageRenderedCorrectly(messageId) {
    const messageEl = document.getElementById(`message_${messageId}`)
    return this.isWidgetMessageElement(messageEl)
  }

  isWidgetMessageElement(messageEl) {
    return !!messageEl && (messageEl.classList.contains("agent-msg") || messageEl.classList.contains("client-reply"))
  }

  setupImagePreview() {
    const list = document.getElementById("messages-list")
    if (!list) return

    if (this._imagePreviewHandler) {
      list.removeEventListener("click", this._imagePreviewHandler)
    }

    this._imagePreviewHandler = (e) => {
      const img = e.target.closest(".attachment-image")
      if (!img) return
      this.openImagePreview(img.src, img.alt)
    }

    list.addEventListener("click", this._imagePreviewHandler)
  }

  openImagePreview(src, alt = "") {
    this.closeImagePreview()

    const overlay = document.createElement("div")
    overlay.classList.add("msg-image-overlay")
    overlay.id = "msg-image-overlay"
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay) this.closeImagePreview()
    })

    const img = document.createElement("img")
    img.src = src
    img.alt = alt
    img.classList.add("msg-image-overlay-img")

    const closeBtn = document.createElement("button")
    closeBtn.classList.add("msg-image-overlay-close")
    closeBtn.innerHTML = "×"
    closeBtn.addEventListener("click", () => this.closeImagePreview())

    overlay.appendChild(img)
    overlay.appendChild(closeBtn)
    document.body.appendChild(overlay)

    requestAnimationFrame(() => overlay.classList.add("active"))

    this._imagePreviewEscHandler = (e) => {
      if (e.key === "Escape") this.closeImagePreview()
    }
    document.addEventListener("keydown", this._imagePreviewEscHandler)
  }

  closeImagePreview() {
    const overlay = document.getElementById("msg-image-overlay")
    if (overlay) {
      overlay.classList.remove("active")
      overlay.addEventListener("transitionend", () => overlay.remove(), { once: true })
      setTimeout(() => { if (overlay.parentNode) overlay.remove() }, 300)
    }
    if (this._imagePreviewEscHandler) {
      document.removeEventListener("keydown", this._imagePreviewEscHandler)
      this._imagePreviewEscHandler = null
    }
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

  showInlineError(message) {
    let errorEl = this.element.querySelector(".widget-inline-error")
    if (!errorEl) {
      errorEl = document.createElement("div")
      errorEl.classList.add("widget-inline-error")
      this.element.appendChild(errorEl)
    }

    errorEl.textContent = message
    clearTimeout(this._inlineErrorTimer)
    this._inlineErrorTimer = setTimeout(() => errorEl.remove(), 4000)
  }

  setSearching(isLoading) {
    const results = document.getElementById("help-results")
    if (results) results.classList.toggle("is-searching", isLoading)
  }

  setSearchActive(isActive) {
    const sheet = this.element.closest(".homepage")?.querySelector(".widget-content-sheet")
    if (sheet) sheet.classList.toggle("is-search-active", isActive)
  }

  showResolvedConversationMessage(event) {
    const row = event.currentTarget.closest(".widget-conv-row")
    const message = row?.querySelector(".widget-resolved-message")
    if (!message) return

    message.hidden = false
    clearTimeout(message._hideTimer)
    message._hideTimer = setTimeout(() => {
      message.hidden = true
    }, 4000)
  }

  // --- Communication with parent frame ---
  persistResumeToken() {
    if (!this.accountIdValue || !this.widgetIdValue || !this.customerSessionTokenValue) return

    const storageKey = `deskbolic:customer-session-token:${this.accountIdValue}:${this.widgetIdValue}`
    try {
      window.localStorage.setItem(storageKey, this.customerSessionTokenValue)
    } catch (error) {}

    try {
      window.dispatchEvent(new CustomEvent("deskbolic:token-updated", {
        detail: { token: this.customerSessionTokenValue }
      }))
    } catch (error) {}

    this.notifyParent("deskbolic:customer", {
      customer_session_token: this.customerSessionTokenValue
    })
  }

  notifyParent(type, data) {
    if (window.parent !== window) {
      window.parent.postMessage(Object.assign({ type: type }, data), "*")
    }
  }

  // --- Utilities ---
  get csrfToken() {
    const meta = document.querySelector("[name='csrf-token']")
    return meta ? meta.content : ""
  }
}
