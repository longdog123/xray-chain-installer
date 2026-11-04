# Required manager updates

**Goal:** Opening `puppyip` or rerunning the installation command must apply available manager updates without asking for approval. The user explicitly authorized this policy on 2026-11-04.

**Architecture:** Keep the existing pinned-commit HTTPS download, candidate validation, separate updater process, transactional backup/rollback and compatibility checks. Remove the public skip-update switch and remote installer confirmation. A failed check or update stops this menu invocation without stopping the live proxy service. A successful update transfers to the installed manager through a version-checked internal menu entry, avoiding repeated downloads or returning to the old code. An already current, consistent installation skips deployment; a same-version installation with mismatched saved schema/version or manager versions is repaired using the validated candidate.

**Boundaries:** Only the two requested entry flows change. Explicit diagnostic and management subcommands retain their existing behavior. Repeating the installation command still proceeds to add a line after a successful update or a same-version skip. Delete, reset, uninstall and incomplete-installation safeguards retain confirmations. Upgrade invariants remain strict; no existing node fields may change.

- [x] Update auto-update and remote-installer tests first. Demonstrate failures on 0.2.20 for forced checks, fail-closed errors and removed approval.
- [x] Remove the public opt-out, require successful version-consistent upgrade, and add checked internal menu handoff. Extract the existing menu loop without changing its actions.
- [x] Remove remote-upgrade confirmation, keep same-version skip and non-downgrade checks, and stop on failure before add.
- [x] Update version, README and durable owner instructions; preserve all protective assertions.
- [x] Run targeted tests and existing upgrade/integration/rollback/address/preview/port/static suites as applicable. Review changes, retain sanitized evidence and run preflight before committing.

Earlier 0.2.20 validation remains under `docs/validation/`. New runs are required because the update failure and menu handoff behavior changes in this task; they do not repeat a live maintenance drill. No production server or customer data is involved.
