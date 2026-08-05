/**
 * Deskbolic Lexical Editor
 * A lightweight rich-text editor for the widget chat input.
 * Supports: text, emoji, file attachments, voice notes, Enter-to-send.
 */
import { createEditor, $getRoot, $createParagraphNode, $createTextNode, $getSelection } from 'lexical'
import { registerRichText } from '@lexical/rich-text'
import { registerHistory, createEmptyHistoryState } from '@lexical/history'
import { $generateHtmlFromNodes } from '@lexical/html'

export class DeskbolicEditor {
  constructor(containerEl, { onSubmit, onFileSelect, csrfToken, i18n = {} }) {
    this.container = containerEl
    this.onSubmit = onSubmit
    this.onFileSelect = onFileSelect
    this.csrfToken = csrfToken
    this._emojiPickerOpen = false
    this.i18n = Object.assign({
      placeholder: 'Type a message…',
      emoji: 'Emoji',
      attach_file: 'Attach file',
      record_voice: 'Record voice',
      stop_recording: 'Stop recording',
      send: 'Send message',
      emoji_smileys: '😀 Smileys',
      emoji_gestures: '👋 Gestures',
      emoji_hearts: '❤️ Hearts',
      emoji_objects: '🎉 Objects'
    }, i18n)

    this._buildUI()
    this._initLexical()
    this._bindEvents()
  }

