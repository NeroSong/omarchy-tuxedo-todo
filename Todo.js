function parseLine(raw) {
  var text = String(raw).replace(/\r$/, "")
  var body = text.trim()
  var priority = /^\([A-Z]\)(?:\s|$)/.test(body) ? body.slice(1, 2) : ""
  if (priority) body = body.slice(3).trim()
  body = body.replace(/^\d{4}-\d{2}-\d{2}(?:\s+|$)/, "")
  var projects = [], contexts = [], metadata = [], title = [], due = ""
  body.split(/\s+/).forEach(function(word) {
    if (!word) return
    if (/^\+[^+\s]+$/.test(word)) {
      if (projects.indexOf(word.slice(1)) < 0) projects.push(word.slice(1))
    } else if (/^@[^@\s]+$/.test(word)) {
      if (contexts.indexOf(word.slice(1)) < 0) contexts.push(word.slice(1))
    } else if (/^[^\s:]+:[^\s:]+$/.test(word) && !/^[a-z][a-z0-9+.-]*:\/\//i.test(word)) {
      metadata.push(word)
      if (/^due:\d{4}-\d{2}-\d{2}$/.test(word)) due = word.slice(4)
    } else title.push(word)
  })
  return { rawText: text, text: text.trim(), displayText: title.join(" "),
    priority: priority, projects: projects, contexts: contexts, metadata: metadata, due: due }
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
