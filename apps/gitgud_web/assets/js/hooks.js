import React from "react"
import ReactDOM from "react-dom"

import {camelCase, upperFirst} from "lodash"

import hljs from "highlight.js"
import "highlight.js/styles/github-gist.css"

import LiveSocket from "phoenix_live_view"

import * as factory from "./components"
import {CommitLineReview} from "./components"

export default () => {
  document.querySelectorAll("article.message").forEach(flash => {
    flash.querySelector("button.delete").addEventListener("click", event => {
      flash.remove()
    })
  })

  document.querySelectorAll("table.diff-table").forEach(table => {
    table.querySelectorAll("tbody tr:not(.hunk) td.code").forEach(td => {
      let origin = td.classList.contains("origin") ? td : td.previousElementSibling
      td.addEventListener("mouseover", () => origin.classList.add("is-active"))
      td.addEventListener("mouseout", () => origin.classList.remove("is-active"))
    })
  })

  document.querySelectorAll(".code .code-inner").forEach(block => hljs.highlightBlock(block))

  document.querySelectorAll("[data-react-class]").forEach(e => {
    const targetId = document.getElementById(e.dataset.reactTargetId)
    const targetDiv = targetId ? targetId : e
    const reactProps = e.dataset.reactProps ? atob(e.dataset.reactProps) : "{}"
    const reactElement = React.createElement(factory[upperFirst(camelCase(e.dataset.reactClass))], JSON.parse(reactProps))
    ReactDOM.render(reactElement, targetDiv)
  })

  if(document.querySelector("[data-phx-view]")) {
    let liveSocket = new LiveSocket("/live")
    liveSocket.connect()
  }
}
