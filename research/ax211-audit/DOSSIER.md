# AX211 AirportItlwm Forensic Audit - Technical Dossier

| Field | Value |
|---|---|
| Dossier date | 2026-11-18 (all audit work performed this date; reference snapshots 2026-11-16 to 2026-11-18) |
| Subject | MSI Modern 14 C12MO / Intel Wi-Fi 6E AX211 (CNvi, so-a0-gf-a0 family) / macOS Sequoia 15.8.2 x86_64, native AirportItlwm |
| Audited revision | `e4857ff` = tag `v2.4.0-ax211-reduced` (working tree clean); shipped binary built from parent `f588ecd` (docs-only difference, CI-004) |
| Upstream base | laobamac/itlwm @ `7204c69` (tag v2.4.0-alpha, 2026-11-01); baseline tag `ax211-baseline-validated` -> `aa19316` |
| Linux reference | torvalds/linux @ `20eef29b` (sparse iwlwifi/mac80211/cfg80211 clone, snapshot 2026-11-17) |
| Firmware reference | linux-firmware @ `747bdda` (WHENCE metadata, snapshot 2026-11-18) |
| Finding totals | 152 findings in `findings.json` + 18 XPLAT findings (`cross-platform-analysis.md`) = 170 |
| Classification scheme | CONFIRMED DEFECT (31) / STRONGLY SUSPECTED DEFECT (17) / UNVERIFIED IMPLEMENTATION RISK (21) / VALIDATED CORRECT BEHAVIOR (40) / UNSUPPORTED OR INCOMPLETE CAPABILITY (41) / UNRESOLVED (2). XPLAT taxonomy adds: ARCHITECTURAL DIFFERENCE x4, FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE x5, FORK DEFECT STRONGLY SUSPECTED x2, UNSUPPORTED CAPABILITY x5, FIRMWARE-VERSION DIFFERENCE x1, UNRESOLVED x1 |
| Evidence context | **Source-only audit.** The directive's live Ubuntu-then-macOS investigation over the network relay was blocked by sandbox policy (ENV-BLOCK-001, see 23-environment-access.md); no runtime evidence from either OS exists. All classifications are source-evidence based; runtime confirmation is pending via the owner-run sanitized diagnostic kit (`tools/`). Suspected is not confirmed. |

Companion reports: 00-repo-state.md, 10-iwx-hal-audit.md, 11-airport-integration-audit.md, 12-itl80211-controlplane-audit.md, 13-itl80211-dataplane-audit.md, 20-linux-iwlwifi-analysis.md, 21-ci-artifact-verification.md, 22-reference-forks-analysis.md, 23-environment-access.md, hardware-inventory.md, ubuntu-analysis.md, macos-analysis.md, cross-platform-analysis.md, findings.json, evidence-manifest.json, tools/.

---

## A. Executive findings

1. **Remote runtime access was blocked; this is a source-only audit.** The directive prescribed live investigation of the physical machines over a network relay client; that access method is blocked by sandbox policy (ENV-BLOCK-001: deterministic block, 3 reproductions across sessions, HTTP 403 session kill). No Ubuntu or macOS runtime evidence exists. Mitigations produced instead: a user-runnable sanitized diagnostic kit (`tools/`), per-OS gap files, and a hardware fact-split. Every runtime-dependent claim below is a hypothesis pending kit confirmation (ENV-001).

2. **The reduction is clean: every behavioral defect found is upstream-inherited.** Live driver files (WCL.cpp/hpp, SkywalkInterface.cpp, AirportItlwmV2.cpp, net80211, hal_iwx behavior) are byte-identical to laobamac/itlwm @ 7204c69; the reduction only deleted code (iwm/iwn HALs, standalone itlwm, non-Sequoia targets) and added a 9-line shared constant (REF-015). Defect fixing therefore means diverging from upstream deliberately, not repairing the reduction.

3. **Roaming is disabled by a latch (CONFIRMED).** Both join paths latch `IEEE80211_F_DESBSSID` for the whole association (DRV-11C-002), which blocks the bgscan trigger and rejects every other BSSID in candidate selection. Any transition is a full AUTH + 4-way handshake with no 11r/11v (DRV-11D-017); after beacon loss the driver stays pinned to the dead BSSID. No reference fork fixes this (REF-001).

4. **Scan has a truncation race plus an infinite idle loop.** ScanDone (posted via a 0-ms timer hop) can overtake the final ScanResult messages, truncating the tail of the network list (DRV-AP-011, STRONGLY SUSPECTED); the one-shot `scanSkipCompletion` guard is only one-deep (DRV-AP-009). Separately, with no pending join the driver scans forever - no idle park, no failover, 30 s dead-BSSID lockout (DRV-11C-003, CONFIRMED) - churning the Wi-Fi menu, burning RF airtime/power at idle, and flooding logs.

5. **Power handling contains an OR-logic bug (CONFIRMED).** `setPOWER` computes "running" as `(if_flags & (IFF_UP | IFF_RUNNING)) != 0` (DRV-AP-006): when the interface is UP but the firmware is stopped (a common post-error state), a radio-on toggle silently fails to re-enable the adapter. The wake path acknowledges power-on without re-enabling at all - recovery depends on airportd/WCL follow-up (DRV-AP-007). The bug is identical in every reference fork (REF-007).

