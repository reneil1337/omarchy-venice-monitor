import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null

  readonly property string pluginDir: decodeURIComponent(
    Qt.resolvedUrl("Service.qml").toString().replace(/^file:\/\//, "").replace(/\/[^/]*$/, ""))
  readonly property string collector: root.pluginDir + "/collector.py"

  // Ten minutes by default. config.json may set refreshSec (60–86400) for a
  // slow API: refreshes are incremental (the collector caches per-day totals
  // and re-reads only the last two days), but the very first build of a long
  // window walks it whole.
  readonly property int refreshSec: configuredRefreshSec
  property int configuredRefreshSec: 600

  FileView {
    id: configFile
    path: root.pluginDir + "/config.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onFileChanged: reload()
  }

  function applyConfig(raw) {
    var seconds = 600
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed && parsed.refreshSec !== undefined) seconds = Number(parsed.refreshSec)
    } catch (e) { }
    if (!isFinite(seconds)) seconds = 600
    configuredRefreshSec = Math.max(60, Math.min(86400, Math.round(seconds)))
  }

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