  // --- Build the DOM structure ---
  _buildUI() {
    this.container.innerHTML = ''
    this.container.classList.add('deskbolic-editor')

    // Editor area (contenteditable, managed by Lexical)
    this.editorEl = document.createElement('div')
    this.editorEl.classList.add('de-editable')
    this.editorEl.setAttribute('role', 'textbox')
    this.editorEl.setAttribute('aria-label', this.i18n.placeholder)
    this.editorEl.contentEditable = 'true'
    this.editorEl.dataset.placeholder = this.i18n.placeholder

    // Toolbar
    this.toolbar = document.createElement('div')
    this.toolbar.classList.add('de-toolbar')

    // Emoji button (SVG)
    this.emojiBtn = this._createToolbarBtn(`
      <svg width="19" height="20" viewBox="0 0 19 20" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M9.49288 2.87501C8.08399 2.87642 6.70715 3.29549 5.53638 4.07925C4.36562 4.86301 3.4535 5.97627 2.91532 7.27832C2.37714 8.58037 2.23705 10.0127 2.51278 11.3944C2.7885 12.776 3.46765 14.0449 4.46439 15.0407C5.46112 16.0364 6.73068 16.7143 8.1126 16.9886C9.49452 17.263 10.9268 17.1214 12.2283 16.582C13.5298 16.0425 14.6421 15.1292 15.4247 13.9577C16.2073 12.7862 16.625 11.4089 16.625 10C16.6255 9.06361 16.4413 8.13631 16.0829 7.2712C15.7246 6.40608 15.1991 5.62012 14.5366 4.95832C13.8742 4.29652 13.0877 3.77186 12.2222 3.41438C11.3568 3.0569 10.4293 2.87361 9.49288 2.87501ZM9.5 15.5417C8.40396 15.5417 7.33254 15.2167 6.42122 14.6077C5.5099 13.9988 4.79961 13.1333 4.38017 12.1207C3.96074 11.1081 3.85099 9.99386 4.06482 8.91888C4.27864 7.8439 4.80644 6.85647 5.58145 6.08146C6.35647 5.30644 7.3439 4.77865 8.41888 4.56482C9.49386 4.351 10.6081 4.46074 11.6207 4.88018C12.6333 5.29961 13.4988 6.0099 14.1077 6.92122C14.7167 7.83255 15.0417 8.90397 15.0417 10C15.0419 10.7278 14.8987 11.4485 14.6202 12.1209C14.3418 12.7934 13.9336 13.4044 13.419 13.919C12.9044 14.4336 12.2934 14.8418 11.6209 15.1202C10.9485 15.3987 10.2278 15.5419 9.5 15.5417ZM11.9581 11.425H13.148C12.8618 12.1597 12.3604 12.7908 11.7095 13.2357C11.0585 13.6807 10.2885 13.9188 9.5 13.9188C8.71155 13.9188 7.94146 13.6807 7.29055 13.2357C6.63964 12.7908 6.13825 12.1597 5.852 11.425H7.04188C7.28982 11.858 7.64771 12.2178 8.07935 12.468C8.511 12.7182 9.00108 12.85 9.5 12.85C9.99893 12.85 10.489 12.7182 10.9207 12.468C11.3523 12.2178 11.7102 11.858 11.9581 11.425ZM5.9375 8.21876C5.9375 8.00738 6.00018 7.80075 6.11762 7.62499C6.23506 7.44924 6.40197 7.31225 6.59726 7.23136C6.79255 7.15047 7.00744 7.12931 7.21476 7.17054C7.42207 7.21178 7.61251 7.31357 7.76197 7.46304C7.91144 7.6125 8.01323 7.80294 8.05447 8.01026C8.09571 8.21757 8.07454 8.43246 7.99365 8.62775C7.91276 8.82304 7.77577 8.98996 7.60002 9.10739C7.42426 9.22483 7.21763 9.28751 7.00625 9.28751C6.7228 9.28751 6.45096 9.17491 6.25053 8.97448C6.0501 8.77405 5.9375 8.50221 5.9375 8.21876ZM10.925 8.21876C10.925 8.00738 10.9877 7.80075 11.1051 7.62499C11.2226 7.44924 11.3895 7.31225 11.5848 7.23136C11.78 7.15047 11.9949 7.12931 12.2023 7.17054C12.4096 7.21178 12.6 7.31357 12.7495 7.46304C12.8989 7.6125 13.0007 7.80294 13.042 8.01026C13.0832 8.21757 13.062 8.43246 12.9811 8.62775C12.9003 8.82304 12.7633 8.98996 12.5875 9.10739C12.4118 9.22483 12.2051 9.28751 11.9938 9.28751C11.7103 9.28751 11.4385 9.17491 11.238 8.97448C11.0376 8.77405 10.925 8.50221 10.925 8.21876Z" fill="black" fill-opacity="0.8"/>
      </svg>
    `, this.i18n.emoji, 'de-emoji-btn')

    // File upload button + hidden input (SVG)
    this.fileBtn = this._createToolbarBtn(`
      <svg width="18" height="18" viewBox="0 0 18 18" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path fill-rule="evenodd" clip-rule="evenodd" d="M7.4092 3.16635C9.45945 1.1161 12.7836 1.1161 14.8338 3.16635C16.8841 5.2166 16.8841 8.54072 14.8338 10.591L9.53052 15.8943C8.06605 17.3587 5.69169 17.3587 4.22722 15.8943C4.02342 15.6905 3.84745 15.4683 3.69977 15.2328L4.3352 14.8344L3.69977 15.2328C2.79177 13.7847 2.96663 11.8516 4.22722 10.591L9.53052 5.28767C10.4092 4.40899 11.8338 4.40899 12.7125 5.28767C13.5912 6.16635 13.5912 7.59097 12.7125 8.46965L7.4092 13.773C7.11631 14.0658 6.64143 14.0658 6.34854 13.773C6.05565 13.4801 6.05565 13.0052 6.34854 12.7123L11.6518 7.40899C11.9447 7.1161 11.9447 6.64123 11.6518 6.34833C11.3589 6.05544 10.8841 6.05544 10.5912 6.34833L5.28788 11.6516C4.53261 12.4069 4.4259 13.5672 4.97062 14.436C5.05879 14.5766 5.16439 14.7101 5.28788 14.8336C6.16656 15.7123 7.59118 15.7123 8.46986 14.8336L13.7732 9.53031C15.2376 8.06585 15.2376 5.69148 13.7732 4.22701C12.3087 2.76255 9.93433 2.76255 8.46986 4.22701L3.16656 9.53031C2.87367 9.82321 2.39879 9.82321 2.1059 9.53031C1.81301 9.23742 1.81301 8.76254 2.1059 8.46965L7.4092 3.16635Z" fill="black" fill-opacity="0.8"/>
      </svg>
    `, this.i18n.attach_file, 'de-file-btn')
    this.fileInput = document.createElement('input')
    this.fileInput.type = 'file'
    this.fileInput.accept = 'image/*,video/*,audio/*,.pdf,.doc,.docx,.txt,.zip'
    this.maxFiles = 5
    this.maxFileSize = 5 * 1024 * 1024
    this.maxVideoSize = 20 * 1024 * 1024
    this.maxAudioSize = 20 * 1024 * 1024
    this.fileInput.multiple = true
    this.fileInput.style.display = 'none'
    // Voice button (SVG)
    this.voiceBtn = this._createToolbarBtn(`
      <svg width="17" height="18" viewBox="0 0 17 18" fill="none" xmlns="http://www.w3.org/2000/svg">
        <g clip-path=\"url(#clip0_903_34515)\">
          <path d=\"M8.5 1.20825C7.93641 1.20825 7.39591 1.43214 6.9974 1.83065C6.59888 2.22916 6.375 2.76967 6.375 3.33325V8.99992C6.375 9.5635 6.59888 10.104 6.9974 10.5025C7.39591 10.901 7.93641 11.1249 8.5 11.1249C9.06358 11.1249 9.60409 10.901 10.0026 10.5025C10.4011 10.104 10.625 9.5635 10.625 8.99992V3.33325C10.625 2.76967 10.4011 2.22916 10.0026 1.83065C9.60409 1.43214 9.06358 1.20825 8.5 1.20825V1.20825Z\" stroke=\"black\" stroke-opacity=\"0.8\" stroke-width=\"1.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>
          <path d=\"M13.4582 7.58325V8.99992C13.4582 10.315 12.9358 11.5761 12.0059 12.506C11.076 13.4359 9.81487 13.9583 8.49984 13.9583C7.18481 13.9583 5.92363 13.4359 4.99377 12.506C4.0639 11.5761 3.5415 10.315 3.5415 8.99992V7.58325\" stroke=\"black\" stroke-opacity=\"0.8\" stroke-width=\"1.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>
          <path d=\"M8.5 13.9583V16.7916\" stroke=\"black\" stroke-opacity=\"0.8\" stroke-width=\"1.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>
          <path d=\"M5.6665 16.7917H11.3332\" stroke=\"black\" stroke-opacity=\"0.8\" stroke-width=\"1.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>
        </g>
        <defs>
          <clipPath id=\"clip0_903_34515\">
            <rect width=\"17\" height=\"17\" fill=\"white\" transform=\"translate(0 0.5)\"/>
          </clipPath>
        </defs>
      </svg>
    `, this.i18n.record_voice, 'de-voice-btn')
    // Send button
    this.sendBtn = document.createElement('button')
    this.sendBtn.type = 'button'
    this.sendBtn.classList.add('de-send-btn')
    this.sendBtn.setAttribute('aria-label', this.i18n.send)
    this.sendBtn.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"></line><polygon points="22 2 15 22 11 13 2 9 22 2"></polygon></svg>`

    // Emoji picker container (hidden)
    this.emojiPicker = document.createElement('div')
    this.emojiPicker.classList.add('de-emoji-picker')
    this.emojiPicker.style.display = 'none'
    this._populateEmojiPicker()

    // File preview area
    this.filePreview = document.createElement('div')
    this.filePreview.classList.add('de-file-preview')

    // Error box
    this.errorBox = document.createElement('div')
    this.errorBox.classList.add('de-error-box')
    this.errorBox.style.display = 'none'

    // Assemble
    this.toolbar.appendChild(this.emojiBtn)
    this.toolbar.appendChild(this.fileBtn)
    this.toolbar.appendChild(this.voiceBtn)
    this.toolbar.appendChild(this.fileInput)

    // input row
    this.inputRow = document.createElement('div')
    this.inputRow.classList.add('de-input-row')

    this.inputRow.appendChild(this.editorEl)
    this.inputRow.appendChild(this.toolbar)
    this.inputRow.appendChild(this.sendBtn)

    this.container.appendChild(this.errorBox)  
    this.container.appendChild(this.filePreview) 
    this.container.appendChild(this.inputRow)
    this.container.appendChild(this.emojiPicker)
  }

