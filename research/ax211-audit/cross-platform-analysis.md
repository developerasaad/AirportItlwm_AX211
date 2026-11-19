# AUDIT-6c: Cross-Platform Comparative Analysis (XPLAT Findings) -- Linux iwlwifi vs. AirportItlwm IWX Fork

**Task ID:** AUDIT-6c (directive Phase 7)
**Date:** 2026-11-18
**Subject:** Formal technical correspondence between the Linux iwlwifi stack (known-good reference for the Intel AX211, PCI 8086:51F0, so-a0-gf-a0) and the AirportItlwm IWX fork (`v2.4.0-ax211-reduced`), operation by operation, with each meaningful difference classified per the directive taxonomy.
**Evidence discipline:** Source-level correspondence only. No runtime evidence from either OS exists in this audit (ENV-001, `23-environment-access.md`). Every classification below is a source-derived judgement; runtime-dependent aspects are flagged inside each finding.

---

## Method

**Inputs (findings sections are the evidence base):**

| Input | Content used |
|---|---|
| `20-linux-iwlwifi-analysis.md` (AUDIT-2d) | Linux reference implementation analysis + correspondence table; findings LINUX-001..LINUX-020 with exact Linux file:function anchors |
| `10-iwx-hal-audit.md` (AUDIT-2a) | IWX HAL forensic audit; findings DRV-IWX-001..025 with ItlIwx.cpp line anchors |
| `11-airport-integration-audit.md` (AUDIT-2b) | Airport/WCL/Skywalk native integration audit; findings DRV-AP-001..028 |
| `12-itl80211-controlplane-audit.md` (AUDIT-2c-1) | net80211 control-plane audit; findings DRV-11C-001..025 + notification-contract-gap table |
| `13-itl80211-dataplane-audit.md` (AUDIT-2c-2) | net80211 data-plane/security audit; findings DRV-11D-001..025 + security capability matrix |
| `23-environment-access.md` (AUDIT-6a) | Why no runtime comparison is possible (ENV-001: the documented remote-access method is blocked by sandbox policy; no live Ubuntu or macOS evidence exists) |

**Reference versions:**

- Linux kernel: torvalds/linux sparse clone @ `20eef29b7c84` (snapshot 2026-11-17; `drivers/net/wireless/intel/iwlwifi/`, `net/mac80211/`, `net/wireless/`). Note: this snapshot has restructured the iwlwifi config model (MAC cfgs in `cfg/ax210.c` + RF cfgs in `cfg/rf-gf.c`; firmware filename composed at runtime); where older literature cites static `so_a0_gf_a0` cfg symbols, this audit cites the current equivalent.
- linux-firmware: WHENCE metadata @ `747bdda274d0` (snapshot 2026-11-18). Latest so-a0-gf-a0 artifact: `iwlwifi-so-a0-gf-a0-89.ucode`, version 86.a67023b2.0 (WHENCE:1080-1081). API 68 is pruned (no longer shipped).
- Fork: `AirportITLWM` @ `e4857ff` = tag `v2.4.0-ax211-reduced`, tree clean.

**Firmware version pinning (the one axis that is a pure version difference):**

- Linux driver pins **exactly API 89** for so-a0-gf-a0 (`ucode_api_min == ucode_api_max == 89`, `cfg/ax210.c:13-16,74-75` intersected in `iwl-drv.c:298-323`); with min==max there is exactly one candidate file and no fallback. Driver and firmware ship as a matched pair; the driver refuses the fork's 68 blob ("no suitable firmware found") and vice versa.
- Fork embeds **API 68** (`iwlwifi-so-a0-gf-a0-68.ucode`, 1,533,812 B, release `core66_LinADVP...core66_LinADLPV::01d30b0c`) plus its `.pnvm`; its HAL TLV/command layouts match 68 only. The fork is 21 API versions behind the newest shipped firmware.

**No runtime comparison is possible.** ENV-001 (remote machine access blocked; reproduced deterministically 3 times) means directive Phases 1-5 were never executed: no Ubuntu runtime, no macOS runtime, no OS-switch coordination. Phase 7 is therefore executed as a **source-level correspondence**: Linux behavior is read from the `20eef29b7c84` source, fork behavior from the prior audit reports (which are themselves source-only), and each difference is classified on that basis. Statements below about *user-visible impact* are hypotheses pending runtime evidence via the sanitized diagnostic kit (`tools/`).

**Classification vocabulary (directive taxonomy -> labels used in this report):**

| Directive class | Label used below |
|---|---|
| Intentional architectural distinction | ARCHITECTURAL DIFFERENCE |
| Difference caused by firmware or kernel versions | FIRMWARE-VERSION DIFFERENCE |
| Hardware or configuration difference | (none landed purely here -- see note) |
| Unsupported capability | UNSUPPORTED CAPABILITY (fork) |
| Incorrect implementation | FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE |
| Potential defect requiring further verification | FORK DEFECT STRONGLY SUSPECTED |
| Unresolved difference with insufficient evidence | UNRESOLVED -- INSUFFICIENT EVIDENCE |

Note on the two classes that did not land: both operating systems drive the *same* AX211 silicon (8086:51F0, so+GF), so no difference is attributable to the Wi-Fi hardware itself. The two genuinely configuration-dependent questions -- whether this chassis's BIOS ships SAR/PPAG tables (XPLAT-017) and whether its ME asserts CSME ownership (Operation 14) -- are carried as UNRESOLVED components because only runtime inspection of the machine can answer them.

---

## Operating model correspondence

Who owns what, side by side:

| Responsibility | Linux (AX211) | macOS fork (AX211) |
|---|---|---|
| Scan policy and scheduling | wpa_supplicant/NetworkManager (userspace) + cfg80211 scheduled-scan offload; driver only builds fw requests | In-driver net80211 state machine + WCL scan requests from airportd; no userspace scan policy layer |
| MLME (auth/assoc/reassoc state machine) | mac80211 (kernel framework, shared by all drivers) | In-driver OpenBSD net80211 port (`ieee80211_proto.c`, STA-only) |
| Supplicant (EAPOL/SAE/PMK derivation) | wpa_supplicant in userspace (SAE, FT, PMKSA, PMF policy) | In-driver OpenBSD supplicant (`ieee80211_pae_*`); PSK and 802.1X-PMK only; macOS supplicant not used (DRV-AP-020) |
| Roaming decisions | wpa_supplicant (RSSI/CQM triggers, 11k/v BTM, 11r FT); driver assists with directed scans and session protection | None -- BSSID latched at join (DRV-11C-002); driver-internal full re-authentication only (DRV-11C-007) |
| Driver / op-mode | iwlmvm (`mvm/`): scan request build, key->fw install, PS commands, time events, recovery policy | IWX HAL (`ItlIwx.cpp`, 13.9k lines): all of the above plus supplicant key installs and firmware embedding |
| Rate control | Firmware TLC programmed by driver (`mvm/rs-fw.c`); minstrel unused for this device | Firmware TLC (parity); host MiRA/AMRR dead code (DRV-11D-007) |
| Bus / interrupt / threading | `pcie/` transport: MSI-X per-CPU RX vectors, ordered workqueues, per-subsystem locking | IOKit: single MSI vector, everything serialized on one IOWorkLoop gate + one rogue watchdog workloop (DRV-IWX-018, DRV-11C-004) |
| Firmware | External file from linux-firmware, API 89 pinned (min==max) | Embedded zlib blob, API 68, matched to ported OpenBSD TLV layouts |
| Events to the OS | nl80211: rich event surface (scan results, sched-scan matches, roam, CQM RSSI/beacon-loss, connect/disconnect with reasons, regulatory, rfkill, station stats) | 8 net80211 events funneled into 11 WCL PostOffice messages; no roam, no disassoc, no beacon-miss, no port-authorized event (DRV-11C-008) |
| Regulatory | cfg80211 self-managed regd + fw LAR (MCC) + ACPI/UEFI SAR/PPAG/GEO/DSM (incl. 6E enable gate) | fw LAR (MCC) + NVM channel tables only; no host regd layer (DRV-11C-015); locale hardcoded FCC (DRV-AP-022) |
| Sleep / wake | D3 WoW image + offloads (net-detect, GTK rekey, patterns, ARP/NS); wake restores state in-place | Full stop + complete firmware reload on wake (PNVM wait included); recovery depends on macOS re-issuing enable() (DRV-IWX-016, DRV-AP-007) |
| Userspace contract | Stable public nl80211/cfg80211 API | Hand-reverse-engineered WCL wire structs with static_assert guards (DRV-AP-018) |

