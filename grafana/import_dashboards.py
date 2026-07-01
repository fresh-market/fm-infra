#!/usr/bin/env python3
import json, re, urllib.request, urllib.error, os, sys, time, base64

GRAFANA_URL = os.getenv("GRAFANA_URL", "http://grafana:3000")
USER = os.getenv("GF_SECURITY_ADMIN_USER", "admin")
PASS = os.getenv("GF_SECURITY_ADMIN_PASSWORD", "user123")
DASHBOARD_DIR = os.getenv("DASHBOARD_DIR", "/dashboards")
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")

auth = base64.b64encode(f"{USER}:{PASS}".encode()).decode()
headers = {"Content-Type": "application/json", "Authorization": f"Basic {auth}"}

# Default time range overrides (applied per filename)
TIME_RANGES = {
    "jvm_micrometer.json": {"from": "now-15m", "to": "now"},
    "mysql_overview.json": {"from": "now-15m", "to": "now"},
}


def get(path):
    req = urllib.request.Request(f"{GRAFANA_URL}{path}", headers=headers)
    return urllib.request.urlopen(req, timeout=5)


def post(path, payload):
    req = urllib.request.Request(
        f"{GRAFANA_URL}{path}", data=json.dumps(payload).encode(), headers=headers
    )
    return urllib.request.urlopen(req, timeout=30)


def ensure_prometheus_datasource():
    """Create Prometheus datasource via API if it doesn't exist. Returns actual UID."""
    try:
        ds = json.loads(get("/api/datasources/uid/prometheus").read())
        print(f"  Prometheus datasource already exists (uid={ds['uid']})")
        return ds["uid"]
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise

    print("  Prometheus datasource not found. Creating via API...")
    try:
        result = json.loads(
            post(
                "/api/datasources",
                {
                    "name": "Prometheus",
                    "type": "prometheus",
                    "uid": "prometheus",
                    "url": PROMETHEUS_URL,
                    "access": "proxy",
                    "isDefault": True,
                    "jsonData": {"timeInterval": "15s"},
                },
            ).read()
        )
        uid = result.get("datasource", {}).get("uid", "prometheus")
        print(f"  Created Prometheus datasource (uid={uid})")
        return uid
    except urllib.error.HTTPError as e:
        print(f"  Create failed ({e.code}): {e.read().decode()}")
        print("  Searching for existing Prometheus datasource...")
        datasources = json.loads(get("/api/datasources").read())
        for ds in datasources:
            if ds.get("type") == "prometheus":
                uid = ds["uid"]
                print(f"  Found existing Prometheus datasource (uid={uid})")
                return uid
        raise RuntimeError("No Prometheus datasource found or created")


def fix_datasources(obj, ds_uid):
    """Convert all datasource references to Grafana 10+ object format using the actual UID."""
    if isinstance(obj, dict):
        if "datasource" in obj:
            ds = obj["datasource"]
            if isinstance(ds, str):
                if ds == "-- Grafana --":
                    obj["datasource"] = {"type": "grafana", "uid": "-- Grafana --"}
                elif ds.startswith("$"):
                    obj["datasource"] = {"uid": "${" + ds[1:] + "}"}
                elif ds:
                    obj["datasource"] = {"type": "prometheus", "uid": ds_uid}
            elif isinstance(ds, dict) and ds.get("uid") == "prometheus":
                ds["uid"] = ds_uid
        for v in obj.values():
            fix_datasources(v, ds_uid)
    elif isinstance(obj, list):
        for item in obj:
            fix_datasources(item, ds_uid)


def fix_variable_queries(dashboard, ds_uid):
    """Convert string variable queries to Grafana 10+ object format and clear stale current values."""
    for var in dashboard.get("templating", {}).get("list", []):
        vtype = var.get("type")

        if vtype == "query":
            if isinstance(var.get("query"), str):
                query_str = var["query"]
                var["query"] = {"query": query_str, "refId": "StandardVariableQuery"}
                if "definition" not in var:
                    var["definition"] = query_str
            var["current"] = {}
            var["options"] = []

        elif vtype == "datasource":
            var["current"] = {"selected": True, "text": "Prometheus", "value": ds_uid}
            var["options"] = []


