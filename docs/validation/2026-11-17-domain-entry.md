# Shared domain entry acceptance

The implementation targets installer 0.2.24. The verified source is
`3a4e6ff95b92f1bbd07073de82a126b93d4c70bf`; the final evidence JSON records the
exact installer, workflow, runner and test hashes. The later archive commit
only adds this evidence and clarifies README wording; it does not change the
verified source, workflow or tests. This is acceptance on a feature branch,
not publication to `main` or installation on a customer server.

## Scope and result

- First interactive installation asks for an optional entry domain. Enter
  keeps automatic VPS IPv4; an entered domain is normalized and reused by
  every node. Explicit initial environment configuration retains priority.
- Menu 12 and `puppyip address` can change the shared address later. Existing
  installations and subsequent additions retain their selected address.
- The address transaction changes only `serverAddress`, preserves unknown
  fields and schema, verifies a private backup, and uses atomic replacement.
  It does not change the runtime configuration, credentials or service.
- Single/all views, installation output, add/port previews and their shared
  edit/reset display path use the same domain resolver and QR link. A newly
  detected machine IP cannot replace a saved domain. Exit addresses retain
  their separate meaning.
- A review found that jq 1.6 can round large unknown numeric fields. Raw
  numeric-token comparison now refuses the transaction before writing when
  any numeric spelling changes; existing semantic invariants remain intact.

## Hosted runs

| Source | GitHub run | Result and reason for next run |
| --- | --- | --- |
| `96388667a70b72aec031ab135605eb16216002fb` | [44029099268](https://github.com/longdog123/xray-chain-installer/actions/runs/44029099268) | 12/13 suites passed, including 50 address cases. Static failed when the previously optional ShellCheck actually ran. Findings were fixed or documented at specific mock boundaries; no suite or assertion was removed. Independent review also led to the numeric preservation guard. |
| `313c56170d290926785a637fe077692c4c235dc7` | [44030569668](https://github.com/longdog123/xray-chain-installer/actions/runs/44030569668) | 13/13 suites passed, including 52 address cases. The owner then requested the initial interactive domain prompt, requiring a changed source and new PTY coverage. |
| `3a4e6ff95b92f1bbd07073de82a126b93d4c70bf` | [44031554206](https://github.com/longdog123/xray-chain-installer/actions/runs/44031554206) | Final 13/13 suites passed, including 57 address cases. All recorded source/workflow/test hashes were independently compared with Git blobs before archiving. |

The required suites are integration, add-preview, port-change, rollback,
auto-update, static, socks-verification, address-refresh, system-errors,
status-errors, error-context, entry-address and preflight. The hosted runner's
eight narrow unit checks also passed. Each run records UTC times, dependency
versions, per-suite duration/exit status and the exact source/workflow commit.

The final 57 address cases cover shared/mixed/independent ports, paused nodes,
schema 1, complete link comparisons, unchanged protected files, backups,
atomic failure, locking, invalid input, IP detection ambiguity, domain
retention across model operations, every shared display/QR path, numeric
preservation, and first-install terminal input including EOF and environment
precedence.

## Evidence and limits

- [Initial failed hosted run](2026-11-17-domain-entry-hosted-first.json)
- [Second successful hosted run](2026-11-17-domain-entry-hosted-second.json)
- [Final successful hosted run](2026-11-17-domain-entry-hosted-final.json)
- [Local narrow checks and staged test scope](2026-11-17-entry-address-local.json)
- [Actual jq 1.6 numeric helper checks](2026-11-17-jq16-number-guard.json)

The local record intentionally preserves the earlier pending status of each
test extension; the final hosted record supersedes those pending execution
entries. Local checks used Windows-native tools only. No retired WSL
distribution was invoked or reconstructed.

Hosted tests used the fixed official Xray v26.3.27 runtime and geodata, checked
against both the official digest and the archived SHA-256. Every suite ran in
a separate network/mount/PID namespace with private temporary filesystems.
The reports record process exit and temporary-entry counts before namespace
release; the private downloaded runtime was removed. Raw logs and synthetic
configuration/key files were not uploaded. The JSON evidence is allowlisted
and contains no customer data, credentials, private paths or full links.

These checks validate configuration generation and compatibility with
synthetic fixtures. They do not establish customer DNS propagation, external
client reachability, firewall behavior or successful real VPS replacement.
No customer server or DNS record was changed, and no production release was
performed by these runs.

## Authorized publication

The owner subsequently authorized publication on 2026-11-17. `main` advanced
from `71343020ec70605f03fd18b3ecf45129758633db` to the verified release commit
`5fafdd72971da64682a048e266e6580fac0735e5` by a normal fast-forward push. The
preflight checks passed again, the hosted run remained successful, and every
recorded source/workflow/test hash still matched the release. The unchanged
full suites were not repeated.

[Public download verification](2026-11-17-publication-0.2.24.json) confirms
that the current installation URL, the legacy redirected URL and the fixed
release-commit URL all returned version 0.2.24 with installer SHA-256
`b9e9ada767c4ad563eb9c9c105016d45bf9cc532dc36597c5df0b7a40247ba54`.
The publication evidence commit changes documentation only. No customer
server was updated directly and no DNS record was modified.
