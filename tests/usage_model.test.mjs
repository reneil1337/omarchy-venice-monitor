// Offline tests for UsageModel.js (the panel's data logic): node --test tests/
import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import test from "node:test"
import vm from "node:vm"

const source = fs.readFileSync(path.join(import.meta.dirname, "..", "UsageModel.js"), "utf8")
const Model = vm.createContext({})
vm.runInContext(source.replace(/^\.pragma library\s*$/m, ""), Model)
// Values cross a vm realm; compare their JSON shape.
const plain = (value) => JSON.parse(JSON.stringify(value))

function history(end, count, perDay = (i) => ({ tokens: 1000 * (i + 1), requests: i + 1, costUSD: i + 0.5 })) {
  const out = []
  for (let i = 0; i < count; i++) out.push({ date: Model.addDays(end, i - count + 1), ...perDay(i) })
  return out
}

test("normalize bounds and validates untrusted input", () => {
  const norm = Model.normalize({
    name: "Venice\u0000<img src=x>" + "x".repeat(200),
    history: [
      { date: "2026-11-09", tokens: -5, requests: "3", costUSD: "1.5" },
      { date: "not-a-date", tokens: 10 },
      { date: "2026-11-10", tokens: Infinity, requests: null },
    ],
    modelDaily: { ["m".repeat(500)]: [["2026-11-10", 7], ["bad", 9], "junk"] },
    balance: { remaining: -1 },
  })
  assert.equal(norm.name.length, 60)
  assert.ok(!norm.name.includes("\u0000"))
  assert.deepEqual(plain(norm.history.map((d) => d.date)), ["2026-11-09", "2026-11-10"])
  assert.equal(norm.history[0].tokens, 0)
  assert.equal(norm.history[0].requests, 3)
  assert.equal(norm.history[0].cost, 1.5)
  assert.equal(norm.history[1].tokens, 0)
  assert.equal(Object.keys(norm.modelDaily)[0].length, 160)
  assert.equal(norm.balance, null)
  assert.equal(Model.normalize(null), null)
  assert.equal(Model.normalize("text"), null)
})

test("normalize caps oversized collections", () => {
  const big = history("2026-11-10", 1000)
  const daily = {}
  for (let i = 0; i < 1000; i++) daily["model-" + i] = [["2026-11-10", 1]]
  const norm = Model.normalize({ history: big, modelDaily: daily })
  assert.equal(norm.history.length, Model.MAX_DAYS)
  assert.equal(Object.keys(norm.modelDaily).length, Model.MAX_MODELS)
})

test("history falls back to recentDays", () => {
  const norm = Model.normalize({ recentDays: [{ date: "2026-11-10", messageCount: 42 }] })
  assert.equal(norm.history.length, 1)
  assert.equal(norm.history[0].tokens, 42)
  assert.equal(norm.hasCost, false)
  assert.equal(norm.hasRequests, false)
})

test("ranges follow the history length", () => {
  const ranges = (count) => plain(Model.availableRanges(Model.normalize({ history: history("2026-11-10", count) })))
  assert.deepEqual(plain(Model.availableRanges(null)), ["week"])
  assert.deepEqual(ranges(7), ["week"])
  assert.deepEqual(ranges(30), ["week", "month"])
  assert.deepEqual(ranges(365), ["week", "month", "quarter", "year"])
})

test("windows are zero-filled and mark unrecorded days", () => {
  const norm = Model.normalize({ history: [{ date: "2026-11-08", tokens: 5, requests: 1 }] })
  const days = Model.windowDays(norm, "week", "2026-11-10")
  assert.equal(days.length, 7)
  assert.equal(days[0].date, "2026-11-04")
  assert.equal(days[6].date, "2026-11-10")
  assert.equal(days[4].tokens, 5)
  assert.equal(days[4].known, true)
  assert.equal(days[6].known, false)
})

