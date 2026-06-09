#!/usr/bin/env bash
# =============================================================================
# start-cluster-multinode.sh — Start a 3-node OpenSearch cluster with the full
# analytics-engine plugin stack for running the multi-shard coverage report.
#
# This is the multi-node counterpart to start-cluster.sh. It creates 3 separate
# OpenSearch data directories, each running as a separate process, forming a
# cluster via seed discovery on localhost ports.
#
# Layout:
#   $DISTRO_DIR/              ← shared binary installation (plugins, libs, bin/)
#   $CLUSTER_DIR/
#     ├── node-0/             ← data + logs + config for node 0 (ports 9200/9300)
#     ├── node-1/             ← data + logs + config for node 1 (ports 9201/9301)
#     └── node-2/             ← data + logs + config for node 2 (ports 9202/9302)
#
# Prerequisites:
#   - Run start-cluster.sh at least once first (builds distro + installs plugins)
#   - Or pass --build to do a full build before starting
#
# Usage:
#   ./scripts/analytics-coverage/start-cluster-multinode.sh [--build] [--clean]
#
#   --build   Run the full build pipeline (same as start-cluster.sh steps 1-6)
#   --clean   Wipe cluster data dirs before starting (fresh cluster)
#
# The cluster will be available at http://localhost:9200
# All 3 nodes run in the foreground (backgrounded children, parent waits).
# Kill with Ctrl+C — sends SIGTERM to all nodes.
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPENSEARCH_HOME="${OPENSEARCH_HOME:-$(cd "$SQL_REPO/../OpenSearch" && pwd)}"
OS_VERSION="3.7.0-SNAPSHOT"
PLUGIN_VERSION="3.7.0.0-SNAPSHOT"

DISTRO_DIR="$OPENSEARCH_HOME/build/distribution/local/opensearch-$OS_VERSION"
CLUSTER_DIR="$SCRIPT_DIR/.workdir/cluster-3node"
NATIVE_LIB_DIR="$OPENSEARCH_HOME/sandbox/libs/dataformat-native/rust/target/release"

NUM_NODES=3
BASE_HTTP_PORT=9200
BASE_TRANSPORT_PORT=9300

# ── Helpers ───────────────────────────────────────────────────────────────────
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RED="\033[31m"
RESET="\033[0m"

step()    { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n${BOLD}  $1${RESET}\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
info()    { echo -e "  ${DIM}→${RESET} $1"; }
success() { echo -e "  ${GREEN}✓${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $1"; }

# ── Parse args ────────────────────────────────────────────────────────────────
DO_BUILD=false
DO_CLEAN=false
for arg in "$@"; do
    case "$arg" in
        --build) DO_BUILD=true ;;
        --clean) DO_CLEAN=true ;;
        --help|-h)
            echo "Usage: $0 [--build] [--clean]"
            echo "  --build   Run the full build pipeline first"
            echo "  --clean   Wipe cluster data dirs before starting"
            exit 0 ;;
        *) echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║     Analytics-Engine Coverage — 3-Node Cluster Setup                ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Nodes:          ${CYAN}$NUM_NODES${RESET}"
echo -e "  HTTP ports:     ${CYAN}$BASE_HTTP_PORT - $((BASE_HTTP_PORT + NUM_NODES - 1))${RESET}"
echo -e "  Transport:      ${CYAN}$BASE_TRANSPORT_PORT - $((BASE_TRANSPORT_PORT + NUM_NODES - 1))${RESET}"
echo -e "  Distro:         ${CYAN}$DISTRO_DIR${RESET}"
echo -e "  Cluster data:   ${CYAN}$CLUSTER_DIR${RESET}"

# ── Pre-flight: kill any existing nodes on our ports ──────────────────────────
KILLED=false
for i in $(seq 0 $((NUM_NODES - 1))); do
    PORT=$((BASE_HTTP_PORT + i))
    if lsof -nP -iTCP:$PORT -sTCP:LISTEN &>/dev/null; then
        warn "Port $PORT is in use — killing existing process..."
        lsof -nP -iTCP:$PORT -sTCP:LISTEN -t | xargs -r kill 2>/dev/null || true
        KILLED=true
    fi
done
# Also check for stale PID files
if [ -d "$CLUSTER_DIR" ]; then
    for pidfile in "$CLUSTER_DIR"/node-*/opensearch.pid; do
        if [ -f "$pidfile" ]; then
            PID=$(cat "$pidfile")
            if kill -0 "$PID" 2>/dev/null; then
                warn "Stale node running (PID $PID) — killing..."
                kill "$PID" 2>/dev/null || true
                KILLED=true
            fi
            rm -f "$pidfile"
        fi
    done
