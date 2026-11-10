# Venice Monitor — Omarchy shell plugin

Charts your Venice account usage in the **AI Usage** bar panel and feeds the
credit balance to the **stock `omarchy.agents` panel**, sharing its design and
panel with [LiteLLM Monitor](https://github.com/reneil1337/omarchy-litellm-monitor).

- Tokens by day, requests, and costs, with a per-model input/output/cache
  breakdown.
- **Usage costs displayed in USD: USD charges + DIEM charges, at 1 DIEM = 1 USD.**
- Last-7-days cost, tokens, and tracked request count in the provider heading
  (labeled `reqs` to keep the heading readable; counts remain a lower bound).
- Available credit in USD equivalents and a daily-credit utilization meter.
- Up to 365 days of token, request, and cost history. The default window is 7
  days — see [Sizing historyDays](#sizing-historydays).

A headless service refreshes every **10 minutes** and writes
`~/.local/state/omarchy/agents/usage/venice.json`. Two panels read it:

- **AI Usage** (this plugin's bar widget, see [below](#ai-usage-panel)) draws
  the charts: a Venice tab with totals and trends, tokens by day (week, month, quarter, or year as far as
  `historyDays` reaches), tokens by model, and the balance.
- **`omarchy.agents`** can show the credit balance card and the 7-day
  heading, and counts Venice into its rotating summary line; with the AI
  Usage widget, hide it there (see below). Since Omarchy 4.5 that panel
  draws no charts for any agent, and plugins cannot add any to it.

## Install

```sh
omarchy plugin add https://github.com/reneil1337/omarchy-venice-monitor --enable
```

For the charts, add the AI Usage widget next to the agents icon and restart
the shell once:

```sh
omarchy bar put io.github.reneil1337.venice --after omarchy.agents
omarchy restart shell
```

The balance card needs the first-party `omarchy.agents` plugin enabled:

```sh
omarchy plugin enable omarchy.agents
```

### From a local checkout

Run these commands from this repository to install before publishing it:

```sh
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.reneil1337.venice"
mkdir -p "$plugin_dir"
mkdir -p "$plugin_dir/i18n"
cp manifest.json Service.qml collector.py config.json.example \
  UsagePanel.qml UsageModel.js Providers.js Plugin.js "$plugin_dir/"
cp i18n/*.json "$plugin_dir/i18n/"
omarchy plugin enable io.github.reneil1337.venice
omarchy restart shell
```

## AI Usage panel

Since Omarchy 4.5 the stock agents panel draws no charts for any agent, and
plugins cannot add any to it. This plugin therefore ships its own bar widget,
**AI Usage**: one icon and one panel with a tab per usage source. The
[Venice](https://github.com/reneil1337/omarchy-venice-monitor) and
[LiteLLM](https://github.com/reneil1337/omarchy-litellm-monitor) monitors ship
the same panel, and either one's widget shows a tab for every record in
`~/.local/state/omarchy/agents/usage/` that has usage: a monitor's long
history, or an agent collector's seven-day window with real tokens. That
gives **Claude Code** (and any other agent with recent usage) its old
seven-day day-and-model charts back, which Omarchy 4.5 removed everywhere.
With both monitors installed **add only one AI Usage widget** to the bar:

```sh
omarchy bar put io.github.reneil1337.venice --after omarchy.agents
```

- **Week · Month · Quarter · Year**, offered as far as a record's history
  reaches (30, 84, and 335 days for the longer ones; agents with only the
  seven-day window show Week with their model totals beside it).
  These are windows, not calendar periods: **Week** is the last seven days
  ending today (not Monday–Sunday), **Month** the last 30 days, **Quarter**
  13 Monday-aligned calendar weeks, **Year** 12 calendar months (from the 1st
  of the month 11 months back). The panel prints the exact dates under the
  range buttons, and every total is the sum of the days the chart draws.
- **Totals**: tokens, requests, and cost (tokens per day when a record has no
  cost), with the change against the window before it.
- **Balance**: remaining credits with a gauge that drains toward empty.
- **Tokens over time**: seven rows with today in bold, or columns for the
  longer ranges (days, calendar weeks, calendar months). Hover for details.
- **Tokens by model**: the top five with their share, renamed SKUs merged,
  and the input/output/cache split on hover in the week view.

| Input | Action |
|---|---|
| Click | Open or close the panel |
| Right click | Refresh every monitor |
| Middle click, ← / →, `1`–`9` | Switch tabs |
| `w` `m` `q` `y` | Week, month, quarter, year |
| `r` or Enter | Refresh the current tab |

```sh
omarchy-shell io.github.reneil1337.venice.usage toggle
omarchy-shell io.github.reneil1337.venice.usage provider venice
omarchy-shell io.github.reneil1337.venice.usage range month
```

The refresh button asks the right collector to run again: a monitor's
service over IPC, or `omarchy-agent-usage-update claude` for an agent.

The panel only reads records; it never writes. `UsagePanel.qml`,
`UsageModel.js`, `Providers.js`, and `i18n/` are identical in both monitor
repositories (only `Plugin.js` differs), so copy changes to both.

After installing or updating, run `omarchy restart shell`: the shell indexes
plugin files when it starts and rejects new ones until then (it reports `File
name case mismatch`). A widget that failed to load once is also dropped from
the bar; run the `bar put` again.

### Hide it from the agents panel

The stock agents panel reads the same record and would show a second Venice
section (just the credit balance and the 7-day heading), and count Venice
into its rotating token summary. If you keep the AI Usage widget, turn the
agents-panel copy off; the record and the AI Usage tab are untouched:

```sh
omarchy bar set omarchy.agents providers '{"venice":{"enabled":false}}' --json
```

Add `"litellm":{"enabled":false}` alongside it if the LiteLLM monitor is
installed too. Reverse with `true`.

## Configure

Generate an **Admin** API key for the account you want to monitor at
[Venice → Settings → API](https://venice.ai/settings/api). Venice rejects
**Inference Only** keys on the billing endpoints with
`Admin API key required` — a billing read needs the Admin key type. The
collector only issues read-only `GET` billing calls; it does not create or
manage keys.

Copy the example in the installed plugin folder:

```sh
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.reneil1337.venice"
cp "$plugin_dir/config.json.example" "$plugin_dir/config.json"
chmod 600 "$plugin_dir/config.json"
```

Edit `config.json` and set `apiKey`:

```json
{
  "baseUrl": "https://api.venice.ai/api/v1",
  "apiKey": "your-venice-api-key",
  "historyDays": 7
}
```

Alternatively, set **`VENICE_API_KEY`** in the environment inherited by
Omarchy shell. A nonempty environment variable overrides `apiKey` in the
file. With the default API URL and history window, the environment variable
alone is sufficient; `config.json` is optional. Exporting it in a terminal
only affects collectors launched from that terminal, not an already-running
shell service.

| Setting | Default | Description |
|---|---|---|
| `baseUrl` | `https://api.venice.ai/api/v1` | Full API base URL, including `/api/v1` |
| `apiKey` | empty | Key for the account to monitor |
| `historyDays` | `7` | Local calendar days to retrieve, from 1 to 365 |
| `maxPages` | `1000` | Maximum 1,000-entry pages per 31-day walk; 1 to 10,000 |
| `refreshSec` | `600` | Seconds between refreshes, from 60 to 86,400. Raise it for long windows |

### Sizing historyDays

The first build walks the **entire** configured window in 31-day chunks,
newest first (so month and quarter fill before the year), saving progress
after each chunk, so an interrupted build resumes and a later refresh
continues where it stopped. Every
later refresh re-reads only the last two days (and any day missing from the
cache), which costs a couple of pages. The cache lives at
`${XDG_STATE_HOME:-~/.local/state}/omarchy/venice-monitor/cache.json`
(mode `0600`, outside the agents usage directory); delete it to force a full
rebuild.

7 days covers everything the stock `omarchy.agents` panel reads
(`recentDays`, `modelUsage`, and the 7-day heading) and the AI Usage panel's
week view, so 7 is the default.

The AI Usage panel offers longer views once the history reaches them:

| `historyDays` | Views |
|---|---|
| 1–29 | Week |
| 30–83 | Week, month |
| 84–334 | Week, month, quarter (13 calendar weeks) |
| 335–365 | Week, month, quarter, year (12 calendar months) |

Size the window to your account's ledger density. As a reference, a busy
account (thousands of requests a day, tens of thousands of ledger entries a
month) takes:

| Window | Views | Pages | First build | Each refresh after that |
|---|---|---|---|---|
| 7 days | Week | ~20 | ~6 s | ~2 s |
| 30 days | + Month | ~84 | ~26 s | ~2 s |
| 91 days | + Quarter | ~255 | ~80 s | ~2 s |
| 365 days | + Year | ~1,800 | 10–20 min | ~2 s |

`maxPages` caps one 31-day walk, not the whole window, and `refreshSec` only
needs raising if the API itself is slow for you.

The page counts scale with usage, not with time alone. A window whose walk
exceeds `maxPages` × 1,000 entries fails with

```
Usage history exceeds maxPages; increase it or reduce historyDays in config.json
```

Raising `maxPages` (up to 10,000) only postpones this and makes every
refresh slower and heavier; pair it with a longer `refreshSec` so walks do not
run back to back. If a refresh gets slow or that error appears, reduce
`historyDays` — the shorter views do not change.

### Why the cache

Venice's only aggregated billing route, `GET /billing/usage-analytics` (beta),
accepts at most 90 days and answers in cost and unit totals per top model,
without request counts, so it cannot back the token and request charts.
`/billing/usage-history` is the per-entry ledger: exact, complete, but roughly
84 pages per 30 days on a busy account and about 1,800 pages for a year. The
day cache exists so only the first build pays that cost.

LiteLLM needs no cache: its proxy aggregates server-side, so a full year is a
handful of requests per refresh.

To estimate the pages a window needs, walk it once with the API directly
(continuations send only `cursor`):

```sh
python3 - <<'EOF'
import json, os, urllib.request, urllib.parse
base = "https://api.venice.ai/api/v1"
key = os.environ["VENICE_API_KEY"]
params = {"startTimestamp": "2026-08-01T00:00:00.000Z",
          "endTimestamp": "2026-09-21T00:00:00.000Z", "pageSize": 1000}
pages = total = 0
while pages < 200:
    req = urllib.request.Request(
        base + "/billing/usage-history?" + urllib.parse.urlencode(params),
        headers={"Authorization": "Bearer " + key})
    with urllib.request.urlopen(req) as r:
        payload = json.load(r)
    pages += 1; total += len(payload["data"])
    if not payload["nextCursor"]: break
    params = {"cursor": payload["nextCursor"]}
print(pages, "pages,", total, "entries")
EOF
```

The API selects the account from the key. Billing history is account-wide,
rather than restricted to calls made with the monitoring key, and can include
Venice web-app activity present in the account ledger. The history endpoint
does not expose a per-key filter.

## Usage

Force a refresh:

```sh
omarchy-shell io.github.reneil1337.venice refresh
```

Open the charts, or the agents panel with the balance card:

```sh
omarchy-shell io.github.reneil1337.venice.usage provider venice
omarchy-shell io.github.reneil1337.venice.usage open
omarchy-shell omarchy.agents open
```

Run the collector from this checkout to diagnose configuration or API errors:

```sh
python3 collector.py --config /path/to/config.json --stdout
```

`--stdout` prints the record without writing to the panel's state directory.
Without it, the collector writes under `${XDG_STATE_HOME:-~/.local/state}`.

## How the numbers work

### Costs and balances

Venice ledger charges are negative amounts. The collector negates and sums
**USD + DIEM** entries using decimal arithmetic; positive refunds reduce
spend. For example, `-2.50 USD` and `-3.00 DIEM` display as **$5.50 USD**.
The same calculation supplies the heading, `history[].costUSD`,
`todayCostUSD`, and `totalCostUSD`. Image, audio, video, and other non-token
usage contributes to costs as well.

`BUNDLED_CREDITS` entries are included in token/request statistics when those
details exist, but excluded from USD costs because Venice does not document
a USD exchange rate for them.

The balance card shows remaining USD and DIEM (summed at the same 1:1 rate)
with a gauge that drains toward empty: the DIEM epoch allocation is the full
tank (100%), and what is left of it is the meter. Below the gauge, the card
reports how much has been spent of the funded amount. That figure includes
daily DIEM credits, which renew each epoch; it is not all permanent prepaid
USD. The balance endpoint does not return an epoch reset timestamp, so no
reset countdown is shown.

### Tokens and requests

Venice can produce several ledger entries for one inference (input, output,
cache, and different currencies), repeating the same `inferenceDetails`.
The collector counts those request IDs once across all pages and counts their
prompt/completion totals once per model. Cached input is split out of prompt
tokens so the model table and token chart agree.

When inference token counts are null, recognized `*-llm-*` and
`*-embedding-*` token SKUs supply token counts from their `units`: `mtoken`
counts millions of tokens, `5m-mtoken` counts 5M-token blocks, and bare
`token` counts single tokens. Long-context requests bill `extended-input`,
`extended-output`, `extended-cache-input`, and `extended-cache-write` SKUs
instead of the plain ones. Unknown token SKUs are recorded in
`unsupportedTokenSkus` and logged. Media units are never treated as tokens.

Request counts cover **distinct IDs actually provided by Venice**. Some
entries, including media usage, have null inference details, so a ledger row
is not treated as a request. `entriesWithoutRequestId` records that gap, and
the heading says “reqs.” Session counts are unavailable. Zero-usage
days are filled explicitly, with local calendar boundaries and historical
daylight-saving offsets. A request spanning midnight is attributed to its
first ledger day in the selected window; charges retain their ledger dates.

### API and refresh behavior

- [`GET /billing/usage-history`](https://docs.venice.ai/api-reference/endpoint/billing/usage-history)
  provides the ledger. Continuation requests send only `cursor`.
- [`GET /billing/balance`](https://docs.venice.ai/api-reference/endpoint/billing/balance)
  provides remaining credit and daily allocation.
- The old `/billing/usage` endpoint was retired on **2026-09-16**.
- The first refresh walks the entire configured window once, in 31-day
  chunks; later refreshes re-read the last two days. Busy accounts can reduce
  `historyDays` to shrink that first walk — see
  [Sizing historyDays](#sizing-historydays). The service
  serializes refreshes, including manual refresh requests.
- Rate-limit and transient server/network failures are retried. A rejected
  cursor restarts the walk once. Invalid data or a page cap fails the refresh
  instead of replacing good history with partial or zero totals.
- Writes are atomic and private (`0600`). Failed usage refreshes leave the
  last successful record and its `updatedAt` unchanged; errors go to the shell
  log/stderr. If only the balance fails, usage still updates without a balance.

## Requirements and checks

- Omarchy 4.5+ shell with plugin support, and `omarchy.agents` for the
  balance card.
- Python 3.9+; no third-party Python dependencies.
- A Venice **Admin** API key (Inference Only keys are rejected by the billing
  endpoints); reading usage never spends credits

Run the offline regression tests and manifest validation:

```sh
python3 -m unittest discover -s tests -v
node --test tests/
omarchy plugin validate .
```

## Update and remove

For git-installed copies:

```sh
omarchy plugin update io.github.reneil1337.venice
omarchy plugin remove io.github.reneil1337.venice
```

To also remove the last collected provider record:

```sh
rm "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage/venice.json"
```

## License

MIT — see [LICENSE](LICENSE).