**What this architectural difference implies for every behavior below:**

1. **Capability placement.** Anything Linux gets from *above* the driver (SAE, FT, BTM/11k/v, CQM roaming, scheduled-scan policy, WoW orchestration, PMF policy) must either be re-implemented inside the kext on macOS or it does not exist. This single fact generates most of the UNSUPPORTED CAPABILITY findings (XPLAT-006, -007, -010, -016).
2. **No userspace backstop.** On Linux, a driver-level transient is absorbed by wpa_supplicant/mac80211 state machines that stay alive. On the fork, the same transient hits a monolith that owns everything, and its in-driver recovery is invisible upward (XPLAT-009) -- there is no layer above to notice and correct.
3. **Concurrency geometry.** Linux distributes work across per-CPU MSI-X vectors and ordered workqueues with subsystem locking. The fork serializes everything (RX, TX, commands, timers, WCL) on one workloop gate -- so any blocking wait (the 2 s PNVM sleep of XPLAT-003, the 1 s per-command `commandSleep` of XPLAT-018) is a whole-stack stall, and the single ungated watchdog becomes a structural hazard (XPLAT-011).
4. **Event asymmetry.** Linux pushes complete state upward continuously; the fork pushes only what its WCL mimicry implements. Every driver-internal recovery (reauth, rekey, rescan, roam) is therefore a state divergence between the chip and the OS (XPLAT-009).

---

## Operation-by-operation correspondence

### 1. PCI enumeration and config (CNVi integrated IDs, so+gf composition)

- **Linux:** PCI ID table `pcie/drv.c:iwl_hw_card_ids` (lines 491-498): `0x51F0` -> `iwl_so_long_latency_mac_cfg` (AX211; also 0x51F1/0x54F0/0x7AF0/0x7F70/0x7A70/0x2725 variants). The MAC config (`cfg/ax210.c:100-110`) carries the CNVi `integrated = true` marker plus `xtal_latency = 12000` and LTR delay; RF config comes from `CSR_HW_RF_ID` (`cfg/rf-gf.c:31-46`, `iwl_rf_gf`, `uhb_supported`). The firmware name **"so-a0-gf-a0" is composed at runtime** from the MAC type/step and RF-ID straps (`iwl-drv.c:187-292`, `iwl_drv_get_fwname_pre`). Driver-side selection *cannot* mismatch firmware vs. silicon (LINUX-001).
- **Fork:** static `iwx_devices[]` (19 IDs, `ItlIwx.cpp:12377-12406`) + a ~230-entry `iwl_dev_info_table` (12765-13338) matched in a loop that never breaks (last-match-wins, DRV-IWX-003); firmware name is a static per-config string (`13638`). Four advertised PCI IDs can never load firmware (blobs not embedded, DRV-IWX-002); the Qu C0/QuZ step fixup is dead code (DRV-IWX-004). For the audit target (0x51F0 + GF) the chain is *accidentally* correct and lands on `iwlax211_2ax_cfg_so_gf_a0` -> `iwlwifi-so-a0-gf-a0-68.ucode` (DRV-IWX-001, validated).
- **Conclusion:** **ARCHITECTURAL DIFFERENCE** (runtime strap-derived config vs. inherited static tables). The residual fork table defects (DRV-IWX-002/003/004) are real but do not affect the AX211 target; they are Tier-2 reduction targets, not AX211 behavior differences. Same hardware both sides -- no hardware/configuration difference.

### 2. Firmware selection and load (API pinning, PNVM, alive handshake)

- **Linux:** exactly one candidate file per family (`iwl-drv.c:298-323`, `:325-387`); gen3 context-info/IML load in `pcie/`; alive handshake via the central notification-wait machinery (`fw/notif-wait.c`). PNVM: source selection with per-family rules (`fw/pnvm.c:297-318` -- external file `iwlwifi-so-a0-gf-a0.pnvm` for AX211+GF), SKU-match TLV walk, **250 ms** completion wait (`fw/pnvm.h:12`), cached-failure short-circuit so a failed parse is never retried (`:372-393`), skip entirely when sku_id is empty; a true timeout is a hard init failure (`mvm/fw.c:407-413`).
- **Fork:** zlib-embedded blobs (`FwData.h:33-44`), TLV parse `iwx_read_firmware` (`ItlIwx.cpp:1461-1865`), gen3 IML load `iwx_ctxt_info_gen3_init` (1157-1268, validated, with an error-path DMA leak DRV-IWX-012), alive wait 1 s on `sc_uc.uc_intr` (`4909`), alive v4/v5 parsing with sku_id extraction (11550-11597) -- all **validated correct** (DRV-IWX-013). The PNVM flow is the defect: dead `goto`, doorbell kicked even after a failed read, **2000 ms** workloop-gate wait for a notification that cannot arrive on SKU mismatch, hard-fail loop (DRV-IWX-008).
- **Conclusion:** **FIRMWARE-VERSION DIFFERENCE** (API 68 vs. 89, XPLAT-002) + **FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE** for the PNVM flow (XPLAT-003). The alive/IML handshake itself is at parity.

### 3. Scan

- **Linux:** versioned scan request family (v17/v16/v15/v14/v12 selected by fw capability, `mvm/scan.c:2736-2743`); five scan types including FRAGMENTED and FAST_BALANCE chosen per-scan from TCM traffic load (`:220-267`); adaptive dwell with per-band budgets (`:1292-1444`); scheduled scan with multi-plan support and **firmware match profiles** (`iwl_mvm_config_sched_scan_profiles`, `:521-604`; MATCH_FOUND notification -> host, `:353-358`); 6 GHz discovery via RNR/colocated short-SSID/BSSID filters with PSC-only fallback (`:1682-1960`, `:2001-2088`); a scan-timeout watchdog that force-NMIs a wedged firmware (`:2698-2707`); CSME scan filtering (`:2745-2790`).
- **Fork:** one `SCAN_REQ_UMAC` per net80211 state step (`iwx_umac_scan`, `ItlIwx.cpp:8061`; v1/v8/v12/v14 request sizes `:7979-8000`); fixed dwell fields set once (`:7928-7931`); channel list from `ic_channels` filtered by the WCL bitmap (`:7689-7729`, `:7697-7702`) with `probeChannel` deciding active/passive (`:7720-7726`); scanning lives entirely in firmware and `ic_state = S_SCAN` is assigned directly by the HAL (DRV-11C-001); no scheduled scan, no match profiles, no adaptation, no scan watchdog; with no pending join the driver **scans forever** (DRV-11C-003); 6 GHz compiled out at the NVM channel table (`#ifdef notyet`, DRV-11C-014/DRV-11D-001).
- **Conclusion:** **ARCHITECTURAL DIFFERENCE** for the request architecture (XPLAT-004) + **FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE** for the unbounded idle loop (XPLAT-005) + **UNSUPPORTED CAPABILITY** for 6 GHz discovery (XPLAT-006).

### 4. Authentication / association

- **Linux:** mac80211 owns the MLME; wpa_supplicant performs SAE (WPA3-Personal) via the external-auth API (`net/mac80211/mlme.c:5431`), FT/802.11r auth (`:5521`, `:9989-9990`), and PMF policy; the driver only reserves firmware session protection during (re)association (`iwl_mvm_protect_assoc`, `mvm/mac80211.c:2601-2624`; `mvm/time-event.c:1415+`).
- **Fork:** in-driver OpenBSD MLME (`ieee80211_proto.c:1428-1737` newstate) made asynchronous by `iwx_newstate_task` (`ItlIwx.cpp:10149-10297`); in-driver supplicant. Auth frames are **open-system only** -- SAE (algorithm 3) frames are counted and dropped (`ieee80211_input.c:2330-2344`, DRV-11D-003); the legacy WPA3->WPA2 authtype mapping is compiled out of the WCL target (`AirportItlwmSkywalkInterface.cpp:128-141`, `#ifndef AIRPORT_WCL`); the WCL path instead rewrites the RSN IE of transition-mode networks to WPA2-PSK (`selectWPA2TransitionMode`, `WCL.hpp:343-425`) -- transition mode works, SAE-only/PMF-required joins are rejected (`classifyLegacyAuth`, `WCL.hpp:506-529`; DRV-AP-004). Association rejection is never retried in place and never poisons the AP (DRV-11C-005); auth retry budget is 3 x 5 s then full rescan (DRV-11C-023).
- **Conclusion:** **ARCHITECTURAL DIFFERENCE** (in-driver supplicant, XPLAT-001) + **UNSUPPORTED CAPABILITY** for SAE/PMF (XPLAT-007). The assoc-retry behavior (DRV-11C-005) is a fork-side strongly-suspected defect but has no direct Linux counterpart to confirm against; it stays anchored to DRV-11C-005.

