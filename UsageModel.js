.pragma library

// Pure helpers behind UsagePanel.qml: turn a usage record into day series,
// chart buckets, totals, and model rows. Kept free of QML so the same file
// can be exercised by the offline tests. Records are untrusted input: every
// collection and string is bounded and every number is checked.

var MAX_DAYS = 400
var MAX_MODELS = 300
var MAX_MODEL_NAME = 160
var MAX_PROVIDER_NAME = 60

// minDays is how much history a range needs before it is offered; the first
// bucket of a quarter or year may be partial, never missing.
var RANGES = [
  { value: "week", days: 7, minDays: 1 },
  { value: "month", days: 30, minDays: 30 },
  { value: "quarter", days: 91, minDays: 84 },
  { value: "year", days: 365, minDays: 335 }
]

var DATE_RE = /^\d{4}-\d{2}-\d{2}$/

function count(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? n : 0
}

function money(value) {
  var n = Number(value)
  return isFinite(n) ? n : null
}

function isDate(value) {
  return typeof value === "string" && DATE_RE.test(value) && !isNaN(parseDate(value).getTime())
}

function parseDate(value) {
  var parts = String(value).split("-")
  return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
}

function formatDate(date) {
  return date.getFullYear()
    + "-" + String(date.getMonth() + 1).padStart(2, "0")
    + "-" + String(date.getDate()).padStart(2, "0")
}

function addDays(value, days) {
  var date = parseDate(value)
  date.setDate(date.getDate() + days)
  return formatDate(date)
}

function todayString(nowMs) {
  return formatDate(new Date(nowMs))
}

function cleanName(value, limit) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, limit)
}

function balanceValue(raw) {
  if (!raw || typeof raw !== "object") return null
  var remaining = Number(raw.remaining)
  var funded = Number(raw.funded)
  if (!isFinite(remaining) || remaining < 0) return null
  return {
    remaining: remaining,
    funded: isFinite(funded) && funded > 0 ? funded : 0,
    spent: count(raw.spent),
    currency: cleanName(raw.currency || "USD", 8).toUpperCase() || "USD",
    estimated: raw.estimated === true
  }
}

function updatedAtMs(value) {
  if (typeof value === "number" && isFinite(value) && value > 0) return value
  var parsed = Date.parse(String(value || ""))
  return isFinite(parsed) ? parsed : 0
}

// The record as the panel reads it. History falls back to the 7-day
// recentDays every agents-panel record carries.
function normalize(raw) {
  if (!raw || typeof raw !== "object") return null

  var byDate = {}
  var hasCost = false
  var hasRequests = false
  var source = Array.isArray(raw.history) ? raw.history.slice(-MAX_DAYS) : []
  for (var i = 0; i < source.length; i++) {
    var entry = source[i]
    if (!entry || !isDate(entry.date)) continue
    var cost = money(entry.costUSD)
    if (cost !== null) hasCost = true
    if (entry.requests !== undefined) hasRequests = true
    byDate[entry.date] = { date: entry.date, tokens: count(entry.tokens), requests: count(entry.requests), cost: cost }
  }
  if (Object.keys(byDate).length === 0 && Array.isArray(raw.recentDays)) {
    var recent = raw.recentDays.slice(-MAX_DAYS)
    for (var r = 0; r < recent.length; r++) {
      if (!recent[r] || !isDate(recent[r].date)) continue
      byDate[recent[r].date] = { date: recent[r].date, tokens: count(recent[r].messageCount), requests: 0, cost: null }
    }
  }
  var history = Object.keys(byDate).sort().map(function(date) { return byDate[date] })

  var modelDaily = {}
  var modelCount = 0
  var daily = raw.modelDaily && typeof raw.modelDaily === "object" ? raw.modelDaily : {}
  for (var model in daily) {
    if (modelCount >= MAX_MODELS) break
    var id = cleanName(model, MAX_MODEL_NAME)
    if (id === "" || !Array.isArray(daily[model])) continue
    var points = daily[model].slice(-MAX_DAYS)
    var series = modelDaily[id] || {}
    for (var p = 0; p < points.length; p++) {
      var point = points[p]
      if (!Array.isArray(point) || !isDate(point[0])) continue
      series[point[0]] = (series[point[0]] || 0) + count(point[1])
    }
    if (!modelDaily[id]) modelCount++
    modelDaily[id] = series
  }

  var modelUsage = {}
  var usage = raw.modelUsage && typeof raw.modelUsage === "object" ? raw.modelUsage : {}
  var usageCount = 0
  for (var name in usage) {
    if (usageCount >= MAX_MODELS) break
    var key = cleanName(name, MAX_MODEL_NAME)
    var bucket = usage[name]
    if (key === "" || !bucket || typeof bucket !== "object") continue
    modelUsage[key] = {
      input: count(bucket.inputTokens),
      output: count(bucket.outputTokens),
      cacheRead: count(bucket.cacheReadInputTokens),
      cacheWrite: count(bucket.cacheCreationInputTokens)
    }
    usageCount++
  }

  // A record with a long history, or an agent's seven-day window, only earns
  // a tab once that window holds tokens; model totals alone can be old.
  var hasUsage = false
  for (var d = 0; d < history.length && !hasUsage; d++) hasUsage = history[d].tokens > 0

  return {
    name: cleanName(raw.name, MAX_PROVIDER_NAME),
    history: history,
    byDate: byDate,
    hasCost: hasCost,
    hasRequests: hasRequests,
    modelDaily: modelDaily,
    modelUsage: modelUsage,
    hasUsage: hasUsage,
    balance: balanceValue(raw.balance),
    updatedAt: updatedAtMs(raw.updatedAt)
  }
}

