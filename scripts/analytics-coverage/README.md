# Analytics-Engine Coverage Scripts

Scripts to run the PPL compatibility coverage report against the analytics-engine.

## Quick Start

```bash
# Terminal 1 — Start the cluster (stays in foreground)
./scripts/analytics-coverage/start-cluster.sh

# Terminal 2 — Run the report (once cluster is GREEN)
./scripts/analytics-coverage/run-report.sh single
```

## What Each Script Does

### `start-cluster.sh`

Builds and starts a single-node OpenSearch cluster with the full analytics-engine stack:

1. Builds OpenSearch local distribution (`./gradlew localDistro -Dsandbox.enabled=true`)
2. Publishes `analytics-api` jar to mavenLocal (SQL plugin depends on it)
3. Builds & publishes the SQL plugin zip to mavenLocal
4. Rebuilds the Rust native library if stale (DataFusion FFM bridge)
5. Installs all plugins into the distribution:
   - `opensearch-job-scheduler` (dependency of SQL plugin)
   - `arrow-base`, `arrow-flight-rpc` (Arrow Flight streaming transport)
   - `analytics-engine` (the query planner/coordinator)
   - `analytics-backend-datafusion` (DataFusion execution backend)
   - `analytics-backend-lucene` (Lucene filter delegation backend)
   - `composite-engine` (composite store manager)
   - `parquet-data-format` (Parquet data format support)
   - `opensearch-sql` (our SQL/PPL plugin)
6. Configures JVM flags:
   - `opensearch.experimental.feature.pluggable.dataformat.enabled=true`
   - `opensearch.experimental.feature.transport.stream.enabled=true`
   - Native library path for DataFusion
   - Netty flags for Arrow Flight
7. Starts OpenSearch in foreground mode

### `run-report.sh [single|multi]`

Runs the coverage report against a running cluster:

- **`single`** (default) — 1 shard, 0 replicas. Standard single-node coverage.
- **`multi`** — 3 shards, 1 replica. Requires a 3-node cluster.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `OPENSEARCH_HOME` | `../OpenSearch` (relative to sql repo) | Path to OpenSearch checkout |
| `CLUSTER_URL` | `localhost:9200` | Cluster REST endpoint |
| `CLUSTER_TRANSPORT` | `localhost:9300` | Cluster transport port |
| `CLUSTER_NAME` | `opensearch` | Cluster name (for log file detection) |
| `CLUSTER_LOG` | auto-detected | Path to cluster log file (for origin attribution) |

## Rebuilding After Code Changes

### Changed SQL plugin code:
```bash
cd ~/opensource/sql
./gradlew publishPluginZipPublicationToMavenLocal -x test -x integTest
# Then restart the cluster (Ctrl+C + re-run start-cluster.sh)
# Or delete the sql plugin and reinstall:
#   $DISTRO/bin/opensearch-plugin remove opensearch-sql
#   $DISTRO/bin/opensearch-plugin install file:///path/to/new.zip
```

### Changed OpenSearch / analytics-engine code:
```bash
# Rebuild affected sandbox plugin(s)
cd ~/opensource/OpenSearch
./gradlew :sandbox:plugins:analytics-engine:bundlePlugin -Dsandbox.enabled=true
# Then reinstall that plugin in the distro
```

### Changed Rust code:
```bash
cd ~/opensource/OpenSearch/sandbox/libs/dataformat-native/rust
cargo build -p opensearch-native-lib --release  # ~12 min
# Restart the cluster — the JVM picks up the new .so at startup
```

## Regenerating Report Without Re-running Tests

After tweaking report logic in `integ-test/build.gradle`:
```bash
./gradlew :integ-test:analyticsCompatibilityReport \
  -x :integ-test:analyticsCompatibilityTest \
  -PclusterLog=/path/to/cluster.log
```

## Output

| File | Contents |
|---|---|
| `integ-test/build/reports/analytics-compatibility/REPORT.md` | Single-shard coverage report |
| `integ-test/build/reports/analytics-compatibility-multishard/REPORT.md` | Multi-shard coverage report |
| `integ-test/build/test-results/analyticsCompatibility/TEST-*.xml` | Raw JUnit XML results |
| `integ-test/build/reports/tests/analyticsCompatibility/index.html` | HTML test report |