def _walk_exprs(obj, fn):
    """Walk the entire dashboard JSON tree and apply fn to every 'expr' string."""
    if isinstance(obj, dict):
        if "expr" in obj and isinstance(obj["expr"], str):
            obj["expr"] = fn(obj["expr"])
        for v in obj.values():
            _walk_exprs(v, fn)
    elif isinstance(obj, list):
        for item in obj:
            _walk_exprs(item, fn)


def fix_spring_boot_namespace(dashboard):
    """Spring Boot Statistics: fix for non-Kubernetes environments.

    1. Namespace variable — set includeAll+allValue=.* so All=.* works as a regex.
    2. Instance variable query — namespace="…" → namespace=~"…" (regex).
    3. ALL panel expr fields — namespace="$Namespace" → namespace=~"$Namespace"
       and pool="$hikaricp" → pool=~"$hikaricp" so the .* allValue is used as regex.
    4. HikariCP variable — set includeAll so an empty pool list doesn't block panel data.
    """
    for var in dashboard.get("templating", {}).get("list", []):
        if var.get("name") == "Namespace" and var.get("type") == "query":
            var["includeAll"] = True
            var["allValue"] = ".*"
            var["current"] = {"selected": True, "text": "All", "value": "$__all"}

        elif var.get("name") == "instance" and var.get("type") == "query":
            query = var.get("query", {})
            if isinstance(query, dict):
                q = query.get("query", "").replace(
                    'namespace="$Namespace"', 'namespace=~"$Namespace"'
                )
                query["query"] = q
                var["definition"] = q

        elif var.get("name") == "hikaricp" and var.get("type") == "query":
            var["includeAll"] = True
            var["allValue"] = ".*"
            var["current"] = {"selected": True, "text": "All", "value": "$__all"}

    # Fix all panel expressions: equality → regex for namespace and pool
    def patch_expr(expr):
        expr = expr.replace('namespace="$Namespace"', 'namespace=~"$Namespace"')
        expr = expr.replace('pool="$hikaricp"', 'pool=~"$hikaricp"')
        return expr

    _walk_exprs(dashboard, patch_expr)


def fix_time_range(dashboard, filename):
    """Override default time range for specific dashboards."""
    if filename in TIME_RANGES:
        dashboard["time"] = TIME_RANGES[filename]


# ── Wait for Grafana ───────────────────────────────────────────────────────────
print(f"Waiting for Grafana at {GRAFANA_URL}...")
for _ in range(30):
    try:
        get("/api/health")
        print("Grafana is ready.")
        break
    except Exception as e:
        print(f"  Not ready: {e}")
        time.sleep(3)
else:
    print("Grafana did not become ready. Exiting.")
    sys.exit(1)

# ── Ensure datasource ─────────────────────────────────────────────────────────
print("Checking Prometheus datasource...")
ds_uid = ensure_prometheus_datasource()

# ── Import dashboards ─────────────────────────────────────────────────────────
files = sorted(f for f in os.listdir(DASHBOARD_DIR) if f.endswith(".json"))
print(f"Found {len(files)} dashboard(s) to import.")

for filename in files:
    path = os.path.join(DASHBOARD_DIR, filename)
    print(f"  Importing {filename}...", end=" ", flush=True)
    try:
        with open(path, encoding="utf-8-sig") as f:
            dashboard = json.load(f)
        dashboard.pop("id", None)
        fix_datasources(dashboard, ds_uid)
        fix_variable_queries(dashboard, ds_uid)
        fix_spring_boot_namespace(dashboard)
        fix_time_range(dashboard, filename)
        result = json.loads(
            post(
                "/api/dashboards/db",
                {"dashboard": dashboard, "overwrite": True, "folderId": 0},
            ).read()
        )
        print(f"OK  ({result.get('slug', '')})")
    except urllib.error.HTTPError as e:
        print(f"ERROR {e.code}: {e.read().decode()}")
    except Exception as e:
        print(f"ERROR: {e}")

print("Import complete.")
