import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.messageHandler = this.handleMessage.bind(this)
    window.addEventListener("message", this.messageHandler)
  }

  disconnect() {
    window.removeEventListener("message", this.messageHandler)
  }

  handleMessage(event) {
    // Basic validation to only accept messages from our preview payload
    if (!event.data || event.data.type !== 'deskbolic:preview:update') return

    const { action, payload } = event.data

    switch (action) {
      case 'updateTheme':
        this.updateTheme(payload.color)
        break
      case 'updateWelcomeTitle':
        this.updateText('.header-1 .title, .header-2 .intro-heading', payload.text)
        break
      case 'updateWelcomeTagline':
        this.updateText('.header-1 .subtitle, .header-2 .intro-subheading', payload.text)
        break
      case 'updateCustomFooterText':
        this.updateCustomFooterText(payload.text)
        break
    }
  }

  updateTheme(color) {
    if (!color) return
    
    // Update the CSS variable which cascades through the app
    document.documentElement.style.setProperty('--widget-primary-color', color)
    
    // Fallback for hardcoded inline styles in the DOM if any
    const coloredElements = document.querySelectorAll('.start-conv-btn, #deskbolic-bubble, .btn-primary, .client-reply, .header-1')
    coloredElements.forEach(el => {
      el.style.setProperty('background-color', color, 'important')
    })
    
    const textElements = document.querySelectorAll('.footer .active, .reply-time .time, .team')
    textElements.forEach(el => {
      el.style.setProperty('color', color, 'important')
    })
  }

  updateText(selector, text) {
    const els = document.querySelectorAll(selector)
    els.forEach(el => {
      el.textContent = text
    })
  }

  updateCustomFooterText(payload) {
    const footerEls = document.querySelectorAll('.powered-by')
    footerEls.forEach(el => {
      if (payload.isCustom) {
        if (payload.text && payload.text.trim() !== '') {
          el.innerHTML = `<span>${payload.text}</span>`
          el.style.display = ''
        } else {
          el.style.display = 'none'
        }
      } else {
        el.innerHTML = `<a href="https://deskbolic.com" target="_blank" rel="noopener">Powered by Deskbolic</a>`
        el.style.display = ''
      }
    })
  }
}
