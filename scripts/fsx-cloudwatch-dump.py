#!/usr/bin/env python3
"""fsx-cloudwatch-dump.py — the D-39 post-cell FSx server-side CloudWatch window dump.

WHY THIS EXISTS
    The RUNBOOK's Lustre source table declares "CloudWatch per-OST/MDT metrics"
    PRIMARY — the server-side view, the one source not measured from the client.
    Nothing captured it, so the multiple-sources rule ran a declared Primary
    short on this leg. This dumps the AWS/FSx metrics for the cell's recorded
    [started_utc, ended_utc] window into the run dir beside the other raw
    sources. CloudWatch is 1-minute resolution, so this stream NEVER joins the
    1 Hz ratio checks — it is the server-side record, not a canary input.

DOC BASIS (fetched 2026-08-21, never recalled):
    https://docs.aws.amazon.com/fsx/latest/LustreGuide/fs-metrics.html
    Namespace AWS/FSx, 1-minute period. Per-OST/MDT granularity exists via the
    StorageTargetId dimension (OSTxxxx / MDTxxxx); per-OSS/MDS via FileServer;
    file-system-level network I/O metrics via FileSystemId alone. All OST disk
    metrics apply on PERSISTENT_2 SSD (the Scratch/HDD exclusions do not bind).

WHAT IT DUMPS
    Every (metric, dimension-set) combination CloudWatch lists for this file
    system — deliberately uncurated (over-capture is cheap; a curated subset is
    a prediction about which axis matters). Five statistics per series:
    Sum, Average, Minimum, Maximum, SampleCount. Sum is meaningless for the
    utilization/CPU percentages and SampleCount for most — harmless, recorded
    anyway rather than curated.

PUBLISH LAG AND THE TWO-PHASE CAPTURE
    CloudWatch publishes with ~1–2 min lag, so the immediate post-cell dump
    (record-run.sh cleanup) may be right-truncated. A dump fetched more than
    FINAL_LAG_S after the cell's end is marked "final": true; re-invocation
    skips final dumps and re-fetches non-final ones, which is what makes the
    run-leg.sh per-step backfill idempotent and cheap. This is also why the
    dump is warn-only at cell time and NOT in record-run.sh's required-streams
    list: making a lag-truncated fetch verdict-gating would flip false
    INCOMPLETEs. CloudWatch retains 15 months, so a missed window is
    re-dumpable long after the fact — unlike every client-side stream.

USAGE
    fsx-cloudwatch-dump.py <run-dir> [<run-dir> ...]   # dump/backfill; skips final dumps
    fsx-cloudwatch-dump.py --force <run-dir> ...       # re-fetch even final dumps

    Non-lustre run dirs and dirs without a recorded window are skipped with a
    line saying so (backfill passes a broad glob). Exit non-zero only when a
    lustre cell that SHOULD dump could not — a skip is not a failure.

OUTPUT (per run dir)
    raw/fsx-cloudwatch.json  verbatim series + window/provenance/final flag
    raw/fsx-cloudwatch.csv   flat rows: timestamp,metric,dimensions,stat,value
"""

import csv
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

NAMESPACE = "AWS/FSx"
PERIOD_S = 60
# Publish-lag margin past the cell's end before a dump counts as final.
FINAL_LAG_S = 180
# Window padding: one bin before the start (bin containing the start), and one
# past the end, so edge bins are captured whole.
PAD_S = 60
STATS = ["Sum", "Average", "Minimum", "Maximum", "SampleCount"]
MAX_QUERIES_PER_CALL = 500  # GetMetricData hard limit
DOC_BASIS = ("https://docs.aws.amazon.com/fsx/latest/LustreGuide/fs-metrics.html "
             "(fetched 2026-08-21): AWS/FSx, 1-minute period; per-OST/MDT via "
             "StorageTargetId, per-OSS/MDS via FileServer")


def die(msg):
    print(f"fsx-cloudwatch-dump: FATAL: {msg}", file=sys.stderr)
    sys.exit(2)


def parse_utc(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def aws(args, region):
    """Run one aws CLI call, return parsed JSON. The CLI auto-paginates."""
    cmd = ["aws", "--region", region, "--output", "json"] + args
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"aws {' '.join(args[:3])}... rc={r.returncode}: {r.stderr.strip()[:500]}")
    return json.loads(r.stdout)


def fsx_id_from_conf():
    """FSX_ID from the environment, else /etc/wsi-bootstrap.conf (terraform-fed,
    never retyped). Fail loud otherwise — a guessed file system id would dump a
    different filesystem's metrics under this cell's name."""
    import os
    v = os.environ.get("FSX_ID")
    if v:
        return v
    conf = Path("/etc/wsi-bootstrap.conf")
    if conf.is_file():
        for line in conf.read_text().splitlines():
            if line.startswith("FSX_ID="):
                return line.split("=", 1)[1].strip().strip('"')
    die("FSX_ID not in the environment and not in /etc/wsi-bootstrap.conf")


def list_series(fsx_id, region):
    """Every (metric, dimensions) combo CloudWatch lists for this file system."""
    out = aws(["cloudwatch", "list-metrics", "--namespace", NAMESPACE,
               "--dimensions", f"Name=FileSystemId,Value={fsx_id}"], region)
    series = []
    for m in out.get("Metrics", []):
        dims = sorted(m.get("Dimensions", []), key=lambda d: d["Name"])
        series.append((m["MetricName"], dims))
    if not series:
        raise RuntimeError(f"list-metrics returned nothing for {fsx_id} — wrong id or no data yet")
    return series