### 5. Key management

- **Linux:** per-station `STA_KEY` commands with cipher coverage CCMP, **GCMP-128/256**, TKIP, WEP (`mvm/sta.c:3602-3606`); **IGTK/BIGTK for MFP offloaded to firmware** (`iwl_mvm_send_mgmt_igtk`, `:3690-3760`); GTK rekey material (KEK/KCK/replay counter) stored from wpa_supplicant and used for **D3 group-rekey offload**, with key/counter read-back on resume (`mvm/d3.c:19-39`, `:1817`).
- **Fork:** `iwx_set_key` (`ItlIwx.cpp:10053-10084`) hardware-installs CCMP only; every other cipher falls back to software crypto on the command gate (DRV-11D-006). Awake-state GTK group rekey is complete and correct in the in-driver supplicant (DRV-11C-020, validated, incl. anti-reinstall guards); GCMP selectors parse as CIPHER_NONE (DRV-11D-002); no `IEEE80211_C_MFP` capability -> IGTK/BIP path unreachable, WCL `setCIPHER_KEY` has no IGTK case (DRV-11D-004); key installs are async and unacknowledged (DRV-11C-010).
- **Conclusion:** **UNSUPPORTED CAPABILITY (fork)** for GCMP/IGTK/sleep-rekey-offload (XPLAT-010); awake-state CCMP + GTK rekey is at parity (validated both sides).

### 6. Roaming / switching

- **Linux:** host-driven by design -- mac80211 beacon-loss counting (default 7) -> CQM notification to wpa_supplicant (`mlme.c:71-73`, `:4945-4947`); wpa_supplicant owns candidate selection, 11r FT, 11k/v BTM; directed roaming scans automatically use all RX chains (`mvm/scan.c:2097-2106`); session protection guards (re)association (`mvm/time-event.c:1415+`); CSME can mark roaming forbidden (`mvm/ops.c:1129-1136`). There is no firmware reassociation engine in MVM (LINUX-006).
- **Fork:** roaming effectively disabled: both join paths latch `IEEE80211_F_DESBSSID` (`WCL.cpp:513-515`), which blocks the bgscan trigger (`ieee80211_input.c:441-450`) and rejects every other BSSID in candidate selection (`ieee80211_node.c:1097-1099`) -- DRV-11C-002 (CONFIRMED). Any transition is a full AUTH + 4-way handshake, no 11r/11v (DRV-11D-017); the entire WCL roaming-assistance surface is stubbed (DRV-AP-012). Driver-internal auto-reauth on deauth runs silently below WCL (DRV-11C-007).
- **Conclusion:** **ARCHITECTURAL DIFFERENCE** for the ownership split (XPLAT-008) + **FORK DEFECT STRONGLY SUSPECTED** for the status staleness the internal recovery creates (XPLAT-009). The F_DESBSSID latch itself is a confirmed fork policy defect (DRV-11C-002) that must be undone before any roaming improvement.

### 7. Connected-state maintenance

- **Linux:** firmware **beacon filtering** with CQM hysteresis (`iwl_mvm_enable_beacon_filter`, `mvm/power.c:845-878`, incl. `bf_roaming_*` dampening) -- firmware forwards only beacons that matter; MISSED_BEACONS notifications feed mac80211's beacon-loss timer -> CQM -> supplicant roam decision; keep-alive at >= 3 x DTIM.
- **Fork:** beacon filter compiled out (`#ifdef notyet`, `ItlIwx.cpp:9917-9929` -- deliberately, to keep ERP/HT-protection updates flowing); missed beacons trigger a directed probe instead (`iwx_rx_bmiss`, `:6205-6248`); node-cache aging is the only staleness mechanism and is split-brained (WCL cache-bgscan retains nodes 5 min; inactivity timers never armed in STA mode, DRV-11C-011); and a **1 s watchdog on a dedicated workloop outside the command gate** mutates MLME state concurrently with the RX thread (DRV-11C-004).
- **Conclusion:** **UNSUPPORTED CAPABILITY (fork)** for beacon filtering/CQM (subsumed in XPLAT-016; LINUX-018 notes the command exists even in API 68) + **FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE** for the ungated watchdog (XPLAT-011).

### 8. Data TX / RX

- **Linux:** TVQM **balanced queue lifecycle**: per-TID dynamic allocation (`iwl_mvm_sta_alloc_queue_tvqm`, `mvm/sta.c:895-927` -> `SCD_QUEUE_CONFIG_CMD` ADD) and explicit removal + free on every agg-stop/sta-removal (`iwl_mvm_disable_txq`, `:351-442`; `pcie/tx-gen2.c:1108-1131`), with size-halving retry on allocation failure (`:1044-1055`) and full HE-size BA queues; a dedicated small management queue; mac80211 per-AC subqueues with per-queue stop/wake; MSI-X per-CPU RX vectors (`pcie/trans.c:1607-1670`); firmware TLC rate control (`mvm/rs-fw.c:573`).
- **Fork:** TVQM queues are **never removed** (`iwx_ampdu_tx_stop` is two lines, DRV-IWX-011) so fwqid increases monotonically; all non-aggregated traffic *and* management share **one 1024-slot ring** with `ac` pinned BE (DRV-IWX-010); gen3 aggregation rings capped at 256 TFDs as a freeze workaround (DRV-IWX-010); non-aggregated frames carry no QoS headers at all (DRV-11D-011); **any** full ring sets `qfullmsk` and stops the entire TX path including EAPOL/deauth (DRV-11D-018); MSI-X fully implemented but hard-disabled `if (0)` -> single MSI vector (DRV-IWX-005); host MiRA rate code is dead (DRV-11D-007, TLC parity confirmed); the softc statically reserves ~21.5 MB wired memory for 512 possible queues of which ~11 are ever used (DRV-IWX-020).
- **Conclusion:** **FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE** for the stall-inducing TX structure (XPLAT-013) and the queue lifecycle (folded into XPLAT-012) + **UNRESOLVED -- INSUFFICIENT EVIDENCE** for the 256-TFD freeze (XPLAT-014) + **ARCHITECTURAL DIFFERENCE** for MSI-X/single-vector (LINUX-016; performance, not correctness).

### 9. Aggregation

- **Linux:** mac80211 drives the full ADDBA/DELBA exchange (`iwl_mvm_mac_ampdu_action`, `mvm/mac80211.c:1007-1070`); the driver maintains a per-TID state machine (OFF -> STARTING -> ON) with SSN bookkeeping (`mvm/sta.c:3083/3188/3341/3414`); teardown always DELBAs the peer and disables+frees the queue; a new association re-runs ADDBA immediately, and queue IDs are reused because removal returns them to the firmware allocator (LINUX-010, LINUX-020).
- **Fork:** ADDBA is armed by a net80211 timer with a **1 s initial interval doubling to 30 s** on failure (DRV-11D-008) and is forbidden entirely on open networks (anti-injection policy, kept); teardown is silent and leaky: `iwx_rm_sta` sends delba with reason 0 = no frame transmitted (DRV-11D-010), `ieee80211_ba_del` never frees reorder buffers or their mbufs (DRV-11D-009), TX BA sessions advertise timeout 0 and are never reaped (DRV-11D-013), and the TVQM queue is never released (DRV-IWX-011).
- **Conclusion:** **FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE** for the teardown lifecycle (XPLAT-012) + **FORK DEFECT STRONGLY SUSPECTED** for the setup-side ramp (XPLAT-015).

### 10. Power management

- **Linux:** a full station-power toolbox: per-vif `MAC_PM_POWER_TABLE` with keep-alive >= 3xDTIM, LPRX, PS timeouts, skip-DTIM policies (`mvm/power.c:345-464`, `:297-343`); **U-APSD** per-AC with QNDP TID, snooze mode, and misbehaving-AP detection (`:122-212`); device power table (`:481-514`); **beacon filter with CQM** (`:845-878`); full WoW (D3 image, magic/disconnect/net-detect/GTK-rekey/4-way/patterns, ARP/NS offloads; `mvm/mac80211.c:737-755`, `mvm/d3.c`, `mvm/offloading.c`); **SAR/PPAG/GEO/TAS/DSM** BIOS tables read from ACPI/UEFI and applied at init (`fw/acpi.c:605-1123`, `mvm/fw.c:856-1055,1696-1698`); LTR handling with `SET_LTR_GEN2` skip (rough parity with fork).
- **Fork:** station PS unconditionally on with fixed flags; no interface to disable it for low latency; beacon filter dead; U-APSD exists only as TLV constants; no WoW/D3 at all -- sleep = full stop, wake = complete firmware reload (PNVM doorbell wait included) gated on macOS re-issuing `enable()` (DRV-IWX-016, DRV-11D-015, DRV-AP-007); **zero SAR/PPAG/GEO support** -- TX power unmanaged by BIOS limits (DRV-IWX-016).
- **Conclusion:** **UNSUPPORTED CAPABILITY (fork)** twice over: the power-saving/latency toolbox (XPLAT-016) and the SAR/PPAG regulatory-power compliance gap (XPLAT-017).

