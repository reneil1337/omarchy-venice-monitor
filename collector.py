#!/usr/bin/env python3
"""Feed Venice billing usage into the stock Omarchy agents panel.

Uses the cursor-paginated /billing/usage-history endpoint and /billing/balance.
Configure config.json next to this script or export VENICE_API_KEY.
All displayed costs are USD equivalents: 1 DIEM = 1 USD. Stdlib only.
"""

import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, time as day_time, timedelta, timezone
from decimal import Decimal, InvalidOperation
from email.utils import parsedate_to_datetime
from pathlib import Path

BASE_URL = "https://api.venice.ai/api/v1"
DAYS = 7
HISTORY_DAYS = 365
PAGE_SIZE = 1000
MAX_PAGES = 1000
STATE_SUBDIR = "omarchy/agents/usage"
RECORD_ID = "venice"
TOKEN_FIELDS = (
    "inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens",
)
TOKEN_KINDS = {
    "input": "inputTokens",
    "output": "outputTokens",
    "cache-input": "cacheReadInputTokens",
    "cache-read": "cacheReadInputTokens",
    "cache-write": "cacheCreationInputTokens",
    "cache-creation": "cacheCreationInputTokens",
    # Long-context models bill "extended" entries instead of the plain ones.
    "extended-input": "inputTokens",
    "extended-output": "outputTokens",
    "extended-cache-input": "cacheReadInputTokens",
    "extended-cache-write": "cacheCreationInputTokens",
}
TOKEN_UNIT_SUFFIX = re.compile(r"-((?:\d+m-)?(?:mtoken|token))$")
TOKEN_KIND_SEPARATOR = re.compile(r"^(.+)-(?:llm|embedding)-(.+)$")


def parse_token_sku(sku):
    """Split a token SKU into (model, kind, units per entry) or None.

    The unit suffix is anchored to the end, so "cache-write-5m-mtoken" parses
    as kind "cache-write" billed in 5M-token blocks instead of a kind of
    "cache-write-5m" in plain millions. Unknown kinds still parse so the model
    name stays right and the kind lands in unsupportedTokenSkus.
    """
    unit = TOKEN_UNIT_SUFFIX.search(sku)
    if not unit:
        return None
    parts = TOKEN_KIND_SEPARATOR.match(sku[:unit.start()])
    if not parts:
        return None
    factor = {"mtoken": 1000000, "token": 1}[unit[1].rsplit("-", 1)[-1]]
    if "-" in unit[1]:
        factor *= int(unit[1].split("-", 1)[0].rstrip("m"))
    return parts[1], parts[2], factor


