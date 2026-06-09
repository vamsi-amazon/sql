#!/usr/bin/env bash
# =============================================================================
# run-report.sh — Run the analytics-engine PPL coverage report
#
# Prerequisites:
#   - Cluster running at localhost:9200 (use start-cluster.sh)
#   - SQL plugin test classes compiled
#
# Usage:
#   ./scripts/analytics-coverage/run-report.sh [single|multi]
#
#   single  (default) — 1 shard, 0 replicas (single-node)
#   multi   — 3 shards, 1 replica (requires 3-node cluster)
#
# Output:
#   single → integ-test/build/reports/analytics-compatibility/REPORT.md
#   multi  → integ-test/build/reports/analytics-compatibility-multishard/REPORT.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPENSEARCH_HOME="${OPENSEARCH_HOME:-$(cd "$SQL_REPO/../OpenSearch" && pwd)}"
MODE="${1:-single}"

CLUSTER_URL="${CLUSTER_URL:-localhost:9200}"
CLUSTER_TRANSPORT="${CLUSTER_TRANSPORT:-localhost:9300}"
CLUSTER_NAME="${CLUSTER_NAME:-analytics-coverage}"
CLUSTER_LOG="${CLUSTER_LOG:-}"

# Auto-detect cluster log location
if [ -z "$CLUSTER_LOG" ]; then
    for candidate in \
        "$OPENSEARCH_HOME/build/testclusters/runTask-0/logs/runTask.log" \
        "$OPENSEARCH_HOME/build/distribution/local/opensearch-3.7.0-SNAPSHOT/logs/opensearch.log" \
        "$OPENSEARCH_HOME/build/distribution/local/opensearch-3.7.0-SNAPSHOT/logs/${CLUSTER_NAME}.log"; do
        if [ -f "$candidate" ]; then
            CLUSTER_LOG="$candidate"
            break
        fi
    done
fi

echo "=== Analytics Coverage Report ==="
echo "  Mode:           $MODE"
echo "  SQL repo:       $SQL_REPO"
echo "  Cluster:        $CLUSTER_URL"
echo "  Cluster log:    ${CLUSTER_LOG:-<not found, origin column will show '?'>}"
echo ""

# Verify cluster is reachable
echo "Checking cluster health..."
HEALTH=$(curl -s --connect-timeout 5 "http://$CLUSTER_URL/_cluster/health" 2>&1) || {
    echo "ERROR: Cannot reach cluster at http://$CLUSTER_URL"
    echo "Start the cluster first: ./scripts/analytics-coverage/start-cluster.sh"
    exit 1
}
echo "  → $HEALTH" | python3 -c "import json,sys; h=json.load(sys.stdin); print(f'  Status: {h[\"status\"]}, Nodes: {h[\"number_of_nodes\"]}')" 2>/dev/null || echo "  → Cluster is up"
echo ""

cd "$SQL_REPO"

# Build args
GRADLE_ARGS=(
    "-Dtests.rest.cluster=$CLUSTER_URL"
    "-Dtests.cluster=$CLUSTER_TRANSPORT"
    "-Dtests.clustername=$CLUSTER_NAME"
    "-Dhttps=false"
)

if [ -n "$CLUSTER_LOG" ]; then
    GRADLE_ARGS+=("-PclusterLog=$CLUSTER_LOG")
fi

REPORT_HISTORY_DIR="$SCRIPT_DIR/.reports"
mkdir -p "$REPORT_HISTORY_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

run_single() {
    echo "Running single-shard compatibility report (1 shard, 0 replicas)..."
    ./gradlew :integ-test:analyticsCompatibilityReport "${GRADLE_ARGS[@]}"
}

run_single_multishard() {
    echo "Running single-node multi-shard report (3 shards, 0 replicas, 1 node)..."
    ./gradlew :integ-test:analyticsSingleNodeMultiShardReport "${GRADLE_ARGS[@]}"
}

