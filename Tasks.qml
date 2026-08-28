import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omarchy-tuxedo"
  ipcTarget: "omarchy-tuxedo"

  readonly property string defaultTodoPath: Quickshell.env("HOME") + "/todo.txt"
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/omarchy-tuxedo.json"
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
  property string todoPath: defaultTodoPath
  property bool badgeDueOnly: false
  property bool twoLineDescriptions: false
  property bool filterSidebarOpen: false
  property string sortMode: "sort:due"
  property string panelMode: "tasks"
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

  function donePath() {
    var slash = todoPath.lastIndexOf("/")
    return (slash >= 0 ? todoPath.slice(0, slash + 1) : "") + "done.txt"
  }

  function tuxedoCommand(args) {
    return ["env", "TODO_FILE=" + todoPath, "DONE_FILE=" + donePath(), "tuxedo"].concat(args)
  }

  function completeTask(task) {
    if (!task || actionProcess.running) return
    statusMessage = "Completing…"
    actionProcess.command = tuxedoCommand(["do", String(task.lineNumber)])
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
    statusMessage = "Completing " + numbers.length + " task(s)…"
    actionProcess.command = tuxedoCommand(["do"].concat(numbers.map(String)))
    actionProcess.running = true
  }

  function deleteSelected() {
    if (selectedCount === 0 || actionProcess.running) return
    var numbers = selectedTaskNumbers(true)
    statusMessage = "Deleting " + numbers.length + " task(s)…"
    actionProcess.command = tuxedoCommand(["del"].concat(numbers.map(String)).concat(["-f"]))
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
    statusMessage = "Saving…"
    actionProcess.command = tuxedoCommand(["replace", String(task.lineNumber), value])
    actionProcess.running = true
  }

  function addTask(text) {
    var value = String(text || "").trim()
    if (value === "" || actionProcess.running) return
    statusMessage = "Adding…"
    actionProcess.command = tuxedoCommand(["add", value])
    actionProcess.running = true
  }

  function filterLabel() {
    if (filterKind === "project") return "+" + filterValue
    if (filterKind === "context") return "@" + filterValue
    if (filterKind === "due") return "Due"
    return "All"
  }

  function loadState(raw) {
    var state = null
    try { state = JSON.parse(String(raw || "")) } catch (e) {}
    var savedPath = state ? String(state.todoPath || "").trim() : ""
    todoPath = savedPath.charAt(0) === "/" ? savedPath : defaultTodoPath
    badgeDueOnly = state && state.badgeDueOnly === true
    twoLineDescriptions = state && state.twoLineDescriptions === true
    var savedSort = state ? String(state.sortMode || "") : ""
    sortMode = ["sort:due", "sort:file", "sort:priority"].indexOf(savedSort) >= 0
      ? savedSort
      : "sort:due"
  }

  function saveState() {
    stateFile.setText(JSON.stringify({
      version: 1,
      todoPath: todoPath,
      badgeDueOnly: badgeDueOnly,
      twoLineDescriptions: twoLineDescriptions,
      sortMode: sortMode
    }, null, 2) + "\n")
  }

  function toggleBadgeMode() {
    badgeDueOnly = !badgeDueOnly
    saveState()
  }

  function toggleDescriptionLines() {
    twoLineDescriptions = !twoLineDescriptions
    saveState()
  }

  function cycleSortMode() {
    var modes = ["sort:due", "sort:file", "sort:priority"]
    var current = modes.indexOf(sortMode)
    sortMode = modes[(current + 1) % modes.length]
    saveState()
    taskList.positionViewAtBeginning()
  }

  function showSettings() {
    panelMode = "settings"
    settingsPathField.text = todoPath
    Qt.callLater(function() {
      settingsPathField.forceActiveFocus()
      settingsPathField.selectAll()
    })
  }

  function hideSettings() {
    panelMode = "tasks"
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function saveTodoPath(path) {
    var value = String(path || "").trim()
    if (value.charAt(0) !== "/") {
      statusMessage = "Use an absolute path beginning with /"
      return
    }
    todoPath = value
    saveState()
    statusMessage = ""
    panelMode = "tasks"
    todoFile.reload()
  }

  onOpenedChanged: {
    if (!opened) {
      selectedLines = ({})
      selectionRevision++
      editingLineNumber = 0
      panelMode = "tasks"
      filterSidebarOpen = false
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
      root.statusMessage = "Could not read the configured todo.txt file"
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
        root.statusMessage = "The action could not be completed"
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
      onEntered: if (root.bar) root.bar.showTooltip(root, root.tasks.length + " open tasks")
      onExited: if (root.bar) root.bar.hideTooltip(root)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: indicator
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.panelMode === "settings" ? settingsPathField : searchField
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
          width: parent.width - taskIcon.width - badgeMode.implicitWidth - settingsButton.width - parent.spacing * 3

          Text {
            text: "Tasks"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            text: root.tasks.length + " open · " + root.dueCount + " due · " + root.sortMode
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
            text: root.badgeDueOnly ? "Due" : "All"
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

        PanelActionButton {
          id: settingsButton
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰒓"
          tooltipText: root.panelMode === "settings" ? "Back to tasks" : "Settings"
          foreground: root.dim
          hoverColor: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.heading
          onClicked: root.panelMode === "settings" ? root.hideSettings() : root.showSettings()
        }
      }

      TextField {
        id: searchField
        visible: root.panelMode === "tasks"
        width: parent.width
        placeholderText: "Search tasks"
        foreground: root.foreground
        accent: Color.accent
        font.family: root.fontFamily
        onTextChanged: root.searchText = text
        Keys.onEscapePressed: root.close()
      }

      Row {
        visible: root.panelMode === "tasks"
        width: parent.width
        height: Style.space(34)
        spacing: Style.space(14)

        TextAction {
          id: filterAction
          iconText: "󰈲"
          label: "Filter"
          selected: root.filterSidebarOpen || root.filterKind === "project" || root.filterKind === "context"
          onActivated: root.filterSidebarOpen = !root.filterSidebarOpen
        }
        TextAction { id: sortAction; iconText: "󰒺"; label: "Sort"; onActivated: root.cycleSortMode() }
        TextAction { id: allAction; iconText: "󰄬"; label: "All"; selected: root.filterKind === "all"; onActivated: root.selectFilter("all", "") }
        TextAction { id: dueAction; iconText: "󰃰"; label: "Due"; selected: root.filterKind === "due"; onActivated: root.selectFilter("due", "") }

        Item {
          width: Math.max(0, parent.width - filterAction.width - sortAction.width - allAction.width
            - dueAction.width - lineMode.implicitWidth - parent.spacing * 5)
          height: 1
        }

        Row {
          id: lineMode
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.twoLineDescriptions ? "Two lines" : "One line"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          ToggleSwitch {
            anchors.verticalCenter: parent.verticalCenter
            checked: root.twoLineDescriptions
            trackHeight: Style.space(18)
            foreground: root.foreground
            accent: Color.accent
            onToggled: root.toggleDescriptionLines()
          }
        }
      }

      Rectangle { visible: root.panelMode === "tasks"; width: parent.width; height: 1; color: root.dim; opacity: 0.35 }

      Item {
        id: taskArea
        visible: root.panelMode === "tasks"
        width: parent.width
        height: parent.height - Style.space(root.selectedCount > 0 ? 251 : 205)

        Rectangle {
          id: filterSidebar
          visible: root.filterSidebarOpen
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Style.space(138)
          radius: Style.cornerRadius
          color: Style.normalFillFor(root.foreground, Color.accent)

          Column {
            anchors.fill: parent
          anchors.margins: Style.space(8)
            spacing: Style.space(8)

            Row {
              width: parent.width

              Text {
                width: parent.width - closeFilters.width
                anchors.verticalCenter: parent.verticalCenter
                text: "Filters"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              PanelActionButton {
                id: closeFilters
                iconText: "×"
                tooltipText: "Close filters"
                foreground: root.dim
                hoverColor: root.foreground
                onClicked: root.filterSidebarOpen = false
              }
            }

            Flickable {
              width: parent.width
              height: parent.height - Style.space(32)
              contentWidth: width
              contentHeight: sidebarColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: sidebarColumn
                width: parent.width
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  text: "Projects"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Repeater {
                  model: root.projects
                  TextAction {
                    required property string modelData
                    width: sidebarColumn.width
                    label: "+" + modelData
                    leftAlign: true
                    selected: root.filterKind === "project" && root.filterValue === modelData
                    onActivated: root.selectFilter("project", modelData)
                  }
                }

                Text {
                  width: parent.width
                  topPadding: Style.space(8)
                  text: "Contexts"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Repeater {
                  model: root.contexts
                  TextAction {
                    required property string modelData
                    width: sidebarColumn.width
                    label: "@" + modelData
                    leftAlign: true
                    selected: root.filterKind === "context" && root.filterValue === modelData
                    onActivated: root.selectFilter("context", modelData)
                  }
                }
              }
            }
          }
        }

        ListView {
          id: taskList
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.right: parent.right
          width: parent.width - (root.filterSidebarOpen ? filterSidebar.width + Style.space(8) : 0)
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
          height: Style.space(editing ? 52 : (root.twoLineDescriptions ? 64 : 48))
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
                wrapMode: root.twoLineDescriptions ? Text.WordWrap : Text.NoWrap
                maximumLineCount: root.twoLineDescriptions ? 2 : 1
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
              text: modelData.overdue ? "overdue" : modelData.due
              color: modelData.isDue ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelActionButton {
              id: editButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "✎"
              tooltipText: "Edit task"
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
              tooltipText: "Save"
              foreground: root.foreground
              hoverColor: Color.accent
              onClicked: root.saveEditing(taskRow.modelData, editField.text)
            }

            PanelActionButton {
              id: cancelEditButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "×"
              tooltipText: "Cancel"
              foreground: root.dim
              hoverColor: root.urgent
              onClicked: root.cancelEditing()
            }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: root.visibleTasks.length === 0
          text: "No tasks in " + root.filterLabel()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
      }

      Text {
        visible: root.panelMode === "tasks" && root.statusMessage !== ""
        width: parent.width
        text: root.statusMessage
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      TextField {
        id: addField
        visible: root.panelMode === "tasks"
        width: parent.width
        placeholderText: "Add a task — try: pay rent Friday"
        foreground: root.foreground
        accent: Color.accent
        font.family: root.fontFamily
        onAccepted: root.addTask(text)
        Keys.onEscapePressed: root.close()
      }

      Row {
        visible: root.panelMode === "tasks" && root.selectedCount > 0
        width: parent.width
        spacing: Style.space(8)

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Complete (" + root.selectedCount + ")"
          iconText: "✓"
          bordered: true
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          onClicked: root.completeSelected()
        }

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Delete (" + root.selectedCount + ")"
          iconText: "󰆴"
          bordered: true
          foreground: root.urgent
          accent: root.urgent
          fontFamily: root.fontFamily
          onClicked: root.deleteSelected()
        }
      }

      Column {
        visible: root.panelMode === "settings"
        width: parent.width
        spacing: Style.space(12)

        Text {
          width: parent.width
          text: "Todo file"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          width: parent.width
          text: "Choose the absolute path to your todo.txt file. The archive will use done.txt in the same folder."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        TextField {
          id: settingsPathField
          width: parent.width
          placeholderText: root.defaultTodoPath
          foreground: root.foreground
          accent: Color.accent
          font.family: root.fontFamily
          onAccepted: root.saveTodoPath(text)
          Keys.onEscapePressed: root.hideSettings()
        }

        Text {
          visible: root.statusMessage !== ""
          width: parent.width
          text: root.statusMessage
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Save"
            iconText: "✓"
            bordered: true
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: root.saveTodoPath(settingsPathField.text)
          }

          Button {
            width: (parent.width - parent.spacing) / 2
            text: "Cancel"
            iconText: "×"
            bordered: true
            foreground: root.dim
            accent: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.hideSettings()
          }
        }
      }
    }
  }

  component TextAction: Item {
    id: action
    required property string label
    property string iconText: ""
    property bool selected: false
    property bool leftAlign: false
    signal activated()
    implicitWidth: actionRow.implicitWidth
    implicitHeight: Style.space(24)
    width: implicitWidth
    height: implicitHeight

    Row {
      id: actionRow
      anchors.left: action.leftAlign ? parent.left : undefined
      anchors.horizontalCenter: action.leftAlign ? undefined : parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        id: actionIcon
        visible: action.iconText !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: action.iconText
        color: action.selected || actionMouse.containsMouse ? Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: action.leftAlign
          ? Math.max(0, action.width - (actionIcon.visible ? actionIcon.width + actionRow.spacing : 0))
          : implicitWidth
        text: action.label
        color: action.selected ? Color.accent : (actionMouse.containsMouse ? root.foreground : root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: action.selected
        font.underline: actionMouse.containsMouse
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.activated()
    }
  }
}