### 11. Recovery / fault handling

- **Linux:** containment: `iwl_mvm_nic_error` (`mvm/ops.c:1964-1989`) aborts **all** notification waits wholesale (`fw/notif-wait.c`), deletes timers, dumps the error log, and sets HW_RESTART_REQUESTED -- and for the AX210 family the driver **does not restart the interface** (firmware self-recovers; explicit `ieee80211_restart_hw` limited to old families or debug policy, `:2008-2064`); command-queue-full is reported as its own error class; RFKILL transitions use the normal interface state machine, not an error reinit (LINUX-012, LINUX-015).
- **Fork:** any SW_ERR/HW_ERR/CT_KILL/state-machine error triggers full stop + firmware reload via `init_task` (DRV-IWX-017) -- visible as multi-second link flaps; synchronous commands sleep 1 s per slot and **leak the CMD_PENDING slot** on timeout, eventually locking all commands out with ENOSPC (DRV-IWX-009); an error-path DMA leak in the gen3 loader (DRV-IWX-012); every reinit re-runs the full load chain against the ~21.5 MB softc (DRV-IWX-020).
- **Conclusion:** **ARCHITECTURAL DIFFERENCE** for the containment-vs-reload model, with an embedded **FORK DEFECT STRONGLY SUSPECTED** (the slot leak) whose fix blueprint is Linux's central wait-abort (XPLAT-018).

### 12. Status / event propagation

- **Linux:** nl80211 delivers a complete event surface to userspace: scan results, scheduled-scan matches (`cfg80211_sched_scan_results` from `iwl_mvm_rx_scan_match_found`, `mvm/scan.c:353-358`), CQM RSSI and beacon-loss (`ieee80211_cqm_beacon_loss_notify`, `mlme.c:4945-4947`), roam/disconnect with reasons, assoc/deauth events, regulatory changes, rfkill, station statistics. The userspace stack's view is always current.
- **Fork:** the complete upward inventory is 8 net80211 events (`ieee80211_var.h:687-695`) funneled into 11 WCL messages (201 ScanResult, 203 Deauth, 211 AssocComplete, 212 FirstBeacon, 213 ConnectComplete, 214 JoinAbortComplete, 216 LinkStatus, 39 LqmUpdate, 237 ScanDone, 49/55 driver lifecycle). **No roam/BSSID-change event, no disassoc event, no beacon-miss event, no port-authorized event** (DRV-11C-008 contract-gap table); LinkStatus-up is posted only inside first-beacon join completion (DRV-11C-007); every MLME transition forces LINK_STATE_DOWN (DRV-11C-017); LQM is a 3-tier RSSI map updated every 8 beacons *of the join-time BSSID* and goes to -2 after any internal roam (DRV-AP-005, DRV-AP-021).
- **Conclusion:** **ARCHITECTURAL DIFFERENCE** for the event transport (nl80211 vs. WCL PostOffice -- no Linux counterpart exists) + **FORK DEFECT STRONGLY SUSPECTED** for the missing-notification consequences (XPLAT-009).

### 13. Regulatory / channels

- **Linux:** cfg80211 self-managed regulatory on top of firmware LAR (MCC updates), NVM channel profiles, ACPI/UEFI SAR/PPAG/GEO tables, DSM function gates including **enable-6E** (`fw/regulatory.h:134-149`), 6 GHz channel/PSD handling in scan (RNR/PSC), PPAG DMI gating (`fw/regulatory.c:339-351`).
- **Fork:** firmware LAR only: NVM channel tables with passive/DFS flags (`iwx_init_channel_map`), MCC initialized "ZZ" and updated via `MCC_CHUB_UPDATE` -> country events flow end-to-end (DRV-AP-022, validated); no host regd layer -- `ieee80211_regdomain.c` is name/code tables only, country changes never reshape the channel list (DRV-11C-015); 6 GHz excluded (`#ifdef notyet`, DRV-11C-014); DFS never actively probed on WCL scans (correct) but the global `PRE_SCAN_PASSIVE2ACTIVE` scan-config flag is a firmware-behavior question mark (DRV-11D-016); locale hardcoded FCC, channel lists active-set only with flags stripped for airportd compatibility (DRV-AP-022).
- **Conclusion:** **ARCHITECTURAL DIFFERENCE** for the regd model (both ultimately delegate rules to firmware LAR; Linux adds a host regd + ACPI/DSM layer that macOS has no equivalent for) + **UNSUPPORTED CAPABILITY** for 6 GHz (XPLAT-006, already counted) + **UNRESOLVED** for the passive2active flag and for the BIOS-table presence that would quantify XPLAT-017.

### 14. Coexistence

- **Linux:** full CSME/MEI layer (`mei/`, SAP protocol): ownership handoff, scan-result filtering (`iwl_mvm_mei_limited_scan`/`iwl_mvm_mei_scan_work`, `mvm/scan.c:2745-2790`), rfkill override, roaming-forbidden events (`mvm/ops.c:1112-1136,1191`); BT coex in `mvm/coex.c`.
- **Fork:** BT coex hard-coded to WIFI-only at init (`ItlIwx.cpp:10446-10456`, DRV-IWX-013); no MEI/CSME awareness at all. If the ME ever owned the radio, the fork would simply fail; the MSI Modern 14 is a consumer (non-vPro) chassis so practical impact is likely nil -- unverified without a runtime DMI/ME check (LINUX-017).
- **Conclusion:** **UNSUPPORTED CAPABILITY (fork)** with **UNRESOLVED** on-this-chassis impact (carried in the summary table; no separate XPLAT finding because the impact is expected nil on this SKU and the gap is already fully documented as DRV-IWX-013/LINUX-017).

---

## XPLAT findings