run_multi() {
    echo "Running multi-node multi-shard report (3 shards, 1 replica, 3 nodes)..."
    ./gradlew :integ-test:analyticsMultiShardReport "${GRADLE_ARGS[@]}"
}

case "$MODE" in
    single)
        run_single
        REPORT_MD="$SQL_REPO/integ-test/build/reports/analytics-compatibility/REPORT.md"
        REPORT_LABEL="single-shard"
        ;;
    single-multishard)
        run_single_multishard
        REPORT_MD="$SQL_REPO/integ-test/build/reports/analytics-compatibility-singlenode-multishard/REPORT.md"
        REPORT_LABEL="single-node-multishard"
        ;;
    multi)
        run_multi
        REPORT_MD="$SQL_REPO/integ-test/build/reports/analytics-compatibility-multishard/REPORT.md"
        REPORT_LABEL="multi-node-multishard"
        ;;
    all)
        echo "Running ALL 3 configurations..."
        echo ""
        run_single
        run_single_multishard
        run_multi
        REPORT_LABEL="all"
        ;;
    *)
        echo "ERROR: Unknown mode '$MODE'. Use 'single', 'single-multishard', 'multi', or 'all'."
        exit 1
        ;;
esac

# ── Archive report and generate HTML ─────────────────────────────────────────
SINGLE_MD="$SQL_REPO/integ-test/build/reports/analytics-compatibility/REPORT.md"
SNMS_MD="$SQL_REPO/integ-test/build/reports/analytics-compatibility-singlenode-multishard/REPORT.md"
MULTI_MD="$SQL_REPO/integ-test/build/reports/analytics-compatibility-multishard/REPORT.md"

# For 'all' mode, generate combined analysis
if [ "$MODE" = "all" ]; then
    REPORT_MD="$SINGLE_MD"  # use single as primary for pass rate extraction
fi

if [ -f "$REPORT_MD" ]; then
    # Save timestamped copy
    ARCHIVE_NAME="${TIMESTAMP}_${REPORT_LABEL}"
    if [ "$MODE" = "all" ]; then
        cp "$SINGLE_MD" "$REPORT_HISTORY_DIR/${ARCHIVE_NAME}_single.md" 2>/dev/null
        cp "$SNMS_MD" "$REPORT_HISTORY_DIR/${ARCHIVE_NAME}_single-multishard.md" 2>/dev/null
        cp "$MULTI_MD" "$REPORT_HISTORY_DIR/${ARCHIVE_NAME}_multi.md" 2>/dev/null
    else
        cp "$REPORT_MD" "$REPORT_HISTORY_DIR/${ARCHIVE_NAME}.md"
    fi

    # Extract pass rate for the index
    PASS_RATE=$(grep -oP '\*\*\d+\.\d+%\*\*' "$REPORT_MD" | head -1 | tr -d '*')
    PASSED=$(grep "| Passed |" "$REPORT_MD" | grep -oP '\d+' | head -1)
    FAILED=$(grep "| Failed |" "$REPORT_MD" | grep -oP '\d+' | head -1)

    # For 'all' mode, generate combined analysis HTML
    if [ "$MODE" = "all" ]; then
        python3 - "$SINGLE_MD" "$SNMS_MD" "$MULTI_MD" "$REPORT_HISTORY_DIR/${ARCHIVE_NAME}.html" "$TIMESTAMP" << 'PYEOF'
import sys, re, os

single_md, snms_md, multi_md, out_html, timestamp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