fi
if [ "$KILLED" = true ]; then
    sleep 3
    success "Previous processes cleaned up"
fi

# ── Optional build step ───────────────────────────────────────────────────────
if [ "$DO_BUILD" = true ]; then
    step "Building (running start-cluster.sh steps 1-6)..."
    info "Builds distro, analytics-api, SQL plugin, rust lib, and installs plugins."
    info "Will stop before starting OpenSearch."
    echo ""
    # Run start-cluster.sh but kill it when it reaches the "exec bin/opensearch" step.
    # We detect readiness by checking for the opensearch.yml config file being written.
    "$SCRIPT_DIR/start-cluster.sh" "$@" &
    BUILD_PID=$!
    # Wait for the config file to appear (written in step 7 just before exec)
    for i in $(seq 1 300); do
        if [ -f "$DISTRO_DIR/config/opensearch.yml" ] && grep -q "analytics-coverage" "$DISTRO_DIR/config/opensearch.yml" 2>/dev/null; then
            sleep 2
            kill $BUILD_PID 2>/dev/null || true
            break
        fi
        if ! kill -0 $BUILD_PID 2>/dev/null; then
            fail "start-cluster.sh exited unexpectedly. Check output above."
            exit 1
        fi
        sleep 1
    done
    wait $BUILD_PID 2>/dev/null || true
    success "Build complete — distro ready with all plugins"
fi

# ── Verify distro exists ─────────────────────────────────────────────────────
if [ ! -d "$DISTRO_DIR" ]; then
    echo -e "  ${RED}ERROR${RESET}: Distribution not found at $DISTRO_DIR"
    echo "  Run with --build or run start-cluster.sh first."
    exit 1
fi

if [ ! -d "$DISTRO_DIR/plugins/analytics-engine" ]; then
    echo -e "  ${RED}ERROR${RESET}: analytics-engine plugin not installed in distro."
    echo "  Run with --build or run start-cluster.sh first."
    exit 1
fi

# ── Clean if requested ────────────────────────────────────────────────────────
if [ "$DO_CLEAN" = true ]; then
    step "Cleaning cluster data directories"
    rm -rf "$CLUSTER_DIR"
    success "Cleaned $CLUSTER_DIR"
fi

# ── Create per-node directories ──────────────────────────────────────────────
step "Configuring $NUM_NODES nodes"

# Build seed hosts list for discovery
SEED_HOSTS=""
for i in $(seq 0 $((NUM_NODES - 1))); do
    if [ -n "$SEED_HOSTS" ]; then SEED_HOSTS="$SEED_HOSTS, "; fi
    SEED_HOSTS="${SEED_HOSTS}127.0.0.1:$((BASE_TRANSPORT_PORT + i))"
done

# Initial cluster-manager nodes (all nodes are cm-eligible)
INITIAL_CM_NODES=""
for i in $(seq 0 $((NUM_NODES - 1))); do
    if [ -n "$INITIAL_CM_NODES" ]; then INITIAL_CM_NODES="$INITIAL_CM_NODES, "; fi
    INITIAL_CM_NODES="${INITIAL_CM_NODES}node-$i"
done

for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_DIR="$CLUSTER_DIR/node-$i"
    NODE_HTTP_PORT=$((BASE_HTTP_PORT + i))
    NODE_TRANSPORT_PORT=$((BASE_TRANSPORT_PORT + i))

    mkdir -p "$NODE_DIR/data" "$NODE_DIR/logs" "$NODE_DIR/config/jvm.options.d"

    # JVM options (same as single-node)
    cat > "$NODE_DIR/config/jvm.options.d/analytics.options" << EOF
-Dopensearch.experimental.feature.pluggable.dataformat.enabled=true
-Dopensearch.experimental.feature.transport.stream.enabled=true
-Djava.library.path=$NATIVE_LIB_DIR
--add-opens=java.base/java.nio=ALL-UNNAMED
--enable-native-access=ALL-UNNAMED
-da:org.apache.calcite...
-Dio.netty.allocator.numDirectArenas=1
-Dio.netty.noUnsafe=false
-Dio.netty.tryUnsafe=true
-Dio.netty.tryReflectionSetAccessible=true
EOF

    # Heap — smaller per node since we have 3
    cat > "$NODE_DIR/config/jvm.options.d/heap.options" << EOF