test("quarter buckets are Monday-aligned calendar weeks", () => {
  // 2026-11-10 is a Tuesday.
  const start = Model.rangeStart("quarter", "2026-11-10")
  assert.equal(start, "2026-08-17")
  assert.equal(Model.parseDate(start).getDay(), 1)
  const norm = Model.normalize({ history: history("2026-11-10", 120) })
  const cols = Model.buckets(Model.windowDays(norm, "quarter", "2026-11-10"), "quarter")
  assert.equal(cols.length, 13)
  assert.equal(cols[12].key, "2026-11-09")
  assert.equal(cols[12].days, 2)
  assert.equal(cols[12].current, true)
  assert.equal(cols[0].days, 7)
})

test("year buckets are calendar months and say when they are partial", () => {
  const norm = Model.normalize({ history: history("2026-11-10", 340) })
  const cols = Model.buckets(Model.windowDays(norm, "year", "2026-11-10"), "year")
  assert.equal(cols.length, 12)
  assert.equal(cols[0].key, "2025-12-01")
  assert.equal(cols[11].key, "2026-11-01")
  assert.ok(cols[0].known < cols[0].days)
  assert.equal(cols[0].first, norm.history[0].date)
})

test("summaries, trends, and previous windows", () => {
  const norm = Model.normalize({ history: history("2026-11-10", 14, (i) => ({ tokens: i < 7 ? 100 : 150, requests: 1, costUSD: 1 })) })
  const now = Model.summarize(Model.windowDays(norm, "week", "2026-11-10"))
  const prev = Model.summarize(Model.previousWindowDays(norm, "week", "2026-11-10"))
  assert.equal(now.tokens, 1050)
  assert.equal(prev.tokens, 700)
  assert.equal(now.cost, 7)
  assert.equal(Model.change(now.tokens, prev.tokens), 0.5)
  assert.equal(Model.change(5, 0), null)
  assert.equal(Model.previousWindowDays(norm, "month", "2026-11-10").length, 0)
})

test("model rows merge renamed SKUs and keep the split for the week", () => {
  const norm = Model.normalize({
    modelDaily: {
      "claude-opus-5-5": [["2026-11-09", 30]],
      "claude-opus-5-5-api": [["2026-11-10", 70]],
      "qwen3-6-27b": [["2026-11-10", 50]],
      "tiny": [["2026-11-10", 1]],
    },
    modelUsage: { "claude-opus-5-5-api": { inputTokens: 10, outputTokens: 20, cacheReadInputTokens: 30, cacheCreationInputTokens: 10 } },
  })
  const days = Model.daySeries(norm, "2026-11-04", "2026-11-10")
  const result = Model.modelRows(norm, days, 2, true)
  assert.equal(result.rows[0].name, "Opus 5.5")
  assert.equal(result.rows[0].total, 100)
  assert.equal(result.rows[0].split.output, 20)
  assert.equal(result.rows[1].name, "Qwen3.6 27B")
  assert.equal(result.otherCount, 1)
  assert.equal(result.otherTotal, 1)
  assert.equal(result.total, 151)
  assert.equal(Model.modelRows(norm, days, 5, false).rows[0].split, null)
})

test("friendly model names", () => {
  const cases = {
    "claude-opus-5-5-api": "Opus 5.5",
    "claude-haiku-4-5-20251001": "Haiku 4.5",
    "deepseek-v4-1-flash-1017-uncensored-api": "DeepSeek V4.1 Flash 1017 Uncensored",
    "openai/ds41-flash-local": "Ds41 Flash Local",
    "hosted_vllm/glm-5-3-flash-local": "GLM 5.3 Flash Local",
    "text-embedding-3-small": "Text Embedding 3 Small",
    "gpt-5.6-sol": "GPT 5.6 Sol",
  }
  for (const [id, name] of Object.entries(cases)) assert.equal(Model.friendlyModelName(id), name, id)
})