### XPLAT-001: One kernel monolith vs. a split stack -- supplicant and MLME ownership inverted
- Classification: **ARCHITECTURAL DIFFERENCE**
- Severity: Info (structural; it enables every gap below) / Confidence: High
- Linux evidence: three-layer stack -- transport (`pcie/`), firmware runtime (`fw/`), op-mode `iwlmvm` (`mvm/`) -- with mac80211 implementing the MLME and wpa_supplicant (userspace) owning scanning policy, roaming decisions, SAE/FT/BTM (20-linux, architecture summary; no supplicant code exists anywhere in `mvm/`).
- Fork evidence: single 13.9k-line class `ItlIwx` wrapping the iwx_softc; in-kernel net80211 MLME + in-kernel OpenBSD supplicant (`ieee80211_pae_*`); WCL.cpp is the only userspace contract; macOS's own supplicant is bypassed for PSK networks (DRV-AP-020, DRV-11D-012).
- Analysis: this is the root intentional distinction of the port (OpenBSD driver model onto IOKit). It explains the shape of every subsequent finding: capabilities that Linux receives from above the driver are absent unless re-implemented in-kext; driver-internal errors have no userspace backstop; one workloop gate serializes what Linux distributes across subsystems; and the event surface upward is whatever WCL mimics. Not an incorrect implementation -- a different (and much smaller) system boundary.
- What runtime comparison would settle it: nothing -- the classification is source-certain. Runtime would only quantify consequences (e.g., whether airportd's own retry logic masks in-driver failures that wpa_supplicant would have absorbed on Linux).

### XPLAT-002: Firmware currency -- fork frozen at API 68, Linux pins API 89 as a matched pair
- Classification: **FIRMWARE-VERSION DIFFERENCE**
- Severity: Medium / Confidence: High
- Linux evidence: `cfg/ax210.c:13-16,74-75` + `iwl-drv.c:298-323` (API min=max=89 for so-a0-gf-a0); WHENCE:1080-1081 (`iwlwifi-so-a0-gf-a0-89.ucode`, v86.a67023b2.0); API 68 absent from current linux-firmware (LINUX-002).
- Fork evidence: embedded `iwlwifi-so-a0-gf-a0-68.ucode` (1,533,812 B, core66 build) + `.pnvm`; HAL TLV/command layouts matched to 68 only (DRV-IWX-006; 00-repo-state).
- Analysis: 21 API versions of firmware fixes/features are unavailable to the fork, and the pinning is bidirectional -- mainline Linux would refuse the 68 blob. The fork's field-reproducible defects (XPLAT-003/-005/-011/-012/-013) all reproduce on API 68 and have driver-side causes, so a firmware upgrade is neither necessary nor sufficient to fix them; it is a separate, high-risk work package (every API bump reshapes command/notification layouts; scan v12->v17 alone re-shapes four parameter blocks). Treat firmware age as a background variable, not a root cause.
- What runtime comparison would settle it: capturing the Ubuntu partition's actual loaded firmware version (`dmesg`) would confirm the inference that the working OS runs a much newer API (open question 1 of 20-linux); the per-API behavioral changelog is unpublished, so only runtime A/B on both OSes could enumerate what 68 is missing.

### XPLAT-003: PNVM load flow -- 2 s gate-held dead wait after a failed read vs. 250 ms fail-fast with cached failure
- Classification: **FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE**
- Severity: Medium / Confidence: High
- Linux evidence: `fw/pnvm.c:372-417` (fail flag short-circuits all later attempts), `:297-318` (per-family source selection; external file for AX211+GF), `:477-478` (skip when sku_id empty), `fw/pnvm.h:12` (`MVM_UCODE_PNVM_TIMEOUT = HZ/4` = 250 ms), `mvm/fw.c:407-413` (a true timeout is a hard init failure) (LINUX-014).
- Fork evidence: DRV-IWX-008: `iwx_load_pnvm` (`ItlIwx.cpp:2154-2184`) -- dead `goto out` (both paths fall through), doorbell kicked even when the PNVM read failed, **2000 ms** wait inside the workloop gate for a notification that cannot arrive on SKU mismatch; EWOULDBLOCK propagates as a hard init failure into the retry loop (`:10779-10791`).
- Analysis: Linux correspondence proves three things the fork gets wrong within the same hardware contract: the wait can be an order of magnitude shorter, a failed parse must be cached so it is never re-burned, and an empty SKU should skip PNVM entirely. Both stacks agree that a *true* timeout is fatal -- so the fork's defect is the 2 s x retry burn on the shared gate (which also stalls every WCL operation), not the hard-fail semantics. The fix is small (respect the failed-read path + shorten the wait).
- What runtime comparison would settle it: whether this unit's fused sku_id matches the embedded .pnvm (i.e., whether every boot and every post-wake reload pays the 2 s) -- boot-log "PNVM complete" vs. timeout, covered by the tools kit (open question 3 of 20-linux, question 2 of 10-hal).

### XPLAT-004: Scan request architecture -- versioned firmware scans with adaptive dwell and scheduled-scan offload vs. one fixed SCAN_REQ_UMAC
- Classification: **ARCHITECTURAL DIFFERENCE**
- Severity: Low-Medium / Confidence: High
- Linux evidence: `mvm/scan.c:2736-2743` (v17..v12 handler table selected by fw capability), `:220-267` (five scan types incl. FRAGMENTED/FAST_BALANCE chosen from TCM traffic load), `:1292-1444` (adaptive dwell + per-band budgets), `:3077-3165` (scheduled scan: plans, delay, 6 GHz non-PSC strip), `:521-604` + `:353-358` (match-profile offload -> MATCH_FOUND wake) (LINUX-003, LINUX-005).
- Fork evidence: `ItlIwx.cpp:7979-8000` (v1/v8/v12/v14 request shapes), `:8061` `iwx_umac_scan`, `:7928-7931` (dwell fixed once), one-shot per net80211 state step (DRV-11C-001); WCL away/home timing fixed at 120/120 TU for stability, with a comment that 30 TU home time coincided with firmware resets on AX210-class hardware (DRV-AP-027).
- Analysis: intentional design split: Linux treats scan cost as a function of traffic and fw capability; the OpenBSD-derived port issues one full-size request per state-machine step. Not a defect by itself -- but it removes the machinery that would bound XPLAT-005's idle loop, and the fork has no equivalent of `iwl_mvm_scan_timeout_wk` (force-NMI on a wedged scan), so a stuck firmware scan wedges the whole interface instead of the firmware.
- What runtime comparison would settle it: off-channel duty-cycle and scan-latency measurement while associated (tools kit) would quantify the cost of the missing adaptation; a wedged-scan reproduction would show whether the missing watchdog matters in practice.

### XPLAT-005: Idle "scan forever" loop vs. bounded scheduled-scan with idle park
- Classification: **FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE**
- Severity: Medium-High / Confidence: High
- Linux evidence: scheduled scan offload keeps the radio scanning in firmware and wakes the host only on a match (`mvm/scan.c:521-604`, `:353-358`); regular scans are bounded by the SCAN_TIMEOUT watchdog (`:2698-2707`) (LINUX-005).
- Fork evidence: DRV-11C-003 (CONFIRMED): the not-found path of `ieee80211_end_scan` (`ieee80211_node.c:1456-1484`) restarts the firmware scan indefinitely ("This will loop forever until an access point is found"); with no pending WCL join, every BSS fails the ESSID match (`node.c:1058-1061`), so after leave/failed join/idle radio-on the firmware scans at full rate forever; after beacon miss the loop runs *with the join BSSID still latched* (DRV-11C-002), producing a multi-second dead zone until the 30 s WCL join timer or a macOS rejoin; every scan end also pushes EVT_SCAN_DONE and every beacon an EVT_BEACON -> WCL message (DRV-11C-024).
- Analysis: Linux proves the bounded alternative exists in the same firmware command family (sched-scan and match profiles are available in API 68) and that nothing requires an infinite host-driven loop. The fork's loop monopolizes the single workloop gate, burns RF airtime and power at idle (elevated heat vs. native), floods the unified log (amplified by DRV-IWX-021's unconditional debug logging), and keeps the menu list churning. This is a defect with a bounded-rescan/sched-scan-emulation fix that does not require a firmware upgrade.
- What runtime comparison would settle it: idle power/heat and off-channel duty-cycle capture while disconnected (tools kit); WCL message-rate count at idle; user-visible "list keeps refreshing when idle" confirmation.

### XPLAT-006: 6 GHz (Wi-Fi 6E) -- first-class Linux subsystem vs. a compiled-out band
- Classification: **UNSUPPORTED CAPABILITY (fork)**
- Severity: High (feature) / Confidence: High
- Linux evidence: `mvm/scan.c:1682-1754` (RNR-derived short-SSID/BSSID filter arrays), `:1757-1960` (per-channel RNR mapping, non-PSC skip), `:2001-2088` + `:2464-2493` (passive 6 GHz PSC fallback), `cfg/rf-gf.c:32` (`uhb_supported`), DSM `DSM_FUNC_ENABLE_6E` (`fw/regulatory.h:138`) (LINUX-004).
- Fork evidence: DRV-11D-001/DRV-11C-014: the ultra-high-band NVM channel list is behind `#ifdef notyet` (`ItlIwx.cpp:409-423`); net80211 has no 6 GHz band (no freq<->chan mapping, no flags); the WCL scan decoder drops 6 GHz entries (`WCL.hpp` decodeScan: `channel > 196 || (flags & 0x2000)`); never advertised to macOS (DRV-AP-003).
- Analysis: same AX211 silicon: Ubuntu can discover 6 GHz APs; the fork cannot represent the band at all. Because 6 GHz mandates WPA3-SAE/PMF, the exclusion also masks XPLAT-007. Closing it requires net80211 band plumbing + scan-API work + WCL channel publication well beyond the HAL -- the single largest capability gap and a deliberate scope cut of the port, not a bug.
- What runtime comparison would settle it: nothing causal -- the source is conclusive. A side-by-side scan list (same room, same APs) on Ubuntu vs. macOS would simply demonstrate it to the owner.