6. **Aggregation resources leak across roam/sleep cycles.** TX aggregation teardown never releases the firmware/driver TVQM queue (DRV-IWX-011: `iwx_ampdu_tx_stop` is two lines); RX reorder buffers and parked mbufs leak per roam (DRV-11D-009); no DELBA is sent to the AP (DRV-11D-010); TX BA sessions advertise timeout 0 (DRV-11D-013). Linux proves the firmware expects explicit queue removal and reuses IDs indefinitely (LINUX-010); after enough cycles (~64 by the audit's arithmetic), ADDBA is refused permanently and throughput pins at legacy rates until reboot. No fork releases these queues either (REF-006).

7. **A command-slot leak can lock out all firmware commands.** A timed-out synchronous command permanently consumes one of the 128 gen3 command-ring slots; enough timeouts yield ENOSPC for all commands and a reinit loop (DRV-IWX-009, STRONGLY SUSPECTED). Linux's central notification-wait abort is the fix blueprint (LINUX-015, XPLAT-018).

8. **WPA3-SAE, PMF, GCMP and the 6 GHz band are absent.** SAE auth frames are dropped and the WPA3-to-WPA2 mapping is compiled out of the WCL target (DRV-11D-003, CONFIRMED); PMF is unadvertised and the IGTK path is dead (DRV-11D-004); GCMP is unrepresentable (DRV-11D-002); 6 GHz is compiled out at `#ifdef notyet` in the NVM channel table (DRV-11D-001, CONFIRMED) and dropped by the WCL scan decoder (DRV-AP-003) - all 6 GHz networks are invisible. WPA2/WPA3 transition networks do work via the RSN-IE rewrite (DRV-AP-004, validated).

9. **The 60-70 Mbps observation has compounding source-level candidates but is NOT attributable.** Candidates: slow ADDBA ramp, 1 s delay / 30 s backoff / never on open networks (DRV-11D-008); one shared non-aggregated TX ring with head-of-line blocking and a 256-TFD cap workaround for an unexplained gen3 freeze (DRV-IWX-010, XPLAT-014 UNRESOLVED); qfullmsk global TX stall where one full ring stops everything including EAPOL (DRV-11D-018, CONFIRMED); aggregation eventually refused via the leak chain (DRV-IWX-011). Competing explanation: the figure was measured "on their internet plan" - the plan itself may be the ceiling; LAN throughput was never tested (MAC-002).

10. **Firmware is stale and over-included.** The kext embeds API-68 firmware (one coherent build, core66_LinADLPV) while mainline Linux pins API 89 for the same so-a0-gf-a0 family - 21 API versions behind; linux-firmware has pruned 68 (XPLAT-002, LINUX-002). A strict AX211 (0x51F0 + GF) build needs 2 of the 15 embedded blobs (1,575,620 of 16,700,476 raw bytes = 9.4%); the other 13 blobs (90.6% of payload) serve non-target devices (DRV-IWX-006, REPO-002). Four advertised PCI IDs can never load firmware at all (DRV-IWX-002).

11. **The shipped kext is unsigned - an installation blocker on stock Sequoia (CI-005).** No code signature of any kind (`CODE_SIGNING_ALLOWED=NO`); `kmutil` will refuse to load it with SIP enabled. Installation requires ad-hoc signing plus recovery approval, or OpenCore injection - not documented in the release notes. Additionally, no CI run exists for the tagged commit `e4857ff`; the release ships a binary built from parent `f588ecd` (docs-only difference; CI-004).

12. **The 1 s watchdog runs ungated - a confirmed concurrency defect.** A dedicated workloop drives `ieee80211_watchdog`, decrementing `ic_mgt_timer` and firing full SCAN transitions concurrently with the RX thread, outside the command gate that serializes everything else (DRV-11C-004, XPLAT-011). `splnet()` is a no-op and all KASSERTs compile away (DRV-IWX-018).

13. **The upward event surface is minimal - the status-staleness cluster.** The complete event inventory has no roam/BSSID-change, no disassoc, no beacon-miss, no port-authorized event (DRV-11C-008). All WCL freshness is keyed to the join-time BSSID; after any internal recovery, LQM is forced to -2 and LinkStatus-up is never posted (DRV-AP-005); a transient deauth triggers a silent auto-reauth that airportd never learns recovered (DRV-11C-007).

14. **Core data security and the build provenance chain are sound.** WPA2/CCMP is validated correct including per-TID replay counters, KRACK reinstall guards and fragattack mitigations (DRV-11D-005/014); GTK/IGTK group rekey handling is complete (DRV-11C-020). The CI artifact chain is verified end-to-end: run 44145096042, binary sha256 `30a3ce59...`, release asset byte-identical (CI-001/002/003/008/010). These are regression safeguards for all future work.

15. **Remediation order (evidence-based).** Fix driver-side lifecycle defects first (aggregation/queue lifecycle, idle scan loop, PNVM wait, watchdog gating) - they reproduce on API 68 and do not require a firmware upgrade; treat a firmware API 68-to-89 re-port as a separate high-risk work package (XPLAT-002 analysis); Tier-2 firmware/device-table reduction (13/15 blobs, 18/19 PCI IDs) only after runtime PCI-ID confirmation via the kit (HW-002). The physically validated baseline tag must never regress.

---

## B. Verified physical hardware

Full detail in `hardware-inventory.md`. No runtime evidence exists (ENV-001), so hardware facts split into three categories: owner-declared (trust), source-verifiable (evidence), unknown (runtime gap).

**Owner-declared (not independently verified - HW-001, UNRESOLVED):**

| Item | Declared value |
|---|---|
| Machine | MSI Modern 14 C12MO |
| Adapter | Intel Wi-Fi 6E AX211 160MHz (CNvi integrated; no separate PCIe card) |
| Boot config | Triple-boot Ubuntu / macOS / Windows |
| macOS | Sequoia 15.8.2, x86_64 (Darwin 24.x) |
| Driver | Native AirportItlwm kext (IWX HAL), reduced build |
| Owner testing | Baseline build hardware-validated (basic Wi-Fi OK); reduced build physically tested: ordinary Wi-Fi works, ~60-70 Mbps stable on their internet plan; "wider wireless experience and native macOS integration appear unreliable or insufficiently polished" (observations, not diagnoses - MAC-002) |

**Source-verifiable:**

- Kext artifact: x86_64 Mach-O kext bundle, Debug, 7,622,312 B, sha256 `30a3ce590b8c137faa0e7f593733bacb15dd1c1c2e5f98773b4f6b350a6b674a`, bundle `com.zxystd.AirportItlwm` v2.4.0; release asset byte-identical to CI run 44145096042 (CI-001/002/008). Baseline binary 16,262,720 B; reduction = -53.13% (CI-003).
- The AX211 is a CNvi (integrated-on-PCH) part: Linux marks the So-family MAC configs `integrated = true`; the device-to-adapter mapping is subdevice-dependent, which is why the deferred Tier-2 device-table trim needs the exact device+subsystem ID first (DRV-IWX-001, LINUX-001, HW-002).
- Firmware family so-a0-gf-a0, API 68, embedded: `iwlwifi-so-a0-gf-a0-68.ucode` (1,533,812 B) + `.pnvm` (41,808 B); 15 blobs embedded total (CI-003).
- 19 PCI IDs advertised in `IOPCIMatch` (REPO-003); AX211-family set CI-checked: 0x51F0/0x51F1/0x54F0/0x7E40/0x7F70; the Alder-Lake CNvi AX211 device `0x2725` (sub 0x0090) maps to the embedded so-a0-gf-a0 blob (CI-003).

**PCI ID candidate table (hardware-inventory.md; exact ID of THIS unit unknown - HW-002, UNRESOLVED):**

| PCI device ID (vendor 8086) | Mapping (source audit) | Embedded fw | Status for this unit |
|---|---|---|---|
| 0x51F0 | So long-latency MAC -> `iwlax211_2ax_cfg_so_gf_a0` (AX211 reference target) | Yes | Candidate (unverified) |
| 0x7F70 | So MAC config (`iwl_so_mac_cfg`) | Yes (so family) | Candidate |
| 0x2725 | Fork dev_info: sub 0x0090 -> `iwlax211_2ax_cfg_so_gf_a0` (Alder-Lake CNvi AX211) | Yes | Candidate |
| 0x7AF0 | So MAC config | Yes | Candidate |
| 0x2720 | QnJ -> `iwlwifi-QuQnj-b0-*-48.ucode` | **No** | Broken-advertised (DRV-IWX-002) |
| 0x2726 | SnJ -> `iwlwifi-SoSnj-a0-*-63.ucode` | **No** | Broken-advertised (DRV-IWX-002) |
| 0x2729 | MA -> `iwlwifi-ma-a0-*-63.ucode` | **No** | Broken-advertised (DRV-IWX-002) |
| 0x7E40 | MA -> `iwlwifi-ma-a0-*-63.ucode` | **No** | Broken-advertised (DRV-IWX-002) |

Whichever candidate this unit actually is, the kext embeds loadable firmware for it, so "Wi-Fi works" does not discriminate between them. Unknowns requiring runtime evidence: exact device+subsystem ID, RF front-end (GF vs GF4), BIOS version, SAR tables (WRDS/EWRD/WGDS/PPAG presence), negotiated link capabilities, Ubuntu kernel/driver/firmware versions, loaded-kext identity on macOS (MAC-001), CSME presence (hardware-inventory.md "UNKNOWN" section).

---

## C. Ubuntu operating environment

**Status: NOT COLLECTED (blocked - ENV-001/ENV-BLOCK-001).** The directive's Phase 1-2 live collection on the Ubuntu partition (kernel version, loaded iwlwifi driver version, loaded firmware version string, PCI enumeration, band/channel capabilities incl. 6 GHz, live association/roam/suspend behavior, BIOS SAR tables, throughput baseline) was never executed. Nothing in this audit is based on live observation of the Ubuntu partition (ubuntu-analysis.md).

**What source analysis established instead (20-linux-iwlwifi-analysis.md, source-only):** the known-good reference for this exact silicon - iwlmvm op-mode, versioned scan v12-v17 with adaptive dwell, scheduled scan with firmware match profiles, host-side roaming with 11r/11k/v, full power-management toolbox (U-APSD/snooze/LPRX/beacon filter/WoW D3), balanced TVQM lifecycle, error containment, BIOS SAR/PPAG/GEO enforcement (LINUX-001..020).

**Source-derived expectation (moderate-confidence inference, not verifiable from local snapshots):** mainline pins exactly API 89 for so-a0-gf-a0 and linux-firmware ships 72 through 89 (68 pruned); by the same driver-source rule, Ubuntu releases of 2024-2026 would ship roughly API 72-74 (24.04 era), 77-78 (24.10), 81-83 (25.04), 86-89 (25.10+). Certain: any 2024+ Ubuntu on this machine runs firmware substantially newer than API 68 (LINUX-002, firmware version analysis).

**How to collect now:** run `tools/ubuntu-diagnostics.sh` (owner-run, read-only, no root, ~1 min, host-side sanitization). Key probes: `03-pci.txt` closes HW-002; `06-driver-fw.txt` confirms the loaded firmware API (LINUX-002 open question 1); `07-kernel-log.txt` covers PNVM SKU match, SAR table presence, error/recovery behavior; `04-wifi-caps.txt` is the 6 GHz baseline for the macOS comparison (DRV-11D-001). Full probe-to-finding table in ubuntu-analysis.md.

---

## D. Linux implementation analysis

Condensed from `20-linux-iwlwifi-analysis.md` (kernel @ 20eef29b), which remains the reference for depth, exact line anchors, and the full correspondence table.

**Architecture.** Three layers: a transport layer (`pcie/`: PCIe DMA rings, MSI-X, gen3 context-info/IML firmware load, PNVM plumbing), a firmware-runtime layer (`fw/`: firmware parsing, notification-wait machinery, ACPI/UEFI regulatory tables), and an op-mode driver. For AX211 the op-mode is **iwlmvm** (`mvm/`) - the newer iwlmld (`mld/`) is selected only for Wi-Fi-7-capable families (`iwl_drv_is_wifi7_supported`, iwl-drv.c:181-185), so AX211 (AX210 family + GF RF) stays on MVM. Above the driver, mac80211 implements the MLME and wpa_supplicant (userspace) owns scanning policy, roaming, SAE/FT/802.11v. Device config is derived at runtime: MAC cfgs (`cfg/ax210.c`) + RF cfgs (`cfg/rf-gf.c`) and the firmware name "so-a0-gf-a0" composed from silicon straps (`iwl_drv_get_fwname_pre`, iwl-drv.c:187-292) - the driver cannot mismatch firmware vs silicon (LINUX-001).

**Ownership model.** The capabilities macOS receives from the driver on Linux come from *above* the driver: wpa_supplicant (SAE via external auth, mlme.c:5431; FT auth, mlme.c:5521/9989-9990; BTM/neighbor reports), mac80211 (MLME, beacon-loss/CQM contract, mlme.c:71-73/4945-4947; per-AC subqueues with per-queue stop/wake), cfg80211 (self-managed regd, scheduled-scan policy). This is the root architectural contrast with the fork's in-kext monolith (XPLAT-001).

**Scan offloads.** Versioned UMAC scan request family v17/v16/v15/v14/v12 selected by fw capability (`iwl_scan_umac_handlers`, mvm/scan.c:2736-2743); five scan types including FRAGMENTED and FAST_BALANCE chosen per-scan from TCM traffic load (`_iwl_mvm_get_scan_type`, :220-267); adaptive dwell with per-band budgets (:1292-1444); scheduled scan with multi-plan support and firmware match profiles (`iwl_mvm_config_sched_scan_profiles`, :521-604; MATCH_FOUND -> host, :353-358); 6 GHz discovery via RNR/colocated short-SSID/BSSID filters with PSC-only fallback (:1682-1960, :2001-2088); a scan-timeout watchdog that force-NMIs a wedged firmware (:2698-2707) (LINUX-003/004/005).

**Roaming (host-side).** No firmware reassociation engine exists in MVM (only beacon-filter hysteresis knobs `bf_roaming_*`, power.c:39-42, and CSME roaming-forbidden events, ops.c:1129-1136). mac80211 beacon-loss counting -> CQM notify -> wpa_supplicant roam decision; directed roaming scans use all RX chains (scan.c:2097-2106); session protection guards (re)association (`iwl_mvm_protect_assoc`, mac80211.c:2601-2624; time-event.c:1415+) (LINUX-006).

**Power-save stack.** Per-vif `MAC_PM_POWER_TABLE` v2 (keep-alive >= 3xDTIM, LPRX, PS timeouts, power.c:345-464); skip-DTIM policies (:297-343); **U-APSD** per-AC with QNDP TID, snooze mode and misbehaving-AP detection (:122-212); device power table (:481-514); **beacon filter with CQM hysteresis** (:845-878) - the biggest single PS win, and the command exists even in API 68 (LINUX-018); full WoW via D3 image + offloads (net-detect, GTK rekey with KEK/KCK, patterns, ARP/NS; d3.c, offloading.c) - sleep is an image switch, not a reload (LINUX-007/008).

**TVQM lifecycle.** Dynamic per-TID queue allocation: `iwl_mvm_sta_alloc_queue_tvqm` (sta.c:895-927) -> `iwl_pcie_gen2_txq_alloc` (tx-gen2.c:1016-1106) with **size-halving retry on failure** (:1044-1055) and full HE-size BA queues (cfg/ax210.c:59); explicit removal on every agg-stop/sta-removal: `iwl_mvm_disable_txq` sends `IWL_SCD_QUEUE_REMOVE` then frees the ring (sta.c:351-442; tx-gen2.c:1108-1131). Queue IDs are reused because removal returns them to the firmware allocator - the direct evidence that the fork's never-released queues are a driver defect, not a firmware limitation (LINUX-010).

**Error containment.** `iwl_mvm_nic_error` (ops.c:1964-1989) aborts **all** notification waits wholesale (fw/notif-wait.c), dumps the error log, and for the AX210 family does **not** restart the interface - the firmware self-recovers while the driver reports (ops.c:2008-2064); command-queue-full is a distinct error class; RFKILL is a state transition, not a reinit (LINUX-012/015).

**Firmware pinning.** API min==max==89 for so-a0-gf-a0 (cfg/ax210.c:13-16,74-75 intersected in iwl-drv.c:298-323): exactly one candidate file, driver and firmware ship as a matched pair; linux-firmware ships 72-89 (latest 89, version 86.a67023b2.0) and has pruned 68 (LINUX-002). The audit's remediation guidance derived from this: the fork's field-reproducible defects all reproduce on API 68 and have driver-side fixes; a firmware re-port is a separate high-risk package (every API bump reshapes command/notification layouts - scan v12 to v17 alone re-shapes four parameter blocks).

Also in report 20: SAR/PPAG/GEO/TAS/DSM BIOS power tables applied at init (fw/acpi.c:605-1123; mvm/fw.c:856-1055) vs the fork's zero SAR support (LINUX-009, compliance exposure); MSI-X per-CPU RX vectors (trans.c:1607-1670) vs the fork's disabled MSI-X (LINUX-016); GCMP/IGTK/MFP firmware-side support (sta.c:3602-3606, :3690-3760) vs the fork's unrepresentable ciphers (LINUX-013); PNVM 250 ms timeout/fail-fast/cached-failure flow (fw/pnvm.c) vs the fork's 2 s dead wait (LINUX-014); rate control at parity - both stacks delegate to firmware TLC (LINUX-019).

---

## E. macOS operating environment

**Status: runtime NOT COLLECTED (blocked - ENV-001/ENV-BLOCK-001).** Phase 4-5 (loaded-kext identity verification, `log show` kernel lines, ioreg attach chain, sleep/wake correlation, symptom correlation) was never executed. No log line, ioreg entry, or kextstat output from this machine has been seen by the audit (macos-analysis.md).

**Source/CI-derived facts:**

- **Kext identity:** `com.zxystd.AirportItlwm` v2.4.0, x86_64-only Mach-O kext bundle, Debug, 7,622,312 B, sha256 `30a3ce59...`; built by CI run 44145096042 from `f588ecd` (parent of the tag; docs-only difference - CI-004); release `v2.4.0-ax211-reduced` asset byte-identical (CI-001). Build provenance traceable via the embedded `_f588ecd` string, not plist metadata (CI-007).
- **Dependencies (9 OSBundleLibraries):** IO80211Family 1.5.0, IOSkywalkFamily 1.0, corecapture 1.0.0, IONetworkingFamily 3.2, IOPCIFamily 2.9, mach/libkern/iokit/bsd KPIs 16.7 - Sequoia-native V2/Skywalk linkage (CI-002). `LSMinimumSystemVersion` 15.2; hard start gate refuses anything except macOS 15.2-15.x (15.8.2 passes) (DRV-AP-002).
- **Architecture:** two-stage match/attach (IOPCIEDeviceWrapper personality with 19 PCI IDs -> NetworkController personality) makes the OS treat the kext as the native AirPort controller; the legacy Apple80211 ioctl path is severed in WCL mode - every native interaction is a WCL message or an IO80211InfraProtocol virtual call (DRV-AP-001/002). See section F.
- **Unsigned (CI-005):** on stock Sequoia 15.8.2 with SIP enabled, `kmutil` will refuse the load; requires ad-hoc signing (`codesign -fs -`) + recovery approval, or OpenCore injection. MAC-001 specifically flags that because the kext is unsigned, nothing cryptographically ties the machine's loaded copy to the audited build - typical Hackintosh injection makes an older/other variant equally loadable.
- **19 PCI IDs advertised**, spanning 7260-era through AX211 with the legacy HALs removed (REPO-003, CI-006); 4 broken-advertised (DRV-IWX-002).

**Owner-reported observations (prior session; observations, NOT diagnoses - MAC-002, UNRESOLVED):** ordinary Wi-Fi connectivity works; ~60-70 Mbps stable (on their internet plan - plan-limited vs driver-limited is indistinguishable without a faster path or known-good comparison); "wider wireless experience and native macOS integration appear unreliable or insufficiently polished."

**MAC-001 (UNRESOLVED, Critical for Phase 4):** loaded-kext-identity-vs-source verification not performed. The directive required proving the loaded kext is the audited build before attributing runtime behavior to this source; that proof is missing, so all source-to-symptom mappings assume identity. Closes in minutes via kit probes 04/05 (`04-kexts.txt`, `05-kext-strings.txt`) plus a `shasum` of the loaded binary vs `30a3ce59...`.

**MAC-002 (UNRESOLVED):** the owner symptom set has no structured log, no reproduction steps, no per-class record. The observations are consistent with several distinct source-level defect clusters, but nothing distinguishes which actually manifest on this machine. The kit's guided checks convert them into evidence-backed findings.

**How to collect now:** run `tools/macos-diagnostics.sh` (read-only, no root; probe 08's log query takes minutes; sanitized bundle). Evidence-to-finding mapping in `tools/README.md`.

---

## F. AirportItlwm architecture

Synthesized from reports 10-13. Four layers, top to bottom:

```
+-----------------------------------------------------------------------------+
| L4  EMBEDDED FIRMWARE (API 68)                                              |
|     15 zlib-compressed blobs in fwList[] (12 .ucode + 3 .pnvm, 16.7 MB raw) |
|     one coherent build: core66_LinADLPV::01d30b0c; AX211 uses               |
|     iwlwifi-so-a0-gf-a0-68.ucode + .pnvm (2 of 15 blobs needed)             |
+-----------------------------------------------------------------------------+
                                   ^ MMIO/MSI/DMA
+-----------------------------------------------------------------------------+
| L3  IWX HAL  (itlwm/hal_iwx/, ItlIwx.cpp 13,919 lines)                      |
|     OpenBSD if_iwx.c (rev 1.45, 2020) mechanically ported onto IOKit;       |
|     gen3 (family >= AX210) paths; single class ItlIwx : ItlHalService,      |
|     ItlDriverInfo, ItlDriverController wrapping struct iwx_softc            |
|     - firmware load: TLV parse -> gen3 context-info + IML -> alive          |
|     - commands: mailbox on TX ring 0 (128 slots gen3), sync 1 s sleeps      |
|     - scan: one SCAN_REQ_UMAC per net80211 state step (v1/8/12/14 shapes)   |
|     - TX: TVQM agg queues (256-TFD cap) + ONE shared non-agg ring (qid 2)   |
|     - RX: 512-slot ring, gen3 one-frame-per-RB, hw CCMP decrypt            |
|     - recovery: any error -> full stop + firmware reload (init_task)        |
+-----------------------------------------------------------------------------+
                                   ^ ic_* callback table / HAL contract
+-----------------------------------------------------------------------------+
| L2  itl80211 = OpenBSD net80211 port, STA-only (IEEE80211_STA_ONLY)         |
|     - MLME: INIT->SCAN->AUTH->ASSOC->RUN, transitions made async by         |
|       iwx_newstate_task; scanning delegated to firmware (state machine dead)|
|     - IN-DRIVER SUPPLICANT: ieee80211_pae_input/output.c (4-way + group     |
|       handshake, PSK/PMK; EAPOL never forwarded to macOS on PSK nets)       |
|     - crypto: CCMP (hw+sw), TKIP/WEP sw-only, BIP present but unreachable   |
|     - rate ctrl: firmware TLC (host MiRA/AMRR dead code)                    |
|     - roam engine present but unreachable (F_DESBSSID latch)                |
|     - timers via CTimeout on main workloop; watchdog = separate workloop    |
|       (ungated - DRV-11C-004)                                               |
+-----------------------------------------------------------------------------+
                                   ^ events (8) / ItlHalService
+-----------------------------------------------------------------------------+
| L1  AIRPORT NATIVE INTEGRATION  (AirportItlwm/, live = V2 files only)       |
|     AirportItlwmSkywalkInterface (IO80211InfraProtocol subclass):           |
|       ~380 virtuals: ~20 implemented, ~264 stubbed Unsupported              |
|     WCL.cpp: hand-reverse-engineered wire structs (static_assert guarded),  |
|       11 upward PostOffice messages: 49 ResetInterface, 55 DriverAvailable, |
|       201 ScanResult, 203 Deauth, 211 AssocComplete, 212 FirstBeacon,       |
|       213 ConnectComplete, 214 JoinAbortComplete, 216 LinkStatus,           |
|       39 LqmUpdate, 237 ScanDone                                            |
|     AirportItlwm (IO80211ControllerV2): corecapture pipes, en0 via          |
|       AirportItlwmEthernetInterface (provider-identity spoof), IOPM         |
|       2-state power, watchdog workloop                                      |
|     IOPCIEDeviceWrapper (stage-1 PCI match, MSI setup)                      |
+-----------------------------------------------------------------------------+
                                   ^ WCL messages / IO80211InfraProtocol
+-----------------------------------------------------------------------------+
| Apple: IO80211FamilyV2 + IOSkywalkFamily  ->  airportd / WiFiAgent / WCL    |
+-----------------------------------------------------------------------------+
```

**Key structural properties (each anchors multiple findings):**

- **Single-workloop model + one ungated exception.** Every task/command/timer entry re-dispatches through `getMainCommandGate()->runAction` when not in-gate; OpenBSD `splnet()/splx()` are no-ops (timeout.c:32-39); the interrupt source runs on the same workloop. The lone exception is the 1 s watchdog on a dedicated workloop that mutates MLME state ungated (DRV-IWX-018, DRV-11C-004).
- **In-driver supplicant.** The 4-way/group handshakes, RSN negotiation and key install run in net80211 inside the kext; WCL only delivers PMK/MSK for enterprise; the macOS supplicant is bypassed for PSK networks (DRV-AP-020, DRV-11D-012).
- **WCL 11-message surface.** All upward communication is 11 message types over reverse-engineered wire structs with raw offsets; there is no roam, disassoc, beacon-miss or port-authorized event (DRV-11C-008; DRV-AP-018).
- **~264 stubbed Skywalk methods** return `kIOReturnUnsupported` (roam, WoW, AWDL, BTCoex, 6G, P2P, softAP, HS2.0, ...) vs ~20 implemented (SSID/BSSID/RSSI/CHANNEL/scan/join/WCL) (DRV-AP-012/013/014).
- **HE (Wi-Fi 6) is opt-in via boot-arg** `itlwm_he=1`; default build connects as 802.11ac even to AX APs (DRV-AP-028).
- **TVQM aggregation with a 256-TFD cap** as a freeze workaround (author comment: larger rings "would trigger system freeze on macOS"; the 1024-slot gen3 size is behind `#ifdef notyet`) and never-released queues (DRV-IWX-010/011).
- **Dead code kept in-tree:** ~4,100 lines of legacy integration files (AirportSTAIOCTL.cpp, AirportVirtualIOCTL.cpp, AirportItlwm.cpp, AirportAWDL.cpp, AirportItlwmInterface.cpp) not compiled by the Sequoia target (DRV-AP-024); legacy Apple80211 ioctl path severed (DRV-AP-001).
- **Scan/join lifecycle:** WCL scan -> firmware UMAC scan -> per-BSS message 201 push -> message 237 on completion (or 20 s timeout); join -> forced S_SCAN -> net80211 auth/assoc -> in-driver 4WHS -> first beacon -> ConnectComplete; 30 s join timeout; scan/join mutual exclusion returns Busy (DRV-AP-008).

---

## G. Runtime observations

**Honest statement: no runtime evidence was collected by this audit (ENV-001).** The only runtime information that exists is the owner's observations from prior sessions, which are observations, not diagnoses (MAC-002). All numbers below are owner-reported.

**Owner observations (both builds physically validated across sessions):**

- Baseline build (`ax211-baseline-validated` / aa19316, clean laobamac upstream 7204c69): basic Wi-Fi validated on hardware by the owner in a prior session.
- Reduced build (v2.4.0-ax211-reduced, e4857ff, binary from f588ecd): physically tested by the owner - **ordinary Wi-Fi connectivity works**; **~60-70 Mbps, stable**, measured on their internet plan; **"wider wireless experience and native macOS integration appear unreliable or insufficiently polished."**
- The ~60-70 Mbps figure cannot be attributed: the internet plan itself may be the ceiling; no LAN throughput test and no known-good comparison exist (MAC-002).

**The directive's symptom classes (mapped to owner phrasing; none observed by the audit itself):**

| Symptom class (per directive) | Owner-observable behavior | Source-level candidates (all unconfirmed - see section M) |
|---|---|---|
| Wi-Fi menu scan list behavior | network list changing/refreshing; possibly fewer networks than Ubuntu | DRV-11C-003 (infinite rescan loop), DRV-AP-011 (ScanDone truncation race), DRV-11C-011/012 (staleness) |
| System Settings / status display | wrong network / no bars after a switch | DRV-AP-005 (stale joinBSSID, LQM -2), DRV-11C-008/017 |
| Joining | slow or unreliable joins, especially right after opening the Wi-Fi menu | DRV-AP-008 (scan/join Busy race, 20 s window), DRV-11C-005 (assoc-rejection loop) |
| Network switching (between APs) | no seamless transition, drops when walking away | DRV-11C-002 (roam disabled), DRV-11D-017 (full re-auth roam) |
| Status after connect/roam | stale state, spurious disconnects | DRV-11C-007 (silent reauth), DRV-AP-005 |
| Power events (sleep/wake) | Wi-Fi dead after wake until toggled | DRV-AP-006 (setPOWER OR-logic), DRV-AP-007 (wake ack-only), DRV-IWX-016/017 (reload model) |

**Provenance note (source/CI-verified, not runtime):** the audited source, the CI-built binary (sha256 `30a3ce59...`), and the published release asset are provably identical chains (CI-001); but which binary the owner's machine actually loaded has never been verified (MAC-001) - the kext is unsigned, so nothing cryptographically ties the loaded copy to this build.

---

## H. Cross-platform correspondence

Condensed from `cross-platform-analysis.md` (XPLAT-001..018), which contains the full per-operation analysis with line anchors and per-finding "what runtime comparison would settle it" notes.

**Headline: ownership inversion (XPLAT-001, ARCHITECTURAL DIFFERENCE).** Linux splits the work: transport (`pcie/`) + firmware runtime (`fw/`) + iwlmvm op-mode (`mvm/`), with mac80211 owning the MLME and wpa_supplicant (userspace) owning scan policy, roaming, SAE/FT/BTM. The fork is one kernel monolith: a 13.9k-line HAL class plus in-kernel net80211 MLME plus in-kernel supplicant, with WCL as the only userspace contract. Consequences that generate most findings below: (1) capabilities Linux gets from above the driver must be re-implemented in-kext or do not exist; (2) no userspace backstop absorbs driver-internal transients; (3) one workloop gate serializes what Linux distributes (any blocking wait - the 2 s PNVM sleep, the 1 s commandSleep - is a whole-stack stall); (4) the event surface upward is only what WCL mimics.

**The 14-operation classification table (reproduced from cross-platform-analysis.md):**

| # | Operation | Dominant classification | Components and anchors |
|---|---|---|---|
| 1 | PCI enumeration & config | ARCHITECTURAL DIFFERENCE | Runtime strap-derived so+gf composition vs. static 19-ID tables (LINUX-001, DRV-IWX-001/002/003/004 - residual table defects fork-side but non-AX211) |
| 2 | Firmware selection & load | FIRMWARE-VERSION DIFFERENCE + FORK DEFECT CONFIRMED | API 89 pinned vs. embedded API 68 (XPLAT-002); PNVM flow defect (XPLAT-003); alive/IML handshake at parity (DRV-IWX-013) |
| 3 | Scan | ARCHITECTURAL DIFFERENCE + FORK DEFECT CONFIRMED + UNSUPPORTED CAPABILITY | Request architecture (XPLAT-004); idle infinite loop (XPLAT-005); 6 GHz (XPLAT-006) |
| 4 | Authentication / association | ARCHITECTURAL DIFFERENCE + UNSUPPORTED CAPABILITY | In-driver supplicant (XPLAT-001); SAE/PMF unjoinable, transition mode via RSN rewrite (XPLAT-007); assoc-retry behavior fork-side (DRV-11C-005) |
| 5 | Key management | UNSUPPORTED CAPABILITY (fork) | GCMP/IGTK/sleep-rekey missing (XPLAT-010); awake CCMP + GTK rekey at parity (DRV-11D-005, DRV-11C-020) |
| 6 | Roaming / switching | ARCHITECTURAL DIFFERENCE + FORK DEFECT STRONGLY SUSPECTED | Ownership split + latch (XPLAT-008); status staleness after internal recovery (XPLAT-009) |
| 7 | Connected-state maintenance | UNSUPPORTED CAPABILITY + FORK DEFECT CONFIRMED | Beacon filter/CQM absent (XPLAT-016, LINUX-018); ungated watchdog (XPLAT-011) |
| 8 | Data TX / RX | FORK DEFECT CONFIRMED + UNRESOLVED + ARCHITECTURAL DIFFERENCE | Shared-ring/no-QoS/global stall (XPLAT-013); 256-TFD freeze (XPLAT-014); MSI-X single vector (LINUX-016, DRV-IWX-005); rate control at parity (LINUX-019) |
| 9 | Aggregation | FORK DEFECT CONFIRMED + FORK DEFECT STRONGLY SUSPECTED | Teardown leak lifecycle (XPLAT-012); setup ramp (XPLAT-015) |
| 10 | Power management | UNSUPPORTED CAPABILITY (fork) | PS/U-APSD/beacon-filter/WoW toolbox (XPLAT-016); SAR/PPAG compliance gap (XPLAT-017) |
| 11 | Recovery / fault handling | ARCHITECTURAL DIFFERENCE + FORK DEFECT STRONGLY SUSPECTED | Containment vs. reload (XPLAT-018); CMD_PENDING slot leak (DRV-IWX-009, LINUX-015) |
| 12 | Status / event propagation | ARCHITECTURAL DIFFERENCE + FORK DEFECT STRONGLY SUSPECTED | nl80211 vs. WCL contract (no Linux counterpart); missing roam/disassoc/port-auth events (XPLAT-009, DRV-11C-008) |
| 13 | Regulatory / channels | ARCHITECTURAL DIFFERENCE + UNSUPPORTED CAPABILITY + UNRESOLVED | Both delegate to firmware LAR; Linux adds cfg80211 regd + ACPI/DSM; 6 GHz (XPLAT-006); PRE_SCAN_PASSIVE2ACTIVE flag (DRV-11D-016); BIOS SAR presence (XPLAT-017) |
| 14 | Coexistence | UNSUPPORTED CAPABILITY (fork) + UNRESOLVED (impact) | CSME/MEI and BT coex absent (DRV-IWX-013, LINUX-017); non-vPro chassis impact expected nil, unverified |

**XPLAT distribution (18 findings):** ARCHITECTURAL DIFFERENCE x4 (001, 004, 008, 018) | FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE x5 (003, 005, 011, 012, 013) | FORK DEFECT STRONGLY SUSPECTED x2 (009, 015) | UNSUPPORTED CAPABILITY x5 (006, 007, 010, 016, 017) | FIRMWARE-VERSION DIFFERENCE x1 (002) | UNRESOLVED x1 (014). No finding is attributable to the Wi-Fi hardware itself (identical silicon both sides).

**Top XPLAT findings:** XPLAT-012 (aggregation lifecycle leak - strongest systemic degradation candidate), XPLAT-013 (TX path structure/global stall), XPLAT-005 (idle scan-forever loop), XPLAT-003 (PNVM 2 s dead wait), XPLAT-011 (ungated watchdog). All confirmed fork defects reproduce on API 68 and have driver-side fixes that do not require a firmware upgrade. Priority order from the report: XPLAT-012/-013, then XPLAT-005, XPLAT-003, XPLAT-011, then capability work (XPLAT-006/-007/-016) as scoped projects.

**Honest limits (report section "What Linux cannot explain"):** the WCL/airportd contracts have no Linux counterpart and are verifiable only on macOS; airportd's own reactions (Busy retry, wake power-on replay, no-age scan ranking) are unverifiable from source; firmware behavioral deltas 68 vs 89 are unpublished; the Linux reference is a mainline snapshot, not the target's actual Ubuntu; two machine-configuration questions (BIOS SAR tables, CSME ownership) are answerable only on the hardware.

---

## I. Confirmed defects

All 31 CONFIRMED DEFECT findings from `findings.json` plus the 5 XPLAT findings classified FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE. Grouped by subsystem; locations are file:line anchors as stated in the source reports. (LINUX-010/014 and REF-001/004/007/010/012 are confirmation-class findings - they *prove* fork defects via correspondence/inheritance rather than being new defect sites; noted inline.)

**IWX HAL (`itlwm/hal_iwx/`):**

| ID | Title | Location | One-line evidence |
|---|---|---|---|
| DRV-IWX-002 | Four advertised PCI IDs can never load firmware | Info.plist IOPCIMatch; cfg refs ItlIwx.cpp:12504-12516, 12295-12315, 12317-12357; `iwx_read_firmware` 1461-1466; `iwx_preinit` fail5 13780-13782 | 0x2720/0x2726/0x2729/0x7E40 map to QuQnj-48/SoSnj-63/ma-a0-63 blobs that are not embedded; `getFWDescByName` returns NULL -> attach fails after matching the device |
| DRV-IWX-004 | Qu C0/QuZ step-fixup compares raw hw_rev against a type-constant | ItlIwx.cpp:13611, 13621 | `sc_hw_rev == CSR_HW_REV_TYPE_QU_C0` never holds (needs `CSR_HW_REV_TYPE()` mask); fixup is dead code; Qu-family only |
| DRV-IWX-010 | Shared 1024-slot non-agg queue; gen3 agg capped at 256 slots (acknowledged freeze bug) | `iwx_tx` 6996-7014; `iwx_alloc_tx_ring` 2661-2672; `iwx_tvqm_alloc_txq` 3501-3506 (TODO comment); if_iwxreg.h:1823 | Pre-ADDBA, all data + mgmt share ring qid 2; author comment: >256 TFDs "would trigger system freeze on macOS ... temporary solution"; `ac` pinned BE (10850) |
| DRV-IWX-012 | Gen3 fw-load error path leaks three DMA allocations | `iwx_ctxt_info_gen3_init` 1157-1268 (1255-1258 vs fail labels 1262-1267) | `if (!iwx_nic_lock(sc)) return EBUSY;` bypasses the fail labels; prph_scratch/prph_info/iml DMA left allocated, pointers clobbered on retry |
| DRV-IWX-018 | One workloop gate; splnet() no-op; all KASSERTs compile away | timeout.c:32-39; gate re-dispatch sites (e.g. 6513-6519); ~25 KASSERT sites | `iwx_stop` 10966 executes `KASSERT(sc->task_refs.refs >= 1)` while `task_refs` is commented out of the softc - compiles only if KASSERT discards its argument |
| DRV-IWX-020 | ~21 MB static softc footprint (512 rings x 1024 slots) | if_iwxvar.h:630, 353, 723-724, 686; if_iwxreg.h:1756 | 512 x (1024 x ~40 B) + 2 x 64 KB resp buffers + iml = ~21.5 MB wired per instance; ~11 of 512 queue slots ever used on AX211 |
| DRV-IWX-021 | IWX_DEBUG hard-enabled; every fw command logged in all builds | ItlIwx.cpp:134-139; hot sites 6687 (per-command), 6913 (per-TX-fill); `#if 1` dumps at 11113/11977/12089 | Not build-gated: Release would ship the same per-command/per-frame logging in the workloop-time paths |
| DRV-IWX-022 | Off-by-one bounds checks in rate pretty-printers (OOB read) | `iwx_rs_pretty_ant` 518-531; `iwx_rs_pretty_bw` 533-547 | Guard is `>` not `>=`; ant==4 / bw==5 read one past the table end; called from `iwx_rs_update` on every TLC notification |
| DRV-IWX-023 | Dead code / OpenBSD-isms inventory (hygiene) | 1126-1136, 416-422, 9917-9929, 1406-1419, 7614-7616, 4699, 11063-11074, 12+ commented bus_dmamap_sync sites | `#if 0`/`#ifdef notyet` blocks, unreachable statements, dead ioctl re-entry guard; collectively mark every port divergence point |

**Airport/WCL integration (`AirportItlwm/`):**

| ID | Title | Location | One-line evidence |
|---|---|---|---|
| DRV-AP-006 | setPOWER OR-logic on IFF_UP\|IFF_RUNNING can skip re-enable | AirportItlwmV2.cpp:1129-1143 (also 1152; dead copy AirportSTAIOCTL.cpp:1006) | `isRunning = (flags & (IFF_UP\|IFF_RUNNING)) != 0` - one flag set passes; correct `== (both)` form exists at WCL.cpp:146; radio-on after fw stop silently no-ops |
| DRV-AP-016 | Scan-result conversion zeroes the rate array | AirportItlwmSkywalkInterface.cpp:979-1005 | Loop bound `result->asr_nrates` read from the just-zeroed struct; rates always empty while nrates nonzero; affects live getCURRENT_NETWORK/getSCAN_RESULT |
| DRV-AP-017 | Undeclared identifier `HalService` in live getSCAN_RESULT | AirportItlwmSkywalkInterface.cpp:1042; tree.h:725 | `RB_NEXT(..., &HalService->...)` has no such symbol; compiles only because RB_NEXT discards its 2nd macro argument; identical in upstream |
| DRV-AP-024 | ~4,100 lines of dead legacy integration files in-tree | pbxproj Sources phase 1632-1693; dead: AirportItlwm.cpp 1046, AirportSTAIOCTL.cpp 1532, AirportVirtualIOCTL.cpp 534, AirportAWDL.cpp 58, AirportItlwmInterface.cpp 50 | Not compiled but contain the fake-scan design (100-ms timer + SCAN_DONE regardless of firmware) and silent-join-drop patterns a future target could resurrect |

**itl80211 control plane:**

| ID | Title | Location | One-line evidence |
|---|---|---|---|
| DRV-11C-002 | Autonomous roaming fully disabled - F_DESBSSID latched for the association | WCL.cpp:513-515 (latch); input.c:441-450 (bgscan gate); node.c:1097-1099 (candidate reject); ieee80211.c:143 + node.c:1407-1408 (cache-bgscan can't roam) | Flag set at every join, cleared only on leave; blocks both the bgscan trigger and same-ESS failover; corrects prior audit DRV-AP-005's premise |
| DRV-11C-003 | No pending join -> scans forever; no idle park; 30 s dead-BSSID lockout | node.c:1456-1484 ("This will loop forever until an access point is found"), 1058-1061; WCL.cpp:527, 581-588 | After leave/failed join/idle, firmware scans at full rate indefinitely; after beacon-miss the loop runs with the pin still latched |
| DRV-11C-004 | 1 s watchdog on a dedicated workloop mutates MLME state off the gate | AirportItlwmV2.cpp:345-361, 116-122; ieee80211.c:906-929; timeout.c:32-39 | Watchdog decrements ic_mgt_timer and fires new_state(SCAN) concurrently with RX-thread transitions; every other net80211 timer correctly goes through CTimeout on the main workloop |

**itl80211 data plane / security:**

| ID | Title | Location | One-line evidence |
|---|---|---|---|
| DRV-11D-003 | WPA3-SAE cannot authenticate; WPA3->WPA2 hack compiled out of WCL target | ieee80211_input.c:2330-2344 (SAE = algorithm 3 dropped); AirportItlwmSkywalkInterface.cpp:128-141 (`#ifndef AIRPORT_WCL`) | "only 'open' auth mode is supported"; the authtype mapping block is not compiled for the Sequoia WCL build (pbxproj defines only AIRPORT_WCL etc.) |
| DRV-11D-006 | Non-CCMP ciphers run in software on the command gate; TKIP countermeasures no-op | ItlIwx.cpp:10060-10062, 7073-7086; output.c:623-625; crypto.c:84-87 | TKIP frames RC4+Michael'd on the single gate; MIC-failure countermeasures explicitly stubbed (`/* XXX TKIP countermeasures! */`) - mandated 60 s shutdown can never trigger |
| DRV-11D-009 | BA teardown leaks RX reorder buffers + mbufs | node.c:2029-2051 (`ieee80211_ba_del`); allocated at input.c:3155-3159 | ba_del resets state/cancels timers but never frees `ba->ba_buf` (~64 entries per TID) or parked mbufs; every roam/deauth executes it; current OpenBSD frees here |
| DRV-11D-011 | Non-aggregated TX frames carry no QoS headers; no per-AC scheduling | output.c:636-646, 684-686; ItlIwx.cpp:10850, 6996-7014 | "We use QoS data frames for aggregation only"; pre-BA frames use the shared non-QoS counter; FIFO ifq; EAPOL contends with bulk BE on one ring |
| DRV-11D-013 | TX BA sessions have no inactivity timeout (ba_timeout_val = 0) | proto.c:1119; ItlIwx.cpp:4622; input.c:847-848, 3319-3320 | Both setter sites force 0; inactivity timer only armed if != 0; a wedged session is never reaped |
| DRV-11D-018 | qfullmsk global TX stall - one full ring stops every queue incl. management | ItlIwx.cpp:10858-10863; `iwx_clear_oactive` 6045-6061 | `if (!sc->qfullmsk.empty()) { ifq_set_oactive; break; }` halts all TX (EAPOL/deauth/SA-Query included) until completions drain or the 15 s watchdog reinits |

**Corroboration-class confirmations (defects of the fork proven via reference material):**

| ID | Title | Location | One-line evidence |
|---|---|---|---|
| LINUX-010 | TVQM ADD->REMOVE->free lifecycle vs. fork's never-released queues | mvm/sta.c:351-442, 3341-3412; pcie/tx-gen2.c:1016-1131 | Linux sends IWL_SCD_QUEUE_REMOVE + frees the ring on every agg-stop/sta-removal and reuses queue IDs - proving DRV-IWX-011 is a driver defect, not a firmware limitation |
| LINUX-014 | PNVM 250 ms fail-fast vs. fork's dead-goto + 2 s dead-wait | fw/pnvm.c:372-417, 297-318, 477-478; fw/pnvm.h:12; mvm/fw.c:407-413 | Linux: 250 ms wait, cached-failure short-circuit, skip when sku_id empty; both treat a true timeout as fatal - the fork's 2 s x retry gate-held burn is the defect (corroborates DRV-IWX-008) |
| REF-001 | F_DESBSSID roam-killing latch universal - no fork fixes it | Audited WCL.cpp:515; FI :598/:699; ER :1225/:1347; AX :520/:616 | Latch/clear pair identical across all five trees; no fork demonstrates un-latching |
| REF-004 | Real WPA3-SAE exists only in Eric (reference availability) | ER WCL.hpp:579-675; net80211 ieee80211_sae.c + input.c:3473; BearSSL-derived P-256 | Full SAE stack (auth alg, AKM selector 8, crypto, H2E) exists as a study reference; BE200-qualified only; GCMP still absent even there |
| REF-007 | setPOWER OR-logic bug identical everywhere | V2.cpp:1152 (audited); AX :1228; ER :1366; FI :2683 | Same one-line bug in all trees; only the correct `==` form inside WCL.cpp:146 exists |
| REF-010 | EAPOL key-length validation missing (newly surfaced upstream defect) | ieee80211_pae_input.c paylen check (`paylen > totlen - sizeof(*key)` wraps); FI EAPOLKeyLength.hpp + host test | Unsigned wrap lets short frames pass any key-data length; FI fixed it with a host-tested helper |
| REF-012 | getSCAN_RESULT cursor staleness (reference fix available) | FI ItlScanCursor.hpp + tests/scan_cursor.cpp | Held-node-pointer-across-requests pattern (and the HalService typo's blast radius) is killed by an address-keyed cursor |

**XPLAT confirmed fork defects (cross-platform-analysis.md):**

| ID | Title | One-line evidence |
|---|---|---|
| XPLAT-003 | PNVM 2 s gate-held dead wait vs. 250 ms fail-fast | = DRV-IWX-008 corroborated by fw/pnvm.c; fix is small (respect failed-read path + shorten wait) |
| XPLAT-005 | Idle scan-forever loop vs. bounded scheduled scan | = DRV-11C-003; Linux proves sched-scan/match profiles exist in the same firmware command family (available in API 68) |
| XPLAT-011 | Ungated watchdog vs. complete serialization | = DRV-11C-004; Linux runs all state mutation through ordered workqueues/locking - nothing requires an ungated timer |
| XPLAT-012 | Aggregation resource lifecycle never returned | = DRV-IWX-011 + DRV-11D-009/010/013 vs. sta.c balanced lifecycle; strongest systemic explanation for degradation-after-roam/sleep |
| XPLAT-013 | TX structure: shared ring, no QoS pre-BA, any full ring stalls all | = DRV-IWX-010 + DRV-11D-011/018 vs. per-queue backpressure + dedicated mgmt queue; global stall is not a firmware constraint |

---

## J. Suspected defects and implementation risks

Explicitly separated from confirmed. STRONGLY SUSPECTED = source path is certain, manifestation frequency is runtime-dependent. UNVERIFIED RISK = structural hazard or fidelity gap whose user impact is unproven. None has runtime confirmation (ENV-001).

**J.1 STRONGLY SUSPECTED DEFECTS (17 from findings.json; + XPLAT-009/-015):**

| ID | Title | Location | One-line evidence |
|---|---|---|---|
| DRV-IWX-003 | dev_info matching loop never breaks - last match wins | ItlIwx.cpp:13560-13594 | No `break;` - later wildcard entries overwrite `sc_cfg`; AX211 accidentally correct; Qu-family firmware selection order-dependent |
| DRV-IWX-008 | PNVM: dead goto, doorbell kicked after failed read, 2 s gate-held wait | `iwx_load_pnvm` 2154-2184 | `goto out` is a no-op; on SKU mismatch the driver rings the doorbell and blocks the gate 2 s for a notification that cannot come; propagates to init retry loop 10779-10791 |
| DRV-IWX-009 | Sync command 1 s timeout leaks the ring slot | `iwx_send_cmd` 6510-6728 (6695-6706, 6721-6726; admission 6555-6557) | CMD_PENDING/queued only undone by late response or ring reset; wedged fw (no error IRQ) permanently consumes one of 128 slots -> ENOSPC for all commands |
| DRV-IWX-011 | TX aggregation teardown never releases fw/driver queues | `iwx_ampdu_tx_stop` 4714-4729 (entirety: 2 lines); `iwx_tvqm_alloc_txq` 3497-3526; `iwx_rm_sta` 7646-7679 | No remove command, no ring free; fwqid monotonic; after ~64 roam/sleep cycles allocation fails and `iwx_ba_task` refuses ADDBA (4615-4618) permanently |
| DRV-IWX-019 | iwx_start uses attemptAction (non-WCL) - starts silently dropped | `iwx_start` 10922-10932 | `attemptAction` returns immediately if the gate is held; parked frames can wait for the next completion to re-kick |
| DRV-AP-005 | Autonomous roam leaves WCL state stale (LQM -2, frozen BEACON_INFO, no LinkStatus-up) | WCL.cpp:709-711, 744-746, 145-151, 624-640 | All freshness keyed to join-time `joinBSSID`; nothing updates it on internal recovery; LinkStatus-up only posted inside first-beacon join completion |
| DRV-AP-011 | ScanDone can overtake final ScanResults | WCL.cpp:290-305, 646-653; AirportItlwmV2.cpp:124-136 | ScanResult posted from RX context vs. ScanDone via a 0-ms timer hop - the tail of the sweep (typically 5 GHz) can be lost |
| DRV-11C-005 | Assoc rejection never retried in place, never poisons the AP | input.c:2745-2755; ieee80211.c:921-928; node.c:1336-1345 | `ni == ic_bss` case records no fails, no retry; watchdog -> full rescan -> same AP re-selected; loops until the 30 s WCL timer |
| DRV-11C-007 | AP deauth triggers silent auto-reauth; airportd never told it recovered | input.c:2951-2962; proto.c:1618-1634; WCL.cpp:788-797, 776-786 | Re-auth runs below WCL; EVT_STA_ASSOC_DONE ignored when !joinPending; Deauth + Link-down posted with no matching Link-up |
| DRV-11C-011 | Scan-cache lifecycle split-brained (roam-bgscan wipes table; WCL cache keeps 5 min; STA aging timers never armed) | ieee80211.c:111-119, 145-150; node.c:741-755, 1422-1423 | No coherent result age exists for the upper layer; nodes can persist across menu refreshes |
| DRV-11D-008 | TX aggregation enable slow/fragile: 1 s delay, 30 s backoff, never on open networks | output.c:629-646, 490-507; node.c:2887-2895, 1762-1763; node.h:439; proto.c:1104-1144; ItlIwx.cpp:4604-4636 | `ni_addba_req_intval` starts 1 s, doubles to 30 s max on failure; open SSIDs never aggregate (deliberate anti-injection policy, kept) |
| DRV-11D-010 | Roam/deauth tears TX BA silently - no DELBA to AP, no notification | ItlIwx.cpp:7647-7678; proto.c:1161-1165; node.c:2044-2051 | `iwx_rm_sta` sends delba with reason 0 = no frame transmitted; AP-side BA state stale until timeout |
| DRV-11D-023 | iwx_run_stop RX-BA teardown leaves net80211 state dangling on roam | ItlIwx.cpp:9972-10044; node.c:1675 | Same-AP reassociation without iwx_rm_sta keeps stale BAIDs counted against `sc_rx_ba_sessions` |
| REF-002 | ScanDone race fixed by restructuring (reference) | ER WCL.cpp keepWCLScanResult/finishWCLScan; FI wclScanStats | Eric: completion defined by held results, 201s replayed before 237; FI measures the race (issues #20/#24/#34) - both merit study, neither copied blind |
| REF-006 | TVQM queue leak identical everywhere (inheritance) | ampdu_tx_stop bodies byte-identical UP :4715 / AX :4727 / FI :4993 / ER :5401 | No fork ever sends a queue remove; fix must be designed from the firmware spec (Linux mvm/mld), not from a reference |
| REF-011 | Join target can be evicted by node-cache make-room sweep | FI node.c +10 at :2254 | FI skips nodes matching the des_bssid pin in the sweep ("the join never reached AUTH", issue #69); upstream sweep is unconditional |
| REF-013 | RX BlockAck timer/gap-deadline math repair (reference) | AX RxTiming.hpp + host tests | Overflow-safe deadlines + re-arm rules, host-tested; AX's own honest negative: "timer repairs have not established a working speed fix" |

Plus XPLAT strongly-suspected: **XPLAT-009** (driver-internal recovery invisible to the OS - the event gap itself is confirmed; user-visible outcome unconfirmed) and **XPLAT-015** (ADDBA ramp = DRV-11D-008; code path source-certain, backoff-hit frequency runtime-dependent).

**J.2 UNVERIFIED IMPLEMENTATION RISKS (21 from findings.json):**

| ID | Title | Location | One-line evidence |
|---|---|---|---|
| DRV-IWX-007 | Firmware decompression `compressed_size * 4` heuristic; inflate return ignored | 1467-1469; FwData.h:46-70 | Future blob inflating >4x would fail silently; magic check contains the blast radius to a failed load |
| DRV-IWX-017 | Full reinit on any fatal event; aggressive error recovery | 11976-12001, 12086-12111; 10248-10254; 10779-10791; 10914, 11021-11057 | No in-place recovery; a single failed session-protection/quota command restarts the radio - visible link flaps |
| DRV-AP-007 | Wake path acks power-on without re-enabling adapter | V2.cpp:1381-1386 (vs off path 1373-1379); enable gate 542-550; setPOWER path 1196-1208 | Re-enable requires airportd/WCL `setPOWER(on)` replay; nothing in-kernel guarantees it |
| DRV-AP-009 | scanSkipCompletion guard is one-deep | WCL.cpp:260-262, 766-775; ItlIwx.cpp:11698-11710, 8974-8981 | A second spurious SCAN_DONE (iteration-complete) completes the WCL scan early with partial results |
| DRV-AP-010 | WCL scan messages carry no age; cache-bgscan retains nodes 5 min | WCL.cpp:307-345; WCL.hpp:118-136; ieee80211.c:145-150 | Pushed results are fresh but BeaconMetadata has no timestamp; vanished APs linger until eviction |
| DRV-AP-015 | macOS 12/13/14 conditionals litter live files; single hard OS gate | V2.cpp:268-271; PrivateSPI.pch:8-30 | Deterministic on this build; maintenance/next-OS hazard; prepared-but-unreachable Tahoe branches |
| DRV-AP-018 | WCL wire contract hand-reverse-engineered; static_asserts only guard | WCL.hpp:57-69, 444-472, 531-562, 201-243; WCL.cpp:694-698, 365 | Any Sequoia point release reshaping private structs trips an assert or silently changes semantics |
| DRV-AP-021 | Getters return errno-style codes; assoc status binary; LQM 3-tier RSSI | SkywalkInterface.cpp:308-324 etc.; WCL.cpp:143-159, 722-742 | Coarse quality tiers quantize macOS ranking; errno-as-IOReturn appears intentional (mimics Apple) |
| DRV-AP-025 | en0 publication relies on provider-identity spoof + deferred BSD attach | AirportItlwmEthernetInterface.cpp:96-103; V2.cpp:31-74 | `getProvider()` lies to avoid a Skywalk cast panic; load-bearing private-SPI workaround |
| DRV-AP-026 | PM ack deadline 5 s vs actual firmware stop cost | V2.cpp:1294, 1302, 1318-1352 | A >5 s firmware stop lets the PM root domain power-manage mid-teardown |
| DRV-11C-006 | Auth-timeout ni_fails poisoning removes APs from scan results | ieee80211.c:917-919; node.c:1336-1345 | After 1-3 auth timeouts the node is skipped then freed - network vanishes from the menu for >= 1 scan cycle |
| DRV-11C-010 | PTK/GTK install async + unacknowledged | ItlIwx.cpp:10053-10084; pae_input.c:552-596 | First encrypted downstream traffic can race the fw key install ("first ping after connect lost") |
| DRV-11C-012 | RSSI last-frame-wins on 2.4 GHz, max-hold on 5 GHz; no smoothing | input.c:2158-2171; node.c:1378-1391 | Menu ordering of 2.4 GHz networks can shuffle frame-to-frame; native drivers average |
| DRV-11C-016 | Timer teardown ordering hazards; watchdog the outlier | timeout.c:41-75; CTimeout.cpp:79-95; node.c:795-800 | ic_bss freed before free_allnodes; watchdog can tick against a stopped firmware during sleep |
| DRV-11C-018 | iwx_newstate silently drops duplicate transitions | ItlIwx.cpp:10273-10275 | Single pending-slot overwrite can desync ic_state from hardware ("associated but firmware never authed" wedge) |
| DRV-11C-025 | free_allnodes "keep current BSS" compares BSSID + strncmp of SSIDs | node.c:2144-2149 | strncmp stops at first NUL - prefix-equal SSIDs compare equal; edge-case cache churn |
| DRV-11D-016 | Global PRE_SCAN_PASSIVE2ACTIVE scan-config flag | ItlIwx.cpp:7963-7966 | Invites firmware to convert passive->active after first scan; regulatory exposure if it applies to DFS in some domains |
| CI-007 | CFBundleGetInfoString absent - git SHA not in plist metadata | Info.plist; embedded `_f588ecd` string | kextstat/Finder cannot distinguish reduced vs baseline builds |
| REF-003 | One-shot scanSkipCompletion replaced by state flags (reference) | ER EVT_SCAN_DONE: `scanDeferred \|\| ic->ic_wcl_scan_restart` | State predicate in net80211 (contract extension) beats WCL-side boolean consumables |
| REPO-001 | Mixed version-tag semantics across one history | 00-repo-state.md sec 8.1 | HEAD described as v2.4.0-ax211-reduced while v2.5.0-alpha / dell-ac9462 tags exist in the same history |
| REPO-004 | Release configuration defined but never built/verified | 00-repo-state.md sec 8.3 | Debug-only CI, dispatch-only, no release job; pbxproj carries unused Release config |

---

## K. Validated correct components

The 40 VALIDATED CORRECT findings - source-verified correctness that functions as the regression baseline for all future work. Grouped by subsystem.

**IWX HAL (7):** DRV-IWX-001 (PCI device table: 19 IDs, AX211 correctly present as So-family; verified trace 0x51F0+GF -> `iwlax211_2ax_cfg_so_gf_a0` -> so-a0-gf-a0-68); DRV-IWX-006 (firmware selection chain + 15 embedded blobs; AX211 needs 2); DRV-IWX-013 (hardware init sequence correct and complete for So/AX211 gen3 - attach, preinit, NVM, context-info/IML, alive, PNVM, post-alive, PHY ctxts, LAR); DRV-IWX-014 (command allocation/queueing mechanics - ring 0, wide-header, narrow-group remap); DRV-IWX-015 (RX path - ring, replenishment, full dispatch table); DRV-IWX-024 (iwx_intr legacy-MSI/ICT heritage code); DRV-IWX-025 (station removal flows consistent; run_stop iterates rxba; generation counters guard races).

**Airport/WCL integration (7):** DRV-AP-001 (WCL-message-native integration; legacy ioctl path intentionally severed); DRV-AP-002 (probe/start lifecycle and interface publication sound; hard OS version gate 15.2+); DRV-AP-019 (join robustness: deferred join across MAC reconfig, abort/leave semantics, 30 s timeout with 802.11 reason, secrets zeroed via explicit_bzero); DRV-AP-020 (key/supplicant model: 4-way in-driver; WCL delivers PMK/MSK for enterprise only); DRV-AP-023 (Fast Lane accepted-and-ignored deliberately - error would make WCL tear the link down); DRV-AP-027 (cache-bgscan semantics for scan-while-associated; off-channel timing tuned for stability); DRV-AP-028 (capability advertisement hand-tuned per OS release - TKIP re-advertised, HE bit for Tahoe, scan-completion bit).

**Control plane (9):** DRV-11C-001 (scan execution lives in firmware; the net80211 scan state machine is dead code - frames the scan findings); DRV-11C-013 (hidden-SSID handling works via directed probes; minor NUL-first-byte edge case); DRV-11C-015 (regulatory passive-by-NVM; DFS/passive never actively probed on the WCL path - regulatorily conservative); DRV-11C-017 (every MLME transition forces LINK_STATE_DOWN - by design, with user-visible side effects); DRV-11C-019 (directed-scan abort semantics handled WCL-side with the one-shot guard; prior fix 812ea1c present); DRV-11C-020 (GTK/IGTK group rekey complete and correct incl. anti-reinstall - hourly AP rotations will not drop the link); DRV-11C-022 (beacon processing in RUN freezes RSN/HE params - correct against beacon loss); DRV-11C-023 (auth retry 3x5 s then rescan - latency budget documented); DRV-11C-024 (EVT_BEACON per frame - correct but chatty).

**Data plane / security (9):** DRV-11D-005 (**CCMP core correct - per-TID replay counters, 11w AAD rules, KRACK guards**, SW + HW-offload paths); DRV-11D-007 (firmware TLC sole rate controller; host MiRA dead code); DRV-11D-012 (EAPOL consumed by the in-driver supplicant under WCL - as designed); DRV-11D-014 (**RX A-MSDU/A-MPDU deaggregation, reordering, duplicate/replay detection validated; fragattack mitigations present**, fragments deliberately dropped); DRV-11D-020 (TX sequence-number architecture matches upstream semantics); DRV-11D-021 (watchdog/auth retry policy sane); DRV-11D-022 (key install/rekey flow correct incl. group-rekey replay protection); DRV-11D-024 (mcast min-basic-rate + echo suppression OK); DRV-11D-025 (memory model sound outside the known leak classes).

**Cross-reference / CI / forks (8):** LINUX-019 (rate control parity - both stacks delegate to firmware TLC); CI-001 (latest reduced build verified end-to-end: run 26, all steps green, sha256 chain matches sidecars + README + release byte-for-byte); CI-002 (binary identity: x86_64, bundle id, 9 OSBundleLibraries incl. Sequoia-required Skywalk/corecapture); CI-003 (all 15 blobs embedded, 16.7 MB raw -> 7.62 MB binary, -53.13% vs baseline; zero iwm/iwn firmware remains; AX211 path covered); CI-008 (size figures accurate; "under 7 MB" holds for the zip only); CI-010 (artifact retention live); REF-014 (Fast Lane divergence in AX noted as hypothesis, not fix); REF-015 (**the reduction introduced none of the found defects - everything behavioral is upstream-inherited**; provenance chain baseline->reduced intact).

**Why this list matters:** any fix must not regress these. In particular the WPA2/CCMP security core, the join-robustness machinery, the country-code end-to-end flow, and the CI verification chain are the load-bearing validated parts of the driver.

---

## L. Unsupported or incomplete functionality

The 41 UNSUPPORTED OR INCOMPLETE CAPABILITY findings. First the user-facing feature matrix (report 11), then the reference-comparison capability gaps.

**Native macOS Wi-Fi feature matrix (Sequoia build; report 11):**

| Native feature | Status | Evidence |
|---|---|---|
| SSID scan (menu open, background) | Supported (WCL message 201 push, directed + channel-restricted) | DRV-AP-027; ItlIwx.cpp:7697-7702 |
| Scan abort | Supported (SCAN_ABORT -> Aborted completion) | WCL.cpp:213-216 |
| Join/associate (open/WEP/WPA-PSK/WPA2-PSK/SAE-transition) | Supported (in-driver supplicant) | WCL.cpp:414-538 |
| WPA3-SAE (SAE-only networks) | **Missing** (join rejected kIOReturnUnsupported) | DRV-11D-003, DRV-AP-004 |
| WPA3 <-> WPA2 transition mode | Supported via RSN-IE rewrite to PSK (scan-copy only) | WCL.hpp:343-425 (upstream 7204c69 fix) |
| PMF/MFP (protected management) | **Missing** (capability bit not advertised; PMF-required nets unreachable) | DRV-11D-004 |
| 802.1X enterprise (EAP) | Supported (PMK/MSK via installWCLKey; EAPOL over en0) | WCL.cpp:363-390 |
| 4-way handshake / GTK rekey | Supported in-driver (validated) | DRV-11C-020 |
| 11r FT (fast transition) | **Missing** (FT auth bits -> Invalid -> join rejected) | WCL.hpp:518-521 |
| 11k/11v (RRM/BTM) | **Missing** (all related handlers stubbed) | DRV-AP-012 |
| Roaming (macOS-assisted) | **Missing** (setROAM/roam profiles/blacklist Unsupported) | DRV-AP-012 |
| Driver-internal roam (bgscan) | Blocked by the F_DESBSSID latch; stale to WCL if it occurs | DRV-11C-002, DRV-AP-005 |
| 6 GHz / Wi-Fi 6E band | **Missing** (channels dropped everywhere) | DRV-AP-003, DRV-11D-001, DRV-11C-014 |
| HE / Wi-Fi 6 (2.4/5 GHz) | **Opt-in** (`itlwm_he=1` boot-arg) | DRV-AP-028 |
| VHT/HT rates & NSS reporting | Supported | SkywalkInterface.cpp:485-566 |
| AWDL (AirDrop/Handoff/Watch unlock) | **Missing** (no virtual interfaces on Sequoia) | DRV-AP-013 |
| P2P / Instant Hotspot / softAP / Hotspot 2.0 | **Missing** (handlers stubbed) | DRV-AP-013 and stubs |
| Wake-on-WiFi (WoW) | **Missing** (params Unsupported; magic-packet filter falsely advertised) | DRV-AP-014 |
| Low-latency mode / Fast Lane | Stubbed / accepted-and-ignored | DRV-AP-023 |
| TKIP group cipher (WPA2 mixed) | Supported (re-advertised deliberately) | DRV-AP-028 |
| WEP | Supported (software crypto; no shared-key auth; WCL setCIPHER_KEY rejects WEP keys - nwkey path exists) | report 13 security matrix |
| Country/regulatory reporting | Partial (fw MCC + geo + boot-arg; locale hardcoded FCC; DFS flags stripped) | DRV-AP-022 |
| LQM / link quality to macOS | Partial (3-tier RSSI, 8-beacon cadence, RSSI-only Sequoia struct) | DRV-AP-021 |
| Traffic counters to WCL | Supported | WCL.cpp:986-995 |
| CC logging / diagnostics (CoreCapture) | Supported (3 pipes + fault reporter) | V2.cpp:169-264 |
| Private/random MAC | Supported (planMacUpdate, WCL replay-safe) | V2.cpp:844-883 |
| Captive-network assistant | Works at IP layer; no driver hooks needed | n/a by design |
| MLO / multi-link (future) | Headers prepared but unimplemented | WCL.hpp:138-147 |

**Additional capability gaps by finding ID (rest of the 41):**

- HAL: DRV-IWX-005 (MSI-X implemented but `if (0)` - single-vector MSI only); DRV-IWX-016 (power management: always-on station PS, no WoW/U-APSD/SAR, sleep = full firmware reload; beacon filter `#ifdef notyet`).
- Control plane: DRV-11C-008 (upward notification inventory minimal - no disassoc/roam/beacon-miss/port-authorized events); DRV-11C-009 (no STA-side handshake timeout - wrong-PSK bounded only by the 30 s WCL timer); DRV-11C-014 (6 GHz excluded at NVM channel table; net80211 has no 6 GHz band support at all); DRV-11C-021 (assoc status reporting binary and lossy).
- Data plane: DRV-11D-002 (no GCMP - WPA3 cipher suites unrepresentable); DRV-11D-015 (no station power-save at the 802.11 layer - fully delegated to firmware PS); DRV-11D-017 (roam always full AUTH + 4-way - no 11r/FT fast path); DRV-11D-019 (raw 802.11 TX injection disabled - no monitor TX/tooling).
- Linux-reference capability deltas (report 20): LINUX-001 (runtime strap-derived config vs static tables), LINUX-002 (firmware currency API 89 vs 68), LINUX-003 (versioned scan family + adaptive dwell), LINUX-004 (6 GHz discovery subsystem), LINUX-005 (scheduled scan + match profiles vs busy rescan loop), LINUX-006 (host-driven roaming 11r/11k/v), LINUX-007 (WoWLAN offload), LINUX-008 (U-APSD/snooze/LPRX/skip-DTIM toolbox), LINUX-009 (BIOS SAR/PPAG/GEO/TAS/DSM stack - compliance exposure), LINUX-012 (error containment), LINUX-013 (GCMP/IGTK/MFP + rekey offload + host SAE), LINUX-015 (central notif-wait infrastructure), LINUX-016 (MSI-X per-CPU RX), LINUX-017 (LED/RFKILL/CSME-MEI platform surface), LINUX-018 (beacon filter with CQM), LINUX-020 (mac80211 BA teardown/restart contract).
- CI/repo: CI-006 (19 PCI IDs spanning 3 generations with legacy HALs removed - accepted risk documented in eb815e4); REPO-002 (firmware breadth vs "AX211-reduced" claim - reduction is driver-level, not firmware/device-level); REPO-003 (IOPCIMatch over-breadth).
- Fork references (capability availability elsewhere): REF-005 (6 GHz implemented end-to-end in Eric - BE200-qualified only), REF-008 (FI's LQM transport for the "link quality off" class), REF-009 (Eric's scan/join deferral model).

---

## M. Root-cause analysis

For each owner symptom class from the directive: ranked causal hypotheses with evidence fit, competing explanations, and what runtime evidence would settle it. **All hypotheses are source-based; runtime confirmation is pending (kit). Classification discipline is maintained throughout: strongly suspected is not confirmed.** Symptom classes themselves are owner observations, not diagnoses (MAC-002).

**M.1 Wi-Fi menu scan list unreliability / truncation**

| Rank | Hypothesis | Finding / class | Evidence fit |
|---|---|---|---|
| 1 | ScanDone (0-ms timer hop) overtakes the final ScanResult messages - tail of the sweep lost | DRV-AP-011 (STRONGLY SUSPECTED) | Matches "list missing my 5 GHz AP until rescan" (5 GHz is the tail of the request); last beacons race the timer |
| 2 | Stale/duplicated entries: no age field + 5-min node retention + split-brained cache lifecycle | DRV-11C-011 (STRONGLY SUSPECTED), DRV-AP-010 (RISK) | Matches "AP I turned off still shows" and list churn between refreshes |
| 3 | Infinite idle rescan loop keeps EVT_SCAN_DONE/BEACON messages (and the menu) churning at idle | DRV-11C-003 (CONFIRMED) | Matches "list keeps changing/refreshing when idle"; also power/heat |
| 4 | Auth-failure node poisoning makes networks vanish for >= 1 cycle after failed joins | DRV-11C-006 (RISK) | Matches "network disappears after failed attempt, comes back later" |

Competing explanation: airportd-side ranking of age-less results (DRV-AP-018's unverifiable contract side). Settling evidence: kit guided check - macOS vs Ubuntu network count from the same spot; debug-log timestamps of postMessage 201 vs 237 per scan generation; 5-min idle log capture.

**M.2 Network switching stalls (moving between APs)**

| Rank | Hypothesis | Finding / class | Evidence fit |
|---|---|---|---|
| 1 | Roaming disabled: F_DESBSSID latched for the association - no bgscan trigger, no same-ESS failover | DRV-11C-002 (CONFIRMED) | Directly matches "no seamless transition; stays on deteriorating AP until full drop"; universal in all forks (REF-001) |
| 2 | After beacon loss: full rescan still pinned to the dead BSSID until the 30 s WCL timer / macOS rejoin | DRV-11C-003 (CONFIRMED) | Matches the multi-second dead zone when walking away |
| 3 | Assoc-rejection loop: reject -> 5 s stall -> rescan -> same AP re-selected -> loop to 30 s | DRV-11C-005 (STRONGLY SUSPECTED) | Matches "joining spins ~30 s then fails" against band-steering/client-limit APs |
| 4 | Stale WCL state after any internal transition | DRV-AP-005 (STRONGLY SUSPECTED) | Menu/status wrongness after switches |

Competing: RF environment (AP density/DFS) - the Ubuntu bundle provides the known-good baseline (walk-between-APs works there per LINUX-006 reference). Settling evidence: kit guided check - walk between two same-SSID APs; macOS log shows no roam/BSS-switch events while signal degrades (expected per DRV-11C-002); Ubuntu 05/07 as baseline.

**M.3 Status staleness after connect/roam**

| Rank | Hypothesis | Finding / class | Evidence fit |
|---|---|---|---|
| 1 | All WCL freshness keyed to join-time BSSID; after any internal recovery LQM = -2, BEACON_INFO frozen, LinkStatus-up never posted | DRV-AP-005 (STRONGLY SUSPECTED) | Matches "shows wrong network / no bars after a switch" |
| 2 | Silent auto-reauth after deauth: airportd saw Deauth + Link-down, never Link-up | DRV-11C-007 (STRONGLY SUSPECTED) | Matches "connection lost" then apparently-fine link; DHCP-lease churn |
| 3 | Missing upward events by design: no roam/disassoc/beacon-miss/port-authorized | DRV-11C-008 (CONFIRMED as contract gap) | The precondition for 1 and 2 |
| 4 | Coarse LQM tiers (3-step RSSI, 8-beacon cadence) quantize the UI | DRV-AP-021 (RISK) | Bars sitting at thresholds; subtle degradation invisible |

Competing: airportd's own reaction to LinkStatus-down with no up (unverifiable from source). Settling evidence: instrumented timestamps of WCL messages 216/39 vs. actual BSSID change across a forced deauth and a roam (kit; open questions 1-2 of reports 11/12).

**M.4 Sleep/wake power issues**

| Rank | Hypothesis | Finding / class | Evidence fit |
|---|---|---|---|
| 1 | setPOWER OR-logic: radio-on toggle no-ops when interface UP but firmware stopped | DRV-AP-006 (CONFIRMED) | Directly matches "Wi-Fi dead after wake until toggled" (post-error state is exactly UP-without-RUNNING) |
| 2 | Wake acks power-on without re-enabling; recovery depends on airportd's setPOWER replay | DRV-AP-007 (RISK) | Matches "dead until toggled" if any wake path skips the replay |
| 3 | Sleep = full firmware reload (PNVM doorbell wait included) - seconds of wake latency, and the 2 s PNVM burn per cycle if SKU-mismatched | DRV-IWX-016 (UNSUPPORTED), DRV-IWX-008 (STRONGLY SUSPECTED) | Matches slow/odd wake behavior; needs boot-log PNVM line |
| 4 | Aggregation leak accumulates per sleep/wake cycle -> throughput steps down after each wake | DRV-IWX-011 (STRONGLY SUSPECTED) | Matches "degrades after sleep until reboot" reports |

Competing: OpenCore/kext-injection quirks (out of source scope; MAC-001 identity check first). Settling evidence: kit guided checks - one sleep/wake cycle with a 2 h log window (DRV-AP-006/007); speed tests across 3 wake cycles with notes (DRV-IWX-011); watch for firmware reload loops, command timeouts, ASPM messages.

**M.5 Throughput ceiling ~60-70 Mbps (compounding candidates)**

| Rank | Hypothesis | Finding / class | Evidence fit |
|---|---|---|---|
| 1 | Aggregation eventually refused: TVQM queue leak -> "Failed allocating TXQ" -> ADDBA refused -> legacy non-aggregated rates permanently until reboot | DRV-IWX-011 + DRV-11D-010 (STRONGLY SUSPECTED; corroborated LINUX-010/REF-006) | Matches "sustained ~60-70 Mbps ceiling" numerically (legacy/non-aggregated levels) and the degrade-over-time pattern |
| 2 | Slow ADDBA ramp: every association pays >= 1 s non-aggregated legacy TX; failed ADDBA pins a TID up to 30 s; open networks never aggregate | DRV-11D-008 (STRONGLY SUSPECTED) | Matches slow ramp after each join/roam; minutes-scale worst case with M.2 |
| 3 | Shared-ring head-of-line blocking + 256-TFD cap: pre-BA traffic and mgmt on one ring; gen3 agg deliberately halved vs Linux (1024) due to the unresolved freeze | DRV-IWX-010 (CONFIRMED, known/worked-around), XPLAT-014 (UNRESOLVED) | Structural ceiling contributor; cap halves aggregation depth vs Linux on same silicon |
| 4 | qfullmsk global stall: one full/stuck ring stops ALL TX incl. EAPOL until completions or the 15 s watchdog | DRV-11D-018 (CONFIRMED) | Matches multi-second dead-air stalls under load |
| 5 | Software TKIP crypto on the single gate (TKIP networks only) | DRV-11D-006 (CONFIRMED, perf part) | Only if the owner's network is WPA/TKIP - unknown |

**Competing explanation (explicitly flagged): the owner's internet plan may itself be the ceiling.** The 60-70 Mbps figure was measured "on my internet plan" (owner's words per the directive); the plan speed is unknown and no LAN throughput test (e.g., iperf to a local host) or known-good comparison exists. The candidates above are driver-imposed ceilings that would matter only above the plan limit. Settling evidence: LAN speed test (iperf) on macOS vs the same test on Ubuntu (kit throughput notes + Ubuntu bundle as baseline); throughput samples every ~500 ms across a forced roam; sleep/wake speed-test series (DRV-IWX-011 guided check); note HE is opt-in (`itlwm_he=1`) - default builds connect as 802.11ac (DRV-AP-028), which is still far above 60-70 Mbps and thus not by itself the ceiling.

**M.6 WPA3 network join failures**

- Primary: DRV-11D-003 (CONFIRMED) - SAE (auth algorithm 3) frames are counted and dropped ("only 'open' auth mode is supported"); the legacy WPA3->WPA2 authtype mapping is compiled out of the WCL target (`#ifndef AIRPORT_WCL`); `classifyLegacyAuth` rejects SAE/FT bits -> join rejected `kIOReturnUnsupported`.
- Transition-mode networks work (RSN-IE rewrite, DRV-AP-004 validated) - so failures are specific to SAE-only SSIDs.
- Settling evidence: kit guided check - join a WPA3-SAE network, note the menu's report, collect the log (auth-error lines expected). Confirmatory only; the gap is source-conclusive.

**M.7 6 GHz networks invisible**

- Primary: DRV-11D-001 (CONFIRMED) - 6-7 GHz channel list behind `#ifdef notyet` (ItlIwx.cpp:409-423); net80211 cannot represent the band (no freq<->chan mapping, no flag); the WCL scan decoder drops 6 GHz entries; never advertised (DRV-AP-003, DRV-11C-014).
- Settling evidence: kit guided check - Ubuntu `04-wifi-caps.txt` lists 6 GHz channels (5955-7115 MHz) while the macOS scan never shows the 6 GHz AP. Confirmatory only; source-conclusive.

**M.8 PMF-required networks unjoinable**

- Primary: the security matrix absence - no `IEEE80211_C_MFP` capability -> MFPC/MFPR never set in assoc RSN IEs; IGTK/BIP path unreachable; WCL `setCIPHER_KEY` has no IGTK case (DRV-11D-004). PMF-required APs refuse association.
- Related: GCMP unrepresentable (DRV-11D-002) blocks WPA3-Enterprise/192-bit; on PMF-optional networks the client remains exposed to unicast deauth/disassoc spoofing (standard 802.11w threat).
- Settling evidence: PMF-optional enterprise AP test (does association complete; does WCL ever attempt an IGTK delivery - open question 4 of report 13).

**Cross-cutting note:** M.1-M.4 share mechanisms (the latch, the leak chain, the event gap, the reload model), so a single runtime session with the kit can discriminate several classes at once; M.5 requires the throughput experiments specifically because the plan-limit confounder cannot be removed from source.

---

## N. Engineering recommendations

Top recommendations ordered by priority. **All corrections are conceptual - the audit directive prohibits implementing any of them now.** Priorities derive from the cross-platform report's remediation order (XPLAT bottom line) and the defect severities; P0 = fix first (high user impact, contained blast radius), P1 = high impact but larger risk or design decisions needed, P2 = hygiene/efficiency, P3 = scoped capability projects.

| # | Priority | Finding IDs | Subsystem | Exact files / functions | Proposed correction (conceptual) | Regression risk | Verification procedure |
|---|---|---|---|---|---|---|---|
| 1 | P0 | DRV-IWX-011, DRV-11D-010, XPLAT-012, LINUX-010, REF-006 | IWX HAL / aggregation | `itlwm/hal_iwx/ItlIwx.cpp`: `iwx_ampdu_tx_stop` (4714-4729), `iwx_rm_sta` (7646-7679), `iwx_tvqm_alloc_txq` (3497-3526) | Send the firmware queue-removal command on BA teardown (per the Linux `iwl_mvm_disable_txq` pattern: IWL_SCD_QUEUE_REMOVE semantics) and free the driver ring so fwqid can be reused; add an explicit remove on sta removal | Medium - wrong remove semantics on API 68 could wedge aggregation; must be derived from the fw spec, not copied from a fork (none releases queues) | Sleep/wake + roam cycles with speedtest after each (kit DRV-IWX-011 guided check); watch for "Failed allocating TXQ" / ADDBA refusals; long-uptime memory |
| 2 | P0 | DRV-11D-009, XPLAT-012 | net80211 data plane | `ieee80211_node.c`: `ieee80211_ba_del` (2029-2051) (buffers allocated at `ieee80211_input.c:3155-3159`) | Free `ba->ba_buf` and any mbufs parked in the window on BA deletion (current OpenBSD does) | Low - pure leak fix; teardown paths already validated (DRV-IWX-025) | Memory-growth measurement across >= 20 forced roams; mbuf pressure counters |
| 3 | P0 | DRV-AP-006, REF-007 | Airport/WCL power | `AirportItlwm/AirportItlwmV2.cpp`: setPOWER path (1129-1143; also 1152) | Change the running test to require BOTH flags: `(if_flags & (IFF_UP \| IFF_RUNNING)) == (IFF_UP \| IFF_RUNNING)` (the form already used at WCL.cpp:146) | Low - one-line logic fix; airplane-mode behavior unchanged in healthy state | Toggle airplane mode right after a firmware failure (EVT_DRIVER_STOPPED conditions); radio must recover (kit open question 4 of report 11) |
| 4 | P0 | DRV-IWX-008, XPLAT-003, LINUX-014 | IWX HAL bring-up | `ItlIwx.cpp`: `iwx_load_pnvm` (2154-2184) | Respect the failed-read path (do not kick the doorbell after a failed PNVM read), shorten the completion wait toward Linux's 250 ms, cache the failure so it is never re-burned, skip entirely when sku_id is empty | Low - Linux correspondence proves all three behaviors are safe within the same hardware contract | Boot/wake log: "PNVM complete notification" vs timeout; wake-latency measurement (kit; open questions 3 of report 20 / 2 of report 10) |
| 5 | P0 | DRV-11C-003, XPLAT-005, LINUX-005 | net80211 control plane | `ieee80211_node.c`: `ieee80211_end_scan` not-found path (1456-1484); WCL join-clear sites (WCL.cpp:574/599/105) | Bound the idle rescan loop: idle park with a low-rate periodic scan, or emulate scheduled-scan semantics on API 68 (the command family exists); keep prompt scanning while a join is pending | Medium - must not slow join acquisition; menu freshness depends on scan cadence | 5-min idle log capture (kit DRV-11C-003 guided check): repeating scan-start/done cycles must stop; join latency after idle must not regress |
| 6 | P0 | DRV-11C-004, XPLAT-011 | Airport/WCL + net80211 timers | `AirportItlwmV2.cpp` watchdog workloop (345-361, 116-122); `ieee80211.c`: `ieee80211_watchdog` (906-929) | Marshal watchdog state mutation through the main command gate (or convert the watchdog to a CTimeout on the main workloop like every other net80211 timer) | Medium - timer-latency change on the auth/assoc path; keep the 1 s cadence | Long-uptime + wake-race logs correlating watchdog SCAN transitions vs. iwx_newstate_task completions (open question 1 of report 12) |
| 7 | P0 | DRV-AP-011, DRV-AP-009, REF-002, REF-003 | WCL scan lifecycle | `AirportItlwm/WCL/WCL.cpp`: `finishWCLScan`/`completeWCLScan`/`fakeScanDone` (290-305), scanSkipCompletion (260-262, 766-775) | Redefine scan completion by consumable state (held results) rather than thread timing - study Eric's completion-by-held-results design (REF-002) and its state-flag replacement for the one-shot guard (REF-003); do not blind-copy | Medium - changes WCL-visible timing semantics; verify against airportd on 15.8 first (Eric open question 1 of report 22) | macOS vs Ubuntu network-count comparison from the same spot (kit DRV-AP-011 guided check); instrumented 201-vs-237 timestamps |
| 8 | P0 | CI-005 | Release process (not code) | Release/packaging step | Provide and document an ad-hoc signing step for Sequoia installation (codesign -fs - + kmutil install --update-all + recovery approval) or ship an OpenCore-injection note; surface it in the release notes | None (documentation/process) | Fresh Sequoia install from the published release; kmutil load succeeds |
| 9 | P1 | DRV-IWX-009, XPLAT-018, LINUX-015 | IWX HAL commands | `ItlIwx.cpp`: `iwx_send_cmd` (6510-6728), `iwx_cmd_done` (6799-6829) | Central pending-response list with an abort sweep on error (the `iwl_abort_notification_waits` pattern) so timed-out commands release their ring slots; do not change the 1 s timeout itself first | Medium - command-path core; late-response handling must stay correct (NULL check at 11659-11663) | Long-uptime log correlation of EWOULDBLOCK -> ENOSPC -> reinit storms; fw-error conditions are not injectable here, so field logs (kit) only |
| 10 | P1 | DRV-11D-010, DRV-11D-013 | aggregation protocol | `ItlIwx.cpp`: `iwx_rm_sta` (7647-7678); `ieee80211_proto.c` delba path (1161-1165); `ba_timeout_val` (proto.c:1119, ItlIwx.cpp:4622) | Send a real DELBA (nonzero reason) on roam/deauth teardown so AP-side BA state does not go stale; consider a nonzero BA inactivity timeout so wedged sessions are reaped | Low-Medium - AP interop corner cases | Roam loop with AP-side state observation; log capture across >= 20 roams |
| 11 | P1 | DRV-11D-008, XPLAT-015 | net80211 aggregation setup | `ieee80211_node.c`: `ni_addba_req_intval` init (1762-1763); `node.h:439` max; trigger path output.c:629-646 | Shorten the 1 s initial ADDBA delay (Linux has no artificial delay); revisit the 30 s backoff ceiling; keep the open-network prohibition (deliberate anti-injection policy) | Medium - aggregation stability was tuned for a reason (upstream "wpa3-transition-and-amsdu" lineage); change incrementally | Post-roam throughput timeline (samples every ~500 ms across a forced roam) + ADDBA timer logs |
| 12 | P1 | DRV-11D-018, DRV-IWX-010, XPLAT-013 | TX path | `ItlIwx.cpp`: `_iwx_start_task` (10858-10863), `iwx_clear_oactive` (6045-6061), `iwx_tx` queue select (6996-7014) | Per-queue backpressure instead of the global qfullmsk stop; at minimum exempt the management/EAPOL path from the global stall (Linux: dedicated mgmt queue + per-queue stop/wake) | High - core TX path; the 256-TFD freeze workaround (DRV-IWX-010) is adjacent and unexplained (XPLAT-014) | Bulk-TCP-during-reassociation reproduction (open question 6 of report 13); queue-depth/oactive instrumentation during an induced stall |
| 13 | P1 | DRV-11C-007, DRV-11C-008, DRV-AP-005, XPLAT-009 | WCL event contract | `WCL.cpp`: `handleWCLLink` (624-640), ASSOC_DONE handler (776-786), deauth handler (788-797); event set in `ieee80211_var.h:687-695` | Post LinkStatus-up (and/or AssocComplete) outside the first-beacon join path so driver-internal recoveries are visible; update joinBSSID freshness on BSSID change; consider adding disassoc/port-authorized events (contract extension) | Medium - WCL message semantics are load-bearing mimicry (DRV-AP-018/023); verify airportd tolerates the new timing | Forced-deauth log capture with 216/39 timestamps vs. BSSID change (kit; open questions 1-2 of reports 11/12) |
| 14 | P1 | DRV-11C-005 | net80211 assoc retry | `ieee80211_input.c`: assoc-resp failure path (2745-2755); `ieee80211.c` watchdog assoc branch (921-928) | In-place assoc retry (2-3 attempts) before rescanning; record ni_fails on the bss node so a rejecting AP is deprioritized | Low | Join an AP that rejects association (e.g. client-limit); confirm the 30 s failure path no longer shows scan->auth->reject cycles (open question 4 of report 12) |
| 15 | P1 | DRV-AP-007, DRV-AP-026 | Airport/WCL power | `AirportItlwmV2.cpp`: `setPowerStateOn` (1381-1386), `enable` gate (542-550), PM ack (1294/1302) | Make the wake path explicitly re-enable the adapter (or post DriverAvailable to force the WCL power-on replay) instead of relying on airportd; review the 5 s PM ack deadline vs. real firmware stop cost | Medium - double-enable paths must be idempotent | Sleep/wake cycles with 2 h log window (kit DRV-AP-006/007 guided check); pmset correlation |
| 16 | P1 | DRV-11C-002, DRV-AP-012, XPLAT-008, REF-001 | roaming policy (design decision) | `WCL.cpp`: latch site (513-515) and clear sites (611); roam stubs in `AirportItlwmSkywalkInterface.hpp` | Design doc first: un-latch F_DESBSSID for same-ESS failover after beacon loss (keep it during an active join attempt); no reference fork demonstrates the un-latch, so this is original design work - do not treat any fork as a roaming reference | High - the latch is upstream-inherited everywhere; un-latching re-activates the bgscan roam engine whose WCL-side staleness (DRV-AP-005) must be fixed first or simultaneously | Walk-between-APs test with BSSID tracking on both OSes (kit DRV-11C-002 guided check); Ubuntu 05/07 as the known-good baseline |
| 17 | P2 | DRV-IWX-016, LINUX-018, XPLAT-016 | IWX HAL power | `ItlIwx.cpp`: beacon filter block behind `#ifdef notyet` (9917-9929); `iwx_power_build_cmd` (7363-7391) | Enable the beacon filter (command exists in API 68) with the documented caveat that default settings block ERP/HT-protection updates - needs a mitigations design (e.g. filter only in stable RUN) | Medium - the notyet is deliberate ("prevent net80211 from getting ERP and HT protection updates") | Idle power/heat measurement before/after; protection-update behavior in mixed 11b/g environments |
| 18 | P2 | DRV-AP-024, DRV-IWX-023, DRV-IWX-005 | tree hygiene | Dead legacy files (AirportSTAIOCTL.cpp, AirportVirtualIOCTL.cpp, AirportItlwm.cpp, AirportAWDL.cpp, AirportItlwmInterface.cpp); dead MSIX code (3113-3212 etc.); `#if 0`/notyet inventory | Delete or quarantine to legacy/ with a README (matching the reduction philosophy of eb815e4); confirm no packaging references first (open question 9 of report 11) | Low - not compiled today; verify via CI build + verify step | CI build green; artifact diff shows only expected changes |
| 19 | P2 | REPO-002, REPO-003, DRV-IWX-002, DRV-IWX-006, CI-006 | Tier-2 reduction (AFTER runtime PCI-ID confirmation) | `itlwm/firmware/` (remove 13 of 15 blobs = 15,124,856 of 16,700,476 raw bytes, 90.6%); `IOPCIMatch` (18 of 19 IDs); ItlIwx.cpp device tables (~600 lines of Qu/QuZ/QnJ/SnJ/MA cfgs + dev_info entries, 12434-13338), gen2 branches, dead MSIX | Strict AX211 build: keep `iwlwifi-so-a0-gf-a0-68.ucode` + `.pnvm` (+ gf4 pair if AX411 subdevices are in scope); remove broken-advertised IDs (0x2720/0x2726/0x2729/0x7E40) regardless; decide the 5-ID "AX211-family" scope first (10-hal Tier-2 inventory) | Medium - over-trimming bricks non-target-but-supported devices; CI firmware-string checks must be updated in step | Kit probe 03 (lspci) confirms the exact device+subsystem ID FIRST (HW-002); then CI build + verify + on-target load test |
| 20 | P2 | DRV-AP-021, REF-008 | WCL status | `WCL.cpp`: `setLQM` (143-159); ifnet-level link-quality reporting | Study FI's `reportLinkQuality` transport (ifnet LQM consumed by configd/apsd - the "link quality off -> push/iMessage dead" fix); verify the symbol exists on 15.8.2 before adopting (FI ran __MAC_15_2; open question 3 of report 22) | Medium - new private-SPI dependency | Push/iMessage-over-Wi-Fi behavior; LQM propagation logs |
| 21 | P3 | DRV-11D-003, DRV-11D-004, DRV-AP-004, XPLAT-007, REF-004 | WPA3/PMF capability | net80211 SAE (nonexistent), `classifyLegacyAuth` (WCL.hpp:506-529), cipher set (ieee80211_crypto.c:133-149) | Scoped project: SAE auth + PMF advertisement + IGTK path. Reference approach exists in Eric (full SAE stack incl. P-256 crypto, REF-004) - study, re-derive for AX211/API-68/15.8.2, do not blind-copy; GCMP remains absent even there (WPA3-Enterprise still blocked) | High - new crypto + supplicant state machine in-kernel | WPA3-only AP join matrix; PMF-required and PMF-optional enterprise tests |
| 22 | P3 | DRV-11D-001, DRV-AP-003, DRV-11C-014, XPLAT-006, REF-005 | 6 GHz capability | `ItlIwx.cpp`: `iwx_nvm_channels_uhb` notyet block (409-423); net80211 band plumbing; WCL channel publication | Scoped project: band-aware channel indexing first (Eric's lesson: solve the numbering in the data model, not per-callsite filters), then scan band fields; Eric qualified only on BE200/MLD firmware - API-68 qualification is open | High - large surface (net80211 + WCL + scan API); Eric's RNR/PSC discovery may need newer scan APIs | Side-by-side scan lists macOS vs Ubuntu near an active 6 GHz AP (kit DRV-11D-001 guided check) |
| 23 | P3 | XPLAT-002, LINUX-002 | firmware currency | HAL TLV/command layouts throughout `ItlIwx.cpp` | Defer: a firmware API 68->89 re-port is a separate, high-risk work package (every API bump reshapes command/notification layouts; scan v12->v17 alone re-shapes four parameter blocks). Fix lifecycle defects first - they reproduce on 68 | Very high - a half-port wedges bring-up | Only after P0/P1 items land and are field-validated; then incremental per-subsystem porting with CI verification at each step |

**Guardrails (binding constraints on all of the above):**

1. **Never regress the physically-validated baseline.** The owner has hardware-validated basic Wi-Fi on both the baseline (`ax211-baseline-validated` -> aa19316) and the reduced build. The baseline tag is the immutable regression reference; per-fix CI builds must be compared against it (see section O).
2. **Fix lifecycle defects before any firmware API 68->89 re-port.** The re-port is high-risk and deferred (row 23); every confirmed fork defect reproduces on API 68 and has a driver-side fix that does not require new firmware.
3. **Tier-2 reduction is an opportunity, not a directive:** 13/15 firmware blobs (90.6% of 16.7 MB), 18/19 PCI IDs, ~600 lines of device tables plus gen2/MSIX branches - but only after runtime PCI-ID confirmation via kit probe 03 (HW-002), and the 5-ID "AX211-family" scope must be decided first.
4. **WPA3/6 GHz reference approaches exist (Eric fork) - study, do not blind-copy.** None of the reference forks is a correctness oracle (FI is AI-assisted beta, ER's Wi-Fi 7 path is experimental per-device, AX is research); every approach must be re-derived against AX211/API-68/Sequoia 15.8.2 and re-qualified on hardware.
5. **CI-005:** add the ad-hoc signing step (or OpenCore note) to the Sequoia installation handoff - it is a process fix, not a code fix, and unblocks all on-target verification.
6. **The directive prohibits implementing any correction now.** This table is the remediation plan for a future, separately-approved engineering phase.

---

## O. Future validation strategy

Two phases, both designed around the evidence gap that defines this audit (ENV-001: no runtime access from the sandbox; all collection is owner-run).

**Phase 1 - owner runs the diagnostic kit on Ubuntu + macOS (`tools/`).**

- `tools/ubuntu-diagnostics.sh` and `tools/macos-diagnostics.sh`: read-only, no root, ~1 min (macOS probe 08's log query can take minutes), host-side sanitization before anything leaves the machine (SSIDs -> AP1/AP2..., MACs -> BSSID1/..., IPv4 -> 10.240.0.x, serials -> REDACTED-SERIAL, hostnames -> HOSTn; mapping destroyed after the run; `REDACTION-LOG.txt` records counts only). Output: `AX211-UBUNTU-EVIDENCE-<UTC>.tar.gz` / `AX211-MACOS-EVIDENCE-<UTC>.tar.gz` with numbered probes.
- The evidence-to-finding mapping is already in `tools/README.md`; the audit's open questions convert into seven guided checks:

| Finding | Guided check | What confirms it |
|---|---|---|
| DRV-11C-002 (roam disabled) | Walk between two same-SSID APs while associated | Log shows no roam/transition events while signal degrades; link sticks to the far AP or drops; Ubuntu probes 05/07 are the known-good baseline |
| DRV-IWX-011 (aggregation leak) | Speed test after fresh boot, then after each of 3 sleep/wake cycles | Throughput steps down per cycle; log shows BA/aggregation teardowns or failures around the wake |
| DRV-AP-011 (scan truncation) | Same-spot network count: macOS vs Ubuntu | macOS consistently lists noticeably fewer networks |
| DRV-11D-003 (WPA3 join) | Join a WPA3-SAE network | Join fails or falls back; driver auth-error lines |
| DRV-11D-001 (6 GHz missing) | Ubuntu caps show 6 GHz channels; macOS scan near an active 6 GHz AP | Ubuntu lists 5955-7115 MHz; macOS never shows the 6 GHz AP |
| DRV-AP-006/007 (power handling) | One sleep/wake cycle, then collect (2 h log window) | Wake-window firmware reload loops, command timeouts, ASPM messages |
| DRV-11C-003 (idle scan loop) | Wi-Fi enabled but not connected for 5 min, then collect | Repeating scan-start/done cycles with no user trigger |

- Additionally: probes `04-kexts.txt` + `05-kext-strings.txt` + a manual `shasum` of the loaded binary vs `30a3ce59...` close MAC-001 (loaded-kext identity); Ubuntu probe `03-pci.txt` closes HW-002 (exact PCI device+subsystem ID) and unblocks the Tier-2 reduction decision; Ubuntu probe `06-driver-fw.txt` confirms the working OS's firmware API (LINUX-002 open question 1).

**Phase 2 - targeted runtime experiments (after kit identity/PCI checks pass):**

1. **Sleep/wake degradation series (DRV-IWX-011):** speed test after fresh boot, then repeat after each of >= 3 sleep/wake cycles, recording each number; collect the macOS bundle after the last wake. A monotonic step-down with aggregation-teardown log lines confirms the leak chain; flat numbers point at the plan-limit confounder.
2. **WPA3 network attempt (DRV-11D-003):** join a known WPA3-SAE SSID; note the menu's report; collect immediately. Expected: unsupported/failure (source-conclusive; confirmatory).
3. **6 GHz AP scan (DRV-11D-001):** stand near an active 6 GHz AP; scan on macOS; compare with Ubuntu caps in the same room. Expected: invisible on macOS (source-conclusive; demonstrative).
4. **Network-count comparison (DRV-AP-011, DRV-11C-011):** same position, count visible networks on macOS vs Ubuntu, 3 repetitions at different times; a consistent large gap supports the truncation/staleness cluster.
5. **Roam-between-APs log capture (DRV-11C-002, DRV-AP-005):** walk between two same-SSID APs with the log window covering the walk; look for BSSID change with no roam event, LQM -2, LinkStatus-down without up. Ubuntu walk in the same environment is the baseline.

**Regression strategy:**

- The baseline tag (`ax211-baseline-validated` -> aa19316) is the immutable reference - both its behavior (physically validated) and its artifact (CI run 44135504957) are fixed points.
- Every candidate fix gets its own CI build (the dispatch-only "Build AX211 Sequoia Debug" workflow already gates: x86_64-only, plist lint, bundle id, OSBundleLibraries, >4 MB binary, 5 firmware strings, 5 AX211 PCI IDs, sha256 record) - extend the verify step per fix where applicable (e.g. firmware-string set changes with Tier-2).
- Re-run the relevant kit guided check after each candidate fix (the seven checks double as before/after experiments), plus the always-on smoke set: boot-to-join, 5-min idle, one sleep/wake, one speed test.
- Keep the validated-correct list (section K) as the do-not-regress checklist; in particular the WPA2/CCMP core (DRV-11D-005/014), GTK rekey (DRV-11C-020), join robustness (DRV-AP-019), and the country-code flow (DRV-AP-022).

---

## P. Evidence index

Full detail (per-item locators, sha256s, collection dates, sanitization status) in `evidence-manifest.json` (EV-001...). Summary:

**Internal audit reports (this directory):**

| File | Content |
|---|---|
| DOSSIER.md | This master dossier (sections A-P) |
| README.md | Index, reading order, counts |
| 00-repo-state.md | AUDIT-1: git state/tags, tree inventory, firmware inventory, PCI IDs, Xcode targets, reference-clone states, anomalies |
| 10-iwx-hal-audit.md | AUDIT-2a: IWX HAL deep audit (DRV-IWX-001..025), Tier-2 reduction inventory, open questions |
| 11-airport-integration-audit.md | AUDIT-2b: Airport/WCL/Skywalk integration (DRV-AP-001..028), feature support matrix, open questions |
| 12-itl80211-controlplane-audit.md | AUDIT-2c-1: control plane (DRV-11C-001..025), notification-contract-gap table, open questions |
| 13-itl80211-dataplane-audit.md | AUDIT-2c-2: data plane/security (DRV-11D-001..025), security capability matrix, throughput-cap candidates |
| 20-linux-iwlwifi-analysis.md | AUDIT-2d: Linux iwlwifi reference (LINUX-001..020), correspondence table, firmware version analysis |
| 21-ci-artifact-verification.md | AUDIT-2e: CI runs/artifacts/kext verification (CI-001..010) |
| 22-reference-forks-analysis.md | AUDIT-3: reference-fork comparison (REF-001..015), lessons, open questions |
| 23-environment-access.md | AUDIT-6a: execution environment, ENV-BLOCK-001/ENV-001, evidence handling |
| hardware-inventory.md | Owner-declared / source-verifiable / unknown split; PCI ID candidates; HW-001/002 |
| ubuntu-analysis.md | Ubuntu runtime gap documentation + probe-to-finding table |
| macos-analysis.md | macOS runtime gap documentation + symptom-class table; MAC-001/002 |
| cross-platform-analysis.md | AUDIT-6c: XPLAT-001..018, operating-model correspondence, 14-operation table, honest limits |
| findings.json | All 152 findings, machine-readable (id, area, title, classification, severity, confidence, evidence, analysis, runtime_confirmation) |
| evidence-manifest.json | EV-xxx evidence items with locators and hashes |
| tools/README.md | Diagnostic kit usage, safety statement, redaction policy, evidence-to-finding mapping |
| tools/ubuntu-diagnostics.sh, tools/macos-diagnostics.sh | Sanitized read-only collectors (probes 01-11 / 01-10) |
| tools/OPTIONAL-privileged.md, tools/OPTIONAL-privileged-list.md | Optional root-only read commands |

**Key external references (clones pinned in refs/, git-ignored):**

| Reference | Commit / state | Used for |
|---|---|---|
| laobamac/itlwm (upstream) | `7204c69` (tag v2.4.0-alpha, dated 2026-11-01; full clone) | Upstream baseline; inherited-vs-introduced determination (REF-015) |
| torvalds/linux (sparse: iwlwifi + mac80211 + cfg80211) | `20eef29b` (snapshot 2026-11-17) | Linux known-good reference (LINUX-001..020) |
| linux-firmware (WHENCE metadata) | `747bdda` (snapshot 2026-11-18) | Firmware version history; API 68 pruned, latest so-a0-gf-a0 = 89 (v86.a67023b2.0) |
| retropineaple/ForbiddenItlwm | `6e15195` (2026-11-18, v0.6.0-beta.2, depth-1) | Reference fork (AWDL focus; instrumentation patterns) |
| Ersiter/Eric-AirportItlwm | `e258fb8` (2026-11-16, depth-1) | Reference fork (WPA3-SAE/6 GHz implementations) |
| ElicoftZ/AirportItlwm-AX211 | `030ef90` (2026-10-14, depth-1) | Reference fork (AX211 hardening; testable-header pattern) |
| MacKernelSDK | `3f75008` (CI build dependency) | CI build reproducibility |

**CI runs and artifacts (GitHub Actions, verified live during the audit):**

| Item | Value |
|---|---|
| Baseline successful run | 44135504957 (head aa19316, dispatch, success, 2026-11-17) - baseline binary 16,262,720 B |
| Reduced successful run | 44145096042 (head f588ecd, dispatch, success, 2026-11-17, job 1m37s, 11 steps green; artifacts 14355752931 + 14356212093, expire 2027-02-15) |
| Failed reduction attempts | 44143226065 (eb815e4, build), 44143916768 (e982fe9, build), 44144616381 (a454f64, verify: binary-size floor) |
| No CI run exists for the tagged commit e4857ff | docs-only commit, dispatch-only workflow never dispatched (CI-004) |
| Release asset zip sha256 | `da628dc5a26a733e6591cc69d85e9547de4a88ff291d066e48bb42b681e0f4fa` (matches sidecar + release) |
| Kext binary sha256 | `30a3ce590b8c137faa0e7f593733bacb15dd1c1c2e5f98773b4f6b350a6b674a` (7,622,312 B, x86_64, embedded build string `_f588ecd`) |
| Releases | v2.5.0-alpha (812ea1c), v2.4.0-baseline-ax211 (asset built from aa19316), v2.4.0-ax211-reduced (asset byte-identical to run 26; prerelease, "awaiting hardware validation" - CI-009) |

**Tags in the audited repo:** `ax211-baseline-validated` -> aa19316 (baseline = clean upstream 7204c69); `v2.4.0-ax211-reduced` -> e4857ff (HEAD, audited); `v2.4.0-baseline-ax211` -> 26a0c8c; `v2.5.0-alpha` -> 812ea1c; `dell-ac9462-v2.5.0-alpha-final` (REPO-001: mixed version lines in one history).

**Absent evidence (by design of this audit's constraints):** no Ubuntu runtime data, no macOS runtime data, no OS-switch coordination, no on-target load test of the shipped artifact (CI-009), no loaded-kext identity proof (MAC-001), no exact PCI device+subsystem ID of the unit (HW-002), no BIOS SAR-table dump, no per-symptom runtime logs. All are obtainable via the Phase 1 kit (section O).

---

*End of dossier. Primary sources: the companion reports listed in section P. This dossier synthesizes; it does not introduce new evidence. Every claim above is anchored to a finding ID or report section; where runtime confirmation is missing, that absence is stated.*
