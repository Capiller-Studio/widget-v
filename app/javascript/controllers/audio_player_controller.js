// audio_player_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["audio", "playButton", "playIcon", "timeDisplay", "waveform", "muteButton", "muteIcon"]

  static values = {
    playIcon: { type: String, default: "/assets/play.svg" },
    pauseIcon: { type: String, default: "/assets/pause.svg" },
    volumeIcon: { type: String, default: "/assets/volume.svg" },
    muteIcon: { type: String, default: "/assets/mute.svg" }
  }

  connect() {
    this.audioTarget.addEventListener("timeupdate", () => this.updateTime())
    this.audioTarget.addEventListener("loadedmetadata", () => this.onLoaded())
    this.audioTarget.addEventListener("ended", () => this.reset())
    this.audioTarget.addEventListener("play", () => this.onPlay())
    this.generateWaveform()
  }

  generateWaveform() {
    const bars = this.waveformTarget
    bars.innerHTML = ""
    const barCount = 40
    for (let i = 0; i < barCount; i++) {
      const bar = document.createElement("div")
      bar.className = "waveform-bar"
      const height = 4 + Math.random() * 28
      bar.style.height = `${height}px`
      bar.dataset.index = i
      bars.appendChild(bar)
    }
  }

  onLoaded() {
    this.timeDisplayTarget.textContent = this.formatTime(this.audioTarget.duration || 0)
    this.updateWaveformProgress(0)
  }

  onPlay() {
    this.timeDisplayTarget.textContent = this.formatTime(this.audioTarget.currentTime)
  }

  toggle() {
    if (this.audioTarget.paused) {
      this.audioTarget.play()
      this.playIconTarget.src = this.pauseIconValue
      this.element.classList.add("is-playing")
    } else {
      this.audioTarget.pause()
      this.playIconTarget.src = this.playIconValue
      this.element.classList.remove("is-playing")
    }
  }

  toggleMute() {
    this.audioTarget.muted = !this.audioTarget.muted
    this.muteIconTarget.src = this.audioTarget.muted ? this.muteIconValue : this.volumeIconValue
    this.element.classList.toggle("is-muted", this.audioTarget.muted)
  }

  updateTime() {
    this.timeDisplayTarget.textContent = this.formatTime(this.audioTarget.currentTime)
    if (this.audioTarget.duration) {
      const progress = this.audioTarget.currentTime / this.audioTarget.duration
      this.updateWaveformProgress(progress)
    }
  }

  updateWaveformProgress(progress) {
    const bars = this.waveformTarget.querySelectorAll(".waveform-bar")
    const activeCount = Math.floor(progress * bars.length)
    bars.forEach((bar, index) => {
      bar.classList.toggle("active", index < activeCount)
    })
  }

  reset() {
    this.playIconTarget.src = this.playIconValue
    this.element.classList.remove("is-playing")
    this.updateWaveformProgress(0)
    this.timeDisplayTarget.textContent = this.formatTime(this.audioTarget.duration || 0)
  }

  formatTime(seconds) {
    if (!seconds || isNaN(seconds)) return "0:00"
    const m = Math.floor(seconds / 60)
    const s = Math.floor(seconds % 60).toString().padStart(2, "0")
    return `${m}:${s}`
  }
}