### XPLAT-007: WPA3-SAE / PMF / GCMP at association -- userspace supplicant vs. CCMP-era in-driver supplicant
- Classification: **UNSUPPORTED CAPABILITY (fork)**
- Severity: High (interop) / Confidence: High
- Linux evidence: SAE performed by wpa_supplicant via the external-auth API (`net/mac80211/mlme.c:5431`); PMF implemented in mac80211; GCMP installed to firmware (`mvm/sta.c:3602-3606`); IGTK/BIGTK offload (`:3690-3760`) (LINUX-013).
- Fork evidence: DRV-11D-003 (auth is open-system only, `ieee80211_input.c:2330-2344`; the legacy WPA3->WPA2 authtype mapping is compiled out of the WCL target); DRV-11D-002 (GCMP selectors parse as CIPHER_NONE); DRV-11D-004 (no `IEEE80211_C_MFP`; IGTK/BIP unreachable; WCL `setCIPHER_KEY` has no IGTK case); DRV-AP-004 (WCL `classifyLegacyAuth` rejects SAE/FT bits; transition-mode networks work via the `selectWPA2TransitionMode` RSN-IE rewrite).
- Analysis: WPA3-only, PMF-required, GCMP, and (per XPLAT-006) all 6 GHz networks are unjoinable; WPA2/WPA3 transition networks connect via PSK. The firmware -- even at API 68 -- supports GCMP/IGTK; the gap is the net80211 cipher/AKM representation and the absence of any SAE implementation in the inherited 2020 OpenBSD base. Missing capability by inheritance, not an incorrect implementation of something that exists.
- What runtime comparison would settle it: join attempts against a WPA3-only AP (expected: unsupported status) are confirmatory only; the gap is source-conclusive.

### XPLAT-008: Roaming -- host-driven 11r/11k/11v with CQM vs. latched BSSID and full re-authentication
- Classification: **ARCHITECTURAL DIFFERENCE**
- Severity: High / Confidence: High
- Linux evidence: roaming owned by wpa_supplicant on top of mac80211 CQM/beacon-loss (`mlme.c:71-73,4945-4947`); FT auth accepted (`:5521,9989-9990`); BTM/neighbor reports in the supplicant; directed roaming scans use all RX chains (`mvm/scan.c:2097-2106`); session protection during (re)assoc (`mvm/time-event.c:1415+`); explicitly no firmware roaming engine in MVM (LINUX-006).
- Fork evidence: DRV-11C-002 (CONFIRMED): `IEEE80211_F_DESBSSID` latched at every join (`WCL.cpp:513-515`) blocks both the bgscan trigger (`input.c:441-450`) and candidate selection (`node.c:1097-1099`); roam/reassoc is always full AUTH + 4-way handshake, no 11r/11v (DRV-11D-017); the WCL roaming-assistance surface is entirely stubbed (DRV-AP-012); the only recovery is driver-internal reauth (DRV-11C-007).
- Analysis: the ownership split is intentional on both sides -- Linux puts roaming above the driver, and the fork has nothing above the driver, so roaming is disabled by a fork policy latch. The latch itself is a confirmed fork defect (it also breaks same-ESS failover after beacon loss), but full parity would require implementing candidate selection, FT, and BTM inside the kext. Note also that every roam the fork *does* perform (join transitions) pays the aggregation re-ramp (XPLAT-015) and the resource-leak tax (XPLAT-012).
- What runtime comparison would settle it: a walk-between-APs test with BSSID tracking on both OSes (seamless on Ubuntu vs. full drop + rescan + re-auth on macOS); macOS log capture of roam-scan lines (open question 1 of 11-airport).

### XPLAT-009: Driver-internal recovery is invisible to the OS -- no roam/disassoc/port-auth events, LQM freezes
- Classification: **FORK DEFECT STRONGLY SUSPECTED**
- Severity: High / Confidence: Medium-High
- Linux evidence: nl80211 event surface keeps userspace current: roam events, CQM RSSI/beacon-loss, disconnect/reassoc with reasons, assoc/deauth notifications (20-linux, ops/mac80211 anchors; `cfg80211_sched_scan_results` etc.).
- Fork evidence: DRV-11C-008 (CONFIRMED contract gap): the complete event inventory has no roam/BSSID-change, no disassoc, no beacon-miss, no port-authorized event; DRV-11C-007 (deauth -> silent auto-reauth while airportd saw Deauth + Link-down and never a Link-up); DRV-AP-005 (all freshness keyed to the join-time `joinBSSID`: LQM forced to -2, frozen BEACON_INFO after any roam); DRV-11C-017 (every MLME transition asserts LINK_STATE_DOWN, flapping en0 during reauth).
- Analysis: the source-level gap is confirmed (events do not exist); what is *not* confirmed is the user-visible outcome (menu showing the wrong network, self-assigned-IP/captive loops, airportd declaring the interface down while associated), because airportd's actual reactions to these WCL messages cannot be exercised from source. Linux shows what a complete event surface looks like but has no counterpart for the WCL contract itself, so it can define the gap but not confirm the symptom.
- What runtime comparison would settle it: instrumented timestamped log of WCL messages 216/39 vs. actual BSSID change across a forced deauth and a roam (tools kit; open questions 1-2 of 11-airport and 12-controlplane).

### XPLAT-010: Key management -- awake GTK rekey at parity, but GCMP/IGTK unrepresentable and no sleep-time rekey
- Classification: **UNSUPPORTED CAPABILITY (fork)**
- Severity: Medium-High / Confidence: High
- Linux evidence: per-sta `STA_KEY` with GCMP/TKIP/WEP coverage (`mvm/sta.c:3602-3606`); IGTK/BIGTK firmware offload with receive-sequence counters (`:3690-3760`); GTK rekey offload during D3 with KEK/KCK and resume key/counter sync (`mvm/d3.c:19-39`, `:1817`) (LINUX-013).
- Fork evidence: DRV-11C-020 (in-driver GTK group rekey validated correct, incl. anti-reinstall and link re-assert); DRV-11D-005 (CCMP core validated, per-TID replay counters, KRACK guards); DRV-11D-002 (GCMP unrepresentable), DRV-11D-004 (no MFP cap, IGTK dead end-to-end); DRV-11C-010 (async unacknowledged firmware key install -- first encrypted frames after join can race the install).
- Analysis: the common case (WPA2-CCMP awake operation and hourly group rekeys) is at parity. The gaps are representation-level (net80211 cipher set) and sleep-level (no D3 image at all, see XPLAT-016). The async-install race is a small residual risk ("first ping after connect lost" class).
- What runtime comparison would settle it: PMF-optional enterprise AP test (does WCL ever attempt an IGTK delivery? open question 4 of 13-dataplane); packet capture of the first encrypted frames after join.

### XPLAT-011: Ungated 1 s watchdog mutates MLME state off the single gate
- Classification: **FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE**
- Severity: Medium-High / Confidence: High (structure), Medium (manifestation frequency)
- Linux evidence: all mac80211/iwlwifi state mutation is serialized by framework locking -- timers and delayed work (e.g. `iwl_mvm_scan_timeout_wk`) run on ordered workqueues; no code path touches MLME state outside the serialization points (20-linux, recovery and timer architecture).
- Fork evidence: DRV-11C-004 (CONFIRMED concurrency defect): a dedicated `fWatchdogWorkLoop` + 1 s timer (`AirportItlwmV2.cpp:345-361`) drives `ieee80211_watchdog` (`ieee80211.c:906-929`), which decrements `ic_mgt_timer` and can fire `new_state(SCAN)` -- a full transition (AMPDU stop, node-table purge) -- while the RX thread on the main workloop concurrently completes auth/assoc; `splnet()` is a no-op (`timeout.c:32-39`); every other net80211 timer correctly goes through CTimeout on the main workloop, making this the lone outlier.
- Analysis: Linux correspondence establishes that nothing in the hardware or firmware requires an ungated timer -- the known-good pattern is complete serialization. The structural violation is source-certain; only its real-world frequency (rare "join succeeded then immediately dropped" / "stuck in SCAN" / post-wake weirdness, since the watchdog also ticks against a stopped firmware during sleep) is runtime-dependent.
- What runtime comparison would settle it: debug-log correlation of watchdog SCAN transitions vs. `iwx_newstate_task` completions over long uptime (open question 1 of 12-controlplane); a wake-race reproduction (watchdog firing while firmware is stopped).

