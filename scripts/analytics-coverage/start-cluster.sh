#!/usr/bin/env bash
# =============================================================================
# start-cluster.sh — Start a single-node OpenSearch cluster with the full
# analytics-engine plugin stack for running the PPL coverage report.
#
# Usage:
#   ./scripts/analytics-coverage/start-cluster.sh              # Normal (incremental)
#   ./scripts/analytics-coverage/start-cluster.sh --force      # Force rebuild all (keep rust)
#   ./scripts/analytics-coverage/start-cluster.sh --clean      # Nuclear: wipe everything including rust
#
# Flags:
#   --force   Delete distro + plugin zips + mavenLocal artifacts, rebuild all.
#             Does NOT rebuild Rust native lib unless source changed.
#   --clean   Like --force but ALSO deletes Rust target dir (full ~15 min rebuild).
#   (none)    Incremental: skip builds if artifacts exist and are up-to-date.
#
# Layout:
#   OpenSearch repo:  $OPENSEARCH_HOME (default: ../OpenSearch)
#   SQL main clone:   .workdir/sql-main/ (builds plugin zip from latest main)
#   Plugin cache:     .plugin-cache/ (job-scheduler zip)
#   Distro:           $OPENSEARCH_HOME/build/distribution/local/opensearch-<version>/
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPENSEARCH_HOME="${OPENSEARCH_HOME:-$(cd "$SQL_REPO/../OpenSearch" && pwd)}"
OS_VERSION="3.7.0-SNAPSHOT"
PLUGIN_VERSION="3.7.0.0-SNAPSHOT"

DISTRO_DIR="$OPENSEARCH_HOME/build/distribution/local/opensearch-$OS_VERSION"
NATIVE_LIB_DIR="$OPENSEARCH_HOME/sandbox/libs/dataformat-native/rust/target/release"
PLUGIN_CACHE="$SCRIPT_DIR/.plugin-cache"

# ── Helpers ───────────────────────────────────────────────────────────────────
BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RED="\033[31m"
RESET="\033[0m"

step() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}  [$1/7] $2${RESET}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

info()    { echo -e "  ${DIM}→${RESET} $1"; }
success() { echo -e "  ${GREEN}✓${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $1"; }
fail()    { echo -e "  ${RED}✗${RESET} $1"; }

elapsed() {
    local start=$1
    local end=$(date +%s)
    echo "$((end - start))s"
}

# ── Parse args ────────────────────────────────────────────────────────────────
DO_FORCE=false
DO_CLEAN=false
for arg in "$@"; do
    case "$arg" in
        --force) DO_FORCE=true ;;
        --clean) DO_CLEAN=true; DO_FORCE=true ;;
        --help|-h)
            echo "Usage: $0 [--force] [--clean]"
            echo ""
            echo "  (none)    Incremental: reuse existing builds, only rebuild what changed"
            echo "  --force   Delete distro + plugins + maven artifacts, rebuild all (keeps rust)"
            echo "  --clean   Nuclear: --force + delete rust target dir (~15 min full rebuild)"
            exit 0 ;;
        *) echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║         Analytics-Engine Coverage — Cluster Setup                   ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  SQL repo:       ${CYAN}$SQL_REPO${RESET} (builds plugin + runs tests)"
echo -e "  OpenSearch:     ${CYAN}$OPENSEARCH_HOME${RESET}"
echo -e "  OS version:     $OS_VERSION"
echo -e "  Mode:           $([ "$DO_CLEAN" = true ] && echo "${RED}CLEAN (full rebuild)${RESET}" || ([ "$DO_FORCE" = true ] && echo "${YELLOW}FORCE (rebuild, keep rust)${RESET}" || echo "${GREEN}incremental${RESET}"))"

# ── Pre-flight: kill any existing OpenSearch on our ports ─────────────────────
if lsof -nP -iTCP:9200 -sTCP:LISTEN &>/dev/null; then
    warn "Port 9200 is in use — killing existing process..."
    lsof -nP -iTCP:9200 -sTCP:LISTEN -t | xargs -r kill 2>/dev/null || true
    sleep 2
    success "Previous process killed"
fi

