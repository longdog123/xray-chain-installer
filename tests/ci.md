# Hosted Linux compatibility gate

The workflow in `.github/workflows/tests.yml` runs once for each push to a
`codex/**` branch. It does not publish or deploy, and needs only `contents: read`.
Keep an existing completed run for an unchanged source; do not rerun the full
gate solely because a conversation or local test environment is unavailable.

`tests/ci.py` requires GitHub Actions, Linux and root. The Ubuntu 24.04 job uses
`sudo` for root-owned fixture installation and namespace isolation. It installs
the dependencies listed in the runner, including `shellcheck`, and runs all
eleven established regression suites, `entry-address.sh`, and `preflight.sh`.
A missing suite fails the gate. Git checkout includes the complete history for
the existing preflight checks, without persisted Git credentials.

The runtime is downloaded from the official XTLS/Xray-core release once per
job. The fixed `v26.3.27` Linux x86-64 archive must match both its official
`.dgst` SHA-256 and the pinned SHA-256 already retained in the November 4
acceptance records. Its binary version is checked before any suite executes.
Changing the runtime requires updating and independently verifying that pin;
no previous local runtime cache or retired WSL distribution is used.

Each suite receives private mount, network and PID namespaces. Its `/tmp` and
`/var/tmp` are separate tmpfs mounts. Application HTTP probes remain fixtures;
tests have no external network access. Namespace exit destroys temporary
fixtures and remaining processes, including on a suite timeout. The real Xray
binary and geodata are shared read-only by convention across these serial
tests; generated configurations and keys stay in private fixture storage.

Subprocess output is captured in temporary, unlinked files and never printed
or uploaded. The job prints only the suite name, status, numeric exit code and
fixed runner failure categories. The uploaded `summary.json` contains source
and workflow commit identifiers, the workflow hash, test/source file hashes,
run identity, installer/runtime/dependency versions, per-suite exit codes and
timings, cleanup observations and exclusions. The suite duration covers the
test command; isolation duration additionally covers namespace setup and
teardown. Artifact retention is 30 days. Preserve relevant sanitized JSON in
the repository's validation archive before expiration when accepting a change.

The JSON also includes bounded diagnostic summaries: known test scenario
identifiers, pass/fail counts, ShellCheck codes with source line numbers, and
fixed error categories. Source locations are limited to `install.sh` and
existing `tests/*.sh` files in this checkout; absolute paths, traceback method
names and all error message text are discarded. Scenario identifiers must use
letters, digits, underscores or hyphens and occur in the public test source
(the entry-address malformed-input cases additionally allow numbered labels).
Oversized output marks diagnostics as truncated without publishing its text.

Each suite has a five-minute command limit and a separate isolation deadline.
The whole job has a 25-minute limit. A cancelled or exhausted job may leave
the last uploaded report with `running` or `not_run` entries; these are not
successful verification. A failed suite is not retried automatically, skipped
or weakened. Diagnose the affected branch with a narrow, sanitized check.
If hosted testing is unavailable or its quota is exhausted, retain the exact
failure and pending checks; do not replace it with a complete local Linux run.

The runner's small, cross-platform unit tests can be checked locally with
`python tests/ci_unit.py`. They check the evidence boundary and archive handling;
they do not execute the installer suites or establish their compatibility.
