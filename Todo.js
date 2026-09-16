function parseLine(raw) {
  var text = String(raw).replace(/\r$/, "")
  var body = text.trim()
  var priority = /^\([A-Z]\)(?:\s|$)/.test(body) ? body.slice(1, 2) : ""
  if (priority) body = body.slice(3).trim()
  body = body.replace(/^\d{4}-\d{2}-\d{2}(?:\s+|$)/, "")
  var projects = [], contexts = [], metadata = [], title = [], due = ""
  var words = body.match(/(?:[^\s"]|"[^"]*")+/g) || []
  words.forEach(function(word) {
    if (!word) return
    if (/^\+[^+\s]+$/.test(word)) {
      if (projects.indexOf(word.slice(1)) < 0) projects.push(word.slice(1))
    } else if (/^@[^@\s]+$/.test(word)) {
      if (contexts.indexOf(word.slice(1)) < 0) contexts.push(word.slice(1))
    } else if (/^[^\s:]+:(?:"[^"]*"|[^\s:]+)$/.test(word) && !/^[a-z][a-z0-9+.-]*:\/\//i.test(word)) {
      metadata.push(word)
      if (/^due:\d{4}-\d{2}-\d{2}$/.test(word)) due = word.slice(4)
    } else title.push(word)
  })
  return { rawText: text, text: text.trim(), displayText: title.join(" "),
    priority: priority, projects: projects, contexts: contexts, metadata: metadata, due: due }
}

function parseCompletedLine(raw) {
  var text = String(raw).replace(/\r$/, "")
  var body = text.trim().replace(/^x(?:\s+|$)/, "")
  var completed = /^\d{4}-\d{2}-\d{2}(?:\s+|$)/.test(body) ? body.slice(0, 10) : ""
  if (completed) body = body.slice(10).trim()
  var task = parseLine(body)
  task.rawText = text
  task.text = text.trim()
  task.completed = true
  task.completedDate = completed
  return task
}

function escapeHtml(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

function metadataHtml(task, color, contextColor) {
  var tags = (task.priority ? ["(" + task.priority + ")"] : [])
    .concat(task.projects.map(function(v) { return "+" + v }))
  var groups = []
  if (tags.length) groups.push(escapeHtml(tags.join("  ")))
  if (task.contexts.length) groups.push('<font color="' + escapeHtml(contextColor) + '">'
    + escapeHtml(task.contexts.map(function(v) { return "@" + v }).join("  ")) + '</font>')
  if (task.metadata.length) groups.push('<font color="' + escapeHtml(color) + '">'
    + escapeHtml(task.metadata.join("  ")) + '</font>')
  return groups.join("  ")
}

function counts(tasks, field) {
  var result = Object.create(null)
  tasks.forEach(function(task) {
    task[field].forEach(function(value) { result[value] = (result[value] || 0) + 1 })
  })
  return result
}

function fuzzyMatch(value, query) {
  var haystack = String(value).toLowerCase()
  var needle = String(query).toLowerCase()
  var needleIndex = 0
  for (var i = 0; i < haystack.length && needleIndex < needle.length; i++) {
    if (haystack[i] === needle[needleIndex]) needleIndex++
  }
  return needleIndex === needle.length
}

function matchesSearch(task, query) {
  var tokens = String(query || "").trim().split(/\s+/).filter(function(token) { return token !== "" })
  return tokens.every(function(token) {
    if (/^in:(?:open|all|done|due|rec)$/i.test(token)) return true
    var values = String(task.text).split(/\s+/)
    var needle = token
    if (token.length > 1 && token[0] === "+") {
      values = task.projects
      needle = token.slice(1)
    } else if (token.length > 1 && token[0] === "@") {
      values = task.contexts
      needle = token.slice(1)
    }
    return values.some(function(value) { return fuzzyMatch(value, needle) })
  })
}

function searchScope(query) {
  var scope = "open"
  String(query || "").trim().split(/\s+/).forEach(function(token) {
    var match = token.toLowerCase().match(/^in:(open|all|done|due|rec)$/)
    if (match) scope = match[1]
  })
  return scope
}

function withSearchScope(query, scope) {
  var value = ["open", "all", "done", "due", "rec"].indexOf(scope) >= 0 ? scope : "open"
  var tokens = String(query || "").trim().split(/\s+/).filter(function(token) {
    return token !== "" && !/^in:(?:open|all|done|due|rec)$/i.test(token)
  })
  if (value !== "open") tokens.push("in:" + value)
  return tokens.join(" ")
}

function isRecurring(task) {
  return task.metadata.some(function(value) { return /^rec:/i.test(value) })
}