# ── Force/Clean: wipe build artifacts ─────────────────────────────────────────
if [ "$DO_FORCE" = true ]; then
    echo ""
    echo -e "${BOLD}${YELLOW}  Wiping build artifacts...${RESET}"

    # Distro
    rm -rf "$DISTRO_DIR"
    info "Deleted distro dir"

    # Plugin cache
    rm -rf "$PLUGIN_CACHE"
    info "Deleted plugin cache"

    # OpenSearch build outputs (distro archives, plugin zips)
    cd "$OPENSEARCH_HOME"
    rm -rf build/distributions build/distribution
    rm -rf plugins/arrow-base/build/distributions
    rm -rf plugins/arrow-flight-rpc/build/distributions
    rm -rf sandbox/plugins/*/build/distributions
    info "Deleted all distribution/plugin zip outputs"

    # mavenLocal artifacts
    rm -rf ~/.m2/repository/org/opensearch/plugin/opensearch-sql-plugin/$PLUGIN_VERSION
    rm -rf ~/.m2/repository/org/opensearch/sandbox/analytics-api/$OS_VERSION
    info "Deleted mavenLocal artifacts (analytics-api + sql-plugin)"

    # Rust (only on --clean)
    if [ "$DO_CLEAN" = true ]; then
        rm -rf "$NATIVE_LIB_DIR"
        info "Deleted Rust target/release (will rebuild from scratch)"
    fi

    success "Wipe complete"
fi

# ── Step 1: Pull latest OpenSearch main ───────────────────────────────────────
step 1 "Pull latest OpenSearch main"
cd "$OPENSEARCH_HOME"
OS_REMOTE=$(git remote -v | grep "opensearch-project/OpenSearch" | grep fetch | awk '{print $1}' | head -1)
if [ -z "$OS_REMOTE" ]; then
    fail "No remote pointing to opensearch-project/OpenSearch.git found."
    echo "    Add one: git remote add upstream git@github.com:opensearch-project/OpenSearch.git"
    exit 1
fi
git pull "$OS_REMOTE" main 2>&1 | tail -3
success "OpenSearch at: $(git log --oneline -1)"

# ── Step 2: Build local OpenSearch distribution ───────────────────────────────
step 2 "Build local OpenSearch distribution"
cd "$OPENSEARCH_HOME"
if [ ! -d "$DISTRO_DIR" ]; then
    info "Building distribution..."
    local_start=$(date +%s)
    ./gradlew localDistro -Dsandbox.enabled=true 2>&1 | tail -5
    success "Distribution ready ($(elapsed $local_start)): $DISTRO_DIR"
else
    success "Distribution exists (skipping). Use --force to rebuild."
fi

# ── Step 3: Publish analytics-api to mavenLocal ───────────────────────────────
step 3 "Publish analytics-api to mavenLocal"
cd "$OPENSEARCH_HOME"
local_start=$(date +%s)
./gradlew :sandbox:libs:analytics-api:publishToMavenLocal -Dsandbox.enabled=true 2>&1 | tail -3
success "analytics-api published ($(elapsed $local_start))"

# ── Step 4: Build SQL plugin from feature branch (this repo) ──────────────────
# The SQL plugin must be built from the feature branch because it registers the
# `plugins.calcite.analytics.force_routing` cluster setting that the test harness
# uses to route queries through the analytics-engine path.
step 4 "Build SQL plugin from feature branch"
cd "$SQL_REPO"
info "SQL repo at: $(git log --oneline -1)"
local_start=$(date +%s)
./gradlew publishPluginZipPublicationToMavenLocal -x test -x integTest 2>&1 | tail -3
SQL_PLUGIN_ZIP=$(find ~/.m2/repository/org/opensearch/plugin/opensearch-sql-plugin/$PLUGIN_VERSION -name "*.zip" | head -1)
if [ -z "$SQL_PLUGIN_ZIP" ]; then
    fail "SQL plugin zip not found in mavenLocal after build!"
    exit 1
fi
success "SQL plugin built ($(elapsed $local_start)): $(basename $SQL_PLUGIN_ZIP)"

# ── Step 5: Rebuild Rust native lib if needed ─────────────────────────────────
step 5 "Check Rust native library"
cd "$OPENSEARCH_HOME"
NATIVE_LIB="$NATIVE_LIB_DIR/libopensearch_native.so"
if [ ! -f "$NATIVE_LIB" ]; then
    warn "Native lib not found — building from scratch (~12 min)..."
    local_start=$(date +%s)
    cd "$OPENSEARCH_HOME/sandbox/libs/dataformat-native/rust"
    cargo build -p opensearch-native-lib --release 2>&1 | grep -E "Compiling opensearch-native|Finished|error" | tail -5
    success "Native lib built ($(elapsed $local_start))"
elif [ "$(find "$OPENSEARCH_HOME/sandbox" -name '*.rs' -newer "$NATIVE_LIB" 2>/dev/null | wc -l)" -gt 0 ]; then
    STALE_COUNT=$(find "$OPENSEARCH_HOME/sandbox" -name '*.rs' -newer "$NATIVE_LIB" 2>/dev/null | wc -l)
    warn "$STALE_COUNT Rust source files changed — rebuilding (~12 min)..."
    local_start=$(date +%s)
    cd "$OPENSEARCH_HOME/sandbox/libs/dataformat-native/rust"
    cargo build -p opensearch-native-lib --release 2>&1 | grep -E "Compiling opensearch-native|Finished|error" | tail -5
    success "Native lib rebuilt ($(elapsed $local_start))"
else
    success "Native lib is up to date"
fi

# ── Step 6: Build and install plugins ─────────────────────────────────────────
step 6 "Build and install plugins"
cd "$OPENSEARCH_HOME"
PLUGIN_CMD="$DISTRO_DIR/bin/opensearch-plugin"

# Build all plugin zips in one Gradle invocation
info "Building all plugin zips..."
local_start=$(date +%s)
./gradlew \
    :plugins:arrow-base:bundlePlugin \
    :plugins:arrow-flight-rpc:bundlePlugin \
    :sandbox:plugins:analytics-engine:bundlePlugin \
    :sandbox:plugins:analytics-backend-datafusion:bundlePlugin \
    :sandbox:plugins:analytics-backend-lucene:bundlePlugin \
    :sandbox:plugins:composite-engine:bundlePlugin \
    :sandbox:plugins:parquet-data-format:bundlePlugin \
    :sandbox:plugins:dsl-query-executor:bundlePlugin \
    :sandbox:plugins:block-cache-foyer:bundlePlugin \
    -Dsandbox.enabled=true 2>&1 | tail -3
success "Plugin zips built ($(elapsed $local_start))"

# Remove all analytics plugins first (reverse dependency order), then install fresh.
# This avoids "cannot be removed because it is extended by other plugins" errors.
info "Removing existing plugins (if any)..."
for p in opensearch-sql dsl-query-executor block-cache-foyer parquet-data-format composite-engine analytics-backend-lucene analytics-backend-datafusion analytics-engine arrow-flight-rpc arrow-base opensearch-job-scheduler; do
    if [ -d "$DISTRO_DIR/plugins/$p" ]; then
        "$PLUGIN_CMD" remove "$p" 2>&1 | tail -1
    fi
done

# Install helper
install_plugin() {
    local name="$1"
    local zip_path="$2"
    if [ ! -f "$zip_path" ]; then
        fail "$name — zip not found: $zip_path"
        return 1
    fi
    "$PLUGIN_CMD" install --batch "file://$zip_path" 2>&1 | tail -1
    info "$name — installed"
}

# opensearch-job-scheduler — download from CI snapshots
mkdir -p "$PLUGIN_CACHE"
JOB_SCHEDULER_ZIP="$PLUGIN_CACHE/opensearch-job-scheduler-$PLUGIN_VERSION.zip"
if [ ! -f "$JOB_SCHEDULER_ZIP" ] || ! file "$JOB_SCHEDULER_ZIP" | grep -q "Zip"; then
    rm -f "$JOB_SCHEDULER_ZIP" 2>/dev/null
    info "Downloading opensearch-job-scheduler from CI snapshots..."
    METADATA_URL="https://ci.opensearch.org/ci/dbc/snapshots/maven/org/opensearch/plugin/opensearch-job-scheduler/$PLUGIN_VERSION/maven-metadata.xml"
    SNAPSHOT_VERSION=$(curl -sL "$METADATA_URL" | grep -B1 "<extension>zip</extension>" | grep -oP '(?<=<value>)[^<]+' | head -1 || echo "")
    if [ -z "$SNAPSHOT_VERSION" ]; then
        SNAPSHOT_VERSION=$(curl -sL "$METADATA_URL" | grep -oP '(?<=<value>)[^<]+' | head -1 || echo "")
    fi
    if [ -z "$SNAPSHOT_VERSION" ]; then
        fail "Could not resolve job-scheduler snapshot version"
        exit 1
    fi
    DOWNLOAD_URL="https://ci.opensearch.org/ci/dbc/snapshots/maven/org/opensearch/plugin/opensearch-job-scheduler/$PLUGIN_VERSION/opensearch-job-scheduler-${SNAPSHOT_VERSION}.zip"
    info "URL: $DOWNLOAD_URL"
    curl -sL "$DOWNLOAD_URL" -o "$JOB_SCHEDULER_ZIP"
    if ! file "$JOB_SCHEDULER_ZIP" | grep -q "Zip"; then
        fail "Downloaded file is not a valid ZIP"
        rm -f "$JOB_SCHEDULER_ZIP"
        exit 1
    fi
    success "Downloaded job-scheduler ($(du -h "$JOB_SCHEDULER_ZIP" | cut -f1))"
else
    info "job-scheduler — using cache ($(du -h "$JOB_SCHEDULER_ZIP" | cut -f1))"
fi

echo ""
info "Installing plugins into distro..."
echo ""
install_plugin "opensearch-job-scheduler" "$JOB_SCHEDULER_ZIP"
install_plugin "arrow-base" "$OPENSEARCH_HOME/plugins/arrow-base/build/distributions/arrow-base-$OS_VERSION.zip"
install_plugin "arrow-flight-rpc" "$OPENSEARCH_HOME/plugins/arrow-flight-rpc/build/distributions/arrow-flight-rpc-$OS_VERSION.zip"
install_plugin "analytics-engine" "$OPENSEARCH_HOME/sandbox/plugins/analytics-engine/build/distributions/analytics-engine-$OS_VERSION.zip"
install_plugin "analytics-backend-datafusion" "$OPENSEARCH_HOME/sandbox/plugins/analytics-backend-datafusion/build/distributions/analytics-backend-datafusion-$OS_VERSION.zip"
install_plugin "analytics-backend-lucene" "$OPENSEARCH_HOME/sandbox/plugins/analytics-backend-lucene/build/distributions/analytics-backend-lucene-$OS_VERSION.zip"
install_plugin "composite-engine" "$OPENSEARCH_HOME/sandbox/plugins/composite-engine/build/distributions/composite-engine-$OS_VERSION.zip"
install_plugin "parquet-data-format" "$OPENSEARCH_HOME/sandbox/plugins/parquet-data-format/build/distributions/parquet-data-format-$OS_VERSION.zip"
install_plugin "dsl-query-executor" "$OPENSEARCH_HOME/sandbox/plugins/dsl-query-executor/build/distributions/dsl-query-executor-$OS_VERSION.zip"
install_plugin "block-cache-foyer" "$OPENSEARCH_HOME/sandbox/plugins/block-cache-foyer/build/distributions/block-cache-foyer-$OS_VERSION.zip"
install_plugin "opensearch-sql" "$SQL_PLUGIN_ZIP"
echo ""
success "All plugins installed"

# ── Step 7: Configure and start ───────────────────────────────────────────────
step 7 "Configure and start OpenSearch"

# JVM options
cat > "$DISTRO_DIR/config/jvm.options.d/analytics.options" << EOF
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
success "JVM flags configured"

# opensearch.yml (always overwrite)
cat > "$DISTRO_DIR/config/opensearch.yml" << EOF
cluster.name: analytics-coverage
node.name: analytics-node-0
cluster.pluggable.dataformat: composite
discovery.type: single-node
network.host: 127.0.0.1
EOF
success "opensearch.yml configured"

# Wipe data dir — always start with clean cluster state
rm -rf "$DISTRO_DIR/data"
info "Data dir wiped (fresh cluster)"

echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Starting OpenSearch on http://localhost:9200${RESET}"
echo -e "${BOLD}  Cluster: analytics-coverage (single-node)${RESET}"
echo -e "${BOLD}  Press Ctrl+C to stop.${RESET}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# Start OpenSearch
cd "$DISTRO_DIR"
exec bin/opensearch
