import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "lgp.tasks"
  ipcTarget: "lgp.tasks"

  readonly property string todoPath: Quickshell.env("HOME") + "/Dropbox/brain-vaults/journaling/assets/todo.txt"
  readonly property string tuxedoPath: Quickshell.env("HOME") + "/Dropbox/github/lpanebr/dotfiles/bin/.local/bin/lgp-tuxedo"
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/tasks.json"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var tasks: []
  property var projects: []
  property var contexts: []
  property string filterKind: "all"
  property string filterValue: ""
  property string searchText: ""
  property int dataRevision: 0
  property string statusMessage: ""
  property bool badgeDueOnly: false
  property string sortMode: "sort:due"
  property var selectedLines: ({})
  property int selectionRevision: 0
  property int editingLineNumber: 0
  readonly property int dueCount: tasks.filter(function(task) { return task.isDue }).length
  readonly property int badgeCount: badgeDueOnly ? dueCount : tasks.length
  readonly property int selectedCount: {
    var revision = selectionRevision
    return Object.keys(selectedLines).length
  }

  readonly property var visibleTasks: {
    var revision = dataRevision
    var result = []
    var needle = searchText.trim().toLowerCase()
    for (var i = 0; i < tasks.length; i++) {
      var task = tasks[i]
      if (filterKind === "project" && task.projects.indexOf(filterValue) < 0) continue
      if (filterKind === "context" && task.contexts.indexOf(filterValue) < 0) continue
      if (filterKind === "due" && !task.isDue) continue
      if (needle !== "" && task.text.toLowerCase().indexOf(needle) < 0) continue
      result.push(task)
    }
    result.sort(function(a, b) {
      if (sortMode === "sort:file") return a.lineNumber - b.lineNumber
      if (sortMode === "sort:priority") {
        var aPriority = a.priority === "" ? 999 : a.priority.charCodeAt(0) - 65
        var bPriority = b.priority === "" ? 999 : b.priority.charCodeAt(0) - 65
        var priorityOrder = aPriority - bPriority
        return priorityOrder !== 0 ? priorityOrder : a.lineNumber - b.lineNumber
      }
      if (a.due === "" && b.due !== "") return 1
      if (a.due !== "" && b.due === "") return -1
      var dueOrder = a.due.localeCompare(b.due)
      return dueOrder !== 0 ? dueOrder : a.lineNumber - b.lineNumber
    })
    return result
  }

  function todayIso() {
    var d = new Date()
    var month = String(d.getMonth() + 1).padStart(2, "0")
    var day = String(d.getDate()).padStart(2, "0")
    return d.getFullYear() + "-" + month + "-" + day
  }

  function parseTodo(raw) {
    var nextTasks = []
    var projectSet = {}
    var contextSet = {}
    var lines = String(raw || "").split("\n")
    var today = todayIso()

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "" || /^x\s/.test(line)) continue
      var words = line.split(/\s+/)
      var taskProjects = []
      var taskContexts = []
      var due = ""
      for (var j = 0; j < words.length; j++) {
        var word = words[j]
        if (/^\+[^+\s]+$/.test(word)) {
          var project = word.slice(1)
          taskProjects.push(project)
          projectSet[project] = true
        } else if (/^@[^@\s]+$/.test(word)) {
          var context = word.slice(1)
          taskContexts.push(context)
          contextSet[context] = true
        } else if (/^due:\d{4}-\d{2}-\d{2}$/.test(word)) {
          due = word.slice(4)
        }
      }
      nextTasks.push({
        lineNumber: i + 1,
        text: line,
        displayText: displayText(line),
        projects: taskProjects,
        contexts: taskContexts,
        due: due,
        isDue: due !== "" && due <= today,
        overdue: due !== "" && due < today,
        priority: /^\([A-Z]\)\s/.test(line) ? line.slice(1, 2) : ""
      })
    }

    tasks = nextTasks
    projects = Object.keys(projectSet).sort(function(a, b) { return a.localeCompare(b) })
    contexts = Object.keys(contextSet).sort(function(a, b) { return a.localeCompare(b) })
    selectedLines = ({})
    selectionRevision++
    editingLineNumber = 0
    dataRevision++
  }

  function displayText(line) {
    return String(line)
      .replace(/^\([A-Z]\)\s+/, "")
      .replace(/^\d{4}-\d{2}-\d{2}\s+/, "")
      .replace(/\s+(?:due|t|rec):\S+/g, "")
      .replace(/\s+[+@]\S+/g, "")
      .trim()
  }

  function selectFilter(kind, value) {
    filterKind = kind
    filterValue = value || ""
    taskList.positionViewAtBeginning()
  }

  function completeTask(task) {
    if (!task || actionProcess.running) return
    statusMessage = "Concluindo…"
    actionProcess.command = [tuxedoPath, "do", String(task.lineNumber)]
    actionProcess.running = true
  }

  function isSelected(task) {
    var revision = selectionRevision
    return !!task && selectedLines[String(task.lineNumber)] === task.text
  }

  function toggleSelected(task) {
    if (!task || editingLineNumber !== 0) return
    var next = {}
    for (var key in selectedLines) next[key] = selectedLines[key]
    var lineKey = String(task.lineNumber)
    if (next[lineKey] === task.text) delete next[lineKey]
    else next[lineKey] = task.text
    selectedLines = next
    selectionRevision++
  }

  function selectedTaskNumbers(descending) {
    var numbers = []
    for (var key in selectedLines) {
      var lineNumber = Number(key)
      if (isFinite(lineNumber) && selectedLines[key] !== undefined) numbers.push(lineNumber)
    }
    numbers.sort(function(a, b) { return descending ? b - a : a - b })
    return numbers
  }

  function completeSelected() {
    if (selectedCount === 0 || actionProcess.running) return
    var numbers = selectedTaskNumbers(false)
    statusMessage = "Concluindo " + numbers.length + " tarefa(s)…"
    actionProcess.command = [tuxedoPath, "do"].concat(numbers.map(String))
    actionProcess.running = true
  }

  function deleteSelected() {
    if (selectedCount === 0 || actionProcess.running) return
    var numbers = selectedTaskNumbers(true)
    statusMessage = "Excluindo " + numbers.length + " tarefa(s)…"
    actionProcess.command = [tuxedoPath, "del"].concat(numbers.map(String)).concat(["-f"])
    actionProcess.running = true
  }

  function startEditing(task) {
    if (!task || actionProcess.running) return
    selectedLines = ({})
    selectionRevision++
    editingLineNumber = task.lineNumber
  }

  function cancelEditing() {
    editingLineNumber = 0
  }

  function saveEditing(task, text) {
    var value = String(text || "").trim()
    if (!task || value === "" || value === task.text || actionProcess.running) {
      editingLineNumber = 0
      return
    }
    statusMessage = "Salvando…"
    actionProcess.command = [tuxedoPath, "replace", String(task.lineNumber), value]
    actionProcess.running = true
  }

  function addTask(text) {
    var value = String(text || "").trim()
    if (value === "" || actionProcess.running) return
    statusMessage = "Adicionando…"
    actionProcess.command = [tuxedoPath, "add", value]
    actionProcess.running = true
  }

  function filterLabel() {
    if (filterKind === "project") return "+" + filterValue
    if (filterKind === "context") return "@" + filterValue
    if (filterKind === "due") return "Vencendo"
    return "Todos"
  }

  function loadState(raw) {
    var state = null
    try { state = JSON.parse(String(raw || "")) } catch (e) {}
    badgeDueOnly = state && state.badgeDueOnly === true
    var savedSort = state ? String(state.sortMode || "") : ""
    sortMode = ["sort:due", "sort:file", "sort:priority"].indexOf(savedSort) >= 0
      ? savedSort
      : "sort:due"
  }

  function saveState() {
    stateFile.setText(JSON.stringify({
      version: 1,
      badgeDueOnly: badgeDueOnly,
      sortMode: sortMode
    }, null, 2) + "\n")
  }

  function toggleBadgeMode() {
    badgeDueOnly = !badgeDueOnly
    saveState()
  }

  function cycleSortMode() {
    var modes = ["sort:due", "sort:file", "sort:priority"]
    var current = modes.indexOf(sortMode)
    sortMode = modes[(current + 1) % modes.length]
    saveState()
    taskList.positionViewAtBeginning()
  }

  onOpenedChanged: {
    if (!opened) {
      selectedLines = ({})
      selectionRevision++
      editingLineNumber = 0
      return
    }
    todoFile.reload()
    statusMessage = ""
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  Component.onCompleted: {
    todoFile.reload()
    stateFile.reload()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
    onFileChanged: reload()
  }

  FileView {
    id: todoFile
    path: root.todoPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseTodo(text())
    onLoadFailed: {
      root.tasks = []
      root.projects = []
      root.contexts = []
      root.dataRevision++
      root.statusMessage = "Não foi possível ler o todo.txt"
    }
    onFileChanged: reload()
  }

  Process {
    id: actionProcess
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.statusMessage = String(text).trim()
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.statusMessage = ""
        addField.text = ""
      } else if (root.statusMessage === "") {
        root.statusMessage = "A ação não pôde ser concluída"
      }
      todoFile.reload()
    }
  }

  implicitWidth: Style.space(38)
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  Item {
    id: indicator
    anchors.fill: parent

    Text {
      anchors.centerIn: parent
      text: "󰄲"
      color: root.barForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body + 2
    }

    Rectangle {
      visible: root.badgeCount > 0
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: 1
      anchors.topMargin: 2
      width: Math.max(Style.space(14), countText.implicitWidth + Style.space(5))
      height: Style.space(14)
      radius: height / 2
      color: root.badgeDueOnly ? root.urgent : Color.accent

      Text {
        id: countText
        anchors.centerIn: parent
        text: root.badgeCount > 99 ? "99+" : String(root.badgeCount)
        color: Color.background
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption - 1
        font.bold: true
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggle()
      onEntered: if (root.bar) root.bar.showTooltip(root, root.tasks.length + " tarefas abertas")
      onExited: if (root.bar) root.bar.hideTooltip(root)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: indicator
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: searchField
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(Style.space(610), Style.space(680))

    Column {
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(10)

        Text {
          id: taskIcon
          text: "󰄲"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading + 3
        }

        Column {
          width: parent.width - taskIcon.width - badgeMode.implicitWidth - parent.spacing * 2

          Text {
            text: "Tarefas"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            text: root.tasks.length + " abertas · " + root.dueCount + " vencendo · " + root.sortMode
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: badgeMode
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.badgeDueOnly ? "Vencidas" : "Todas"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          ToggleSwitch {
            anchors.verticalCenter: parent.verticalCenter
            checked: root.badgeDueOnly
            trackHeight: Style.space(18)
            foreground: root.foreground
            accent: root.urgent
            onToggled: root.toggleBadgeMode()
          }
        }
      }

      TextField {
        id: searchField
        width: parent.width
        placeholderText: "Buscar tarefas"
        foreground: root.foreground
        accent: Color.accent
        font.family: root.fontFamily
        onTextChanged: root.searchText = text
        Keys.onEscapePressed: root.close()
      }

      Flickable {
        width: parent.width
        height: Style.space(34)
        contentWidth: filterRow.implicitWidth
        contentHeight: height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Row {
          id: filterRow
          spacing: Style.space(6)

          FilterChip { label: "Ordem"; selected: false; onActivated: root.cycleSortMode() }
          FilterChip { label: "Todos"; selected: root.filterKind === "all"; onActivated: root.selectFilter("all", "") }
          FilterChip { label: "Vencendo"; selected: root.filterKind === "due"; onActivated: root.selectFilter("due", "") }

          Repeater {
            model: root.projects
            FilterChip {
              required property string modelData
              label: "+" + modelData
              selected: root.filterKind === "project" && root.filterValue === modelData
              onActivated: root.selectFilter("project", modelData)
            }
          }

          Repeater {
            model: root.contexts
            FilterChip {
              required property string modelData
              label: "@" + modelData
              selected: root.filterKind === "context" && root.filterValue === modelData
              onActivated: root.selectFilter("context", modelData)
            }
          }
        }
      }

      Rectangle { width: parent.width; height: 1; color: root.dim; opacity: 0.35 }

      ListView {
        id: taskList
        width: parent.width
        height: parent.height - Style.space(root.selectedCount > 0 ? 251 : 205)
        model: root.visibleTasks
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          id: taskRow
          required property var modelData
          readonly property bool selected: root.isSelected(modelData)
          readonly property bool editing: root.editingLineNumber === modelData.lineNumber
          width: ListView.view.width
          height: Style.space(editing ? 52 : 48)
          radius: Style.cornerRadius
          color: selected
            ? Style.selectedFillFor(root.foreground, Color.accent)
            : (taskMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")

          MouseArea {
            id: taskMouse
            anchors.fill: parent
            enabled: !taskRow.editing
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleSelected(taskRow.modelData)
          }

          Row {
            visible: !taskRow.editing
            anchors.fill: parent
            anchors.leftMargin: Style.space(5)
            anchors.rightMargin: Style.space(5)
            spacing: Style.space(9)

            Rectangle {
              id: completeBox
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(16)
              height: width
              radius: Math.max(2, Style.cornerRadius / 2)
              color: "transparent"
              border.width: 1
              border.color: modelData.isDue ? root.urgent : root.dim

              Text {
                anchors.centerIn: parent
                text: "✓"
                color: root.foreground
                opacity: completeMouse.containsMouse ? 1 : 0
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: completeMouse
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.completeTask(taskRow.modelData)
              }
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - completeBox.width - dueText.width - editButton.width - parent.spacing * 3
              spacing: 2

              Text {
                width: parent.width
                text: modelData.displayText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: modelData.priority === "A"
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: modelData.priority !== "" || modelData.projects.length > 0 || modelData.contexts.length > 0
                text: (modelData.priority !== "" ? ["(" + modelData.priority + ")"] : [])
                  .concat(modelData.projects.map(function(v) { return "+" + v }))
                  .concat(modelData.contexts.map(function(v) { return "@" + v }))
                  .join("  ")
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Text {
              id: dueText
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(80)
              horizontalAlignment: Text.AlignRight
              text: modelData.overdue ? "atrasada" : modelData.due
              color: modelData.isDue ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelActionButton {
              id: editButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "✎"
              tooltipText: "Editar tarefa"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.body + 2
              onClicked: root.startEditing(taskRow.modelData)
            }
          }

          Row {
            visible: taskRow.editing
            anchors.fill: parent
            anchors.leftMargin: Style.space(4)
            anchors.rightMargin: Style.space(4)
            spacing: Style.space(5)

            TextField {
              id: editField
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - saveEditButton.width - cancelEditButton.width - parent.spacing * 2
              text: taskRow.editing ? taskRow.modelData.text : ""
              foreground: root.foreground
              accent: Color.accent
              font.family: root.fontFamily
              onAccepted: root.saveEditing(taskRow.modelData, text)
              onVisibleChanged: if (visible) Qt.callLater(function() {
                editField.forceActiveFocus()
                editField.selectAll()
              })
              Keys.onEscapePressed: root.cancelEditing()
            }

            PanelActionButton {
              id: saveEditButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "✓"
              tooltipText: "Salvar"
              foreground: root.foreground
              hoverColor: Color.accent
              onClicked: root.saveEditing(taskRow.modelData, editField.text)
            }

            PanelActionButton {
              id: cancelEditButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "×"
              tooltipText: "Cancelar"
              foreground: root.dim
              hoverColor: root.urgent
              onClicked: root.cancelEditing()
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: root.visibleTasks.length === 0
          text: "Nenhuma tarefa em " + root.filterLabel()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Text {
        width: parent.width
        visible: root.statusMessage !== ""
        text: root.statusMessage
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      TextField {
        id: addField
        width: parent.width
        placeholderText: "Adicionar tarefa — ex.: pagar aluguel sexta"
        foreground: root.foreground
        accent: Color.accent
        font.family: root.fontFamily
        onAccepted: root.addTask(text)
        Keys.onEscapePressed: root.close()
      }

      Row {
        visible: root.selectedCount > 0
        width: parent.width
        spacing: Style.space(8)

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Concluir (" + root.selectedCount + ")"
          iconText: "✓"
          bordered: true
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: root.completeSelected()
        }

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Excluir (" + root.selectedCount + ")"
          iconText: "󰆴"
          bordered: true
          foreground: root.urgent
          accent: root.urgent
          fontFamily: root.fontFamily
          onClicked: root.deleteSelected()
        }
      }
    }
  }

  component FilterChip: Rectangle {
    id: chip
    required property string label
    property bool selected: false
    signal activated()
    width: chipText.implicitWidth + Style.space(16)
    height: Style.space(30)
    radius: height / 2
    color: selected ? Color.accent : (chipMouse.containsMouse ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent")
    border.width: selected ? 0 : 1
    border.color: root.dim

    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.label
      color: chip.selected ? Color.background : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: chip.selected
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.activated()
    }
  }
}