class ApiError(RuntimeError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class CursorRejected(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # The billing API has no redirects; keep bearer credentials on its host.
        return None


def load_config(path):
    try:
        with open(path, encoding="utf-8") as stream:
            config = json.load(stream)
    except FileNotFoundError:
        config = {}
    if not isinstance(config, dict):
        raise ValueError("config.json must contain a JSON object")
    base = config.get("baseUrl", BASE_URL)
    key = os.environ.get("VENICE_API_KEY", "").strip() or config.get("apiKey", "")
    if not isinstance(base, str) or not isinstance(key, str):
        raise ValueError("baseUrl and apiKey must be strings")
    base, key = base.strip().rstrip("/"), key.strip()
    url = urllib.parse.urlsplit(base)
    if (url.scheme not in ("https", "http") or not url.netloc
            or url.username or url.password or url.query or url.fragment):
        raise ValueError("baseUrl must be an API base URL, e.g. " + BASE_URL)
    if not key or any(char.isspace() for char in key):
        raise ValueError("Set apiKey in config.json or export VENICE_API_KEY")
    history_days = config.get("historyDays", HISTORY_DAYS)
    max_pages = config.get("maxPages", MAX_PAGES)
    for name, value, maximum in (("historyDays", history_days, 365),
                                 ("maxPages", max_pages, 10000)):
        if type(value) is not int or not 1 <= value <= maximum:
            raise ValueError("%s must be an integer between 1 and %d" % (name, maximum))
    return base, key, history_days, max_pages


def retry_delay(headers, attempt):
    value = headers.get("Retry-After", "")
    try:
        delay = float(value)
    except ValueError:
        try:
            delay = parsedate_to_datetime(value).timestamp() - time.time()
        except (TypeError, ValueError, OverflowError):
            delay = 2 + attempt * 2
    return max(0, min(60, delay))


def api_get(base, key, path, params=None, retries=3):
    query = urllib.parse.urlencode(params or {})
    request = urllib.request.Request(base + path + ("?" + query if query else ""), headers={
        "Authorization": "Bearer " + key,
        "Accept": "application/json",
        "User-Agent": "omarchy-venice-monitor/1.0",
    })
    opener = urllib.request.build_opener(NoRedirect)
    for attempt in range(retries):
        try:
            with opener.open(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            status, headers = error.code, error.headers
            error.close()
            if status == 401:
                raise ApiError(status, "Venice authentication failed; billing endpoints require an Admin API key") from None
            if status == 403:
                raise ApiError(status, "Venice denied billing access for this API key") from None
            if (status != 429 and not 500 <= status < 600) or attempt == retries - 1:
                raise ApiError(status, "Venice HTTP %d for %s" % (status, path)) from None
            time.sleep(retry_delay(headers, attempt))
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == retries - 1:
                raise
            time.sleep(2 + attempt * 2)


def iso_utc(moment):
    return moment.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def date_window(now, history_days):
    today = datetime.fromtimestamp(now).date()
    dates = [(today - timedelta(days=offset)).isoformat()
             for offset in range(history_days - 1, -1, -1)]
    # Convert the actual local midnight, rather than applying today's UTC
    # offset to a year of timestamps (which would misgroup DST boundaries).
    start = datetime.combine(today - timedelta(days=history_days - 1), day_time.min)
    return dates, iso_utc(start), iso_utc(datetime.fromtimestamp(now, timezone.utc))


def fetch_history(base, key, start, end, max_pages):
    params = {"startTimestamp": start, "endTimestamp": end, "pageSize": PAGE_SIZE}
    cursors = set()
    for _ in range(max_pages):
        try:
            payload = api_get(base, key, "/billing/usage-history", params)
        except ApiError as error:
            if error.status == 400 and "cursor" in params:
                raise CursorRejected("Venice rejected the usage-history cursor") from error
            raise
        if (not isinstance(payload, dict) or not isinstance(payload.get("data"), list)
                or "nextCursor" not in payload):
            raise ValueError("Unexpected Venice usage-history response")
        yield from payload["data"]
        cursor = payload["nextCursor"]
        if cursor is None:
            return
        if not isinstance(cursor, str) or not cursor or cursor in cursors:
            raise ValueError("Invalid or repeated Venice usage-history cursor")
        cursors.add(cursor)
        # Continuations MUST send only cursor, including no pageSize.
        params = {"cursor": cursor}
    raise RuntimeError("Usage history exceeds maxPages; increase it or reduce historyDays in config.json")


def decimal_number(value):
    try:
        number = Decimal(str(value))
    except InvalidOperation:
        raise ValueError("Invalid number in Venice billing response") from None
    if not number.is_finite():
        raise ValueError("Non-finite number in Venice billing response")
    return number


def token_count(value):
    if value is None:
        return None
    number = decimal_number(value)
    if number < 0 or number != number.to_integral_value():
        raise ValueError("Invalid token count in Venice billing response")
    return int(number)


def empty_parts():
    return dict.fromkeys(TOKEN_FIELDS, 0)


def empty_day():
    return {"tokens": 0, "requests": 0, "costUSD": Decimal(0),
            "entries": 0, "entriesWithoutRequestId": 0, "models": {}}


def summarize_history(rows, dates):
    days = {day: empty_day() for day in dates}
    request_days = {}
    requests = {}
    unsupported_skus = set()

    for row_index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ValueError("Unexpected Venice billing entry")
        stamp = datetime.fromisoformat(str(row.get("timestamp", "")).replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            raise ValueError("Venice billing timestamps must include a timezone")
        day = stamp.astimezone().date().isoformat()
        if day not in days:
            continue
        info = days[day]
        info["entries"] += 1
        # Ledger debits are negative; refunds/credits reverse prior charges.
        # Bundled credits have no documented USD conversion, so are excluded.
        if row.get("currency") in ("USD", "DIEM"):
            info["costUSD"] -= decimal_number(row.get("amount"))

        details = row.get("inferenceDetails")
        if details is None:
            details = {}
        if not isinstance(details, dict):
            raise ValueError("Unexpected Venice inference details")
        request_id = details.get("requestId")
        if request_id is not None and not isinstance(request_id, str):
            raise ValueError("Unexpected Venice request ID")
        if request_id:
            request_days[request_id] = min(day, request_days.get(request_id, day))
        else:
            info["entriesWithoutRequestId"] += 1

        sku = row.get("sku")
        if not isinstance(sku, str) or not sku:
            raise ValueError("Missing SKU in Venice billing entry")
        parsed = parse_token_sku(sku)
        model = parsed[0] if parsed else sku
        field = TOKEN_KINDS.get(parsed[1].replace("_", "-")) if parsed else None
        prompt = token_count(details.get("promptTokens"))
        completion = token_count(details.get("completionTokens"))
        if not field and prompt is None and completion is None:
            if "token" in sku:
                unsupported_skus.add(sku)
            continue  # Images, audio, video, etc. still contribute to cost.
        if not field:
            unsupported_skus.add(sku)

        # Input/output/cache charges repeat the same inferenceDetails. Keep a
        # request only once across all pages and currencies. Anonymous ledger
        # rows can still supply token units, but cannot supply request counts.
        identity = (model, request_id) if request_id else (model, row_index)
        request = requests.setdefault(identity, {
            "model": model, "day": day, "prompt": None, "completion": None,
            "billed": dict.fromkeys(TOKEN_FIELDS, Decimal(0)),
        })
        request["day"] = min(request["day"], day)
        for name, count in (("prompt", prompt), ("completion", completion)):
            if count is not None:
                previous = request[name]
                request[name] = count if previous is None else max(previous, count)
        if field:
            units = decimal_number(row.get("units"))
            if units < 0:
                raise ValueError("Negative token units in Venice billing response")
            request["billed"][field] += units * parsed[2]

    for day in request_days.values():
        days[day]["requests"] += 1
    for request in requests.values():
        parts = {field: int(round(value)) for field, value in request["billed"].items()}
        prompt = request["prompt"]
        if prompt is not None:
            # OpenAI-style prompt totals include cached input. Subtract the
            # cache components so the panel's additive model bars stay exact.
            parts["cacheReadInputTokens"] = min(parts["cacheReadInputTokens"], prompt)
            parts["cacheCreationInputTokens"] = min(parts["cacheCreationInputTokens"],
                                                    prompt - parts["cacheReadInputTokens"])
            parts["inputTokens"] = prompt - parts["cacheReadInputTokens"] - parts["cacheCreationInputTokens"]
        if request["completion"] is not None:
            parts["outputTokens"] = request["completion"]
        total = sum(parts.values())
        if total:
            info = days[request["day"]]
            info["tokens"] += total
            bucket = info["models"].setdefault(request["model"], empty_parts())
            for field in TOKEN_FIELDS:
                bucket[field] += parts[field]
    return days, sorted(unsupported_skus)


def fetch_activity(base, key, now, history_days, max_pages):
    dates, start, end = date_window(now, history_days)
    for attempt in range(2):
        try:
            days, unsupported = summarize_history(fetch_history(base, key, start, end, max_pages), dates)
            return dates, days, unsupported
        except CursorRejected:
            if attempt:
                raise
            # A new walk starts from scratch so retried pages aren't counted twice.


def model_usage_window(days, dates):
    usage = {}
    for day in dates:
        for model, parts in days[day]["models"].items():
            bucket = usage.setdefault(model, empty_parts())
            for field in TOKEN_FIELDS:
                bucket[field] += parts[field]
    return usage


def compact_tokens(count):
    for unit, divisor in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if count >= divisor:
            return ("%g" % round(count / divisor, 0 if count >= 10 * divisor else 1)) + unit
    return str(count)


def balance_fields(payload):
    if not isinstance(payload, dict) or not isinstance(payload.get("balances"), dict):
        raise ValueError("Unexpected Venice balance response")
    balances = payload["balances"]
    diem = decimal_number(balances["diem"]) if balances.get("diem") is not None else None
    usd = decimal_number(balances["usd"]) if balances.get("usd") is not None else None
    allocation = decimal_number(payload.get("diemEpochAllocation", 0))
    result = {"limits": [], "canConsume": payload.get("canConsume")}
    if diem is None and usd is None:
        return result
    remaining = max(Decimal(0), (diem or Decimal(0)) + (usd or Decimal(0)))
    # The epoch allocation is the full tank (100%): the panel's balance gauge
    # drains from it toward empty as credits are consumed.
    funded = max(Decimal(0), allocation)
    result["balance"] = {
        "remaining": float(remaining),
        "funded": float(funded),
        "spent": float(max(Decimal(0), funded - remaining)),
        "currency": "USD",
        "estimated": False,
    }
    return result


def build_record(base, key, now, history_days=HISTORY_DAYS, max_pages=MAX_PAGES):
    dates, days, unsupported = fetch_activity(base, key, now, history_days, max_pages)
    today = days[dates[-1]]
    recent = dates[-DAYS:]
    history = [{"date": day, "tokens": days[day]["tokens"], "requests": days[day]["requests"],
                "costUSD": float(days[day]["costUSD"])} for day in dates]
    model_daily = {}
    for day in dates:
        for model, parts in days[day]["models"].items():
            model_daily.setdefault(model, []).append([day, sum(parts.values())])
    recent_cost = sum(days[day]["costUSD"] for day in recent)
    recent_tokens = sum(days[day]["tokens"] for day in recent)
    recent_requests = sum(days[day]["requests"] for day in recent)
    missing_ids = sum(days[day]["entriesWithoutRequestId"] for day in dates)
    record = {
        "schemaVersion": 1,
        "id": RECORD_ID,
        "name": "Venice",
        "ready": True,
        "scope": "account",
        "hasLocalStats": False,
        "hasPromptStats": today["entriesWithoutRequestId"] == 0,
        "tierLabel": "%dd: $%.2f USD · %s tokens · %s tracked req" % (
            len(recent), recent_cost, compact_tokens(recent_tokens), compact_tokens(recent_requests)),
        "usageStatusText": "",
        "authHelpText": "",
        "todayPrompts": today["requests"],
        "todaySessions": 0,
        "todayTotalTokens": today["tokens"],
        "todayTokensByModel": {model: sum(parts.values()) for model, parts in today["models"].items()},
        "todayCostUSD": float(today["costUSD"]),
        "recentDays": [{"date": day, "messageCount": days[day]["tokens"]} for day in recent],
        "totalPrompts": sum(info["requests"] for info in days.values()),
        "totalSessions": 0,
        "totalCostUSD": float(sum(info["costUSD"] for info in days.values())),
        "activeDays": sum(info["entries"] > 0 for info in days.values()),
        "activeDates": [day for day in dates if days[day]["entries"]],
        "modelUsage": model_usage_window(days, recent),
        "history": history,
        "modelDaily": model_daily,
        "currency": "USD",
        "entriesWithoutRequestId": missing_ids,
        "unsupportedTokenSkus": unsupported,
        "limits": [],
        "updatedAt": int(now * 1000),
    }
    if unsupported:
        print("Some token SKUs are unrecognized; see unsupportedTokenSkus in venice.json", file=sys.stderr)
    # A temporarily unavailable balance must not discard successfully fetched usage.
    try:
        record.update(balance_fields(api_get(base, key, "/billing/balance")))
    except (RuntimeError, ValueError, OSError) as error:
        print("Venice balance unavailable: %s" % error, file=sys.stderr)
    return record


def write_record(record, state_base):
    path = Path(state_base) / STATE_SUBDIR / (RECORD_ID + ".json")
    path.parent.mkdir(parents=True, exist_ok=True)
    # A unique, private temp file also makes manual and service refreshes safe
    # to run concurrently. Readers only ever see a complete JSON document.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".venice-", suffix=".tmp", delete=False) as stream:
            temporary = stream.name
            json.dump(record, stream, indent=1, allow_nan=False)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=Path(__file__).resolve().with_name("config.json"),
                        help="Config file (default: config.json next to collector.py)")
    parser.add_argument("--stdout", action="store_true", help="Print JSON instead of writing a usage record")
    args = parser.parse_args(argv)
    try:
        base, key, history_days, max_pages = load_config(args.config)
        record = build_record(base, key, time.time(), history_days, max_pages)
        if args.stdout:
            print(json.dumps(record, indent=1, allow_nan=False))
        else:
            state_base = os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state"
            write_record(record, state_base)
    except (RuntimeError, ValueError, OSError) as error:
        print("Venice monitor: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