### XPLAT-012: Aggregation resource lifecycle across roam/sleep -- queues and reorder buffers never returned
- Classification: **FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE**
- Severity: High / Confidence: High
- Linux evidence: balanced TVQM lifecycle -- `iwl_mvm_disable_txq` sends `IWL_SCD_QUEUE_REMOVE` + frees the ring on every agg-stop/sta-removal (`mvm/sta.c:351-442`, `:3341-3412`; `pcie/tx-gen2.c:1108-1131`); queue IDs are reused because removal returns them to the allocator; mac80211 always DELBAs the peer and re-runs ADDBA on each new association (LINUX-010, LINUX-020).
- Fork evidence: DRV-IWX-011 (`iwx_ampdu_tx_stop` = two lines: qid = INVALID + stats decrement; no remove command, no ring free; fwqid increases monotonically; after ~64 roam/sleep cycles TVQM allocation must fail, after which `iwx_ba_task` refuses ADDBA permanently); DRV-11D-010 (`iwx_rm_sta` delba reason 0 = no DELBA frame to the AP); DRV-11D-009 (`ieee80211_ba_del` never frees reorder buffers or parked mbufs -- per-roam kernel-memory leak); DRV-11D-013 (TX BA timeout advertised as 0, so a wedged session is never reaped).
- Analysis: Linux runs the same TVQM allocator on the same silicon family with a balanced ADD/REMOVE lifecycle across unlimited roam/sleep cycles -- proving the firmware expects explicit removal and the leak is a driver defect with a concrete fix (send remove + free ring + free reorder buffers), not a firmware limitation. Together with XPLAT-015 this is the strongest systemic explanation for the reported "throughput degrades after roaming/sleep until reboot": leaks accumulate until aggregation is permanently refused and the link pins at legacy non-aggregated rates.
- What runtime comparison would settle it: forced-roam log capture watching for "Failed allocating TXQ" / ADDBA refusals after N roams (open question 1 of 10-hal and 13-dataplane); memory-growth measurement across roam cycles.

### XPLAT-013: TX path structure -- one shared ring, no QoS before aggregation, any full ring stalls everything
- Classification: **FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE**
- Severity: High / Confidence: High
- Linux evidence: per-TID TVQM queues plus a dedicated management queue (`mvm/sta.c:895-927`; mgmt min_txq_size 128, `:852-858`); mac80211 per-AC subqueues with per-queue stop/wake (backpressure is per-queue); MSI-X per-CPU RX (`pcie/trans.c:1607-1670`).
- Fork evidence: DRV-IWX-010 (until ADDBA completes, all data ACs *and* management share one 1024-slot ring; `ac` parameter pinned `EDCA_AC_BE`); DRV-11D-011 (non-aggregated frames carry no QoS headers at all, so pre-BA traffic has no WMM priority; EAPOL contends with bulk traffic on the shared ring); DRV-11D-018 (CONFIRMED: `qfullmsk` -- one full ring sets `ifq_set_oactive` and stops *all* TX including EAPOL/deauth/SA-Query until completions drain or the 15 s watchdog reinitializes); DRV-IWX-005 (MSI-X implemented but `if (0)` -> single vector, contributing to the throughput ceiling, LINUX-016).
- Analysis: Linux's known-good structure -- separate management path, per-queue backpressure, per-AC scheduling -- demonstrates that the global stall is not a firmware constraint. Consequences: EAPOL starvation under load -> 100 ms handshake timeouts -> re-auth loops (amplifying join unreliability), and multi-second total dead air whenever a single aggregation ring wedges (which XPLAT-012 makes progressively more likely).
- What runtime comparison would settle it: bulk-TCP-during-reassociation reproduction (open question 6 of 13-dataplane); queue-depth and oactive instrumentation during an induced stall.

### XPLAT-014: Gen3 aggregation capped at 256 TFDs with an unexplained freeze
- Classification: **UNRESOLVED -- INSUFFICIENT EVIDENCE**
- Severity: Medium / Confidence: Medium
- Linux evidence: `cfg/ax210.c:59` (full `IWL_DEFAULT_QUEUE_SIZE_HE` BA queues for this family) and `pcie/tx-gen2.c:1044-1055` (graceful size-halving retry on allocation failure) -- much larger rings on the same TVQM allocator and firmware family with no freeze workaround (LINUX-011).
- Fork evidence: DRV-IWX-010 (author comment at `iwx_tvqm_alloc_txq`: for gen3 devices, TFD counts larger than 256 "would trigger system freeze on macOS"; ring size limited to 256 as a "temporary solution"; the 1024-slot gen3 size is behind `#ifdef notyet`).
- Analysis: Linux's behavior suggests the freeze is host-side (IOMMU/coalescing/alignment/bc_tbl sizing in the kext -- one candidate is the bc_tbl allocation sized for 1024 while the ring runs 256, noted in 10-hal open question 3), but a macOS kernel freeze cannot be root-caused from source on either side. Neither confirmed defect nor exonerated firmware; the cap also halves aggregation throughput vs. Linux on the same silicon.
- What runtime comparison would settle it: controlled reproduction on macOS with the ring size restored plus DMA tracing; comparison against Linux's size-halving allocator behavior on the same chassis. This is the clearest case where only runtime evidence can classify the difference.

### XPLAT-015: ADDBA ramp -- 1 s delay, 30 s backoff, never on open networks
- Classification: **FORK DEFECT STRONGLY SUSPECTED**
- Severity: High (throughput ramp) / Confidence: High (code path), Medium (frequency)
- Linux evidence: mac80211 initiates ADDBA on traffic without artificial delay; `iwl_mvm_sta_tx_agg_start/oper` complete immediately and aggregation is re-established right after each association (LINUX-020); no timer-based ramp exists anywhere in the Linux agg path.
- Fork evidence: DRV-11D-008: the ADDBA request timer starts at 1 s (`ni_addba_req_intval`, `node.c:1762-1763`) and doubles to a 30 s maximum on each failure (`node.h:439`); aggregation is additionally forbidden on open networks by deliberate anti-injection policy (`output.c:490-507` -- kept intentionally).
- Analysis: every association/reassociation pays >= 1 s of non-aggregated, non-QoS legacy TX before A-MPDU starts; a single failed ADDBA pins a TID near legacy rates for up to 30 s; on open/guest SSIDs throughput is permanently capped. Combined with XPLAT-012/-013, the post-roam throughput ramp is minutes-scale worst case. The code path is source-certain; the *frequency* with which users hit the 30 s backoff (vs. the 1 s baseline) is runtime-dependent.
- What runtime comparison would settle it: post-roam throughput timeline (throughput samples every ~500 ms across a forced roam -- e.g. iperf) plus ADDBA timer logs on the target machine.

### XPLAT-016: Power management -- fixed always-on PS; no U-APSD/snooze/LPRX/beacon-filter/WoW; sleep = firmware reload
- Classification: **UNSUPPORTED CAPABILITY (fork)**
- Severity: Medium-High / Confidence: High
- Linux evidence: `mvm/power.c:122-212` (U-APSD per-AC, QNDP TID, snooze when all ACs U-APSD, misbehaving-AP detection), `:297-343` (skip-DTIM policies), `:345-464` (LPRX, keep-alive, PS timeouts), `:845-878` (beacon filter with CQM hysteresis), `mvm/mac80211.c:737-755` + `mvm/d3.c` (full WoW: D3 image, net-detect, GTK-rekey, 4-way, patterns), `mvm/offloading.c` (ARP/NS offload) (LINUX-007, LINUX-008, LINUX-018).
- Fork evidence: DRV-IWX-016 (station PS unconditionally on with fixed flags -- neither maximal saving nor a low-latency off path; beacon filter `#ifdef notyet`; U-APSD only TLV constants; WoWLAN section parsed but never loaded); DRV-11D-015 (net80211 PS machinery inert; everything delegated to firmware PS); missed-beacon handling is a directed probe, a poor airtime-cost substitute for the beacon filter (LINUX-018); sleep = full stop and wake = complete firmware reload chain including the PNVM wait (XPLAT-003), with re-enable dependent on macOS issuing `enable()` (DRV-AP-007).
- Analysis: structural to the port (upstream OpenBSD if_iwx has no D3 either) -- a capability gap, not a misimplementation. Independent of everything else, the beacon filter alone is the biggest single power win the fork leaves disabled, and its command exists in API 68 (low-risk fork fix). Wake latency is seconds (full reload) vs. sub-second (D3 image) on Linux.
- What runtime comparison would settle it: battery/power-draw and wake-latency measurement on both OSes (pmset/log timestamps); boot/wake log of whether the PNVM 2 s penalty (XPLAT-003) is paid on every wake.

