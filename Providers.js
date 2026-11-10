.pragma library

// Marks and refresh targets for the monitors this panel knows by name. Any
// other record with a `history` array still gets a tab, with the default
// mark and no refresh button.
var known = {
  // nf-md-domino_mask (U+F1023), a Venetian carnival mask.
  venice: { glyph: "\uDB84\uDC23", refreshTarget: "io.github.reneil1337.venice" },
  // nf-md-router_network (U+F1087): a proxy routing to many models.
  litellm: { glyph: "\uDB84\uDC87", refreshTarget: "io.github.reneil1337.litellm" },
  // nf-md-robot_excited (U+F16A3), the agents panel's own agent mark.
  claude: { glyph: "\uDB85\uDEA3", refreshArgv: ["omarchy-agent-usage-update", "claude"] }
}

// nf-md-chart_bar (U+F0128): the bar icon and the fallback mark.
var defaultGlyph = "\uDB80\uDD28"

var defaultOrder = ["venice", "litellm"]

function glyphFor(id) {
  return known[id] ? known[id].glyph : defaultGlyph
}

function refreshTargetFor(id) {
  return known[id] ? known[id].refreshTarget : ""
}

// How to ask a provider to collect again: a monitor's service over IPC, or
// the stock agents collector for a coding agent.
function refreshArgvFor(id) {
  if (known[id] && known[id].refreshArgv) return known[id].refreshArgv
  var target = refreshTargetFor(id)
  return target === "" ? [] : ["omarchy-shell", "-q", target, "refresh"]
}

// Known monitors first in their usual order, then the rest by id.
function sortIds(ids) {
  return ids.slice().sort(function(a, b) {
    var ra = defaultOrder.indexOf(a)
    var rb = defaultOrder.indexOf(b)
    if (ra < 0) ra = defaultOrder.length
    if (rb < 0) rb = defaultOrder.length
    return ra - rb || (a < b ? -1 : a > b ? 1 : 0)
  })
}
