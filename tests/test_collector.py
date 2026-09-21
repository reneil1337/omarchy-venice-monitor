import contextlib
import io
import json
import os
import tempfile
import threading
import time
import unittest
import urllib.error
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import collector


NOW = datetime(2026, 9, 17, 12, tzinfo=timezone.utc).timestamp()
BALANCE = {
    "balances": {"diem": 7.5, "usd": 2.5},
    "diemEpochAllocation": 10,
    "canConsume": True,
    "consumptionCurrency": "DIEM",
}


def entry(kind="input", units=0.001, amount=-0.5, currency="USD", request_id="request-1",
          prompt=1000, completion=200, stamp="2026-09-17T10:00:00Z", model="test-model"):
    return {
        "timestamp": stamp,
        "sku": model + "-llm-" + kind + "-mtoken",
        "units": units,
        "amount": amount,
        "currency": currency,
        "pricePerUnitUsd": 1,
        "notes": "API Inference",
        "inferenceDetails": {
            "requestId": request_id,
            "promptTokens": prompt,
            "completionTokens": completion,
            "inferenceExecutionTime": 2000,
        } if request_id else None,
    }


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {"TZ": "UTC", "VENICE_API_KEY": ""})
        self.environment.start()
        time.tzset()
        self.addCleanup(time.tzset)
        self.addCleanup(self.environment.stop)

    def record(self, rows, **kwargs):
        with patch.object(collector, "api_get", side_effect=[{"data": rows, "nextCursor": None}, BALANCE]):
            return collector.build_record("https://example.test/api/v1", "test-key", NOW, **kwargs)

    def test_currency_charges_sum_while_repeated_inference_details_count_once(self):
        record = self.record([
            entry(units=0.0008),
            entry("cache-input", units=0.0002, amount=-0.25, currency="DIEM"),
            entry("output", units=0.0002, amount=-1, currency="DIEM"),
        ])
        self.assertEqual(record["todayTotalTokens"], 1200)
        self.assertEqual(record["todayPrompts"], 1)
        self.assertEqual(record["todayCostUSD"], 1.75)
        self.assertEqual(record["totalCostUSD"], 1.75)
        self.assertEqual(record["history"][-1]["costUSD"], 1.75)
        self.assertIn("$1.75 USD", record["tierLabel"])
        self.assertEqual(record["currency"], "USD")
        self.assertEqual(record["modelUsage"]["test-model"], {
            "inputTokens": 800, "outputTokens": 200,
            "cacheReadInputTokens": 200, "cacheCreationInputTokens": 0,
        })
        self.assertEqual(record["todayTokensByModel"], {"test-model": 1200})

    def test_cache_writes_are_not_double_counted(self):
        record = self.record([
            entry("cache_write", units=0.0003),
            entry("cache-read", units=0.0002),
            entry("output", units=0.0002),
        ])
        self.assertEqual(record["todayTotalTokens"], 1200)
        self.assertEqual(record["modelUsage"]["test-model"]["inputTokens"], 500)
        self.assertEqual(record["modelUsage"]["test-model"]["cacheCreationInputTokens"], 300)

    def test_null_inference_details_use_million_token_units_not_media_units(self):
        image = entry(amount=-0.2, request_id=None)
        image.update(sku="grok-imagine-image-image-unit", units=2)
        record = self.record([
            entry(units=0.0003, amount=-0.1, request_id=None), image,
            entry("output", units=0.000111, amount=-0.1, request_id="null-tokens",
                  prompt=None, completion=None),
        ])
        self.assertEqual(record["todayTotalTokens"], 411)
        self.assertEqual(record["todayPrompts"], 1)
        self.assertEqual(record["entriesWithoutRequestId"], 2)
        self.assertFalse(record["hasPromptStats"])
        self.assertEqual(record["todayCostUSD"], 0.4)

    def test_currency_split_does_not_double_inference_totals(self):
        record = self.record([entry(currency="USD"), entry(currency="DIEM")])
        self.assertEqual(record["todayTotalTokens"], 1200)
        self.assertEqual(record["todayPrompts"], 1)
        self.assertEqual(record["todayCostUSD"], 1)

    def test_refunds_reduce_spend_and_bundled_credits_have_no_usd_conversion(self):
        refund = entry(amount=0.1, request_id=None)
        refund["sku"] = "billing-refund"
        record = self.record([entry(amount=-0.2), entry(amount=-0.1, currency="DIEM"),
                              entry(amount=-99, currency="BUNDLED_CREDITS"), refund])
        self.assertEqual(record["todayCostUSD"], 0.2)
        self.assertEqual(record["todayTotalTokens"], 1200)

    def test_history_and_model_window_match_and_zero_fill(self):
        record = self.record([entry(), entry(stamp="2026-09-01T12:00:00Z", request_id="older")],
                             history_days=365)
        self.assertEqual(len(record["history"]), 365)
        self.assertEqual(len(record["recentDays"]), 7)
        self.assertEqual(record["history"][0]["date"], "2025-09-18")
        self.assertEqual(record["recentDays"][-2]["messageCount"], 0)
        self.assertEqual(record["activeDays"], 2)
        self.assertEqual(record["totalPrompts"], 2)
        self.assertEqual(sum(record["modelUsage"]["test-model"].values()),
                         sum(row["messageCount"] for row in record["recentDays"]))
        self.assertEqual(len(record["modelDaily"]["test-model"]), 2)

    def test_default_window_is_seven_days(self):
        record = self.record([entry()])
        self.assertEqual(len(record["history"]), 7)
        self.assertEqual(record["history"][0]["date"], "2026-09-11")
        self.assertEqual(record["history"][-1]["date"], "2026-09-17")

    def test_one_request_across_midnight_has_one_token_total_and_request(self):
        record = self.record([entry(stamp="2026-09-16T23:59:59Z"),
                              entry("output", stamp="2026-09-17T00:00:01Z")])
        self.assertEqual(record["totalPrompts"], 1)
        self.assertEqual(record["history"][-2]["tokens"], 1200)
        self.assertEqual(record["history"][-1]["tokens"], 0)
        self.assertEqual(record["history"][-1]["costUSD"], 0.5)

    def test_local_dates_honor_historical_dst(self):
        os.environ["TZ"] = "America/New_York"
        time.tzset()
        now = datetime(2026, 3, 9, 12, tzinfo=timezone.utc).timestamp()
        dates, start, end = collector.date_window(now, 3)
        self.assertEqual(start, "2026-03-07T05:00:00.000Z")
        self.assertEqual(end, "2026-03-09T12:00:00.000Z")
        days, _ = collector.summarize_history([
            entry(stamp="2026-03-08T04:30:00Z", request_id="before-dst"),
            entry(stamp="2026-03-09T04:30:00Z", request_id="after-dst"),
        ], dates)
        self.assertEqual(days["2026-03-07"]["requests"], 1)
        self.assertEqual(days["2026-03-08"]["requests"], 0)
        self.assertEqual(days["2026-03-09"]["requests"], 1)

    def test_positive_timezone_midnight_uses_previous_utc_day(self):
        os.environ["TZ"] = "Europe/Berlin"
        time.tzset()
        _, start, _ = collector.date_window(NOW, 1)
        self.assertEqual(start, "2026-09-16T22:00:00.000Z")

    def test_balance_gauge_drains_from_epoch_allocation(self):
        fields = collector.balance_fields(BALANCE)
        self.assertEqual(fields["balance"]["remaining"], 10)
        self.assertEqual(fields["balance"]["funded"], 10)
        self.assertEqual(fields["balance"]["spent"], 0)
        self.assertEqual(fields["balance"]["currency"], "USD")
        self.assertFalse(fields["balance"]["estimated"])
        self.assertEqual(fields["limits"], [])
        # The panel's gauge drains toward empty: remaining/funded.
        self.assertAlmostEqual(fields["balance"]["remaining"] / fields["balance"]["funded"], 1.0)

    def test_balance_gauge_matches_account_state(self):
        fields = collector.balance_fields({
            "balances": {"diem": 174.046883, "usd": 1.31}, "diemEpochAllocation": 200,
        })
        self.assertEqual(fields["balance"]["remaining"], 175.356883)
        self.assertEqual(fields["balance"]["funded"], 200)
        self.assertAlmostEqual(fields["balance"]["spent"], 24.643117)
        self.assertAlmostEqual(fields["balance"]["remaining"] / fields["balance"]["funded"], 0.876784415)

    def test_usd_only_and_exhausted_balance(self):
        fields = collector.balance_fields({"balances": {"diem": None, "usd": 0}, "diemEpochAllocation": 0})
        self.assertEqual(fields["balance"]["remaining"], 0)
        # No allocation means no gauge; the panel hides the meter and shows
        # the remaining figure only.
        self.assertEqual(fields["balance"]["funded"], 0)
        self.assertEqual(fields["balance"]["spent"], 0)
        self.assertEqual(fields["limits"], [])

    def test_empty_account_still_gets_complete_zero_history_and_balance(self):
        record = self.record([])
        self.assertTrue(record["ready"])
        self.assertEqual(record["totalCostUSD"], 0)
        self.assertEqual(record["totalPrompts"], 0)
        self.assertEqual(record["modelUsage"], {})
        self.assertIn("balance", record)

    def test_balance_failure_does_not_discard_usage(self):
        with patch.object(collector, "api_get", side_effect=[{"data": [entry()], "nextCursor": None},
                                                             collector.ApiError(500, "unavailable")]), \
                contextlib.redirect_stderr(io.StringIO()):
            record = collector.build_record("base", "key", NOW)
        self.assertEqual(record["todayTotalTokens"], 1200)
        self.assertNotIn("balance", record)

    def test_cursor_only_pagination_and_cross_page_deduplication(self):
        with patch.object(collector, "api_get", side_effect=[
            {"data": [entry()], "nextCursor": "cursor_2"},
            {"data": [entry("output")], "nextCursor": None}, BALANCE,
        ]) as api:
            record = collector.build_record("base", "key", NOW)
        self.assertEqual(api.call_args_list[0].args[3]["pageSize"], 1000)
        self.assertEqual(api.call_args_list[1].args[3], {"cursor": "cursor_2"})
        self.assertEqual(record["todayPrompts"], 1)
        self.assertEqual(record["todayTotalTokens"], 1200)

    def test_rejected_cursor_restarts_without_adding_first_page_twice(self):
        with patch.object(collector, "api_get", side_effect=[
            {"data": [entry()], "nextCursor": "expired"}, collector.ApiError(400, "expired"),
            {"data": [entry(), entry("output")], "nextCursor": None}, BALANCE,
        ]) as api:
            record = collector.build_record("base", "key", NOW)
        self.assertEqual(api.call_args_list[0].args[3], api.call_args_list[2].args[3])
        self.assertEqual(record["todayCostUSD"], 1)
        self.assertEqual(record["todayPrompts"], 1)

    def test_partial_and_malformed_history_never_succeed(self):
        for payload in ({}, {"data": None, "nextCursor": None}, {"data": []},
                        {"data": [], "nextCursor": ""}):
            with self.subTest(payload=payload), patch.object(collector, "api_get", return_value=payload):
                with self.assertRaises(ValueError):
                    list(collector.fetch_history("base", "key", "start", "end", 1))
        with patch.object(collector, "api_get", return_value={"data": [entry()], "nextCursor": "more"}):
            with self.assertRaisesRegex(RuntimeError, "maxPages"):
                collector.build_record("base", "key", NOW, max_pages=1)
        with patch.object(collector, "api_get", return_value={"data": [], "nextCursor": "repeated"}):
            with self.assertRaisesRegex(ValueError, "repeated"):
                list(collector.fetch_history("base", "key", "start", "end", 3))

    def test_extended_and_5m_token_skus_replace_plain_entries(self):
        # Long-context requests bill extended SKUs instead of the plain ones,
        # and cache writes can be billed in 5M-token blocks.
        extended = entry("extended-input", units=0.0005, amount=-0.3, request_id="ext", prompt=None)
        extended.update(sku="claude-fable-5-1-llm-extended-input-mtoken")
        extended_out = entry("extended-output", units=0.0002, amount=-0.3, request_id="ext", prompt=None)
        extended_out.update(sku="claude-fable-5-1-llm-extended-output-mtoken")
        big_cache = entry("cache-write", units=0.0002, amount=-0.3, request_id="big", prompt=1100)
        big_cache.update(sku="claude-fable-5-1-llm-cache-write-5m-mtoken")
        record = self.record([extended, extended_out, big_cache])
        usage = record["modelUsage"]["claude-fable-5-1"]
        self.assertEqual(usage["inputTokens"], 600)
        self.assertEqual(usage["outputTokens"], 400)
        self.assertEqual(usage["cacheCreationInputTokens"], 1000)
        self.assertEqual(record["todayTotalTokens"], 2000)
        self.assertEqual(record["todayPrompts"], 2)
        self.assertEqual(record["unsupportedTokenSkus"], [])

    def test_unknown_token_sku_is_reported_without_fabricating_tokens(self):
        row = entry("new-type", request_id=None)
        with contextlib.redirect_stderr(io.StringIO()):
            record = self.record([row])
        self.assertEqual(record["unsupportedTokenSkus"], [row["sku"]])
        self.assertEqual(record["todayTotalTokens"], 0)
        self.assertEqual(record["todayCostUSD"], 0.5)

    def test_config_environment_override_and_environment_only_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            with patch.dict(os.environ, {"VENICE_API_KEY": " environment-key "}):
                self.assertEqual(collector.load_config(path),
                                 (collector.BASE_URL, "environment-key", 7, 1000))
                path.write_text(json.dumps({"apiKey": "file-key", "historyDays": 30}))
                self.assertEqual(collector.load_config(path)[1:3], ("environment-key", 30))
            self.assertEqual(collector.load_config(path)[1], "file-key")

    def test_invalid_configuration_has_readable_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            for config in ([], {"apiKey": ""}, {"apiKey": "key", "historyDays": True},
                           {"apiKey": "key", "baseUrl": "file:///tmp/test"},
                           {"apiKey": "key", "maxPages": 0}):
                with self.subTest(config=config):
                    path.write_text(json.dumps(config))
                    with self.assertRaises(ValueError):
                        collector.load_config(path)

    def test_atomic_private_record_and_failed_refresh_preserves_it(self):
        with tempfile.TemporaryDirectory() as directory:
            record = self.record([entry()])
            path = collector.write_record(record, directory)
            before = path.read_bytes()
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(before)["id"], "venice")
            config_path = Path(directory) / "config.json"
            config_path.write_text('{"apiKey":"key"}')
            with patch.dict(os.environ, {"XDG_STATE_HOME": directory}), \
                    patch.object(collector, "api_get", side_effect=collector.ApiError(401, "auth failed")), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(collector.main(["--config", str(config_path)]), 1)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_serialization_failure_cleans_temp_file_and_preserves_record(self):
        with tempfile.TemporaryDirectory() as directory:
            path = collector.write_record({"id": "venice"}, directory)
            with self.assertRaises(ValueError):
                collector.write_record({"invalid": float("nan")}, directory)
            self.assertEqual(json.loads(path.read_text()), {"id": "venice"})
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_rate_limits_and_server_errors_retry_but_auth_does_not(self):
        for status in (429, 500, 401, 403):
            with self.subTest(status=status):
                error = urllib.error.HTTPError("https://example.test", status, "failed",
                                               {"Retry-After": "1"}, io.BytesIO(b"secret body"))
                with patch.object(collector.urllib.request.OpenerDirector, "open",
                                  side_effect=[error, io.BytesIO(b'{"data": []}')]) as api, \
                        patch.object(collector.time, "sleep") as sleep:
                    if status in (401, 403):
                        with self.assertRaises(collector.ApiError) as raised:
                            collector.api_get("https://example.test", "key", "/billing/usage-history")
                        self.assertNotIn("secret body", str(raised.exception))
                        self.assertEqual(api.call_count, 1)
                        sleep.assert_not_called()
                    else:
                        self.assertEqual(collector.api_get("https://example.test", "key", "/billing/usage-history"),
                                         {"data": []})
                        sleep.assert_called_once_with(1)

    def test_real_http_transport_cli_and_cursor_contract(self):
        calls = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                url = urlsplit(self.path)
                query = parse_qs(url.query)
                calls.append((url.path, query, self.headers.get("Authorization"), self.headers.get("Accept")))
                if url.path == "/api/v1/billing/balance":
                    payload = BALANCE
                elif "cursor" in query:
                    payload = {"data": [entry("output", amount=-0.2, currency="DIEM")], "nextCursor": None}
                else:
                    payload = {"data": [entry(amount=-0.1)], "nextCursor": "next_page"}
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                config = Path(directory) / "config.json"
                config.write_text(json.dumps({"baseUrl": "http://127.0.0.1:%d/api/v1" % server.server_port,
                                              "apiKey": "test-only-key"}))
                output = io.StringIO()
                with patch.object(collector.time, "time", return_value=NOW), \
                        patch.dict(os.environ, {"XDG_STATE_HOME": directory}), \
                        contextlib.redirect_stdout(output):
                    self.assertEqual(collector.main(["--config", str(config), "--stdout"]), 0)
                record = json.loads(output.getvalue())
                self.assertEqual(record["todayCostUSD"], 0.3)
                self.assertEqual(record["todayTotalTokens"], 1200)
                self.assertFalse((Path(directory) / collector.STATE_SUBDIR).exists())
            self.assertEqual(calls[1][1], {"cursor": ["next_page"]})
            self.assertEqual(len(calls), 3)
            self.assertTrue(all(call[2:] == ("Bearer test-only-key", "application/json") for call in calls))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
