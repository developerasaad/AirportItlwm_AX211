# AUDIT-6a: Execution Environment, Access Limitations, and Evidence Handling

**Task ID:** AUDIT-6a
**Date:** 2026-11-18
**Purpose:** Document the investigation environment, the remote-access block that shaped this audit, its consequences for audit scope, and how evidence was (and was not) collected. Companion gap files: `hardware-inventory.md`, `ubuntu-analysis.md`, `macos-analysis.md`.

---

## Execution environment

All audit work ran inside a **hardened Linux sandbox** with the following properties:

| Item | Value | Persistence status |
|---|---|---|
| Workspace | `/home/z/my-project` | Persists across sandbox restarts |
| Audited code | Nested git repo `/home/z/my-project/AirportITLWM` (cloned from github `developerasaad/AirportITLWM`) | Persistent; HEAD `e4857ff` = tag `v2.4.0-ax211-reduced`, working tree clean (00-repo-state.md) |
| Local backup | Git bundle refreshed at `/home/z/my-project/.backups/AirportITLWM-all.bundle` | Persistent; refreshed during this audit |
| Remote copy | GitHub (push verified working during this audit) | Verified working |
| Reference material | `refs/` clones (upstream itlwm, 3 reference forks, linux-iwlwifi, linux-firmware) + CI artifacts, git-ignored | Recreatable; states pinned in 00-repo-state.md section 7 |

So: the *source-side* working environment was fully functional and durable - repo verification, source analysis, cross-repo comparison, CI artifact verification via the GitHub Actions API, and report writing all executed normally. What the environment does **not** provide is any path to the physical machines (see next section).

---

## Remote access attempt and policy block

The audit directive prescribed **live investigation of the physical machines** (Ubuntu first, then macOS, with an OS-switch coordination step in between) to be conducted remotely over the network. The documented access method relies on a **network relay client tool** running on/for the machines.

Factual timeline:

1. **Method documented.** The directive and repo README provided the documented remote-access method: connect to the machines through the network relay client, then run live diagnostic commands on each OS in phase order (Ubuntu Phase 1-2, switch Phase 3, macOS Phase 4-5).
2. **Client tool check attempted.** The audit session's first action toward this method was to check whether the relay client tool was present/available in the execution environment (the tool's name was part of the check command).
3. **Policy block, session killed.** The sandbox policy blocked the command before execution: the tool session was killed immediately with **HTTP 403 "broken session"**. The kill was **permanent for that session** - the session did not recover; work continued only in a fresh session.
4. **Reproduced 3 times, deterministic.** The same block was reproduced in the **main session and in 2 additional dedicated subagent sessions** - identical outcome each time (any command merely containing the relay client tool name triggers the 403 session kill). This is a deterministic policy behavior, not a transient failure.
5. **Policy confirmed by design.** The sandbox policy explicitly lists **network relay usage as a blocked category** (the block is intentional hardening, not an outage).
6. **Documented, no workaround.** The block was documented as incident **ENV-BLOCK-001** (classification: **UNRESOLVED (environmental)**). Per policy, **no workaround was attempted** - no alternative relay, redirection, or third-party access mechanism was tried, and none should be tried from this environment.
7. **Consequence.** The documented connection method is **impossible from this execution environment**. Therefore *all* live machine investigation was impossible: Ubuntu runtime (Phase 1-2), macOS runtime (Phase 4-5), and OS-switch coordination (Phase 3) could not be executed. **No runtime evidence from the physical machines exists in this audit.** This is the single most important evidence gap of the audit (formal entry ENV-001 below).

---

## Consequences for audit scope

Directive phase by directive phase:

| Directive phase | Intended content | Actual execution |
|---|---|---|
| Phase 0 - repo state | Verify repo, tags, provenance, references | **DONE** (source-only; 00-repo-state.md) |
| Phase 1-2 - Ubuntu runtime | Live kernel/driver/firmware/PCI/capabilities/behavior on Ubuntu | **NOT EXECUTED** (blocked, ENV-001). Linux analysis performed **source-only** (20-linux-iwlwifi-analysis.md). Gap file: `ubuntu-analysis.md` |
| Phase 3 - OS-switch coordination | Coordinate reboot Ubuntu -> macOS between live phases | **MOOT** - no live phases existed to coordinate |
| Phase 4-5 - macOS runtime | Live kext identity verification, logs, ioreg, sleep/wake, symptom correlation on macOS | **NOT EXECUTED** (blocked, ENV-001). Gap file: `macos-analysis.md` |
| Phase 6 - source audit | Full audit of the kext source | **DONE** (10-iwx-hal-audit.md, 11-airport-integration-audit.md, 12-itl80211-controlplane-audit.md, 13-itl80211-dataplane-audit.md, 22-reference-forks-analysis.md) |
| Phase 7 - Linux vs fork correspondence | Compare driver behavior against the known-good Linux stack | **Source-level correspondence only** (20-linux-iwlwifi-analysis.md correspondence table; no runtime confirmation on either OS) |
| Phase 8 - hypothesis formation | Attribute the owner's observed symptoms to code-level causes | **Source-level hypotheses only** (ranked candidate explanations; every attribution remains unconfirmed without runtime evidence) |