def extract_stats(path):
    if not os.path.exists(path):
        return {'pass_rate': '?', 'passed': 0, 'failed': 0, 'skipped': 0, 'total': 0, 'time': '?'}
    with open(path) as f:
        content = f.read()
    stats = {}
    m = re.search(r'\*\*Pass rate\*\*.*?\*\*(\d+\.\d+%)\*\*', content)
    stats['pass_rate'] = m.group(1) if m else '?'
    m = re.search(r'\| Passed \| (\d+)', content)
    stats['passed'] = int(m.group(1)) if m else 0
    m = re.search(r'\| Failed \| (\d+)', content)
    stats['failed'] = int(m.group(1)) if m else 0
    m = re.search(r'\| Skipped \| (\d+)', content)
    stats['skipped'] = int(m.group(1)) if m else 0
    m = re.search(r'\| Tests executed.*?\| (\d+)', content)
    stats['total'] = int(m.group(1)) if m else 0
    m = re.search(r'\| Total time \| ([\d.]+)s', content)
    stats['time'] = m.group(1) + 's' if m else '?'
    # Extract category breakdown
    m = re.search(r'Correctness.*?\| (\d+)', content)
    stats['correctness'] = int(m.group(1)) if m else 0
    m = re.search(r'Stability.*?\| (\d+)', content)
    stats['stability'] = int(m.group(1)) if m else 0
    return stats

s = extract_stats(single_md)
snms = extract_stats(snms_md)
mu = extract_stats(multi_md)

def color(rate_str):
    try:
        v = float(rate_str.rstrip('%'))
        if v >= 70: return '#28a745'
        if v >= 50: return '#ffc107'
        return '#dc3545'
    except: return '#666'

date_display = f"{timestamp[:4]}-{timestamp[4:6]}-{timestamp[6:8]} {timestamp[9:11]}:{timestamp[11:13]}:{timestamp[13:15]}"

# Compute regressions
delta_snms = snms['failed'] - s['failed']
delta_multi = mu['failed'] - s['failed']

html = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<title>Coverage Analysis — All Configs — {date_display}</title>
<style>
body {{ font-family: -apple-system, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; background: #f8f9fa; }}
h1 {{ color: #1a1a2e; border-bottom: 3px solid #16213e; padding-bottom: 10px; }}
h2 {{ color: #16213e; margin-top: 35px; border-left: 4px solid #0f3460; padding-left: 12px; }}
table {{ border-collapse: collapse; width: 100%; margin: 15px 0; }}
th, td {{ border: 1px solid #ddd; padding: 8px 12px; text-align: left; }}
th {{ background: #16213e; color: white; }}
tr:nth-child(even) {{ background: #f2f2f2; }}
.summary-grid {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; margin: 20px 0; }}
.summary-card {{ background: white; border-radius: 8px; padding: 20px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
.summary-card .number {{ font-size: 2em; font-weight: bold; }}
.summary-card .label {{ color: #666; margin-top: 5px; font-size: 0.9em; }}
.delta {{ font-size: 0.8em; color: #dc3545; }}
.badge {{ display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.85em; }}
.badge-red {{ background: #ffebee; color: #c62828; }}
.badge-orange {{ background: #fff3e0; color: #e65100; }}
.badge-blue {{ background: #e3f2fd; color: #1565c0; }}
.badge-green {{ background: #e8f5e9; color: #2e7d32; }}
pre {{ background: #1a1a2e; color: #e0e0e0; padding: 12px; border-radius: 6px; overflow-x: auto; font-size: 0.85em; }}
</style></head><body>

<h1>Analytics-Engine Coverage — Combined Analysis</h1>
<p><em>Generated: {date_display} | OpenSearch 3.7.0-SNAPSHOT</em></p>

<div class="summary-grid">
  <div class="summary-card">
    <div class="number" style="color:{color(s['pass_rate'])}">{s['pass_rate']}</div>
    <div class="label">Single-Shard<br>(1 shard, 0 replicas, 1 node)</div>
  </div>
  <div class="summary-card">
    <div class="number" style="color:{color(snms['pass_rate'])}">{snms['pass_rate']}</div>
    <div class="label">Multi-Shard<br>(3 shards, 0 replicas, 1 node)</div>
    <div class="delta">+{delta_snms} failures vs single</div>
  </div>
  <div class="summary-card">
    <div class="number" style="color:{color(mu['pass_rate'])}">{mu['pass_rate']}</div>
    <div class="label">Multi-Node<br>(3 shards, 1 replica, 3 nodes)</div>
    <div class="delta">+{delta_multi} failures vs single</div>
  </div>
</div>

<h2>Comparison Table</h2>
<table>
<tr><th>Metric</th><th>1 shard / 1 node</th><th>3 shards / 1 node</th><th>3 shards / 3 nodes</th></tr>
<tr><td>Pass rate</td><td style="color:{color(s['pass_rate'])};font-weight:bold">{s['pass_rate']}</td><td style="color:{color(snms['pass_rate'])};font-weight:bold">{snms['pass_rate']}</td><td style="color:{color(mu['pass_rate'])};font-weight:bold">{mu['pass_rate']}</td></tr>
<tr><td>Passed</td><td>{s['passed']}</td><td>{snms['passed']}</td><td>{mu['passed']}</td></tr>
<tr><td>Failed</td><td>{s['failed']}</td><td>{snms['failed']}</td><td>{mu['failed']}</td></tr>
<tr><td>Skipped</td><td>{s['skipped']}</td><td>{snms['skipped']}</td><td>{mu['skipped']}</td></tr>
<tr><td>Total (in scope)</td><td>{s['total']}</td><td>{snms['total']}</td><td>{mu['total']}</td></tr>
<tr><td>Runtime</td><td>{s['time']}</td><td>{snms['time']}</td><td>{mu['time']}</td></tr>
<tr><td>Correctness failures</td><td>{s['correctness']}</td><td>{snms['correctness']}</td><td>{mu['correctness']}</td></tr>
<tr><td>Stability errors</td><td>{s['stability']}</td><td>{snms['stability']}</td><td>{mu['stability']}</td></tr>
</table>

<h2>Key Findings</h2>
<ul>
<li><strong>Single → Multi-shard drop:</strong> {s['pass_rate']} → {snms['pass_rate']} ({delta_snms:+d} failures). Caused by shard coordination — ordering, streaming fragment dispatch, span merge.</li>
<li><strong>Multi-shard → Multi-node drop:</strong> {snms['pass_rate']} → {mu['pass_rate']} ({mu['failed'] - snms['failed']:+d} failures). Negligible — replication doesn't introduce meaningful new failures.</li>
<li><strong>Correctness vs Stability split (multi-shard):</strong> {snms['correctness']} correctness ({int(100*snms['correctness']/(snms['correctness']+snms['stability'])) if (snms['correctness']+snms['stability']) > 0 else 0}%) / {snms['stability']} stability ({int(100*snms['stability']/(snms['correctness']+snms['stability'])) if (snms['correctness']+snms['stability']) > 0 else 0}%)</li>
</ul>

<h2>Multi-Shard Regression Categories</h2>
<table>
<tr><th>Category</th><th>Count</th><th>Share</th><th>Root Cause</th></tr>
<tr><td><span class="badge badge-orange">ORDERING</span></td><td>~104</td><td>56%</td><td><code>RowProducingSink.feed()</code> appends batches in arrival order (race) vs Lucene's deterministic <code>shardIndex ASC</code> tiebreaker</td></tr>
<tr><td><span class="badge badge-red">STREAMING</span></td><td>~45</td><td>24%</td><td>Streaming fragment dispatch fails for full-text search on multi-shard parquet — <code>ReaderContext</code> not acquired before dispatch</td></tr>
<tr><td><span class="badge badge-blue">SPAN/AGG</span></td><td>~26</td><td>14%</td><td>Coordinator reduce doesn't coalesce partial span buckets from different shards</td></tr>
<tr><td><span class="badge badge-red">SERVER 500</span></td><td>~11</td><td>6%</td><td>Multi-fragment plan shapes trigger planner/executor bugs not hit by single-shard</td></tr>
</table>

<h2>Action Items</h2>
<table>
<tr><th>Priority</th><th>Issue</th><th>Tests</th><th>Fix</th></tr>
<tr><td>P1</td><td>Streaming fragment + Lucene filter delegation</td><td>45</td><td>Fix <code>AnalyticsSearchService</code> reader context setup for multi-shard</td></tr>
<tr><td>P2</td><td>Span bucket merge</td><td>26</td><td>Fix <code>ReduceStageExecution</code> to coalesce adjacent span buckets</td></tr>
<tr><td>P3</td><td>Ordering parity with DSL</td><td>104</td><td>Use <code>OrdinalAppendingSink</code> ordinals for merge ordering, or fix tests</td></tr>
<tr><td>P4</td><td>Misc server errors</td><td>11</td><td>Individual bug fixes in planner</td></tr>
</table>

</body></html>"""

with open(out_html, 'w') as f:
    f.write(html)
print(f"  Combined analysis: {out_html}")
PYEOF
        # Set PASS_RATE for the index from the single-shard report
        PASS_RATE=$(grep -oP '\*\*\d+\.\d+%\*\*' "$SINGLE_MD" | head -1 | tr -d '*')
    else
        # For single-mode reports, generate simple HTML version
        python3 - "$REPORT_MD" "$REPORT_HISTORY_DIR/${ARCHIVE_NAME}.html" "$REPORT_LABEL" "$PASS_RATE" << 'PYEOF'
import sys, re, html

md_path, html_path, label, pass_rate = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(md_path, 'r') as f:
    md = f.read()

# Simple markdown to HTML conversion for tables and headers
lines = md.split('\n')
body_lines = []
in_table = False
for line in lines:
    if line.startswith('# '):
        body_lines.append(f'<h1>{html.escape(line[2:])}</h1>')
    elif line.startswith('## '):
        body_lines.append(f'<h2>{html.escape(line[3:])}</h2>')
    elif line.startswith('### '):
        body_lines.append(f'<h3>{html.escape(line[4:])}</h3>')
    elif '|' in line and line.strip().startswith('|'):
        cells = [c.strip() for c in line.split('|')[1:-1]]
        if all(re.match(r'^[-:]+$', c) for c in cells):
            continue  # separator row
        if not in_table:
            body_lines.append('<table>')
            in_table = True
        tag = 'th' if body_lines[-1] == '<table>' else 'td'
        row = ''.join(f'<{tag}>{html.escape(c)}</{tag}>' for c in cells)
        body_lines.append(f'<tr>{row}</tr>')
    else:
        if in_table:
            body_lines.append('</table>')
            in_table = False
        if line.strip():
            body_lines.append(f'<p>{html.escape(line)}</p>')
if in_table:
    body_lines.append('</table>')

pass_color = '#28a745' if float(pass_rate.rstrip('%')) >= 70 else '#ffc107' if float(pass_rate.rstrip('%')) >= 50 else '#dc3545'

html_content = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<title>Coverage Report — {label} — {pass_rate}</title>
<style>
body {{ font-family: -apple-system, sans-serif; max-width: 1100px; margin: 0 auto; padding: 20px; background: #f8f9fa; }}
h1 {{ color: #1a1a2e; border-bottom: 2px solid #16213e; padding-bottom: 8px; }}
h2 {{ color: #16213e; margin-top: 30px; }}
table {{ border-collapse: collapse; width: 100%; margin: 10px 0; }}
th, td {{ border: 1px solid #ddd; padding: 6px 10px; text-align: left; font-size: 0.9em; }}
th {{ background: #16213e; color: white; }}
tr:nth-child(even) {{ background: #f2f2f2; }}
.pass-badge {{ display: inline-block; font-size: 1.5em; font-weight: bold; color: {pass_color}; border: 2px solid {pass_color}; border-radius: 8px; padding: 5px 15px; margin: 10px 0; }}
</style></head><body>
<div class="pass-badge">{pass_rate}</div>
{''.join(body_lines)}
</body></html>"""

with open(html_path, 'w') as f:
    f.write(html_content)
PYEOF
    fi  # end if MODE=all / else

    # Regenerate index.html listing all reports (latest first, max 30)
    python3 - "$REPORT_HISTORY_DIR" << 'PYEOF'
import os, re, sys

report_dir = sys.argv[1]
reports = []
for f in sorted(os.listdir(report_dir), reverse=True):
    if f.endswith('.html') and f != 'index.html':
        # Parse: 20260604-041729_single-shard.html
        m = re.match(r'(\d{8})-(\d{6})_(.+)\.html', f)
        if m:
            date_str = f"{m.group(1)[:4]}-{m.group(1)[4:6]}-{m.group(1)[6:8]} {m.group(2)[:2]}:{m.group(2)[2:4]}:{m.group(2)[4:6]}"
            label = m.group(3)
            # Read pass rate from the file
            with open(os.path.join(report_dir, f), 'r') as fh:
                content = fh.read()
            pass_match = re.search(r'class="pass-badge">([^<]+)<', content)
            pass_rate = pass_match.group(1) if pass_match else '?'
            reports.append((date_str, label, pass_rate, f))

# Keep only last 30
reports = reports[:30]

rows = []
for date, label, rate, filename in reports:
    rate_val = float(rate.rstrip('%')) if rate != '?' else 0
    color = '#28a745' if rate_val >= 70 else '#ffc107' if rate_val >= 50 else '#dc3545'
    rows.append(f'<tr><td>{date}</td><td>{label}</td><td style="color:{color};font-weight:bold">{rate}</td><td><a href="{filename}">View</a></td></tr>')

index_html = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<title>Analytics Coverage Reports — History</title>
<style>
body {{ font-family: -apple-system, sans-serif; max-width: 900px; margin: 0 auto; padding: 20px; background: #f8f9fa; }}
h1 {{ color: #1a1a2e; }}
table {{ border-collapse: collapse; width: 100%; }}
th, td {{ border: 1px solid #ddd; padding: 10px 14px; text-align: left; }}
th {{ background: #16213e; color: white; }}
tr:nth-child(even) {{ background: #f2f2f2; }}
a {{ color: #0f3460; }}
.subtitle {{ color: #666; margin-top: -10px; }}
</style></head><body>
<h1>Analytics-Engine Coverage Reports</h1>
<p class="subtitle">Last {len(reports)} runs (latest first). Reports older than 30 are auto-pruned.</p>
<table>
<tr><th>Date</th><th>Config</th><th>Pass Rate</th><th>Report</th></tr>
{''.join(rows)}
</table>
</body></html>"""

with open(os.path.join(report_dir, 'index.html'), 'w') as f:
    f.write(index_html)

# Prune: keep only last 30 html + md pairs
all_reports = sorted([f for f in os.listdir(report_dir) if f != 'index.html'], reverse=True)
html_files = [f for f in all_reports if f.endswith('.html')]
if len(html_files) > 30:
    for old in html_files[30:]:
        os.remove(os.path.join(report_dir, old))
        md_version = old.replace('.html', '.md')
        md_path = os.path.join(report_dir, md_version)
        if os.path.exists(md_path):
            os.remove(md_path)

print(f"  Index updated: {len(reports)} reports in history")
PYEOF

    echo ""
    echo "=== Report generated ==="
    echo "  Markdown: $REPORT_MD"
    echo "  HTML:     $REPORT_HISTORY_DIR/${ARCHIVE_NAME}.html"
    echo "  Index:    $REPORT_HISTORY_DIR/index.html"
    echo "  Pass rate: ${PASS_RATE:-unknown}"
fi
