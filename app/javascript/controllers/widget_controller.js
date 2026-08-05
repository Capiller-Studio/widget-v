import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { DeskbolicEditor } from "../lib/deskbolic_editor"

const cableConnections = new Map()
const CABLE_DISCONNECT_DELAY = 30000

function cableConnectionKey(cableUrl, connectionToken) {
  return `${cableUrl}|${connectionToken}`
}

export default class extends Controller {
  static targets = ["editorContainer"]
  static values = {
    connectionToken: String,
    accountId: String,
    widgetId: String,
    customerSessionToken: String,
    url: String,
    avatarUrl: String,
    cableUrl: String,
    playIcon: String,
    pauseIcon: String,
    volumeIcon: String,
    muteIcon: String
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

    this.subscribeToCable(cableUrl)
  }

  disconnect() {
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

    // Show outgoing message immediately
    if (text) this.appendOutgoingMessage(text)
    // Show image previews for file attachments
    files.forEach(file => {
      if (file.type.startsWith('image/')) {
        this.appendOutgoingImage(file)
      } else if (file.type.startsWith('audio/')) {
        this.appendOutgoingAudio(file)
      } else {
        this.appendOutgoingMessage(`📎 ${file.name}`)
      }
    })

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: { "X-CSRF-Token": this.csrfToken },
        body: formData
      })

      if (!response.ok) {
        throw new Error(`Message send failed: ${response.status}`)
      }
    } catch (error) {
      console.error("[Deskbolic] Network error:", error)
      this.showInlineError("Message failed to send. Please try again.")
      throw error
    }
  }

  search(event) {
    const query = event.target.value
    if (query.length > 0 && query.length < 3) return

    clearTimeout(this._searchTimeout)
    this._searchTimeout = setTimeout(() => {
      this.setSearching(true)
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
      .catch(error => {
        console.error("[Deskbolic] Search failed:", error)
      })
      .finally(() => this.setSearching(false))
    }, 300)
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
  }

  onDisconnected() {
    this._reconnectAttempts++
  }

  onRejected() {
    console.error("[Deskbolic] WebSocket connection rejected. Invalid token.")
  }

  formatTime(date) {
    const d = date || new Date()
    let hours = d.getHours()
    const minutes = d.getMinutes().toString().padStart(2, "0")
    const ampm = hours >= 12 ? "PM" : "AM"
    hours = hours % 12 || 12
    return `${hours}:${minutes} ${ampm}`
  }

  createMsgTime() {
    const timeEl = document.createElement("div")
    timeEl.classList.add("msg-time")
    timeEl.textContent = this.formatTime()
    return timeEl
  }

  // --- Message handling ---

  handleReceived(data) {
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
      if (message && !message.incoming && (message.content || (message.attachments || []).length)) {
        const sender = message.sender || {}
        this.appendIncomingMessage(message.content, message.attachments || [], sender.avatar_url, sender.display_name || sender.name)

        this.unreadCount++
        this.notifyParent("deskbolic:unread", { count: this.unreadCount })
      }
    }
  }

  appendIncomingMessage(content, attachments = [], agentAvatarUrl, agentName) {
    const list = document.getElementById("messages-list")
    if (!list) return

    const messageEl = document.createElement("div")
    messageEl.classList.add("agent-msg")
    const avatarSrc = agentAvatarUrl || this.avatarUrlValue || '/assets/human.png'
    const emojiClass = this.isSingleEmojiMessage(content) ? " single-emoji-message" : ""
    messageEl.innerHTML = `<img src="${avatarSrc}" class="person-img" alt="${this.escapeHtml(agentName || 'Agent')}" title="${this.escapeHtml(agentName || 'Agent')}"><div class="agent-reply${emojiClass}">${this.escapeHtml(content)}</div>`
    const replyDiv = messageEl.querySelector(".agent-reply")
    if (replyDiv) replyDiv.after(this.createMsgTime())

    if (attachments.length) {
      this.appendAttachments(messageEl, attachments)
    }

    list.appendChild(messageEl)
    this.scrollToBottom()
  }

  appendOutgoingMessage(content) {
    const list = document.getElementById("messages-list")
    if (!list) return

    const messageEl = document.createElement("div")
    messageEl.classList.add("client-reply")
    if (this.isSingleEmojiMessage(content)) messageEl.classList.add("single-emoji-message")
    messageEl.textContent = content
    messageEl.appendChild(this.createMsgTime())
    list.appendChild(messageEl)
    this.scrollToBottom()
  }

  appendOutgoingImage(file) {
    const list = document.getElementById("messages-list")
    if (!list) return

    const messageEl = document.createElement("div")
    messageEl.classList.add("client-reply")

    const attachmentsEl = document.createElement("div")
    attachmentsEl.classList.add("msg-attachments")

    const attachmentImgWrapper = document.createElement("div")
    attachmentImgWrapper.classList.add("msg-attachment-img")

    const img = document.createElement("img")
    img.src = URL.createObjectURL(file)
    img.classList.add("attachment-image")
    img.onload = () => this.scrollToBottom()

    attachmentImgWrapper.appendChild(img)
    attachmentsEl.appendChild(attachmentImgWrapper)
    messageEl.appendChild(attachmentsEl)
    messageEl.appendChild(this.createMsgTime())
    list.appendChild(messageEl)

    this.scrollToBottom()
  }

  appendOutgoingAudio(file) {
    const list = document.getElementById("messages-list")
    if (!list) return

    const messageEl = document.createElement("div")
    messageEl.classList.add("client-reply")

    const attachmentsEl = document.createElement("div")
    attachmentsEl.classList.add("msg-attachments")

    const audioWrapper = document.createElement("div")
    audioWrapper.classList.add("msg-attachment-audio")
    audioWrapper.dataset.controller = "audio-player"
    audioWrapper.dataset.audioPlayerPlayIconValue = this.playIconValue || "/assets/play.svg"
    audioWrapper.dataset.audioPlayerPauseIconValue = this.pauseIconValue || "/assets/pause.svg"
    audioWrapper.dataset.audioPlayerVolumeIconValue = this.volumeIconValue || "/assets/volume.svg"
    audioWrapper.dataset.audioPlayerMuteIconValue = this.muteIconValue || "/assets/mute.svg"

    const audio = document.createElement("audio")
    audio.dataset.audioPlayerTarget = "audio"
    audio.preload = "metadata"
    audio.src = URL.createObjectURL(file)

    const controls = document.createElement("div")
    controls.classList.add("audio-player-controls")

    const playBtn = document.createElement("button")
    playBtn.type = "button"
    playBtn.classList.add("audio-btn")
    playBtn.dataset.action = "audio-player#toggle"
    playBtn.dataset.audioPlayerTarget = "playButton"

    const playIcon = document.createElement("img")
    playIcon.src = this.playIconValue || "/assets/play.svg"
    playIcon.dataset.audioPlayerTarget = "playIcon"
    playIcon.alt = "Play"
    playBtn.appendChild(playIcon)

    const waveform = document.createElement("div")
    waveform.classList.add("audio-waveform")
    waveform.dataset.audioPlayerTarget = "waveform"

    const muteBtn = document.createElement("button")
    muteBtn.type = "button"
    muteBtn.classList.add("audio-btn", "audio-mute-btn")
    muteBtn.dataset.action = "audio-player#toggleMute"
    muteBtn.dataset.audioPlayerTarget = "muteButton"

    const muteIcon = document.createElement("img")
    muteIcon.src = this.volumeIconValue || "/assets/volume.svg"
    muteIcon.dataset.audioPlayerTarget = "muteIcon"
    muteIcon.alt = "Mute"
    muteBtn.appendChild(muteIcon)

    controls.appendChild(playBtn)
    controls.appendChild(waveform)
    controls.appendChild(muteBtn)

    const timeDisplay = document.createElement("div")
    timeDisplay.classList.add("audio-time")
    timeDisplay.dataset.audioPlayerTarget = "timeDisplay"
    timeDisplay.textContent = "0:00"

    audioWrapper.appendChild(audio)
    audioWrapper.appendChild(controls)
    audioWrapper.appendChild(timeDisplay)
    attachmentsEl.appendChild(audioWrapper)
    messageEl.appendChild(attachmentsEl)
    messageEl.appendChild(this.createMsgTime())
    list.appendChild(messageEl)

    this.scrollToBottom()
  }

  appendAttachments(container, attachments) {
    if (!attachments.length) return

    const attachmentsEl = document.createElement("div")
    attachmentsEl.classList.add("msg-attachments")

    attachments.forEach((attachment) => {
      if (!attachment.url) return

      if (attachment.attachment_type === "audio" || (attachment.content_type || "").startsWith("audio/")) {
        const audioWrapper = document.createElement("div")
        audioWrapper.classList.add("msg-attachment-audio")
        audioWrapper.dataset.controller = "audio-player"
        audioWrapper.dataset.audioPlayerPlayIconValue = this.playIconValue || "/assets/play.svg"
        audioWrapper.dataset.audioPlayerPauseIconValue = this.pauseIconValue || "/assets/pause.svg"
        audioWrapper.dataset.audioPlayerVolumeIconValue = this.volumeIconValue || "/assets/volume.svg"
        audioWrapper.dataset.audioPlayerMuteIconValue = this.muteIconValue || "/assets/mute.svg"

        const audio = document.createElement("audio")
        audio.dataset.audioPlayerTarget = "audio"
        audio.preload = "metadata"
        audio.src = attachment.url

        const controls = document.createElement("div")
        controls.classList.add("audio-player-controls")

        const playBtn = document.createElement("button")
        playBtn.type = "button"
        playBtn.classList.add("audio-btn")
        playBtn.dataset.action = "audio-player#toggle"
        playBtn.dataset.audioPlayerTarget = "playButton"

        const playIcon = document.createElement("img")
        playIcon.src = this.playIconValue || "/assets/play.svg"
        playIcon.dataset.audioPlayerTarget = "playIcon"
        playIcon.alt = "Play"
        playBtn.appendChild(playIcon)

        const waveform = document.createElement("div")
        waveform.classList.add("audio-waveform")
        waveform.dataset.audioPlayerTarget = "waveform"

        const muteBtn = document.createElement("button")
        muteBtn.type = "button"
        muteBtn.classList.add("audio-btn", "audio-mute-btn")
        muteBtn.dataset.action = "audio-player#toggleMute"
        muteBtn.dataset.audioPlayerTarget = "muteButton"

        const muteIcon = document.createElement("img")
        muteIcon.src = this.volumeIconValue || "/assets/volume.svg"
        muteIcon.dataset.audioPlayerTarget = "muteIcon"
        muteIcon.alt = "Mute"
        muteBtn.appendChild(muteIcon)

        controls.appendChild(playBtn)
        controls.appendChild(waveform)
        controls.appendChild(muteBtn)

        const timeDisplay = document.createElement("div")
        timeDisplay.classList.add("audio-time")
        timeDisplay.dataset.audioPlayerTarget = "timeDisplay"
        timeDisplay.textContent = "0:00"

        audioWrapper.appendChild(audio)
        audioWrapper.appendChild(controls)
        audioWrapper.appendChild(timeDisplay)
        attachmentsEl.appendChild(audioWrapper)
      } else if (attachment.attachment_type === "image" || (attachment.content_type || "").startsWith("image/")) {
        const wrapper = document.createElement("div")
        wrapper.classList.add("msg-attachment-img")

        const img = document.createElement("img")
        img.src = attachment.url
        img.classList.add("attachment-image")
        img.alt = attachment.filename || "Image attachment"
        img.onload = () => this.scrollToBottom()

        wrapper.appendChild(img)
        attachmentsEl.appendChild(wrapper)
      } else {
        const link = document.createElement("a")
        link.href = attachment.url
        link.target = "_blank"
        link.rel = "noopener"
        link.classList.add("msg-attachment-file")

        const icon = document.createElement("span")
        icon.classList.add("file-icon")
        icon.textContent = "📄"

        const name = document.createElement("span")
        name.classList.add("file-name")
        name.textContent = attachment.filename || "Attachment"

        link.appendChild(icon)
        link.appendChild(name)
        attachmentsEl.appendChild(link)
      }
    })

    if (attachmentsEl.childElementCount) container.appendChild(attachmentsEl)
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
    const helpSection = this.element.closest(".help-section") || this.element
    helpSection.classList.toggle("is-searching", isLoading)
  }

  // --- Communication with parent frame ---
  persistResumeToken() {
    if (!this.accountIdValue || !this.widgetIdValue || !this.customerSessionTokenValue) return

    const storageKey = `deskbolic:customer-session-token:${this.accountIdValue}:${this.widgetIdValue}`
    try {
      window.localStorage.setItem(storageKey, this.customerSessionTokenValue)
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
  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  isSingleEmojiMessage(content) {
    const text = (content || "").trim()
    if (!text) return false

    const segments = typeof Intl !== "undefined" && Intl.Segmenter
      ? Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text))
      : Array.from(text)
    if (segments.length !== 1) return false

    const singleEmojiPattern = /^(?:(?:[\u{1F1E6}-\u{1F1FF}]{2})|(?:[0-9#*]\uFE0F?\u20E3)|(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic}\uFE0F?)\p{Emoji_Modifier}?(?:\u200D(?:\p{Emoji_Presentation}|\p{Extended_Pictographic}\uFE0F?)\p{Emoji_Modifier}?)*))$/u
    return singleEmojiPattern.test(text)
  }

  get csrfToken() {
    const meta = document.querySelector("[name='csrf-token']")
    return meta ? meta.content : ""
  }
}