function rangeInfo(value) {
  for (var i = 0; i < RANGES.length; i++) if (RANGES[i].value === value) return RANGES[i]
  return RANGES[0]
}

// Ranges the record has enough history for, shortest first.
function availableRanges(norm) {
  var days = norm && Array.isArray(norm.history) ? norm.history.length : 0
  var out = []
  for (var i = 0; i < RANGES.length; i++) {
    if (i === 0 || days >= RANGES[i].minDays) out.push(RANGES[i].value)
  }
  return out
}

// The first day a range covers. Week and month are rolling; a quarter is
// thirteen calendar weeks starting on Monday, a year twelve calendar months.
function rangeStart(range, today) {
  var date = parseDate(today)
  if (range === "quarter") {
    var weekday = (date.getDay() + 6) % 7
    date.setDate(date.getDate() - weekday - 12 * 7)
    return formatDate(date)
  }
  if (range === "year") return formatDate(new Date(date.getFullYear(), date.getMonth() - 11, 1))
  return addDays(today, -(rangeInfo(range).days - 1))
}

// Every calendar day from start to end inclusive, zero-filled. `known` tells
// a quiet day apart from one the record does not cover.
function daySeries(norm, start, end) {
  var out = []
  if (!norm || !norm.byDate || !isDate(start) || !isDate(end) || start > end) return out
  for (var date = start; date <= end && out.length < MAX_DAYS; date = addDays(date, 1)) {
    var entry = norm.byDate[date]
    out.push({
      date: date,
      tokens: entry ? entry.tokens : 0,
      requests: entry ? entry.requests : 0,
      cost: entry ? entry.cost : null,
      known: !!entry
    })
  }
  return out
}

function windowDays(norm, range, today) {
  return daySeries(norm, rangeStart(range, today), today)
}

// The window of equal length right before this one, for the trend arrows.
// Only offered when the record covers all of it.
function previousWindowDays(norm, range, today) {
  if (!norm || !norm.byDate) return []
  var start = rangeStart(range, today)
  var days = windowDays(norm, range, today).length
  var prevEnd = addDays(start, -1)
  var prevStart = addDays(start, -days)
  var series = daySeries(norm, prevStart, prevEnd)
  for (var i = 0; i < series.length; i++) if (!series[i].known) return []
  return series
}

function summarize(days) {
  var total = { tokens: 0, requests: 0, cost: 0, hasCost: false, activeDays: 0, peak: null, known: 0 }
  for (var i = 0; i < days.length; i++) {
    var day = days[i]
    if (day.known) total.known++
    total.tokens += day.tokens
    total.requests += day.requests
    if (day.cost !== null) {
      total.cost += day.cost
      total.hasCost = true
    }
    if (day.tokens > 0) total.activeDays++
    if (!total.peak || day.tokens > total.peak.tokens) total.peak = day
  }
  return total
}

// Relative change, or null when there is nothing to compare against.
function change(current, previous) {
  if (!(previous > 0)) return null
  return (current - previous) / previous
}

function bucketOf(range, date) {
  if (range === "quarter") {
    var parsed = parseDate(date)
    parsed.setDate(parsed.getDate() - (parsed.getDay() + 6) % 7)
    return formatDate(parsed)
  }
  if (range === "year") return date.slice(0, 7) + "-01"
  return date
}

// Chart columns: days for week and month, calendar weeks for a quarter,
// calendar months for a year. Days the record does not cover stay out of a
// bucket's span so a partial first bucket says what it holds.
function buckets(days, range) {
  var out = []
  var index = {}
  for (var i = 0; i < days.length; i++) {
    var day = days[i]
    var key = bucketOf(range, day.date)
    var bucket = index[key]
    if (!bucket) {
      bucket = { key: key, first: "", last: "", tokens: 0, requests: 0, cost: 0, hasCost: false, known: 0, days: 0 }
      index[key] = bucket
      out.push(bucket)
    }
    bucket.days++
    if (!day.known) continue
    bucket.known++
    if (bucket.first === "") bucket.first = day.date
    bucket.last = day.date
    bucket.tokens += day.tokens
    bucket.requests += day.requests
    if (day.cost !== null) {
      bucket.cost += day.cost
      bucket.hasCost = true
    }
  }
  if (out.length > 0) out[out.length - 1].current = true
  return out
}

