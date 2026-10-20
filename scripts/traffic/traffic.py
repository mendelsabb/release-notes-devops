"""Continuous HTTP load that measures client-visible failures during a rollout.

Runs *inside* the cluster (as a Job, see scripts/traffic.sh) against the
Service's DNS name, so it sees exactly what other in-cluster clients see:
kube-proxy endpoint updates, pod termination, connection resets. Standard
library only.

Every request is classified as one of:
  ok          2xx response
  http_error  any non-2xx response (a 5xx during rollout is an availability failure;
              4xx is unexpected for this read-only workload and also counted)
  timeout     no response within --timeout
  conn_error  connection refused/reset or closed before a response

Exit status is 1 when failures exceed --max-failures (default 0).
"""

import argparse
import http.client
import json
import socket
import sys
import threading
import time
from collections import Counter
from urllib.parse import urlsplit


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--url", required=True, help="e.g. http://release-notes.prod.svc/api/releases")
    p.add_argument("--duration", type=float, default=90, help="seconds to run")
    p.add_argument("--rps", type=float, default=40, help="target total requests per second")
    p.add_argument("--concurrency", type=int, default=8)
    p.add_argument("--timeout", type=float, default=5, help="per-request timeout (s)")
    p.add_argument("--max-failures", type=int, default=0)
    p.add_argument(
        "--keepalive",
        action="store_true",
        help="reuse one connection per worker (default: new connection per request)",
    )
    return p.parse_args()


class Stats:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.outcomes: Counter[str] = Counter()
        self.statuses: Counter[str] = Counter()
        self.versions: Counter[str] = Counter()
        self.first_seen: dict[str, float] = {}
        self.last_seen: dict[str, float] = {}
        self.latencies: list[float] = []
        self.failures: list[dict] = []

    def record(self, t: float, outcome: str, latency: float, status=None, version=None, err=None):
        with self.lock:
            self.outcomes[outcome] += 1
            if status is not None:
                self.statuses[str(status)] += 1
            if outcome == "ok":
                self.latencies.append(latency)
            if version:
                self.versions[version] += 1
                self.first_seen.setdefault(version, t)
                self.last_seen[version] = t
            if outcome != "ok" and len(self.failures) < 50:
                self.failures.append(
                    {"t": round(t, 2), "outcome": outcome, "status": status, "error": err}
                )


def percentile(sorted_values: list[float], q: float) -> float:
    if not sorted_values:
        return 0.0
    idx = min(len(sorted_values) - 1, round(q * (len(sorted_values) - 1)))
    return sorted_values[idx]


def worker(args, target, stats: Stats, start: float, stop: threading.Event, interval: float):
    conn = None
    next_at = time.monotonic()
    while not stop.is_set():
        if conn is None or not args.keepalive:
            conn = http.client.HTTPConnection(target.hostname, target.port or 80, timeout=args.timeout)
        t0 = time.monotonic()
        try:
            conn.request("GET", target.path or "/", headers={"User-Agent": "traffic-generator"})
            resp = conn.getresponse()
            resp.read()
            latency = time.monotonic() - t0
            outcome = "ok" if 200 <= resp.status < 300 else "http_error"
            stats.record(
                t0 - start, outcome, latency, resp.status, resp.getheader("X-App-Version")
            )
            if not args.keepalive or resp.getheader("Connection", "").lower() == "close":
                conn.close()
                conn = None
        except (TimeoutError, socket.timeout) as exc:
            stats.record(t0 - start, "timeout", time.monotonic() - t0, err=type(exc).__name__)
            conn.close()
            conn = None
        except (OSError, http.client.HTTPException) as exc:
            stats.record(t0 - start, "conn_error", time.monotonic() - t0, err=type(exc).__name__)
            conn.close()
            conn = None
        next_at += interval
        delay = next_at - time.monotonic()
        if delay > 0:
            stop.wait(delay)
        else:
            next_at = time.monotonic()  # running behind: do not burst to catch up


def main() -> int:
    args = parse_args()
    target = urlsplit(args.url)
    stats = Stats()
    stop = threading.Event()
    start = time.monotonic()
    interval = args.concurrency / args.rps
    threads = [
        threading.Thread(target=worker, args=(args, target, stats, start, stop, interval))
        for _ in range(args.concurrency)
    ]
    print(
        f"traffic: {args.url} for {args.duration:.0f}s at ~{args.rps:.0f} rps "
        f"({args.concurrency} workers, {'keep-alive' if args.keepalive else 'new connection'} "
        f"per request, timeout {args.timeout}s)",
        flush=True,
    )
    for t in threads:
        t.start()

    last_total = 0
    while (elapsed := time.monotonic() - start) < args.duration:
        time.sleep(min(5, args.duration - elapsed))
        with stats.lock:
            total = sum(stats.outcomes.values())
            failed = total - stats.outcomes["ok"]
            versions = ", ".join(f"{v}={n}" for v, n in sorted(stats.versions.items()))
        print(
            f"[{time.monotonic() - start:5.0f}s] requests={total} (+{total - last_total}) "
            f"failed={failed} versions: {versions}",
            flush=True,
        )
        last_total = total
    stop.set()
    for t in threads:
        t.join(timeout=args.timeout + 1)

    lat = sorted(stats.latencies)
    total = sum(stats.outcomes.values())
    failed = total - stats.outcomes["ok"]
    summary = {
        "url": args.url,
        "duration_s": round(time.monotonic() - start, 1),
        "total": total,
        "ok": stats.outcomes["ok"],
        "failed": failed,
        "http_error": stats.outcomes["http_error"],
        "timeout": stats.outcomes["timeout"],
        "conn_error": stats.outcomes["conn_error"],
        "status_codes": dict(stats.statuses),
        "latency_ms": {
            "p50": round(percentile(lat, 0.50) * 1000, 1),
            "p95": round(percentile(lat, 0.95) * 1000, 1),
            "p99": round(percentile(lat, 0.99) * 1000, 1),
            "max": round((lat[-1] if lat else 0) * 1000, 1),
        },
        "versions": {
            v: {
                "requests": n,
                "first_seen_s": round(stats.first_seen[v], 1),
                "last_seen_s": round(stats.last_seen[v], 1),
            }
            for v, n in sorted(stats.versions.items(), key=lambda kv: stats.first_seen[kv[0]])
        },
        "failure_samples": stats.failures[:10],
        "max_failures": args.max_failures,
        "passed": failed <= args.max_failures,
    }
    print("SUMMARY " + json.dumps(summary), flush=True)
    print(
        f"\nRESULT: {'PASS' if summary['passed'] else 'FAIL'} - {total} requests, {failed} failed "
        f"(http_error={summary['http_error']} timeout={summary['timeout']} "
        f"conn_error={summary['conn_error']}), p95={summary['latency_ms']['p95']}ms",
        flush=True,
    )
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
