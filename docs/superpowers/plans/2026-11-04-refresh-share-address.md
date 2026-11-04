# Refresh displayed server addresses

**Goal:** On a normal VPS whose public IPv4 has been replaced, `puppyip show` and menu item 3 display the current address without confirmation. Keep existing node settings and the running service intact.

**Design:** Resolve one address per viewing operation. A saved domain or an explicitly disabled refresh remains unchanged. For a numeric address, retain it while it is still assigned locally. Otherwise only use a unique eligible local IPv4 that agrees with a short, direct public-IP probe. Ambiguous addressing and failed detection retain the saved address. Pass the result explicitly to link generation and QR output, without persisting it. Ordinary configuration rendering and upgrade invariants continue using the saved state.

Historical numeric custom entrances have no provenance metadata. The local/probe agreement is a conservative heuristic, not proof that a saved numeric entrance is obsolete. Document `XRAY_CHAIN_AUTO_ADDRESS=0` for users who intentionally retain a numeric relay entrance. Domains, NAT and multiple public interfaces are preserved by default. Existing client profiles are not remotely updated.

**Scope:** `install.sh` owns resolution and display argument propagation; `tests/address-refresh.sh` owns regression coverage; `tests/static.sh` includes syntax validation; `README.md` describes use and limits. No new persistent state fields, migrations or changes to upgrade assertions.

- [x] Write and run failing tests against 0.2.19: shared, mixed, all-independent, paused and legacy nodes; QR payload; only address changes; unchanged state/config; one probe per batch and fresh resolution next time.
- [x] Implement `resolve_share_address`, preserving domains, existing local addresses, ambiguous networks and detection failure. Allow explicit opt-out. Keep `build_share_link` pure unless passed a display address.
- [x] Pass the resolved address through `command_show`, `show_all_connections`, `show_connection`, then QR generation. No confirmations, writes or service actions.
- [x] Run address regressions plus static, integration, add-preview, port-change, auto-update and rollback checks. Verify all original compatibility assertions remain.
- [x] Review changes independently, retain a sanitized test report, and run preflight. Report local implementation separately from publication and live VPS verification.

## Validation notes

The earlier reproduction is archived locally under `diagnostics/ip-change-2026-11-04` in the original checkout. It confirmed stale addresses in 91 links across four changed-IP scenarios. New tests are justified because behavior is now being changed. Tests must use synthetic fixtures and isolate host networking/service boundaries. Network reachability after a real provider IP replacement is outside this local validation.
