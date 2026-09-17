# Venice Monitor — Omarchy shell plugin

Feeds your Venice account usage into the **stock `omarchy.agents` panel** as
a `venice` provider, following the same service-only design as
[LiteLLM Monitor](https://github.com/reneil1337/omarchy-litellm-monitor).

- Daily token chart and per-model input/output/cache breakdown for the last 7 days.
- **Usage costs displayed in USD: USD charges + DIEM charges, at 1 DIEM = 1 USD.**
- Last-7-days cost, tokens, and tracked request count in the provider heading.
- Available credit in USD equivalents and a daily-credit utilization meter.
- Up to 365 days of token, request, and cost history in the usage record.

A headless service refreshes every **10 minutes** and writes
`~/.local/state/omarchy/agents/usage/venice.json`. The existing agents panel
provides the bar icon and visualization. Panel versions supporting `history`
and `modelDaily` can also render longer week/month/quarter/year views; the
stock 7-day panel uses `recentDays` and `modelUsage`.

## Install

```sh
omarchy plugin add https://github.com/reneil1337/omarchy-venice-monitor --enable
```

Make sure the first-party `omarchy.agents` plugin is enabled:

```sh
omarchy plugin enable omarchy.agents
```

### From a local checkout

Run these commands from this repository to install before publishing it:

```sh
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.reneil1337.venice"
mkdir -p "$plugin_dir"
cp manifest.json Service.qml collector.py config.json.example "$plugin_dir/"
omarchy plugin enable io.github.reneil1337.venice
```

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
  "historyDays": 365
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
| `historyDays` | `365` | Local calendar days to retrieve, from 1 to 365 |
| `maxPages` | `1000` | Maximum 1,000-entry pages per walk; configurable from 1 to 10,000 |

The API selects the account from the key. Billing history is account-wide,
rather than restricted to calls made with the monitoring key, and can include
Venice web-app activity present in the account ledger. The history endpoint
does not expose a per-key filter.

## Usage

Force a refresh:

```sh
omarchy-shell io.github.reneil1337.venice refresh
```

Open the agents panel:

```sh
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
the heading says “tracked req.” Session counts are unavailable. Zero-usage
days are filled explicitly, with local calendar boundaries and historical
daylight-saving offsets. A request spanning midnight is attributed to its
first ledger day in the selected window; charges retain their ledger dates.

### API and refresh behavior

- [`GET /billing/usage-history`](https://docs.venice.ai/api-reference/endpoint/billing/usage-history)
  provides the ledger. Continuation requests send only `cursor`.
- [`GET /billing/balance`](https://docs.venice.ai/api-reference/endpoint/billing/balance)
  provides remaining credit and daily allocation.
- The old `/billing/usage` endpoint was retired on **2026-09-16**.
- Each refresh walks the entire configured history window. Busy accounts can
  reduce `historyDays` to reduce API traffic and refresh time. The service
  serializes refreshes, including manual refresh requests.
- Rate-limit and transient server/network failures are retried. A rejected
  cursor restarts the walk once. Invalid data or a page cap fails the refresh
  instead of replacing good history with partial or zero totals.
- Writes are atomic and private (`0600`). Failed usage refreshes leave the
  last successful record and its `updatedAt` unchanged; errors go to the shell
  log/stderr. If only the balance fails, usage still updates without a balance.

## Requirements and checks

- Omarchy Quattro shell with plugin support and `omarchy.agents` enabled.
- Python 3.9+; no third-party Python dependencies.
- A Venice **Admin** API key (Inference Only keys are rejected by the billing
  endpoints); reading usage never spends credits

Run the offline regression tests and manifest validation:

```sh
python3 -m unittest discover -s tests -v
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