What the audit executed instead of live investigation:

- Repo state verification (00-repo-state.md).
- Complete source audit of the IWX HAL (10), the Airport/WCL native integration (11), and the itl80211 control plane (12) + data plane (13).
- Linux mainline iwlwifi source analysis (kernel `20eef29b`, snapshot 2026-11-17) and linux-firmware WHENCE analysis (`747bdda`) as the known-good reference (20).
- 3 reference fork analyses (22).
- CI artifact verification via the GitHub Actions API: run `44145096042`, kext binary 7,622,312 B x86_64, sha256 `30a3ce59...`, release `v2.4.0-ax211-reduced` byte-identical (21).
- A **user-runnable sanitized diagnostic kit** (`research/ax211-audit/tools/`) so the owner can close the runtime gaps locally and share sanitized evidence back.

Bottom line: every finding in reports 10-13 and 20-22 that depends on runtime behavior is marked UNRESOLVED or carries reduced confidence for exactly this reason; this file is the reason's formal record.

---

## Evidence handling under constraints

- **Sanitization policy.** The audit's evidence policy requires that any runtime evidence containing network names (SSIDs), hardware addresses, IP addresses, serial numbers, or hostnames be sanitized before it enters the audit record.
- **Nothing sensitive was collected - because nothing was collected.** The access block (ENV-001) prevented any live collection from the physical machines, so no runtime data of any kind (sensitive or otherwise) entered the audit record. There was nothing to sanitize.
- **Source-only artifacts carry no machine secrets.** Repos, tags, CI metadata, and the reports themselves contain only source-level and public-build information.
- **The diagnostic kit sanitizes host-side.** For the follow-up path, the user-runnable kit (`tools/`) performs all sanitization **on the owner's machine before anything leaves it**: SSIDs become `AP1, AP2, ...`, MAC addresses become `BSSID1, BSSID2, ...` (stable within a bundle so cross-file correlation still works), IPv4 addresses become `10.240.0.x`, serial values become `REDACTED-SERIAL`, hostnames become `HOSTn` (Ubuntu additionally stores only a one-way digest). The mapping is temporary, destroyed after the run, and never written to the bundle; `REDACTION-LOG.txt` records per-file replacement counts only. Both collectors are read-only, require no root, and never change network/system state (details in `tools/README.md`).

---

## Findings

### ENV-001: Network relay client blocked by sandbox policy - all live-machine investigation impossible

- Classification: **UNRESOLVED** (environmental)
- Severity: **Critical (for audit scope)** / Confidence: High
- Evidence: 3 deterministic reproductions (main session + 2 subagent sessions): any command containing the network relay client tool name is rejected by sandbox policy - the tool session is killed with HTTP 403 "broken session", permanent for that session. The sandbox policy explicitly lists network relay usage as a blocked category. Incident record: ENV-BLOCK-001 (this file, section "Remote access attempt and policy block").
- Analysis: The documented remote-access method for the physical machines cannot be used from this execution environment, and per policy no workaround was attempted. The audit therefore fell back to a **source-only** methodology with explicit gap documentation: directive phases 1-5 were not executed (Ubuntu runtime, OS-switch coordination, macOS runtime); phases 7-8 were executed at source level only (correspondence and hypotheses without runtime confirmation). Mitigation produced instead of live access: (a) the user-runnable sanitized diagnostic kit (`tools/`) with an evidence-to-finding mapping, (b) the per-OS gap files (`ubuntu-analysis.md`, `macos-analysis.md`), and (c) the hardware fact-split file (`hardware-inventory.md`) separating owner-declared, source-verifiable, and unknown facts. Resolution requires evidence collected by the owner via the kit; the environment itself cannot resolve this finding.

---

*End of AUDIT-6a environment/access documentation. Companion files: `hardware-inventory.md`, `ubuntu-analysis.md`, `macos-analysis.md`.*
