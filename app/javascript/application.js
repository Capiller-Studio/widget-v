// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import "./controllers"

let pendingWidgetRequests = 0

function widgetLoader() {
  let loader = document.getElementById("widget-loading-indicator")
  if (loader) return loader

  loader = document.createElement("div")
  loader.id = "widget-loading-indicator"
  loader.className = "widget-loading-indicator"
  loader.setAttribute("aria-live", "polite")
  loader.innerHTML = '<span class="widget-loading-spinner"></span>'
  document.body.appendChild(loader)
  return loader
}

function setWidgetLoading(isLoading) {
  pendingWidgetRequests = Math.max(0, pendingWidgetRequests + (isLoading ? 1 : -1))
  widgetLoader().classList.toggle("is-active", pendingWidgetRequests > 0)
}

function acceptsTurboStream(headers) {
  if (!headers) return false
  if (typeof headers.get === "function") {
    return headers.get("Accept")?.includes("turbo-stream")
  }

  return headers.Accept?.includes("turbo-stream") || headers.accept?.includes("turbo-stream")
}

function isWidgetEventTarget(target) {
  return target.closest?.("#deskbolic-widget") || target.id === "widget"
}

document.addEventListener("turbo:before-fetch-request", (event) => {
  if (acceptsTurboStream(event.detail.fetchOptions.headers) && isWidgetEventTarget(event.target)) {
    if (event.target.dataset) event.target.dataset.widgetLoadingRequest = "true"
    setWidgetLoading(true)
  }
})

document.addEventListener("turbo:before-fetch-response", (event) => {
  if (event.target.dataset?.widgetLoadingRequest === "true" || isWidgetEventTarget(event.target)) {
    if (event.target.dataset) delete event.target.dataset.widgetLoadingRequest
    setWidgetLoading(false)
  }
})

document.addEventListener("turbo:fetch-request-error", (event) => {
  if (event.target.dataset?.widgetLoadingRequest === "true" || isWidgetEventTarget(event.target)) {
    if (event.target.dataset) delete event.target.dataset.widgetLoadingRequest
    setWidgetLoading(false)
  }
})

document.addEventListener("click", (event) => {
  const closeButton = event.target.closest?.(".widget-close-btn")
  if (!closeButton) return

  event.preventDefault()
  if (window.parent !== window) {
    window.parent.postMessage({ type: "deskbolic:close" }, "*")
  }
})