  _createToolbarBtn(iconMarkup, label, cls) {
    const btn = document.createElement('button')
    btn.type = 'button'
    btn.classList.add('de-toolbar-btn', cls)
    btn.setAttribute('aria-label', label)
    btn.innerHTML = iconMarkup
    return btn
  }

  // --- Init Lexical ---
  _initLexical() {
    this.editor = createEditor({
      namespace: 'DeskbolicChat',
      onError: (error) => console.error('[Deskbolic Editor]', error),
      nodes: [],
      editable: true
    })

    this.editor.setRootElement(this.editorEl)
    registerRichText(this.editor)
    registerHistory(this.editor, createEmptyHistoryState(), 300)

    // Track empty state for placeholder
    this.editor.registerUpdateListener(({ editorState }) => {
      editorState.read(() => {
        const root = $getRoot()
        const text = root.getTextContent().trim()
        this.editorEl.classList.toggle('de-empty', text.length === 0)
      })
    })
    this.editorEl.classList.add('de-empty')
  }

  // --- Events ---
  _bindEvents() {
    // Enter to send (Shift+Enter for newline)
    this.editorEl.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault()
        this._handleSubmit()
      }
    })

    // Send button
    this.sendBtn.addEventListener('click', () => this._handleSubmit())

    // Emoji button
    this.emojiBtn.addEventListener('click', (e) => {
      e.stopPropagation()
      this._toggleEmojiPicker()
    })

    // File button
    this.fileBtn.addEventListener('click', () => this.fileInput.click())
    this.fileInput.addEventListener('change', () => this._handleFileSelect())
    this.voiceBtn.addEventListener('click', () => this._toggleRecording())
    // Close emoji picker on outside click
    document.addEventListener('click', (e) => {
      if (this._emojiPickerOpen && !this.emojiPicker.contains(e.target) && !this.emojiBtn.contains(e.target)) {
        this._closeEmojiPicker()
      }
    })
  }

  _showRecordingIndicator() {
    this._clearFiles()
    const chip = document.createElement('div')
    chip.classList.add('de-file-chip', 'de-recording-chip')
    chip.id = 'de-recording-indicator'

    const micIcon = document.createElement('span')
    micIcon.classList.add('de-recording-icon')
    micIcon.textContent = '🎤'
    chip.appendChild(micIcon)

    const label = document.createElement('span')
    label.classList.add('de-recording-label')
    label.textContent = 'Recording...'
    chip.appendChild(label)

    const dots = document.createElement('span')
    dots.classList.add('de-recording-dots')
    dots.innerHTML = '<span></span><span></span><span></span>'
    chip.appendChild(dots)

    const stopBtn = document.createElement('button')
    stopBtn.type = 'button'
    stopBtn.classList.add('de-file-remove', 'de-recording-stop')
    stopBtn.textContent = '×'
    stopBtn.addEventListener('click', () => {
      if (this._mediaRecorder && this._mediaRecorder.state === 'recording') {
        this._mediaRecorder.stop()
      }
    })
    chip.appendChild(stopBtn)

    this.filePreview.innerHTML = ''
    this.filePreview.appendChild(chip)
    this.filePreview.style.display = 'flex'
  }

  _hideRecordingIndicator() {
    const indicator = document.getElementById('de-recording-indicator')
    if (indicator) indicator.remove()
    if (!this._selectedFiles || this._selectedFiles.length === 0) {
      this.filePreview.style.display = 'none'
    }
  }

  _showError(message) {
    this.errorBox.textContent = message
    this.errorBox.style.display = 'block'

    clearTimeout(this._errorTimer)
    this._errorTimer = setTimeout(() => {
      this.errorBox.style.display = 'none'
      this.errorBox.textContent = ''
    }, 4000)
  }

  _setSubmitting(isSubmitting) {
    this._isSubmitting = isSubmitting
    this.container.classList.toggle('is-submitting', isSubmitting)
    this.sendBtn.disabled = isSubmitting
    this.emojiBtn.disabled = isSubmitting
    this.fileBtn.disabled = isSubmitting
    this.voiceBtn.disabled = isSubmitting
  }

  async _handleSubmit() {
    if (this._isSubmitting) return

    const text = this.getTextContent()
    if (!text && (!this._selectedFiles || this._selectedFiles.length === 0)) return

    const files = this._selectedFiles || []
    this._setSubmitting(true)
    this.clear()
    this._clearFiles()

    try {
      if (this.onSubmit) {
        await this.onSubmit(text, files)
      }
    } catch (error) {
      this._showError('Message failed to send. Please try again.')
    } finally {
      this._setSubmitting(false)
    }
  }

  _handleFileSelect() {
    const files = Array.from(this.fileInput.files)
    if (!files.length) return

    const totalFiles = (this._selectedFiles?.length || 0) + files.length
    if (totalFiles > this.maxFiles) {
      this._showError(`You can only upload ${this.maxFiles} files`)
      return
    }

    const validFiles = []
    for (const file of files) {
      const error = this._validateFile(file)
      if (error) {
        this._showError(error)
        continue
      }
      validFiles.push(file)
    }

    this._selectedFiles = (this._selectedFiles || []).concat(validFiles)
    this._renderFilePreview()

    if (this.onFileSelect) {
      this.onFileSelect(validFiles)
    }

    this.fileInput.value = ''
  }

  _validateFile(file) {
    const isVideo = file.type.startsWith('video/')
    const isAudio = file.type.startsWith('audio/')

    if (isVideo && file.size > this.maxVideoSize) {
      return `Video exceeds 20MB limit`
    }
    if (isAudio && file.size > this.maxAudioSize) {
      return `Audio exceeds 20MB limit`
    }
    if (!isVideo && file.size > this.maxFileSize) {
      return `File exceeds 5MB limit`
    }

    return null
  }

  _renderFilePreview() {
    this.filePreview.innerHTML = ''
    if (!this._selectedFiles || this._selectedFiles.length === 0) {
      this.filePreview.style.display = 'none'
      return
    }

    this.filePreview.style.display = 'flex'
    this._selectedFiles.forEach((file, idx) => {
      const chip = document.createElement('div')
      chip.classList.add('de-file-chip')

      if (file.type.startsWith('image/')) {
        const img = document.createElement('img')
        img.src = URL.createObjectURL(file)
        img.classList.add('de-file-thumb')
        chip.appendChild(img)
      } else if (file.type.startsWith('audio/')) {
        const audioIcon = document.createElement('span')
        audioIcon.classList.add('de-file-audio-icon')
        audioIcon.textContent = 'Voice'
        chip.appendChild(audioIcon)
      }

      const name = document.createElement('span')
      name.classList.add('de-file-name')
      name.textContent = file.name.length > 15 ? file.name.substring(0, 12) + '...' : file.name
      chip.appendChild(name)

      const remove = document.createElement('button')
      remove.type = 'button'
      remove.classList.add('de-file-remove')
      remove.textContent = '×'
      remove.addEventListener('click', () => {
        this._selectedFiles.splice(idx, 1)
        this._renderFilePreview()
      })
      chip.appendChild(remove)

      this.filePreview.appendChild(chip)
    })
  }

  _clearFiles() {
    this._selectedFiles = []
    this._renderFilePreview()
  }

  async _toggleRecording() {
    if (this._mediaRecorder && this._mediaRecorder.state === 'recording') {
      this._mediaRecorder.stop()
      return
    }

    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || !window.MediaRecorder) {
      this._showError('Voice recording is not supported in this browser')
      return
    }

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      const chunks = []
      this._mediaRecorder = new MediaRecorder(stream)

      this._mediaRecorder.addEventListener('dataavailable', (event) => {
        if (event.data && event.data.size > 0) chunks.push(event.data)
      })

      this._mediaRecorder.addEventListener('stop', () => {
        stream.getTracks().forEach((track) => track.stop())
        this.voiceBtn.classList.remove('is-recording')
        this.voiceBtn.setAttribute('aria-label', this.i18n.record_voice)

        if (!chunks.length) return

        const type = this._mediaRecorder.mimeType || 'audio/webm'
        const extension = type.includes('mp4') ? 'm4a' : 'webm'
        const file = new File(chunks, `voice-note-${Date.now()}.${extension}`, { type })
        const error = this._validateFile(file)
        if (error) {
          this._showError(error)
          return
        }

        this._selectedFiles = (this._selectedFiles || []).concat(file)
        this._renderFilePreview()
      })

      this._mediaRecorder.start()
      this.voiceBtn.classList.add('is-recording')
      this.voiceBtn.setAttribute('aria-label', this.i18n.stop_recording)
      this._showRecordingIndicator()
    } catch (error) {
      this._showError('Microphone permission is required to record voice')
    }
  }

  // --- Emoji Picker ---
  _populateEmojiPicker() {
    const categories = {
      [this.i18n.emoji_smileys]: ['😀','😃','😄','😁','😆','😅','🤣','😂','🙂','😊','😇','🥰','😍','😘','😗','😋','😛','😜','🤪','😝','🤑','🤗','🤭','😐','😑','😶','😏','😒','🙄','😬','😮‍💨','🤥','😌','😔','😪','🤤','😴','😷','🤒','🤕','🤢','🤮','🥴','😵','🤯','🥳','🥺','😢','😭','😤','😠','😡','🤬','💀','☠️','💩','🤡','👹','👺','👻','👽','👾','🤖'],
      [this.i18n.emoji_gestures]: ['👋','🤚','🖐️','✋','🖖','👌','🤌','🤏','✌️','🤞','🫰','🤟','🤘','🤙','👈','👉','👆','🖕','👇','☝️','🫵','👍','👎','✊','👊','🤛','🤜','👏','🙌','🫶','👐','🤲','🤝','🙏','💪','🫂'],
      [this.i18n.emoji_hearts]: ['❤️','🧡','💛','💚','💙','💜','🖤','🤍','🤎','💔','❣️','💕','💞','💓','💗','💖','💘','💝','💟','♥️','🩷','🩵','🩶'],
      [this.i18n.emoji_objects]: ['🎉','🎊','🎈','🎁','🏆','🔥','⭐','✨','💫','🌟','💯','💥','🎵','🎶','👑','💎','🔔','📌','🚀','💡','📎','✅','❌','⚡','☀️','🌈','🌸','🍀']
    }

    Object.entries(categories).forEach(([label, emojis]) => {
      const section = document.createElement('div')
      section.classList.add('de-emoji-section')

      const heading = document.createElement('div')
      heading.classList.add('de-emoji-heading')
      heading.textContent = label
      section.appendChild(heading)

      const grid = document.createElement('div')
      grid.classList.add('de-emoji-grid')
      emojis.forEach(emoji => {
        const btn = document.createElement('button')
        btn.type = 'button'
        btn.classList.add('de-emoji-item')
        btn.textContent = emoji
        btn.addEventListener('click', () => {
          this._insertEmoji(emoji)
          this._closeEmojiPicker()
        })
        grid.appendChild(btn)
      })

      section.appendChild(grid)
      this.emojiPicker.appendChild(section)
    })
  }

  _insertEmoji(emoji) {
    this.editor.update(() => {
      const selection = $getSelection()
      if (selection) {
        selection.insertText(emoji)
      } else {
        const root = $getRoot()
        const paragraph = root.getLastChild() || $createParagraphNode()
        if (!root.getLastChild()) root.append(paragraph)
        paragraph.append($createTextNode(emoji))
      }
    })
    this.editorEl.focus()
  }

  _toggleEmojiPicker() {
    this._emojiPickerOpen ? this._closeEmojiPicker() : this._openEmojiPicker()
  }

  _openEmojiPicker() {
    this.emojiPicker.style.display = 'block'
    this._emojiPickerOpen = true
  }

  _closeEmojiPicker() {
    this.emojiPicker.style.display = 'none'
    this._emojiPickerOpen = false
  }

  // --- Public API ---
  getTextContent() {
    let text = ''
    this.editor.getEditorState().read(() => {
      text = $getRoot().getTextContent().trim()
    })
    return text
  }

  getHtmlContent() {
    let html = ''
    this.editor.update(() => {
      html = $generateHtmlFromNodes(this.editor)
    })
    return html
  }

  clear() {
    this.editor.update(() => {
      const root = $getRoot()
      root.clear()
      root.append($createParagraphNode())
    })
  }

  focus() {
    this.editorEl.focus()
  }

  destroy() {
    // Clean up object URLs
    if (this._selectedFiles) {
      this._selectedFiles.forEach(f => {
        if (f._objectUrl) URL.revokeObjectURL(f._objectUrl)
      })
    }
  }
}
