# research/ax211-audit — Index

Source-level forensic audit of the reduced AirportItlwm tree (`e4857ff` =
`v2.4.0-ax211-reduced`) for the Intel AX211 (so-a0-gf-a0 family) on macOS
Sequoia 15.8.2 / MSI Modern 14 C12MO. Audit date 2026-11-18. **152 findings**
(`findings.json`) **+ 18 XPLAT findings** (`cross-platform-analysis.md`) =
**170 total**. No driver source was modified by the audit.

## Reading order

1. **`DOSSIER.md`** — master dossier: start here (executive findings,
   verified hardware facts, per-OS summaries, remediation order).
2. **`findings.json`** — machine-readable findings (all 152, with
   classifications and source anchors).
3. **Per-subsystem reports** — `00` through `13` (repo state, IWX HAL,
   Airport/WCL integration, itl80211 control & data planes), then `20`–`23`
   (Linux reference, CI verification, fork comparison, environment).
4. **Cross-platform** — `cross-platform-analysis.md` (18 XPLAT findings).
5. **Tools** — `tools/` (owner-run runtime diagnostic kit, Ubuntu + macOS).

## File index

| File | Contents |
|---|---|
| `DOSSIER.md` | Master dossier: executive summary, 15 headline findings, hardware fact-split, per-OS and Linux condensed analyses, remediation order (690 lines). |
| `00-repo-state.md` | Repo state verification: revision/tag provenance, upstream base (laobamac/itlwm @ 7204c69), tree cleanliness, reference snapshots. |
| `10-iwx-hal-audit.md` | IWX HAL deep audit (25 DRV-IWX findings): firmware load/PNVM, command rings, gen3 transport, aggregation/queue lifecycle, power state machine. |
| `11-airport-integration-audit.md` | Native macOS integration layer audit (28 DRV-AP findings): WCL/Airport control plane, scan/power/event handling, status reporting. |
| `12-itl80211-controlplane-audit.md` | itl80211 control plane audit (25 DRV-11C findings): scan/association/roaming, node lifecycle, bgscan latch, watchdog concurrency. |
| `13-itl80211-dataplane-audit.md` | itl80211 data plane & security audit (25 DRV-11D findings): TX/RX paths, aggregation, CCMP/replay/KRACK, WPA3-SAE/PMF/6 GHz capability gaps. |
| `20-linux-iwlwifi-analysis.md` | Linux mainline iwlwifi reference analysis (20 LINUX findings, kernel @ 20eef29b): iwlmvm architecture, scan offloads, roaming, power-save, TVQM lifecycle, error containment. |
| `21-ci-artifact-verification.md` | CI artifact verification (10 CI findings): GitHub Actions run 44145096042, binary sha256 30a3ce59…, 7,622,312 B x86_64, release provenance, unsigned-kext blocker. |
| `22-reference-forks-analysis.md` | Reference fork comparison (15 REF findings): 3 forks vs. this tree; reduction is clean, all behavioral defects upstream-inherited (REF-015). |
| `23-environment-access.md` | Execution environment & evidence handling: remote runtime access blocked (ENV-BLOCK-001), gap documentation methodology. |
| `hardware-inventory.md` | Hardware inventory with honest fact-split: owner-declared vs. source-verifiable vs. unknown (PCI ID candidate table, HW findings). |
| `ubuntu-analysis.md` | Ubuntu runtime analysis — NOT EXECUTED (gap documentation): planned probes, source-derived expectations, probe-to-finding mapping. |
| `macos-analysis.md` | macOS runtime analysis — NOT EXECUTED (gap documentation): planned probes (loaded kext identity, link status), probe-to-finding mapping. |
| `cross-platform-analysis.md` | Cross-platform comparative analysis: 18 XPLAT findings mapping fork behavior to Linux iwlwifi correspondence (firmware API 68 vs 89, TVQM, roaming, notification-wait). |
| `findings.json` | All 152 machine-readable findings: ID, classification, severity, source anchors, cross-references (schema v1.0). |
| `evidence-manifest.json` | Evidence manifest: every artifact/snapshot examined, hashes, provenance, and what was NOT collected. |
| `tools/README.md` | Diagnostic kit guide: safety statement, when/how to run, bundle sharing instructions. |
| `tools/ubuntu-diagnostics.sh` | Ubuntu 24.x owner-run read-only diagnostic script (no root, ~1 min, sanitizes host-side). |
| `tools/macos-diagnostics.sh` | macOS Sequoia owner-run read-only diagnostic script (Terminal/zsh, read-only probes). |
| `tools/OPTIONAL-privileged.md` | Exact list of the few optional root probes that add evidence beyond the no-root kit. |
| `tools/OPTIONAL-privileged-list.md` | Superseded earlier draft of the privileged-probe list (kept for history; see OPTIONAL-privileged.md). |

## Finding-ID scheme

| Prefix | Scope | Count |
|---|---|---|
| `DRV-IWX` | IWX hardware-abstraction layer (firmware, transport, rings, queues) | 25 |
| `DRV-AP` | Airport / WCL native macOS integration layer | 28 |
| `DRV-11C` | itl80211 control plane (scan/assoc/roam/lifecycle) | 25 |
| `DRV-11D` | itl80211 data plane & security layer | 25 |
| `LINUX` | Linux mainline iwlwifi reference analysis | 20 |
| `CI` | CI artifact / build provenance verification | 10 |
| `REF` | Reference-fork comparison | 15 |
| `REPO` | Repository state / packaging | 4 |
| `XPLAT` | Cross-platform correspondence (in cross-platform-analysis.md, not findings.json) | 18 |
| `HW` | Hardware inventory unknowns (hardware-inventory.md) | — |
| `MAC` | macOS runtime gaps (macos-analysis.md) | — |
| `ENV` | Environment access limitations (23-environment-access.md) | — |

Classification scheme (every finding carries one):
**CONFIRMED DEFECT** (31) · **STRONGLY SUSPECTED DEFECT** (17) ·
**UNVERIFIED IMPLEMENTATION RISK** (21) · **VALIDATED CORRECT BEHAVIOR** (40) ·
**UNSUPPORTED OR INCOMPLETE CAPABILITY** (41) · **UNRESOLVED** (2) — totals 152.
The XPLAT taxonomy adds: ARCHITECTURAL DIFFERENCE (4), FORK DEFECT CONFIRMED
BY LINUX CORRESPONDENCE (5), FORK DEFECT STRONGLY SUSPECTED (2), UNSUPPORTED
CAPABILITY (5), FIRMWARE-VERSION DIFFERENCE (1), UNRESOLVED (1).

## Evidence context (disclaimer)

**This is a source-only audit.** The prescribed live Ubuntu-then-macOS
investigation over the network relay was blocked by sandbox policy
(ENV-BLOCK-001; see `23-environment-access.md`); no runtime evidence from
either OS exists. All classifications are source-evidence based; runtime
confirmation is pending via the owner-run sanitized diagnostic kit in
`tools/`. Suspected is not confirmed.