def fetch_window(series, start, end, region):
    """GetMetricData for every series x stat, chunked under the query limit."""
    queries, legend = [], {}
    for i, (metric, dims) in enumerate(series):
        for stat in STATS:
            qid = f"q{i}_{stat.lower()}"
            legend[qid] = {"metric": metric,
                           "dimensions": {d["Name"]: d["Value"] for d in dims},
                           "stat": stat}
            queries.append({
                "Id": qid,
                "MetricStat": {
                    "Metric": {"Namespace": NAMESPACE, "MetricName": metric,
                               "Dimensions": dims},
                    "Period": PERIOD_S,
                    "Stat": stat,
                },
                "ReturnData": True,
            })
    results = []
    import tempfile
    for lo in range(0, len(queries), MAX_QUERIES_PER_CALL):
        # file:// rather than inline: a batch of hundreds of queries exceeds the
        # kernel's per-argument size limit (E2BIG) as one argv string.
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tf:
            json.dump(queries[lo:lo + MAX_QUERIES_PER_CALL], tf)
            qfile = tf.name
        try:
            out = aws(["cloudwatch", "get-metric-data",
                       "--metric-data-queries", f"file://{qfile}",
                       "--start-time", iso(start), "--end-time", iso(end),
                       "--scan-by", "TimestampAscending"], region)
        finally:
            Path(qfile).unlink(missing_ok=True)
        results.extend(out.get("MetricDataResults", []))
    rows = []
    for r in results:
        info = legend[r["Id"]]
        rows.append({**info,
                     "timestamps": [t.replace("+00:00", "Z") for t in r.get("Timestamps", [])],
                     "values": r.get("Values", []),
                     "status_code": r.get("StatusCode")})
    return rows


def dump_run_dir(run_dir, fsx_id, region, force):
    """Returns 'dumped' | 'final' | 'skipped' | 'failed'."""
    meta_path = run_dir / "metadata.json"
    if not meta_path.is_file():
        print(f"  skip (no metadata.json): {run_dir.name}")
        return "skipped"
    meta = json.loads(meta_path.read_text())
    if meta.get("fs") != "lustre":
        print(f"  skip (fs={meta.get('fs')}): {run_dir.name}")
        return "skipped"
    if not meta.get("started_utc") or not meta.get("ended_utc"):
        print(f"  skip (no recorded window — interrupted cell?): {run_dir.name}")
        return "skipped"

    out_json = run_dir / "raw" / "fsx-cloudwatch.json"
    if out_json.is_file() and not force:
        try:
            if json.loads(out_json.read_text()).get("final"):
                return "final"
        except (json.JSONDecodeError, OSError):
            pass  # unreadable prior dump -> re-fetch

    started = parse_utc(meta["started_utc"])
    ended = parse_utc(meta["ended_utc"])
    w_start = started.replace(second=0, microsecond=0) - timedelta(seconds=PAD_S)
    w_end = ended.replace(second=0, microsecond=0) + timedelta(seconds=PERIOD_S + PAD_S)
    fetched = datetime.now(timezone.utc)
    final = fetched >= ended + timedelta(seconds=FINAL_LAG_S)

    try:
        series = fetch_window(list_series(fsx_id, region), w_start, w_end, region)
    except RuntimeError as e:
        print(f"  FAILED {run_dir.name}: {e}", file=sys.stderr)
        return "failed"

    (run_dir / "raw").mkdir(exist_ok=True)
    payload = {
        "fetched_utc": iso(fetched),
        "file_system_id": fsx_id,
        "namespace": NAMESPACE,
        "period_s": PERIOD_S,
        "cell_started_utc": meta["started_utc"],
        "cell_ended_utc": meta["ended_utc"],
        "window_start_utc": iso(w_start),
        "window_end_utc": iso(w_end),
        # final: fetched late enough that CloudWatch's publish lag cannot have
        # right-truncated the window. Non-final dumps are re-fetched by the
        # run-leg.sh per-step backfill; final ones are skipped (idempotence).
        "final": final,
        "final_lag_s": FINAL_LAG_S,
        "doc_basis": DOC_BASIS,
        "series": series,
    }
    out_json.write_text(json.dumps(payload, indent=1))

    with (run_dir / "raw" / "fsx-cloudwatch.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["timestamp_utc", "metric", "dimensions", "stat", "value"])
        for s in series:
            dims = ";".join(f"{k}={v}" for k, v in sorted(s["dimensions"].items()))
            for t, v in zip(s["timestamps"], s["values"]):
                w.writerow([t, s["metric"], dims, s["stat"], v])

    n_pts = sum(len(s["values"]) for s in series)
    print(f"  dumped {run_dir.name}: {len(series)} series, {n_pts} points, final={final}")
    return "dumped"


def main():
    import os
    args = sys.argv[1:]
    force = "--force" in args
    dirs = [Path(a) for a in args if a != "--force"]
    if not dirs:
        die("usage: fsx-cloudwatch-dump.py [--force] <run-dir> [<run-dir> ...]")
    region = os.environ.get("AWS_REGION") or die("AWS_REGION is unset -- source env.sh")
    fsx_id = fsx_id_from_conf()

    counts = {"dumped": 0, "final": 0, "skipped": 0, "failed": 0}
    for d in sorted(dirs):
        if not d.is_dir():
            continue
        counts[dump_run_dir(d, fsx_id, region, force)] += 1
    print(f"fsx-cloudwatch-dump: {counts['dumped']} dumped, {counts['final']} already-final, "
          f"{counts['skipped']} skipped, {counts['failed']} FAILED")
    sys.exit(1 if counts["failed"] else 0)


if __name__ == "__main__":
    main()
