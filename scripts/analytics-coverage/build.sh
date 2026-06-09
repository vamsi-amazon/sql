#!/usr/bin/env bash
# =============================================================================
# build.sh — Build everything needed to run the analytics-engine coverage cluster.
#
# Pulls latest OpenSearch main, builds the distro, publishes analytics libs,
# builds the SQL plugin, checks/rebuilds the Rust native lib, and installs all
# plugins into the local distro. Does NOT start the cluster.
#
# Usage:
#   ./scripts/analytics-coverage/build.sh              # Incremental (skip what's up-to-date)
#   ./scripts/analytics-coverage/build.sh --force      # Force rebuild all (keep rust)
#   ./scripts/analytics-coverage/build.sh --clean      # Nuclear: wipe everything including rust
#   ./scripts/analytics-coverage/build.sh --skip-pull  # Don't git pull (use current checkout)
#
# After this completes, start the cluster with:
#   ./scripts/analytics-coverage/start-cluster-multinode.sh --clean
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
    echo -e "${BOLD}  [$1/6] $2${RESET}"
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
DO_FORCE=true    # Default: always force rebuild for reproducibility
DO_CLEAN=false
SKIP_PULL=false
for arg in "$@"; do
    case "$arg" in
        --incremental) DO_FORCE=false ;;
        --clean) DO_CLEAN=true ;;
        --skip-pull) SKIP_PULL=true ;;
        --help|-h)
            echo "Usage: $0 [--incremental] [--clean] [--skip-pull]"
            echo ""
            echo "  (none)         Default: force rebuild all (keeps rust) — always reproducible"
            echo "  --incremental  Skip rebuilds if artifacts exist (faster, less safe)"
            echo "  --clean        Also delete rust target dir (~15 min full rebuild)"
            echo "  --skip-pull    Don't git pull OpenSearch (use current checkout as-is)"
            exit 0 ;;
        *) echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║         Analytics-Engine Coverage — Build                           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  SQL repo:       ${CYAN}$SQL_REPO${RESET}"
echo -e "  OpenSearch:     ${CYAN}$OPENSEARCH_HOME${RESET}"
echo -e "  OS version:     $OS_VERSION"
echo -e "  Mode:           $([ "$DO_CLEAN" = true ] && echo "${RED}CLEAN (full rebuild)${RESET}" || ([ "$DO_FORCE" = true ] && echo "${YELLOW}FORCE (rebuild, keep rust)${RESET}" || echo "${GREEN}incremental${RESET}"))"
echo -e "  Pull:           $([ "$SKIP_PULL" = true ] && echo "${YELLOW}SKIP${RESET}" || echo "${GREEN}yes${RESET}")"

