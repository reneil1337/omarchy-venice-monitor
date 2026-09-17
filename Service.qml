import QtQuick
import Quickshell.Io

Item {
  id: root

  property var shell: null

  readonly property int refreshSec: 600
  readonly property string collector: decodeURIComponent(Qt.resolvedUrl("collector.py").toString().replace(/^file:\/\//, ""))

  Process {
    id: collectorProcess
    running: false

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("io.github.reneil1337.venice", text.trim())
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.log("io.github.reneil1337.venice", text.trim())
    }

    onRunningChanged: {
      if (!collectorProcess.running && root.queuedRefresh) {
        root.queuedRefresh = false
        Qt.callLater(root.runCollector)
      }
    }
  }

  property bool queuedRefresh: false

  function runCollector() {
    if (collectorProcess.running) {
      queuedRefresh = true
      return
    }
    collectorProcess.command = ["python3", root.collector]
    collectorProcess.running = true
  }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runCollector()
  }

  IpcHandler {
    target: "io.github.reneil1337.venice"
    function refresh(): string {
      root.runCollector()
      return "ok"
    }
  }

  Component.onCompleted: console.log("venice-sync service loaded")
}
