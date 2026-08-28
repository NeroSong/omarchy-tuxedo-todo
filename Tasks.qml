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

  onOpenedChanged: {
    if (!opened) return
    todoFile.reload()
    statusMessage = ""
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  Component.onCompleted: todoFile.reload()

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
      text: "☑"
      color: root.barForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body + 2
    }

    Rectangle {
      visible: root.tasks.length > 0
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: 1
      anchors.topMargin: 2
      width: Math.max(Style.space(14), countText.implicitWidth + Style.space(5))
      height: Style.space(14)
      radius: height / 2
      color: root.tasks.some(function(task) { return task.isDue }) ? root.urgent : Color.accent

      Text {
        id: countText
        anchors.centerIn: parent
        text: root.tasks.length > 99 ? "99+" : String(root.tasks.length)
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
          text: "☑"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading + 3
        }

        Column {
          width: parent.width - Style.space(48)

          Text {
            text: "Tarefas"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            text: root.tasks.length + " abertas · " + root.tasks.filter(function(task) { return task.isDue }).length + " vencendo"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
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
        height: parent.height - Style.space(205)
        model: root.visibleTasks
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
          required property var modelData
          width: ListView.view.width
          height: Style.space(48)
          radius: Style.cornerRadius
          color: taskMouse.containsMouse ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(5)
            anchors.rightMargin: Style.space(5)
            spacing: Style.space(9)

            Rectangle {
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
                opacity: taskMouse.containsMouse ? 1 : 0
                font.pixelSize: Style.font.caption
              }
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(116)
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
                visible: modelData.projects.length > 0 || modelData.contexts.length > 0
                text: modelData.projects.map(function(v) { return "+" + v }).concat(modelData.contexts.map(function(v) { return "@" + v })).join("  ")
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(80)
              horizontalAlignment: Text.AlignRight
              text: modelData.overdue ? "atrasada" : modelData.due
              color: modelData.isDue ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: taskMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.completeTask(modelData)
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
