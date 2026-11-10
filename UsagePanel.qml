import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "UsageModel.js" as Model
import "Providers.js" as Providers
import "Plugin.js" as Plugin

// The usage dashboard the stock agents panel stopped drawing in Omarchy 4.5:
// totals with trends, tokens by day, week, month, quarter, or year, and
// tokens by model. One tab per usage record that carries a `history` array
// (the Venice and LiteLLM monitors write one), read straight from the agents
// usage directory; the stock agents panel keeps limits and balances. Shared
// verbatim by the Venice and LiteLLM monitors; only Plugin.js differs, and
// either monitor's widget shows every tab.
Panel {
  id: root
  moduleName: Plugin.pluginId
  ipcTarget: Plugin.pluginId + ".usage"
  manageIpc: false

  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Commons.Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string usageDir: stateHome + "/omarchy/agents/usage"
  readonly property int maxRecordBytes: 4 * 1024 * 1024
  readonly property int maxRecords: 64

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ------------------------------------------------------------- discovery

  property var recordIds: []
  property int dataRevision: 0

  Process {
    id: listProcess
    running: false
    command: ["find", root.usageDir, "-maxdepth", "1", "-type", "f", "-name", "*.json", "-printf", "%f\n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyListing(text)
    }
  }

  function rescan() {
    if (!listProcess.running) listProcess.running = true
  }

  function applyListing(output) {
    var ids = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length && ids.length < maxRecords; i++) {
      var match = lines[i].trim().match(/^([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.json$/)
      if (match) ids.push(match[1])
    }
    ids.sort()
    if (JSON.stringify(ids) !== JSON.stringify(recordIds)) recordIds = ids
  }

  Instantiator {
    id: recordFiles
    model: root.recordIds
    delegate: RecordFile {
      required property var modelData
      recordId: modelData
    }
    onObjectAdded: root.dataRevision++
    onObjectRemoved: root.dataRevision++
  }

  function reloadRecords() {
    for (var i = 0; i < recordFiles.count; i++) {
      var file = recordFiles.objectAt(i)
      if (file) file.reload()
    }
  }

  // Every record with a history gets a tab; the agents panel's own records,
  // which carry only the last seven days, stay with the agents panel.
  readonly property var providers: {
    var rev = dataRevision
    var byId = {}
    for (var i = 0; i < recordFiles.count; i++) {
      var file = recordFiles.objectAt(i)
      if (file && file.data) byId[file.recordId] = file
    }
    return Providers.sortIds(Object.keys(byId)).map(function(id) {
      var data = byId[id].data
      return {
        id: id,
        name: data.name !== "" ? data.name : id,
        glyph: Providers.glyphFor(id),
        refreshArgv: Providers.refreshArgvFor(id),
        data: data
      }
    })
  }

  // ------------------------------------------------------------------ data

  property string selectedId: ""
  property string refreshingId: ""
  property double nowMs: Date.now()
  property string range: "week"
  property bool cursorActive: false

  readonly property int selectedIndex: {
    for (var i = 0; i < providers.length; i++) if (providers[i].id === selectedId) return i
    return 0
  }
  readonly property var current: providers.length > 0 ? providers[selectedIndex] : null
  readonly property var record: current ? current.data : null
  readonly property bool refreshing: !!current && refreshingId === current.id
  readonly property bool alarming: {
    for (var i = 0; i < providers.length; i++) if (balanceAlarming(providers[i].data.balance)) return true
    return false
  }

  readonly property string today: Model.todayString(nowMs)
  readonly property var ranges: Model.availableRanges(record)
  readonly property string activeRange: ranges.indexOf(range) >= 0 ? range : "week"
  readonly property var days: record ? Model.windowDays(record, activeRange, today) : []
  readonly property var previousDays: record ? Model.previousWindowDays(record, activeRange, today) : []
  readonly property var totals: Model.summarize(days)
  readonly property var previousTotals: previousDays.length > 0 ? Model.summarize(previousDays) : null
  readonly property var columns: Model.buckets(days, activeRange)
  readonly property real columnPeak: Math.max(1, Model.peakTokens(columns))
  // modelUsage covers the record's last seven days, so its split only
  // matches the week view while the record is current.
  readonly property bool splitMatches: activeRange === "week" && !!record
    && record.history.length > 0 && record.history[record.history.length - 1].date === today
  readonly property var models: record
    ? Model.modelRows(record, days, 5, splitMatches)
    : ({ rows: [], otherCount: 0, otherTotal: 0, total: 0 })
  readonly property var tiles: buildTiles()

  function refresh() {
    if (!current || current.refreshArgv.length === 0) return
    refreshingId = current.id
    refreshTimeout.restart()
    Quickshell.execDetached(current.refreshArgv)
  }

  function refreshAll() {
    for (var i = 0; i < providers.length; i++) {
      if (providers[i].refreshArgv.length > 0) Quickshell.execDetached(providers[i].refreshArgv)
    }
  }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedId = providers[wrapped].id
    if (panelFlick) panelFlick.contentY = 0
  }

  function selectRange(value) {
    if (ranges.indexOf(value) >= 0) range = value
  }

  function stepRange(step) {
    var index = ranges.indexOf(activeRange)
    if (index < 0 || ranges.length === 0) return
    range = ranges[Math.max(0, Math.min(ranges.length - 1, index + step))]
  }

  // ------------------------------------------------------------ formatting

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function formatTokens(n) {
    var parts = Model.tokenParts(n)
    return Commons.I18n.formatNumber(parts.value, parts.decimals) + parts.unit
  }

  function formatCount(n) {
    return n >= 10000 ? formatTokens(n) : Commons.I18n.formatNumber(Math.round(n))
  }

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + Commons.I18n.formatNumber(amount, Math.abs(amount) >= 100000 ? 0 : 2)
  }

  function locale() { return Qt.locale(Commons.I18n.formatLocale) }

  function shortDay(date) {
    return locale().dayName([7, 1, 2, 3, 4, 5, 6][Model.parseDate(date).getDay()], Locale.ShortFormat)
  }

  function shortDate(date) {
    return Model.parseDate(date).toLocaleDateString(locale(), "MMM d")
  }

  function longDate(date) {
    return Model.parseDate(date).toLocaleDateString(locale(), "ddd, MMM d")
  }

  function monthLabel(date, long) {
    return Model.parseDate(date).toLocaleDateString(locale(), long ? "MMMM yyyy" : "MMM")
  }

  function updatedText() {
    if (!record) return strings.t("panel.noData")
    if (refreshing) return strings.t("panel.refreshing")
    if (!(record.updatedAt > 0)) return current.name
    var minutes = Math.max(0, Math.floor((nowMs - record.updatedAt) / 60000))
    if (minutes < 1) return strings.t("panel.updatedJustNow")
    if (minutes < 60) return strings.tn("panel.updatedMinutes", minutes).arg(Commons.I18n.formatNumber(minutes))
    var hours = Math.floor(minutes / 60)
    if (hours < 48) return strings.tn("panel.updatedHours", hours).arg(Commons.I18n.formatNumber(hours))
    var daysAgo = Math.floor(hours / 24)
    return strings.tn("panel.updatedDays", daysAgo).arg(Commons.I18n.formatNumber(daysAgo))
  }

  function rangeLabel(value) { return strings.t("range." + value) }

  // The exact days behind every total, so a rolling window can't be mistaken
  // for a calendar week or month.
  function windowCaption() {
    if (!record || days.length === 0) return ""
    return strings.t("caption." + activeRange)
      .arg(shortDate(days[0].date)).arg(shortDate(days[days.length - 1].date))
  }

  function trendText(current, previous) {
    var delta = Model.change(current, previous)
    if (delta === null) return ""
    var percent = Math.round(Math.abs(delta) * 100)
    if (percent === 0) return strings.t("trend.flat")
    return (delta > 0 ? "▲ " : "▼ ") + strings.t("trend.percent").arg(Commons.I18n.formatNumber(Math.min(percent, 999)))
  }

  function previousText(value) {
    return strings.t("previous." + activeRange).arg(value)
  }

  // Three tiles: tokens and, when the record has them, requests and cost.
  // A record without cost gets the daily average in that slot.
  function buildTiles() {
    var prev = previousTotals
    var out = [{
      label: strings.t("stat.tokens"),
      value: formatTokens(totals.tokens),
      trend: prev ? trendText(totals.tokens, prev.tokens) : "",
      tooltip: root.tileTooltip(prev ? previousText(formatTokens(prev.tokens)) : "")
    }]
    if (record && record.hasRequests) {
      out.push({
        label: strings.t("stat.requests"),
        value: formatCount(totals.requests),
        trend: prev ? trendText(totals.requests, prev.requests) : "",
        tooltip: root.tileTooltip(prev ? previousText(formatCount(prev.requests)) : "")
      })
    }
    if (record && record.hasCost && totals.hasCost) {
      out.push({
        label: strings.t("stat.cost"),
        value: formatMoney(totals.cost, "USD"),
        trend: prev && prev.hasCost ? trendText(totals.cost, prev.cost) : "",
        tooltip: root.tileTooltip(prev && prev.hasCost ? previousText(formatMoney(prev.cost, "USD")) : "")
      })
    }
    if (out.length < 3) {
      var span = Math.max(1, totals.known)
      out.push({
        label: strings.t("stat.perDay"),
        value: formatTokens(totals.tokens / span),
        trend: "",
        tooltip: root.tileTooltip(strings.tn("stat.activeDays", totals.activeDays).arg(Commons.I18n.formatNumber(totals.activeDays)))
      })
    }
    return out
  }

  function tileTooltip(detail) {
    var lines = [windowCaption()]
    if (detail !== "") lines.push(detail)
    return lines.filter(function(line) { return line !== "" }).join("\n")
  }

  function chartTitle() {
    if (activeRange === "quarter") return strings.t("section.byWeek")
    if (activeRange === "year") return strings.t("section.byMonth")
    return strings.t("section.byDay")
  }

  function peakText() {
    if (!totals.peak || totals.peak.tokens <= 0) return ""
    var label = activeRange === "week" ? shortDay(totals.peak.date) : shortDate(totals.peak.date)
    return strings.t("chart.peak").arg(label).arg(formatTokens(totals.peak.tokens))
  }

  function axisLabel(bucket) {
    if (!bucket) return ""
    if (activeRange === "year") return bucket.current ? strings.t("chart.thisMonth") : monthLabel(bucket.key, false)
    if (activeRange === "quarter") return bucket.current ? strings.t("chart.thisWeek") : shortDate(bucket.key)
    return bucket.current ? strings.t("chart.today") : shortDate(bucket.key)
  }

  function usageLines(tokens, requests, cost, hasCost) {
    var parts = [strings.tn("tooltip.tokens", tokens).arg(formatTokens(tokens))]
    if (record && record.hasRequests)
      parts.push(strings.tn("tooltip.requests", requests).arg(formatCount(requests)))
    if (hasCost) parts.push(formatMoney(cost, "USD"))
    return parts.join(" · ")
  }

  function bucketTooltip(bucket) {
    if (!bucket) return ""
    var title
    if (activeRange === "year") title = monthLabel(bucket.key, true)
    else if (activeRange === "quarter") title = shortDate(bucket.key) + " – " + shortDate(Model.addDays(bucket.key, 6))
    else title = longDate(bucket.key)
    if (bucket.known === 0) return title + "\n" + strings.t("tooltip.notRecorded")
    var text = title + "\n" + usageLines(bucket.tokens, bucket.requests, bucket.cost, bucket.hasCost)
    if (bucket.known < bucket.days && !bucket.current)
      text += "\n" + strings.t("tooltip.partial").arg(Commons.I18n.formatNumber(bucket.known)).arg(Commons.I18n.formatNumber(bucket.days))
    return text
  }

  function dayTooltip(day) {
    if (!day) return ""
    if (!day.known) return longDate(day.date) + "\n" + strings.t("tooltip.notRecorded")
    return longDate(day.date) + "\n" + usageLines(day.tokens, day.requests, day.cost || 0, day.cost !== null)
  }

  function modelTooltip(row) {
    if (!row) return ""
    var share = strings.t("model.share").arg(Commons.I18n.formatNumber(Math.round(row.share * 100)))
    if (row.name !== row.id) share = row.id + "\n" + share
    if (!row.split) return share
    return share + "\n" + strings.t("model.split")
      .arg(formatTokens(row.split.input)).arg(formatTokens(row.split.output))
      .arg(formatTokens(row.split.cacheRead)).arg(formatTokens(row.split.cacheWrite))
  }

  function balanceAlarming(b) {
    return !!b && b.funded > 0 && b.remaining / b.funded <= 0.1
  }

  function balanceDetail(b) {
    if (!b || !(b.funded > 0)) return ""
    var key = b.estimated ? "balance.spentEstimated" : "balance.spent"
    return strings.t(key).arg(formatMoney(b.spent, b.currency)).arg(formatMoney(b.funded, b.currency))
  }

  // ------------------------------------------------------------ lifecycle

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    cursorActive = false
    rescan()
    reloadRecords()
    if (panelFlick) panelFlick.contentY = 0
  }

  Component.onCompleted: rescan()

  // A monitor installed later shows up without a restart, and the panel
  // re-reads its records while open: an atomic replace can drop a watch.
  Timer {
    interval: root.opened ? 30000 : 300000
    running: true
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      root.rescan()
      if (root.opened) root.reloadRecords()
    }
  }

  // Only a fallback: the record arriving clears the spinner sooner. A long
  // history window can take minutes to re-walk, so wait before giving up.
  Timer {
    id: refreshTimeout
    interval: 600000
    onTriggered: root.refreshingId = ""
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshAll(); return "ok" }
    function provider(id: string): string {
      for (var i = 0; i < root.providers.length; i++) {
        if (root.providers[i].id === id) {
          root.selectProvider(i)
          return "ok"
        }
      }
      return "unknown: " + root.providers.map(function(p) { return p.id }).join(", ")
    }
    function range(value: string): string {
      if (root.ranges.indexOf(value) < 0) return "unavailable: " + root.ranges.join(", ")
      root.selectRange(value)
      return "ok"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Providers.defaultGlyph
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refreshAll()
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.selectedIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(660))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      implicitHeight: column.implicitHeight
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          if (root.providers.length > 1) root.selectProvider(root.selectedIndex + dx)
          else root.stepRange(dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "r") root.refresh()
        else if (key === "w") root.selectRange("week")
        else if (key === "m") root.selectRange("month")
        else if (key === "q") root.selectRange("quarter")
        else if (key === "y") root.selectRange("year")
        else if (/^[1-9]$/.test(key)) root.selectProvider(Number(key) - 1)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero ----------
          PanelHero {
            id: hero
            // The hero's icon and trailing control resolve `root` to the
            // PanelHero itself, so they reach panel state through these.
            readonly property bool busy: root.refreshing
            signal refreshClicked()
            onRefreshClicked: root.refresh()

            width: parent.width
            readonly property string glyph: root.current ? root.current.glyph : Providers.defaultGlyph
            readonly property bool canRefresh: !!root.current && root.current.refreshArgv.length > 0
            title: root.current ? root.current.name : strings.t("panel.title")
            meta: root.updatedText()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: hero.glyph
                color: hero.foreground
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                visible: hero.canRefresh
                iconText: "󰑐"
                tooltipText: strings.t("action.refresh")
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                enabled: !hero.busy
                onClicked: hero.refreshClicked()
              }
            }
          }

          Column {
            visible: !root.record
            width: parent.width
            spacing: Style.space(6)
            topPadding: Style.space(12)
            bottomPadding: Style.space(12)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("panel.noData")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("panel.noDataHelp")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Providers ----------
          Row {
            id: providerSwitch
            visible: root.providers.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.providers.length > 0
              ? (width - spacing * (root.providers.length - 1)) / root.providers.length
              : 0

            Repeater {
              model: root.providers

              Button {
                required property var modelData
                required property int index
                width: providerSwitch.cellWidth
                text: modelData.name
                iconText: modelData.glyph
                selected: index === root.selectedIndex
                hasCursor: root.cursorActive && index === root.selectedIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.selectProvider(index)
              }
            }
          }

          // ---------- Range ----------
          Row {
            id: rangeSwitch
            visible: !!root.record && root.ranges.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.ranges.length > 0
              ? (width - spacing * (root.ranges.length - 1)) / root.ranges.length
              : 0

            Repeater {
              model: root.ranges

              Button {
                required property var modelData
                width: rangeSwitch.cellWidth
                text: root.rangeLabel(modelData)
                selected: modelData === root.activeRange
                hasCursor: root.cursorActive && root.providers.length <= 1 && modelData === root.activeRange
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.selectRange(modelData)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !!root.record && root.days.length > 0
            width: parent.width
            text: root.windowCaption()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight

            MouseArea {
              id: captionHover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
            }

            PanelToolTip {
              visible: captionHover.containsMouse
              text: strings.t("caption.note")
              fontFamily: root.fontFamily
            }
          }

          // ---------- Totals ----------
          Row {
            id: tileRow
            visible: !!root.record
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.tiles.length > 0
              ? (width - spacing * (root.tiles.length - 1)) / root.tiles.length
              : 0

            Repeater {
              model: root.tiles

              StatTile {
                required property var modelData
                width: tileRow.cellWidth
                tile: modelData
              }
            }
          }

          // ---------- Balance ----------
          PanelSeparator {
            visible: balanceSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            readonly property var balance: root.record ? root.record.balance : null
            readonly property real ratio: balance && balance.funded > 0 ? root.clamp(balance.remaining / balance.funded, 0, 1) : -1

            visible: !!balance
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: strings.t("section.balance").toUpperCase()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                textFormat: Text.PlainText
                text: strings.t("balance.credits")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: balanceSection.balance ? root.formatMoney(balanceSection.balance.remaining, balanceSection.balance.currency) : ""
                color: root.balanceAlarming(balanceSection.balance) ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming(balanceSection.balance)
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetail(balanceSection.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- Tokens over time ----------
          PanelSeparator {
            visible: chartSection.visible
            foreground: root.foreground
          }

          Column {
            id: chartSection
            visible: !!root.record && root.days.length > 0
            width: parent.width
            spacing: Style.spacing.md

            SectionHeading {
              width: parent.width
              text: root.chartTitle()
              trailing: root.peakText()
            }

            Column {
              visible: root.activeRange === "week"
              width: parent.width
              spacing: 0

              Repeater {
                model: root.activeRange === "week" ? root.days : []

                DayRow {
                  required property var modelData
                  width: chartSection.width
                  day: modelData
                  ratio: modelData.tokens / root.columnPeak
                  today: modelData.date === root.today
                }
              }
            }

            ColumnChart {
              visible: root.activeRange !== "week"
              width: parent.width
              columns: root.activeRange !== "week" ? root.columns : []
              peak: root.columnPeak
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.rows.length > 0
            width: parent.width
            spacing: Style.space(6)

            SectionHeading {
              width: parent.width
              text: strings.t("section.byModel")
              trailing: root.models.rows.length > 1 || root.models.otherCount > 0
                ? strings.tn("model.count", root.models.rows.length + root.models.otherCount)
                    .arg(Commons.I18n.formatNumber(root.models.rows.length + root.models.otherCount))
                : ""
            }

            Repeater {
              model: root.models.rows

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                share: modelData.total / Math.max(1, root.models.rows[0].total)
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.models.otherCount > 0
              width: parent.width
              leftPadding: Style.space(8)
              text: strings.tn("model.more", root.models.otherCount)
                .arg(Commons.I18n.formatNumber(root.models.otherCount))
                .arg(root.formatTokens(root.models.otherTotal))
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  // One usage record, followed on disk. Only a record with a `history` array
  // yields data; the stock agents' records stay with the agents panel.
  component RecordFile: Item {
    id: recordFile
    property string recordId: ""
    property var data: null
    property string parsedText: ""

    visible: false

    function reload() { file.reload() }

    function clear() {
      if (data === null && parsedText === "") return
      parsedText = ""
      data = null
      root.dataRevision++
    }

    function parse(content) {
      var text = String(content || "")
      if (text === parsedText) return
      if (text.length > root.maxRecordBytes) {
        console.warn(root.moduleName, "Ignoring oversized usage record", file.path)
        clear()
        return
      }
      var next = null
      try {
        var raw = JSON.parse(text)
        if (raw && typeof raw === "object") {
          var parsed = Model.normalize(raw)
          // A monitor's long history, or an agent collector's seven-day
          // window with real numbers, earns a tab; empty records do not.
          if (parsed && parsed.hasUsage) next = parsed
        }
      } catch (e) {
        console.warn(root.moduleName, "Ignoring bad usage record", file.path, e)
      }
      parsedText = text
      data = next
      if (root.refreshingId === recordId) root.refreshingId = ""
      root.dataRevision++
    }

    FileView {
      id: file
      path: root.usageDir + "/" + recordFile.recordId + ".json"
      watchChanges: true
      printErrors: false
      onFileChanged: reload()
      onLoaded: recordFile.parse(text())
      onLoadFailed: recordFile.clear()
    }
  }

  component SectionHeading: Item {
    id: heading
    property string text: ""
    property string trailing: ""

    implicitHeight: Math.max(headingLabel.implicitHeight, headingTrailing.implicitHeight)

    PanelSectionHeader {
      id: headingLabel
      anchors.left: parent.left
      anchors.right: headingTrailing.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: heading.text.toUpperCase()
      foreground: root.foreground
      fontFamily: root.fontFamily
      elide: Text.ElideRight
    }

    Text {
      id: headingTrailing
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: heading.trailing
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component StatTile: Item {
    id: statTile
    property var tile: null

    implicitHeight: tileColumn.implicitHeight + Style.space(16)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Column {
      id: tileColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: statTile.tile ? statTile.tile.label.toUpperCase() : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.0
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: statTile.tile ? statTile.tile.value : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        // Keeps the tiles level when only some have a trend.
        text: statTile.tile && statTile.tile.trend !== "" ? statTile.tile.trend : " "
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: tileHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: tileHover.containsMouse && !!statTile.tile && statTile.tile.tooltip !== ""
      text: statTile.tile ? statTile.tile.tooltip : ""
      fontFamily: root.fontFamily
    }
  }

  // Rounded track filled to a ratio: what is left of a prepaid balance.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false

    implicitHeight: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
      }
    }
  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: dayHover.containsMouse ? root.alpha(root.foreground, 0.05) : "transparent"
    }

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: dayRow.today ? strings.t("chart.today") : (dayRow.day ? root.shortDay(dayRow.day.date) : "")
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(48)
      elide: Text.ElideRight
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today || dayHover.containsMouse ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: dayRow.day && dayRow.day.known ? root.formatTokens(dayRow.day.tokens) : "—"
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day)
      fontFamily: root.fontFamily
    }
  }

  // Columns for the longer ranges: days for a month, calendar weeks for a
  // quarter, calendar months for a year. The newest column is lit.
  component ColumnChart: Item {
    id: chart
    property var columns: []
    property real peak: 1
    property int hovered: -1

    implicitHeight: bars.height + axis.implicitHeight + Style.space(6)

    Row {
      id: bars
      width: parent.width
      height: Style.space(120)
      spacing: chart.columns.length > 20 ? Style.space(2) : Style.space(5)

      readonly property real barWidth: chart.columns.length > 0
        ? Math.max(1, (width - spacing * (chart.columns.length - 1)) / chart.columns.length)
        : 0

      Repeater {
        model: chart.columns

        Item {
          id: columnItem
          required property var modelData
          required property int index
          readonly property bool lit: modelData.current || chart.hovered === index

          width: bars.barWidth
          height: bars.height

          Rectangle {
            anchors.fill: parent
            radius: Math.min(width / 2, Style.space(3))
            color: columnItem.lit ? root.alpha(root.foreground, 0.08) : root.alpha(root.foreground, 0.04)
          }

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: columnItem.modelData.tokens > 0
              ? Math.max(Style.space(2), parent.height * root.clamp(columnItem.modelData.tokens / chart.peak, 0, 1))
              : 0
            radius: Math.min(width / 2, Style.space(3))
            color: columnItem.lit ? root.foreground : root.alpha(root.foreground, 0.55)

            Behavior on height {
              NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
            }
          }

          MouseArea {
            id: columnHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            onContainsMouseChanged: {
              if (containsMouse) chart.hovered = columnItem.index
              else if (chart.hovered === columnItem.index) chart.hovered = -1
            }
          }

          PanelToolTip {
            visible: columnHover.containsMouse
            text: root.bucketTooltip(columnItem.modelData)
            fontFamily: root.fontFamily
          }
        }
      }
    }

    Item {
      id: axis
      anchors.top: bars.bottom
      anchors.topMargin: Style.space(6)
      width: parent.width
      implicitHeight: axisFirst.implicitHeight

      Text {
        id: axisFirst
        textFormat: Text.PlainText
        anchors.left: parent.left
        text: chart.columns.length > 1 ? root.axisLabel(chart.columns[0]) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        // The hovered column names itself here as well as in its tooltip.
        text: chart.hovered >= 0 && chart.hovered < chart.columns.length
          ? root.axisLabel(chart.columns[chart.hovered]) + " · " + root.formatTokens(chart.columns[chart.hovered].tokens)
          : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        text: chart.columns.length > 0 ? root.axisLabel(chart.columns[chart.columns.length - 1]) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label,
  // scaled to the heaviest model so the top row is always full.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, modelHover.containsMouse ? 0.08 : 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelShare.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelShare
      textFormat: Text.PlainText
      text: modelRow.row ? strings.t("trend.percent").arg(Commons.I18n.formatNumber(Math.round(modelRow.row.share * 100))) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? root.formatTokens(modelRow.row.total) : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      horizontalAlignment: Text.AlignRight
      width: Style.space(44)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