test("token units", () => {
  assert.deepEqual(plain(Model.tokenParts(999)), { value: 999, decimals: 0, unit: "" })
  assert.deepEqual(plain(Model.tokenParts(1500)), { value: 1.5, decimals: 1, unit: "K" })
  assert.deepEqual(plain(Model.tokenParts(607e6)), { value: 607, decimals: 0, unit: "M" })
  assert.deepEqual(plain(Model.tokenParts(1.2e10)), { value: 12, decimals: 0, unit: "B" })
  assert.equal(Model.tokenParts(-4).value, 0)
})

test("every Text in the panel renders plain text", () => {
  // Record fields such as model ids reach these labels; AutoText would let
  // markup-shaped input (<img src=...>) load a remote resource.
  const qml = fs.readFileSync(path.join(import.meta.dirname, "..", "UsagePanel.qml"), "utf8")
  const blocks = qml.split(/\n\s*Text \{/).slice(1)
  assert.ok(blocks.length > 10)
  // textFormat sits on the first or second line of each block, after any id.
  for (const block of blocks) assert.match(block.split("\n").slice(0, 3).join("\n"), /textFormat: Text\.PlainText/)
})

test("known monitors sort first and unknown ones get the default mark", () => {
  const providers = vm.createContext({})
  vm.runInContext(fs.readFileSync(path.join(import.meta.dirname, "..", "Providers.js"), "utf8")
    .replace(/^\.pragma library\s*$/m, ""), providers)
  assert.deepEqual(plain(providers.sortIds(["zeta", "litellm", "alpha", "venice"])), ["venice", "litellm", "alpha", "zeta"])
  assert.equal(providers.glyphFor("alpha"), providers.defaultGlyph)
  assert.equal(providers.refreshTargetFor("venice"), "io.github.reneil1337.venice")
  assert.equal(providers.refreshTargetFor("alpha"), "")
})

test("half-built records never throw", () => {
  for (const norm of [{}, { history: [] }, { byDate: {} }, { modelDaily: {}, modelUsage: {} }]) {
    assert.doesNotThrow(() => {
      Model.availableRanges(norm)
      Model.windowDays(norm, "week", "2026-11-10")
      Model.previousWindowDays(norm, "month", "2026-11-10")
      Model.modelRows(norm, Model.daySeries(norm, "2026-11-04", "2026-11-10"), 5, true)
    })
  }
  const odd = { history: [], byDate: {}, modelDaily: { broken: undefined }, modelUsage: { also: null } }
  assert.equal(Model.modelRows(odd, Model.daySeries(odd, "2026-11-04", "2026-11-10"), 5, true).rows.length, 0)
})

test("hasUsage separates real records from empty ones", () => {
  assert.equal(Model.normalize({ recentDays: [{ date: "2026-11-10", messageCount: 0 }] }).hasUsage, false)
  assert.equal(Model.normalize({ history: [{ date: "2026-11-10", tokens: 5 }] }).hasUsage, true)
  assert.equal(Model.normalize({ modelUsage: { m: { inputTokens: 1 } } }).hasUsage, false)
  assert.equal(Model.normalize({ recentDays: [{ date: "2026-11-10", messageCount: 9 }],
    modelUsage: { m: { inputTokens: 1 } } }).hasUsage, true)
})

test("refresh commands per provider", () => {
  const providers = vm.createContext({})
  vm.runInContext(fs.readFileSync(path.join(import.meta.dirname, "..", "Providers.js"), "utf8")
    .replace(/^\.pragma library\s*$/m, ""), providers)
  assert.deepEqual(plain(providers.refreshArgvFor("claude")), ["omarchy-agent-usage-update", "claude"])
  assert.deepEqual(plain(providers.refreshArgvFor("venice")), ["omarchy-shell", "-q", "io.github.reneil1337.venice", "refresh"])
  assert.deepEqual(plain(providers.refreshArgvFor("unknown")), [])
})