-Xms512m
-Xmx512m
EOF

    # opensearch.yml — per-node config
    cat > "$NODE_DIR/config/opensearch.yml" << EOF
# Node identity
cluster.name: analytics-coverage
node.name: node-$i

# Paths
path.data: $NODE_DIR/data
path.logs: $NODE_DIR/logs

# Network
network.host: 127.0.0.1
http.port: $NODE_HTTP_PORT
transport.port: $NODE_TRANSPORT_PORT

# Discovery
discovery.seed_hosts: [$SEED_HOSTS]
cluster.initial_cluster_manager_nodes: [$INITIAL_CM_NODES]

# Analytics-engine settings
cluster.pluggable.dataformat: composite
EOF

    # Copy the base jvm.options from distro (heap is overridden above)
    if [ ! -f "$NODE_DIR/config/jvm.options" ]; then
        cp "$DISTRO_DIR/config/jvm.options" "$NODE_DIR/config/jvm.options"
    fi

    # Copy log4j config
    if [ ! -f "$NODE_DIR/config/log4j2.properties" ]; then
        cp "$DISTRO_DIR/config/log4j2.properties" "$NODE_DIR/config/log4j2.properties"
    fi

    info "node-$i: http=$NODE_HTTP_PORT transport=$NODE_TRANSPORT_PORT"
done

success "All $NUM_NODES nodes configured"

# ── Start all nodes ──────────────────────────────────────────────────────────
step "Starting $NUM_NODES-node cluster"

PIDS=()

cleanup() {
    echo ""
    warn "Shutting down cluster..."
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
    done
    wait 2>/dev/null
    success "All nodes stopped"
    exit 0
}
trap cleanup SIGINT SIGTERM

for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_DIR="$CLUSTER_DIR/node-$i"
    info "Starting node-$i..."

    OPENSEARCH_PATH_CONF="$NODE_DIR/config" \
    OPENSEARCH_HOME="$DISTRO_DIR" \
    "$DISTRO_DIR/bin/opensearch" \
        -d -p "$NODE_DIR/opensearch.pid" \
        -Epath.data="$NODE_DIR/data" \
        -Epath.logs="$NODE_DIR/logs" \
        >> "$NODE_DIR/logs/stdout.log" 2>&1

    # Read the PID
    sleep 2
    if [ -f "$NODE_DIR/opensearch.pid" ]; then
        PIDS+=("$(cat "$NODE_DIR/opensearch.pid")")
        success "node-$i started (PID: $(cat "$NODE_DIR/opensearch.pid"))"
    else
        warn "node-$i PID file not found — check $NODE_DIR/logs/"
    fi
done

# ── Wait for cluster to form ─────────────────────────────────────────────────
echo ""
info "Waiting for cluster to form (up to 60s)..."
for attempt in $(seq 1 30); do
    HEALTH=$(curl -s --connect-timeout 2 "http://127.0.0.1:$BASE_HTTP_PORT/_cluster/health" 2>/dev/null || echo "")
    if echo "$HEALTH" | grep -q '"number_of_nodes":3'; then
        STATUS=$(echo "$HEALTH" | grep -oP '"status":"[^"]+"' | cut -d'"' -f4)
        echo ""
        success "Cluster formed! Status: $STATUS, Nodes: 3"
        echo ""
        echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${BOLD}  3-node cluster ready at http://localhost:$BASE_HTTP_PORT${RESET}"
        echo -e "${BOLD}  Cluster name: analytics-coverage${RESET}"
        echo -e "${BOLD}  Press Ctrl+C to stop all nodes.${RESET}"
        echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo ""
        break
    fi
    sleep 2
done

if ! echo "$HEALTH" | grep -q '"number_of_nodes":3'; then
    warn "Cluster did not form within 60s. Check node logs:"
    for i in $(seq 0 $((NUM_NODES - 1))); do
        echo "    $CLUSTER_DIR/node-$i/logs/"
    done
fi

# ── Keep running until Ctrl+C ────────────────────────────────────────────────
# Tail all node logs interleaved so you can see activity
info "Tailing node logs (Ctrl+C to stop)..."
echo ""
tail -f "$CLUSTER_DIR"/node-*/logs/*.log 2>/dev/null &
TAIL_PID=$!

# Wait for any node to die
wait_for_exit() {
    while true; do
        for pid in "${PIDS[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                warn "A node process died (PID: $pid)"
                cleanup
            fi
        done
        sleep 5
    done
}
wait_for_exit