# ── Force/Clean: wipe build artifacts ─────────────────────────────────────────
if [ "$DO_FORCE" = true ]; then
    echo ""
    echo -e "${BOLD}${YELLOW}  Wiping build artifacts...${RESET}"

    rm -rf "$DISTRO_DIR"
    info "Deleted distro dir"

    rm -rf "$PLUGIN_CACHE"
    info "Deleted plugin cache"

    cd "$OPENSEARCH_HOME"
    rm -rf build/distributions build/distribution
    rm -rf plugins/arrow-base/build/distributions
    rm -rf plugins/arrow-flight-rpc/build/distributions
    rm -rf sandbox/plugins/*/build/distributions
    info "Deleted all distribution/plugin zip outputs"

    rm -rf ~/.m2/repository/org/opensearch/plugin/opensearch-sql-plugin/$PLUGIN_VERSION
    rm -rf ~/.m2/repository/org/opensearch/sandbox/analytics-api/$OS_VERSION
    rm -rf ~/.m2/repository/org/opensearch/sandbox/analytics-framework/$OS_VERSION
    info "Deleted mavenLocal artifacts"

    if [ "$DO_CLEAN" = true ]; then
        rm -rf "$NATIVE_LIB_DIR"
        info "Deleted Rust target/release (will rebuild from scratch)"
    fi

    success "Wipe complete"
fi

# ── Step 1: Pull latest OpenSearch main ───────────────────────────────────────
step 1 "Pull latest OpenSearch main"
cd "$OPENSEARCH_HOME"
if [ "$SKIP_PULL" = true ]; then
    success "Skipped (--skip-pull). At: $(git log --oneline -1)"
else
    OS_REMOTE=$(git remote -v | grep "opensearch-project/OpenSearch" | grep fetch | awk '{print $1}' | head -1)
    if [ -z "$OS_REMOTE" ]; then
        fail "No remote pointing to opensearch-project/OpenSearch.git found."
        echo "    Add one: git remote add upstream git@github.com:opensearch-project/OpenSearch.git"
        exit 1
    fi
    git pull "$OS_REMOTE" main 2>&1 | tail -3
    success "OpenSearch at: $(git log --oneline -1)"
fi

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

# ── Step 3: Publish analytics libs to mavenLocal ──────────────────────────────
step 3 "Publish analytics-api + analytics-framework to mavenLocal"
cd "$OPENSEARCH_HOME"
local_start=$(date +%s)
./gradlew \
    :sandbox:libs:analytics-api:publishToMavenLocal \
    :sandbox:libs:analytics-framework:publishToMavenLocal \
    -Dsandbox.enabled=true 2>&1 | tail -3
success "Analytics libs published ($(elapsed $local_start))"

# ── Step 4: Build SQL plugin ─────────────────────────────────────────────────
step 4 "Build SQL plugin"
cd "$SQL_REPO"
info "SQL repo at: $(git log --oneline -1) [$(git branch --show-current)]"
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

info "Cleaning and rebuilding all plugin zips from source..."
local_start=$(date +%s)
./gradlew \
    :plugins:arrow-base:clean :plugins:arrow-base:bundlePlugin \
    :plugins:arrow-flight-rpc:clean :plugins:arrow-flight-rpc:bundlePlugin \
    :sandbox:plugins:analytics-engine:clean :sandbox:plugins:analytics-engine:bundlePlugin \
    :sandbox:plugins:analytics-backend-datafusion:clean :sandbox:plugins:analytics-backend-datafusion:bundlePlugin \
    :sandbox:plugins:analytics-backend-lucene:clean :sandbox:plugins:analytics-backend-lucene:bundlePlugin \
    :sandbox:plugins:composite-engine:clean :sandbox:plugins:composite-engine:bundlePlugin \
    :sandbox:plugins:parquet-data-format:clean :sandbox:plugins:parquet-data-format:bundlePlugin \
    :sandbox:plugins:dsl-query-executor:clean :sandbox:plugins:dsl-query-executor:bundlePlugin \
    :sandbox:plugins:block-cache-foyer:clean :sandbox:plugins:block-cache-foyer:bundlePlugin \
    -Dsandbox.enabled=true 2>&1 | tail -5
success "Plugin zips built ($(elapsed $local_start))"

# Remove all existing plugins (localDistro may have pre-installed some sandbox plugins;
# we remove everything and reinstall from our freshly-built zips to guarantee consistency).
info "Removing existing plugins (if any)..."
for p in $(ls "$DISTRO_DIR/plugins/" 2>/dev/null); do
    "$PLUGIN_CMD" remove "$p" 2>&1 | tail -1
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
# Install order matters — plugins declare dependencies via extended.plugins:
#   arrow-flight-rpc extends arrow-base
#   analytics-backend-datafusion extends analytics-engine
#   analytics-backend-lucene extends analytics-engine, composite-engine
#   parquet-data-format extends composite-engine
#   dsl-query-executor extends analytics-engine
#   opensearch-sql extends opensearch-job-scheduler
install_plugin "opensearch-job-scheduler" "$JOB_SCHEDULER_ZIP"
install_plugin "arrow-base" "$OPENSEARCH_HOME/plugins/arrow-base/build/distributions/arrow-base-$OS_VERSION.zip"
install_plugin "arrow-flight-rpc" "$OPENSEARCH_HOME/plugins/arrow-flight-rpc/build/distributions/arrow-flight-rpc-$OS_VERSION.zip"
install_plugin "analytics-engine" "$OPENSEARCH_HOME/sandbox/plugins/analytics-engine/build/distributions/analytics-engine-$OS_VERSION.zip"
install_plugin "composite-engine" "$OPENSEARCH_HOME/sandbox/plugins/composite-engine/build/distributions/composite-engine-$OS_VERSION.zip"
install_plugin "analytics-backend-datafusion" "$OPENSEARCH_HOME/sandbox/plugins/analytics-backend-datafusion/build/distributions/analytics-backend-datafusion-$OS_VERSION.zip"
install_plugin "analytics-backend-lucene" "$OPENSEARCH_HOME/sandbox/plugins/analytics-backend-lucene/build/distributions/analytics-backend-lucene-$OS_VERSION.zip"
install_plugin "parquet-data-format" "$OPENSEARCH_HOME/sandbox/plugins/parquet-data-format/build/distributions/parquet-data-format-$OS_VERSION.zip"
install_plugin "dsl-query-executor" "$OPENSEARCH_HOME/sandbox/plugins/dsl-query-executor/build/distributions/dsl-query-executor-$OS_VERSION.zip"
install_plugin "block-cache-foyer" "$OPENSEARCH_HOME/sandbox/plugins/block-cache-foyer/build/distributions/block-cache-foyer-$OS_VERSION.zip"
install_plugin "opensearch-sql" "$SQL_PLUGIN_ZIP"
echo ""
success "All plugins installed ($(ls $DISTRO_DIR/plugins/ | wc -l) total)"

echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Build complete!${RESET}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${BOLD}Commits built from:${RESET}"
echo -e "    OpenSearch: ${CYAN}$(git -C "$OPENSEARCH_HOME" log --oneline -1)${RESET}"
echo -e "    SQL plugin: ${CYAN}$(git -C "$SQL_REPO" log --oneline -1) [$(git -C "$SQL_REPO" branch --show-current)]${RESET}"
echo ""
echo -e "  ${BOLD}Distro:${RESET} $DISTRO_DIR"
echo -e "  ${BOLD}Plugins ($(ls $DISTRO_DIR/plugins/ | wc -l)):${RESET}"
ls "$DISTRO_DIR/plugins/" | sed 's/^/    /'
echo ""
echo -e "  ${BOLD}Verification:${RESET}"
# Print plugin-descriptor.properties version from a key plugin to confirm it's fresh
VERIFY_JAR="$DISTRO_DIR/plugins/analytics-engine/analytics-engine-$OS_VERSION.jar"
if [ -f "$VERIFY_JAR" ]; then
    BUILD_TS=$(stat -c '%y' "$VERIFY_JAR" | cut -d. -f1)
    echo -e "    analytics-engine jar built at: ${CYAN}$BUILD_TS${RESET}"
fi
SQL_JAR=$(find "$DISTRO_DIR/plugins/opensearch-sql" -name "opensearch-sql-plugin-*.jar" | head -1)
if [ -n "$SQL_JAR" ]; then
    BUILD_TS=$(stat -c '%y' "$SQL_JAR" | cut -d. -f1)
    echo -e "    opensearch-sql jar built at:   ${CYAN}$BUILD_TS${RESET}"
fi
echo ""
echo "  Next: start the cluster with:"
echo "    ./scripts/analytics-coverage/start-cluster-multinode.sh --clean"
echo ""
