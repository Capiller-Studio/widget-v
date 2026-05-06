/**
 * Deskbolic Lexical Editor
 * A lightweight rich-text editor for the widget chat input.
 * Supports: text, emoji, file attachments, Enter-to-send.
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

    // Emoji button
    this.emojiBtn = this._createToolbarBtn('😊', this.i18n.emoji, 'de-emoji-btn')

    // File upload button + hidden input
    this.fileBtn = this._createToolbarBtn('📎', this.i18n.attach_file, 'de-file-btn')
    this.fileInput = document.createElement('input')
    this.fileInput.type = 'file'
    this.fileInput.accept = 'image/*,video/*,.pdf,.doc,.docx,.txt,.zip'
    this.maxFiles = 5
    this.maxFileSize = 5 * 1024 * 1024
    this.maxVideoSize = 20 * 1024 * 1024
    this.fileInput.multiple = true
    this.fileInput.style.display = 'none'

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

  _createToolbarBtn(emoji, label, cls) {
    const btn = document.createElement('button')
    btn.type = 'button'
    btn.classList.add('de-toolbar-btn', cls)
    btn.setAttribute('aria-label', label)
    btn.textContent = emoji
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

    // Close emoji picker on outside click
    document.addEventListener('click', (e) => {
      if (this._emojiPickerOpen && !this.emojiPicker.contains(e.target) && !this.emojiBtn.contains(e.target)) {
        this._closeEmojiPicker()
      }
    })
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

  _handleSubmit() {
    const text = this.getTextContent()
    if (!text && this._selectedFiles.length === 0) return

    if (this.onSubmit) {
      this.onSubmit(text, this._selectedFiles || [])
    }

    this.clear()
    this._clearFiles()
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

    if (isVideo && file.size > this.maxVideoSize) {
      return `Video exceeds 20MB limit`
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