### XPLAT-017: SAR / PPAG / GEO -- BIOS power-limit enforcement absent in the fork
- Classification: **UNSUPPORTED CAPABILITY (fork)** -- regulatory-compliance exposure
- Severity: High (compliance) / Confidence: High (gap), UNRESOLVED (actual exposure)
- Linux evidence: `fw/acpi.c:605-1123` (WRDS/EWRD/WGDS/PPAG readers), `mvm/fw.c:856-1055,1696-1698` (SAR profile 1 applied at init, geo profiles), `fw/regulatory.h:134-149` (DSM functions incl. enable-6E, UNII-4, energy-detection), `fw/regulatory.c:339-351` (PPAG DMI gate) (LINUX-009).
- Fork evidence: DRV-IWX-016 ("zero matches for SAR/PPAG/GEO in the HAL") -- TX power is unmanaged by BIOS SAR limits on the macOS side.
- Analysis: on the same chassis, Ubuntu enforces BIOS SAR profiles; the fork transmits with unmanaged TX power. Two honest limits: (a) whether this MSI BIOS actually ships WRDS/EWRD/WGDS/PPAG for this SKU is runtime-only; (b) macOS lacks the ACPI DSM/UEFI interfaces Linux uses, so even a willing fix needs a different table source (embedded tables or IOACPI probing) -- non-trivial on this OS. The driver-side capability gap is source-verifiable; the real-world exposure is not.
- What runtime comparison would settle it: ACPI table dump on the Ubuntu partition (tools kit) to confirm whether WRDS/EWRD/WGDS/PPAG exist for 8086:51F0; TX-power measurement comparison between OSes on the same channel.

### XPLAT-018: Recovery model -- containment with central wait-abort vs. full reload; leaked command slots
- Classification: **ARCHITECTURAL DIFFERENCE** (with an embedded FORK DEFECT STRONGLY SUSPECTED)
- Severity: Medium-High / Confidence: High
- Linux evidence: `iwl_mvm_nic_error` (`mvm/ops.c:1964-1989`) aborts all notification waits wholesale (`fw/notif-wait.c`, `iwl_abort_notification_waits`), dumps the error log, and for the AX210 family does **not** restart the interface -- the firmware self-recovers and the driver reports (`:2008-2064`); command-queue-full is a distinct error class; RFKILL is a state transition, not a reinit (LINUX-012, LINUX-015).
- Fork evidence: DRV-IWX-017 (any SW_ERR/HW_ERR/CT_KILL/state-machine error -> full stop + firmware reload via `init_task`; any auth/assoc/run error likewise restarts the radio -- visible link flaps); DRV-IWX-009 (per-slot 1 s `commandSleep`; a timed-out synchronous command permanently consumes one of 128 gen3 command-ring slots because CMD_PENDING/queued are only undone by a late response or a ring reset; enough timeouts -> ENOSPC for all commands -> the reinit loop); DRV-IWX-012 (error-path DMA leak in the gen3 loader); DRV-IWX-020 (~21.5 MB wired softc as the per-instance footprint this model reinitializes around).
- Analysis: the reload model itself is OpenBSD heritage -- intentional, and defensible for a port without mac80211's restart machinery. What Linux correspondence proves wrong *within* that model: (a) pending waits can be aborted centrally, so leaked command slots are not an inherent cost of synchronous commands; (b) errors can be contained without a reload, so transient firmware slowness need not become a link flap. The slot leak is the embedded strongly-suspected defect (its trigger -- a wedged firmware that raises no error interrupt -- is runtime-dependent); the wait-abort pattern is the concrete fix blueprint that does not require changing the fork's threading model.
- What runtime comparison would settle it: long-uptime log correlation of command timeouts (EWOULDBLOCK) -> ENOSPC -> reinit storms; fw-error-injection is not possible from this environment, so only field logs (tools kit) can establish the leak's real-world rate.

---

## Difference classification summary table

| # | Operation | Dominant classification | Components and anchors |
|---|---|---|---|
| 1 | PCI enumeration & config | ARCHITECTURAL DIFFERENCE | Runtime strap-derived so+gf composition vs. static 19-ID tables (LINUX-001, DRV-IWX-001/002/003/004 -- residual table defects are fork-side but non-AX211) |
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

Classification distribution across the 18 XPLAT findings: ARCHITECTURAL DIFFERENCE x4 (XPLAT-001, -004, -008, -018) | FORK DEFECT CONFIRMED BY LINUX CORRESPONDENCE x5 (XPLAT-003, -005, -011, -012, -013) | FORK DEFECT STRONGLY SUSPECTED x2 (XPLAT-009, -015) | UNSUPPORTED CAPABILITY (fork) x5 (XPLAT-006, -007, -010, -016, -017) | FIRMWARE-VERSION DIFFERENCE x1 (XPLAT-002) | UNRESOLVED -- INSUFFICIENT EVIDENCE x1 (XPLAT-014). No finding is attributable to the Wi-Fi hardware itself (identical silicon both sides).

---

## What Linux cannot explain (honest limits of this correspondence)

1. **The macOS framework contracts have no Linux counterpart.** The WCL PostOffice wire structs, the IO80211InfraProtocol virtual surface, the en0 provider-identity spoof, and the capability-byte mimicry (DRV-AP-018, DRV-AP-025, DRV-AP-028, DRV-AP-023) are Apple-private interfaces reverse-engineered by the fork. Linux can describe what a *complete* driver-to-OS contract looks like in nl80211 terms, but it cannot validate any WCL semantics, cannot say whether a given stub or mimicry is the *correct* answer to a given airportd query, and cannot predict which static_assert will break on the next macOS point release. Every DRV-AP-* finding is verifiable only on macOS.

2. **airportd's own behavior is unverifiable from Linux.** Whether airportd retries on `kIOReturnBusy` from a scan/join conflict (DRV-AP-008), whether it reliably re-issues `setPOWER(on)` after wake (DRV-AP-007 -- the fork's wake correctness depends on it), how it ranks scan results that carry no age field (DRV-AP-010), and what it does when LQM goes invalid (-2) or a LinkStatus-down arrives with no matching up (DRV-11C-007) -- these are userspace daemon behaviors on the macOS side with no Linux analogue. The fork-side prerequisites are source-confirmed; the *consequences* remain hypotheses until macOS runtime logs exist.

3. **Firmware behavioral differences between API 68 and API 89 are unverifiable from source.** Intel does not publish per-API changelogs in linux-firmware; the driver source shows only that gates and command shapes changed (scan v14+ per-channel flags/PSD, PASSIVE_6GHZ_SCAN, SET_LTR_GEN2, SAR table v2, IGTK/BIGTK shapes, `sta_remove_requires_queue_remove` semantics), not what the firmware *fixed*. Two fork-adjacent firmware-behavior questions are therefore open: whether the firmware resets the fork's authors observed under aggressive scan timing (WCL.hpp:290-312 comment) are fixed in newer APIs, and whether any part of the gen3 aggregation edge cases (XPLAT-014) is firmware-side. Only runtime A/B on both OSes -- or an infeasible HAL port -- could enumerate the deltas.

4. **The Linux reference itself is a snapshot, not the target's Ubuntu.** All Linux behavior herein is read from mainline `20eef29b7c84`; the Ubuntu partition's actual kernel and firmware versions are moderate-confidence inference (any 2024+ Ubuntu runs a substantially newer API than 68). Confirming the working OS's exact firmware is a one-command runtime task (open question 1 of 20-linux).

5. **Two machine-configuration questions can only be answered on the hardware:** whether the MSI BIOS ships WRDS/EWRD/WGDS/PPAG for this SKU (quantifies the XPLAT-017 compliance exposure) and whether this chassis's ME ever asserts CSME ownership (Operation 14). These are the only candidates for a genuine hardware/configuration difference in this audit, and both are UNRESOLVED pending the owner-run diagnostic kit.

**Bottom line:** the Linux correspondence is decisive exactly where the two stacks share a hardware contract -- PNVM timing (XPLAT-003), TVQM lifecycle (XPLAT-012), TX queue structure (XPLAT-013), watchdog serialization (XPLAT-011), scheduled-scan bounds (XPLAT-005) -- and silent exactly where macOS is Apple-private -- the WCL/airportd contract and the airportd daemon itself. The confirmed fork defects all reproduce on API 68 and have driver-side fixes that do not require a firmware upgrade; the firmware-version gap (XPLAT-002) is a background variable, and the priority order for remediation remains: XPLAT-012/-013 (aggregation/queue lifecycle), XPLAT-005 (idle loop), XPLAT-003 (PNVM wait), XPLAT-011 (watchdog gating), then capability work (XPLAT-006/-007/-016) as scoped projects.

---

*End of AUDIT-6c. Companion documents: `20-linux-iwlwifi-analysis.md` (Linux reference), `10-iwx-hal-audit.md`, `11-airport-integration-audit.md`, `12-itl80211-controlplane-audit.md`, `13-itl80211-dataplane-audit.md` (fork audits), `23-environment-access.md` (evidence constraints). Runtime follow-up: `tools/` diagnostic kit.*