"""Generate infrastructure/monitoring/dashboards/release-notes.json.

Kept as code so panels and queries are reviewable; the JSON is committed and
loaded by Grafana's file provisioning. Run: uv run python scripts/gen_dashboard.py
"""

import json
from pathlib import Path

OUT = (
    Path(__file__).resolve().parents[1] / "infrastructure/monitoring/dashboards/release-notes.json"
)
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
APP = 'namespace=~"$env", app_kubernetes_io_name="release-notes"'
# Business traffic only: exclude probes and scrapes.
API = APP + ', route!~"/health|/ready|/metrics"'

panels = []


def panel(title, kind, targets, x, y, w, h, ds=PROM, **extra):
    panels.append(
        {
            "id": len(panels) + 1,
            "title": title,
            "type": kind,
            "datasource": ds,
            "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "targets": [
                {"refId": chr(65 + i), "datasource": ds, **t} for i, t in enumerate(targets)
            ],
            **extra,
        }
    )


def prom(expr, legend):
    return {"expr": expr, "legendFormat": legend}


def ts(unit, **defaults):
    return {"fieldConfig": {"defaults": {"unit": unit, **defaults}, "overrides": []}}


panel(
    "Available replicas",
    "stat",
    [
        prom(
            'kube_deployment_status_replicas_available{namespace=~"$env", deployment="release-notes"}',
            "{{namespace}}",
        ),
    ],
    0,
    0,
    6,
    5,
    **ts(
        "none",
        thresholds={
            "mode": "absolute",
            "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}],
        },
    ),
)
panel(
    "Request rate",
    "stat",
    [
        prom(f"sum by (namespace) (rate(http_requests_total{{{API}}}[1m]))", "{{namespace}}"),
    ],
    6,
    0,
    6,
    5,
    **ts("reqps"),
)
panel(
    "5xx error ratio",
    "stat",
    [
        prom(
            f'sum by (namespace) (rate(http_requests_total{{{API}, status=~"5.."}}[5m]))'
            f" / sum by (namespace) (rate(http_requests_total{{{API}}}[5m]))",
            "{{namespace}}",
        ),
    ],
    12,
    0,
    6,
    5,
    **ts(
        "percentunit",
        noValue="0",
        thresholds={
            "mode": "absolute",
            "steps": [{"color": "green", "value": None}, {"color": "red", "value": 0.01}],
        },
    ),
)
panel(
    "Running versions (pods per version)",
    "stat",
    [
        prom(
            f"sum by (namespace, version) (release_notes_build_info{{{APP}}})",
            "{{namespace}} v{{version}}",
        ),
    ],
    18,
    0,
    6,
    5,
    **ts("none"),
)

panel(
    "Request rate by route and status",
    "timeseries",
    [
        prom(
            f"sum by (namespace, route, status) (rate(http_requests_total{{{API}}}[1m]))",
            "{{namespace}} {{route}} {{status}}",
        ),
    ],
    0,
    5,
    12,
    8,
    **ts("reqps"),
)
panel(
    "Latency p50 / p95 / p99",
    "timeseries",
    [
        prom(
            f"histogram_quantile({q}, sum by (namespace, le) "
            f"(rate(http_request_duration_seconds_bucket{{{API}}}[1m])))",
            f"{{{{namespace}}}} p{p}",
        )
        for q, p in ((0.5, 50), (0.95, 95), (0.99, 99))
    ],
    12,
    5,
    12,
    8,
    **ts("s"),
)
panel(
    "HTTP status distribution",
    "timeseries",
    [
        prom(f"sum by (status) (rate(http_requests_total{{{API}}}[1m]))", "{{status}}"),
    ],
    0,
    13,
    12,
    8,
    **ts("reqps", custom={"stacking": {"mode": "normal"}, "fillOpacity": 30}),
)
panel(
    "Pods by version (rollouts)",
    "timeseries",
    [
        prom(
            f"sum by (namespace, version) (release_notes_build_info{{{APP}}})",
            "{{namespace}} v{{version}}",
        ),
        prom(
            'kube_deployment_status_replicas_unavailable{namespace=~"$env", deployment="release-notes"}',
            "{{namespace}} unavailable",
        ),
    ],
    12,
    13,
    12,
    8,
    **ts("none", custom={"lineInterpolation": "stepAfter"}),
)
panel(
    "Scrape target up (per pod)",
    "timeseries",
    [
        prom(f"up{{{APP}}}", "{{namespace}} {{pod}}"),
    ],
    0,
    21,
    12,
    6,
    **ts("none", min=0, max=1),
)
panel(
    "Log volume by level",
    "timeseries",
    [
        {
            "expr": 'sum by (namespace, level) (count_over_time({namespace=~"$env", app="release-notes", '
            'component="api", level=~"$level"}[1m]))',
            "legendFormat": "{{namespace}} {{level}}",
        },
    ],
    12,
    21,
    12,
    6,
    ds=LOKI,
    **ts("none", custom={"drawStyle": "bars", "stacking": {"mode": "normal"}}),
)
panel(
    "Application logs",
    "logs",
    [
        {
            "expr": '{namespace=~"$env", app="release-notes", component="api", level=~"$level"} '
            '| json | line_format "{{.level}} {{.pod}} {{.method}} {{.route}} {{.status}} '
            '{{.duration_ms}}ms {{.message}}"'
        },
    ],
    0,
    27,
    24,
    10,
    ds=LOKI,
    options={
        "showTime": True,
        "wrapLogMessage": True,
        "sortOrder": "Descending",
        "enableLogDetails": True,
    },
)

dashboard = {
    "uid": "release-notes",
    "title": "Release Notes",
    "tags": ["release-notes"],
    "timezone": "browser",
    "refresh": "10s",
    "schemaVersion": 39,
    "time": {"from": "now-30m", "to": "now"},
    "templating": {
        "list": [
            {
                "name": "env",
                "label": "Environment",
                "type": "custom",
                "query": "dev,prod",
                "current": {"text": ["prod"], "value": ["prod"]},
                "multi": True,
                "includeAll": True,
                "allValue": "dev|prod",
                "options": [
                    {"text": v, "value": v, "selected": v == "prod"} for v in ("dev", "prod")
                ],
            },
            {
                "name": "level",
                "label": "Log level",
                "type": "custom",
                "query": "DEBUG,INFO,WARNING,ERROR",
                "multi": True,
                "includeAll": True,
                "allValue": ".+",
                "current": {"text": ["All"], "value": ["$__all"]},
                "options": [],
            },
        ]
    },
    "panels": panels,
}

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"wrote {OUT.relative_to(Path.cwd()) if OUT.is_relative_to(Path.cwd()) else OUT}")