function peakTokens(list) {
  var peak = 0
  for (var i = 0; i < list.length; i++) peak = Math.max(peak, list[i].tokens)
  return peak
}

function addSplit(target, split) {
  if (!split) return target
  var out = target || { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  out.input += split.input
  out.output += split.output
  out.cacheRead += split.cacheRead
  out.cacheWrite += split.cacheWrite
  return out
}

// Models by tokens over the window, heaviest first, one row per display
// name so a renamed SKU (`opus-5-5` and `opus-5-5-api`) stays one model. The
// input/output/cache split rides along only when modelUsage covers the same
// days (the 7-day window every collector writes it for).
function modelRows(norm, days, limit, withSplit) {
  var dates = days.map(function(day) { return day.date })
  var byName = {}
  var rows = []
  var grand = 0
  function add(id, total, split) {
    var name = friendlyModelName(id)
    var row = byName[name]
    if (!row) {
      row = { id: id, name: name, total: 0, split: null }
      byName[name] = row
      rows.push(row)
    }
    row.total += total
    row.split = addSplit(row.split, split)
    grand += total
  }
  var daily = norm.modelDaily || {}
  for (var id in daily) {
    var series = daily[id]
    if (!series || typeof series !== "object") continue
    var total = 0
    for (var i = 0; i < dates.length; i++) total += series[dates[i]] || 0
    if (total > 0) add(id, total, withSplit ? (norm.modelUsage[id] || null) : null)
  }
  var usage = norm.modelUsage || {}
  if (rows.length === 0 && withSplit) {
    for (var model in usage) {
      var u = usage[model]
      if (!u || typeof u !== "object") continue
      var sum = u.input + u.output + u.cacheRead + u.cacheWrite
      if (sum > 0) add(model, sum, u)
    }
  }
  rows.sort(function(a, b) { return b.total - a.total || (a.name < b.name ? -1 : 1) })
  for (var r = 0; r < rows.length; r++) rows[r].share = grand > 0 ? rows[r].total / grand : 0
  var shown = rows.slice(0, limit)
  var rest = rows.slice(limit)
  var otherTotal = 0
  for (var o = 0; o < rest.length; o++) otherTotal += rest[o].total
  return { rows: shown, otherCount: rest.length, otherTotal: otherTotal, total: grand }
}

// Compact token counts: 1.2K, 607M, 12B. Decimal formatting is the caller's
// (locale-aware) job; this only picks the unit and the rounded value.
function tokenParts(n) {
  var value = count(n)
  if (value >= 1e9) return { value: value / 1e9, decimals: value >= 1e10 ? 0 : 1, unit: "B" }
  if (value >= 1e6) return { value: value / 1e6, decimals: value >= 1e7 ? 0 : 1, unit: "M" }
  if (value >= 1e3) return { value: value / 1e3, decimals: value >= 1e4 ? 0 : 1, unit: "K" }
  return { value: value, decimals: 0, unit: "" }
}

var WORDS = { gpt: "GPT", openai: "OpenAI", deepseek: "DeepSeek", glm: "GLM", vl: "VL", minimax: "MiniMax" }

function modelWordCase(word) {
  var lower = word.toLowerCase()
  if (WORDS[lower]) return WORDS[lower]
  if (/^\d/.test(word)) return word.toUpperCase()
  return word.charAt(0).toUpperCase() + word.slice(1)
}

// Model ids arrive hyphenated with the version split across segments
// (`claude-opus-5-5-api`, `deepseek-v4-1-flash`). Drop routing prefixes and
// API suffixes, join a number onto a word ending in a digit (Opus 5.5,
// V4.1), and title-case the rest.
function friendlyModelName(id) {
  var name = String(id || "")
  var slash = name.lastIndexOf("/")
  if (slash >= 0 && slash < name.length - 1) name = name.slice(slash + 1)
  name = name.replace(/^claude-/, "").replace(/-api$/, "").replace(/-\d{8}$/, "")
  var parts = name.split(/[-_]/)
  var words = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "") continue
    var last = words.length - 1
    if (/^\d+$/.test(part) && last >= 0 && /\d$/.test(words[last])) words[last] += "." + part
    else words.push(modelWordCase(part))
  }
  return words.length > 0 ? words.join(" ") : String(id || "")
}
