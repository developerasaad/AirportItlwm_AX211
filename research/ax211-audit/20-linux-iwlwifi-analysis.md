# AUDIT-2d: Linux iwlwifi Source-Level Analysis for Intel AX211 (so-a0-gf-a0)

**Task ID:** AUDIT-2d
**Date:** 2026-11-18
**Purpose:** Establish the Linux reference implementation for the AX211 (Intel Wi-Fi 6E AX211, PCI 8086:51F0) and build a capability/behavior correspondence table against the AirportItlwm IWX fork (prior audits AUDIT-2a/2b/2c-1/2c-2/2d, IDs DRV-IWX-0xx and DRV-11C/D-0xx).
**Classification discipline:** This is a **source-only** analysis. No runtime evidence from either OS was available. Findings that depend on runtime behavior are marked UNRESOLVED or carry reduced confidence.

---

## Method

| Source | Commit | Snapshot date | Coverage |
|---|---|---|---|
| `refs/linux-iwlwifi` (torvalds/linux sparse clone: `drivers/net/wireless/intel/iwlwifi/`, `net/mac80211/`, `net/wireless/`) | `20eef29b7c84` | 2026-11-17 | Full iwlwifi tree incl. `cfg/`, `mvm/`, `mld/`, `pcie/`, `fw/`, `mei/`; mac80211 + cfg80211. Read: `cfg/ax210.c`, `cfg/rf-gf.c`, `cfg/sc.c`, `cfg/22000.c`, `iwl-drv.c` (fw selection), `pcie/drv.c` (PCI IDs), `mvm/scan.c` (full structural read), `mvm/power.c`, `mvm/sta.c` (TVQM/agg), `mvm/tx.c` (spot), `mvm/d3.c` (WoW inventory), `mvm/ops.c` (recovery/RFKILL), `mvm/mac80211.c` (WoW flags, ampdu, keys), `mvm/rs-fw.c` (inventory), `fw/pnvm.c` (full), `fw/acpi.c` + `fw/regulatory.h` (SAR/PPAG/DSM), `pcie/trans.c` (MSI-X/LTR), `pcie/tx-gen2.c` (TVQM alloc), `mei/` (inventory), `net/mac80211/mlme.c` (roaming/11r/beacon loss). |
| `refs/linux-firmware` (WHENCE metadata) | `747bdda274d0` | 2026-11-18 | `WHENCE` grep for `so-a0-gf-a0` (all 13 entries + pnvm). Git history is a single squashed commit — no per-version dates available. |
| Fork source `itlwm/hal_iwx/` @ `e4857ff` | — | — | Spot checks only (scan command usage); fork behavior otherwise taken from prior audit reports (IDs cited). |
| Prior audit reports | — | — | `10-iwx-hal-audit.md`, `12-itl80211-controlplane-audit.md`, `13-itl80211-dataplane-audit.md`, `00-repo-state.md`. |

Kernel-version note: this mainline snapshot has **restructured the iwlwifi config model**. The historical `iwlwifi_cfg so_a0_gf_a0_cfg` symbols no longer exist; configs are now split into MAC configs (`cfg/ax210.c`) + RF configs (`cfg/rf-gf.c`), and the firmware filename is **composed at runtime** from the hardware's MAC type/step and RF-ID. Where older literature cites `so_a0_gf_a0` static cfgs, this audit cites the current equivalent.

---

## Linux iwlwifi architecture for AX211 (summary)

Linux iwlwifi is a three-layer stack: a **transport** layer (`pcie/`) owning the PCIe DMA rings, MSI-X, context-info/IML gen3 firmware load and PNVM plumbing; a **firmware runtime** layer (`fw/`) owning firmware parsing, notification-wait machinery, dump collection, ACPI/UEFI regulatory tables; and an **op-mode** driver. For AX211 the op-mode is **`iwlmvm`** (mvm/) — the new `iwlmld` op-mode (mld/) is selected only for Wi-Fi-7-capable families (`iwl_drv_is_wifi7_supported()`, `iwl-drv.c:181-185`: `device_family >= IWL_DEVICE_FAMILY_BZ && RF >= FM`), so AX211 (AX210 family, GF RF) stays on MVM. Above it, **mac80211** implements the MLME state machine and **wpa_supplicant** (user space) owns scanning policy, roaming decisions, SAE/FT/802.11v BTM. Firmware-assisted features (scan, PS, WoW, rate control/TLC) are requested by the driver via versioned UMAC commands (e.g. scan request versions v12–v17 selected by `fw_capa`), with the firmware doing channel scheduling, dwell adaptation, and power management. The driver pins exactly one firmware API per family (min==max, e.g. 89 for so-a0-gf-a0 in this snapshot) and refuses older files, so driver and firmware always ship as a matched pair.

---

## Key subsystem analyses

### 1. Device identification (so-a0-gf-a0 family)

- PCI ID table: `pcie/drv.c:iwl_hw_card_ids` — "Ty/So devices" block, lines 491–498:
  - `0x51F0` → `iwl_so_long_latency_mac_cfg` (**AX211**, the target machine's 8086:51F0)
  - `0x51F1` → `iwl_so_long_latency_imr_mac_cfg` (IMR variant)
  - `0x54F0` → `iwl_so_long_latency_mac_cfg` (AX211 refresh)
  - `0x7AF0`, `0x7F70` → `iwl_so_mac_cfg`; `0x7A70` → `iwl_so_long_latency_imr_mac_cfg` (So with different strap latency classes)
  - `0x2725` → `iwl_ty_mac_cfg` (Ty = AX411-class MAC)
- MAC config `iwl_so_long_latency_mac_cfg` (`cfg/ax210.c:100-110`): `device_family = IWL_DEVICE_FAMILY_AX210`, `integrated = true`, `low_latency_xtal = true`, `xtal_latency = 12000`, `ltr_delay = IWL_CFG_TRANS_LTR_DELAY_2500US`, `umac_prph_offset = 0x300000`. The **integrated flag** is the CNVi (integrated-on-PCH) marker; discrete cards (e.g. AX200 `iwl_ax200_mac_cfg`, `cfg/22000.c:99-105`) lack it and instead set `bisr_workaround`.
- RF identification is from `CSR_HW_RF_ID`; RF config `iwl_rf_gf` (`cfg/rf-gf.c:31-46`): `uhb_supported = true` (6 GHz), `nvm_type = IWL_NVM_EXT`, `num_rbds = IWL_NUM_RBDS_HE`, `led_mode = IWL_LED_RF_STATE`, ucode API min/max 100/100 (overridden for AX210-family MACs, see §2).
- Human names via `iwl_dev_info` table: `pcie/drv.c:1019` `IWL_DEV_INFO(iwl_rf_gf, iwl_ax211_name, RF_TYPE(GF))` → `"Intel(R) Wi-Fi 6E AX211 160MHz"` (`cfg/rf-gf.c:62`); Killer variants at `drv.c:1033-1034`.
- Firmware name is composed at runtime in `iwl_drv_get_fwname_pre()` (`iwl-drv.c:187-292`): MAC type `IWL_CFG_MAC_TYPE_SO` → `"so"` with step forced 'a' (`:218-222`), RF type `IWL_CFG_RF_TYPE_GF` → `"gf"` with step 'a' (`:268-271`), CDB suffix "" for non-CDB → **`iwlwifi-so-a0-gf-a0`** (`:287-289`). This is why no static `so_a0_gf_a0` config symbol exists anymore.
- Fork comparison: fork's device table (prior finding DRV-IWX-001/002) hard-codes 19 IDs and embeds firmware for only some; Linux's MAC+RF model derives everything (fw name, integrated/discrete, LTR, xtal) from silicon straps, so it cannot mismatch fw blob vs. device.

### 2. Firmware (API version discipline)

- Driver-side range: `iwl_get_ucode_api_versions()` (`iwl-drv.c:298-323`) intersects MAC base params and RF cfg ranges. For so-a0-gf-a0: `iwl_ax210_base.ucode_api_min/max = 89/89` (`cfg/ax210.c:13-16,74-75`) vs `iwl_rf_gf` 100/100 → **API 89 only** (RF range discarded because `cfg->ucode_api_min (100) > base->ucode_api_max (89)`, `iwl-drv.c:313-319`). `iwl_request_firmware()` (`:325-387`) starts at max and **decrements** only across supported APIs — with min==max there is exactly one candidate file: `iwlwifi-so-a0-gf-a0-89.ucode`. Newer families (BZ/SC/DR) use a "core release" numbering scheme (`ENCODE_CORE_AS_API()`, `iwl-config.h:222`) with a fallback rule at `iwl-drv.c:352-353`.
- `MODULE_FIRMWARE` for the family: `IWL_FW_AND_PNVM(IWL_SO_A_GF_A_FW_PRE, IWL_AX210_UCODE_API_MAX)` (`cfg/ax210.c:134`) — note **and PNVM**: the driver also declares `iwlwifi-so-a0-gf-a0.pnvm` as a required external artifact.
- linux-firmware WHENCE (`refs/linux-firmware/WHENCE`): so-a0-gf-a0 entries at lines 774-775 (pnvm), 852-853 (-72), 900-901 (-73), 948-949 (-74), 1052-1081 (-77, -78, -79, -81, -83, -84, -86, -89). Latest: **`iwlwifi-so-a0-gf-a0-89.ucode`, Version 86.a67023b2.0** (WHENCE:1080-1081). **API 68 is no longer shipped** (pruned). No behavioral notes are recorded in WHENCE for this family (no special verbatim notes).
- Fork: embeds `iwlwifi-so-a0-gf-a0-68.ucode` (1,533,812 B, release string `core66_LinADVP...core66_LinADLPV::01d30b0c`, AUDIT-1/00-repo-state) — 21 API versions behind current linux-firmware. See Firmware-version analysis section.

### 3. Scan architecture (`mvm/scan.c`, 3,646 lines)

Linux builds firmware scan requests from a stack-provided `struct cfg80211_scan_request` (regular) or `cfg80211_sched_scan_request` (scheduled), normalized into `struct iwl_mvm_scan_params` (`mvm/scan.c:82-109`) which carries ssids/channels/match_sets/**scan_plans**/**scan_6ghz_params**/flags. Command building is **versioned**: `iwl_scan_umac_handlers[] = { v17, v16, v15, v14, v12 }` (`:2736-2743`) — newest fw capability wins; each version re-shapes general/probe/channel parameter blocks (e.g. `iwl_mvm_scan_umac_v14_and_above`, `:2527+`).

Key structural elements:

- **Scan types + timing** — `scan_timing[]` (`:59-80`): UNASSOC (0/0), WILD (suspend 30 / out 120 ms), MILD (120/120), FRAGMENTED (95/44), FAST_BALANCE (30/37). Selection is dynamic per scan: `_iwl_mvm_get_scan_type()` (`:220-267`) picks FRAGMENTED under high traffic or low-latency, FAST_BALANCE when DCM with a P2P GO, MILD at medium load, WILD otherwise — i.e. **the off-channel budget adapts to current traffic** (`iwl_mvm_get_traffic_load()` reads the TCM traffic classifier).
- **Dwell parameters** — `iwl_mvm_scan_umac_dwell()` (`:1292-1389`) / `_v11` (`:1400-1444`): active/passive dwell (IWL_SCAN_DWELL_ACTIVE/PASSIVE), fragmented dwell, **adaptive-dwell** fields: `adwell_default_n_aps` (2.4/5 GHz), `adwell_default_hb_n_aps`, per-scan `adwell_max_budget` (directed vs. full-scan budgets), `scan_priority`, per-LMAC (LB/HB) `max_out_time`/`suspend_time`. Channel-entry `n_aps_override` for GO-friendly/social channels (`:1520-1586`).
- **Fragmented scan** — flag `IWL_UMAC_SCAN_GEN_FLAGS_V2_FRAGMENTED_LMAC1` + `gp->num_of_fragments[SCAN_LB_LMAC_IDX] = IWL_SCAN_NUM_OF_FRAGS` (`:2392-2395`): the channel list is split into fragments so the radio returns to the BSS between fragments — this is how Linux scans while associated without dropping voice/low-latency traffic.
- **Scheduled scan (NL80211)** — `iwl_mvm_sched_scan_start()` (`:3077-3165+`): multi-plan support (`params.scan_plans` = `cfg80211_sched_scan_plan` iterations+interval), match sets, `delay` (trimmed to 16-bit), **6 GHz non-PSC channels are stripped** from the channel list (`:3147-3156`). **Offload profiles** are programmed separately by `iwl_mvm_config_sched_scan_profiles()` (`:521-604`): `SCAN_OFFLOAD_UPDATE_PROFILES_CMD` uploads one profile per match-set with `ssid_index`, permissive cipher/auth bitmap (`IWL_AUTH_ALGO_PSK|8021X|SAE|8021X_SHA384|OWE`), `network_type ANY`, `client_bitmap SCAN_CLIENT_SCHED_SCAN`, and any-beacon-notify for wildcard sets; firmware then raises **MATCH_FOUND_NOTIFICATION** (`fw/api/commands.h:304`) handled by `iwl_mvm_rx_scan_match_found()` (`mvm/scan.c:353-358`) → `cfg80211_sched_scan_results()`. These are the "LOOKUP profile triggers."
- **6 GHz discovery (RNR/colocated)** — the driver does not blind-scan 6 GHz: for a "6 GHz scan" (RNR-derived), `iwl_mvm_umac_scan_fill_6g_chan_list()` (`:1682-1754`) fills short-SSID + BSSID filter arrays (`pp->short_ssid[]` via crc32 of the SSID, `pp->bssid_array[]`) from `cfg80211_scan_6ghz_params` (collocated AP info parsed by cfg80211 from RNR IEs); `iwl_mvm_umac_scan_cfg_channels_v7_6g()` (`:1757-1960`) per-channel maps `short_ssid_bitmap`/`bssid_bitmap`, skips **non-PSC channels** when there is no RNR info (`:1787-1789`), honors `unsolicited_probe_on_chan`, PSD values, `psc_no_listen`, and `force_passive` for hidden SSIDs (capa `HIDDEN_6GHZ_SCAN`).
- **6 GHz passive fallback** — `iwl_mvm_scan_6ghz_passive_scan()` (`:2001-2088`): when all 6 GHz channels are NVM-disabled (no 6 GHz known), a **wildcard scan with ≥4 channels on a station interface**, after reset/resume or an expiry interval, temporarily enables **passive scan on PSC channels only** (capa `PASSIVE_6GHZ_SCAN`; appended by `iwl_mvm_scan_umac_fill_ch_p_v7`, `:2464-2493`). This is the "discover 6 GHz APs for the first time" path.
- **Offload flags & EBS** — `iwl_mvm_scan_umac_flags_v2()` (`:2090-2147`): FORCE_PASSIVE when no direct SSIDs, USE_ALL_RX_CHAINS for directed (roaming) scans, FRAGMENTED, `pass_all` vs. match filtering, iter notifications. EBS (enhanced busy scan) usage decided in `iwl_mvm_scan_use_ebs()` (`:846-872`).
- **Robustness** — a watchdog `SCAN_TIMEOUT` delayed work `iwl_mvm_scan_timeout_wk()` (`:2698-2707`) force-NMIs the firmware if a regular scan never completes; `iwl_mvm_check_running_scans()` (`:2628+`) prevents concurrent scan-type conflicts.
- **CSME coexistence** — `iwl_mvm_mei_limited_scan()`/`iwl_mvm_mei_scan_work()` (`:2745-2790`) let CSME (vPro) filter/limit scan results when the ME owns the radio.

Fork comparison (prior findings): the fork sends a single `SCAN_REQ_UMAC` (`ItlIwx.cpp:8061 iwx_umac_scan`, sizes v1/v8/v12/v14 at `:7979-8000`) — one-shot per net80211 `SCAN` state, no scan plans, no match profiles, no adaptive dwell (fixed dwell fields), no fragmentation, no RNR/colocated filtering (fork's net80211 has no 6 GHz band at all — DRV-11C-014), and with no pending join the driver **loops scans forever** (DRV-11C-003), with no scan timeout NMI and no MEI/CSME awareness.

### 4. Roaming

- **Host-driven by design**: mac80211 + wpa_supplicant own roaming. `grep roam` in `mvm/` finds only beacon-filter hysteresis knobs (`bf_roaming_energy_delta`, `bf_roaming_state` in `mvm/power.c:39-42,79,799-802` — beacon-filter dampening, not roaming) and CSME `roaming_forbidden` events (`mvm/ops.c:1129-1136,1191` — ME tells the driver when the owner forbids roaming). There is **no firmware reassociation engine** wired into the MVM opmode.
- Candidate scan: a directed scan (single SSID) automatically sets `USE_ALL_RX_CHAINS` to improve hearing the target AP's beacons (`mvm/scan.c:2097-2106`).
- **Connection keep-alive / beacon loss**: mac80211 tracks `beacon_loss_count` (default 7, `net/mac80211/mlme.c:71-73`), runs a timer (`:4346`, `:4945-4947`) and reports `ieee80211_cqm_beacon_loss_notify` → wpa_supplicant triggers roam/scan. The driver forwards MISSED_BEACONS notifications from firmware.
- **802.11r (FT)**: auth type `WLAN_AUTH_FT` accepted by mac80211 (`mlme.c:5521`, `:9989-9990`), FT elements allowed in (re)assoc (`:2020-2021`); wpa_supplicant performs the over-the-DS/over-the-air exchange and mac80211 sends the reassoc (`:2693-2695`).
- **802.11k/v**: neighbor reports and BTM requests are processed in wpa_supplicant; mac80211 merely cooperates (BTM noted at `mlme.c:8862` in the context of MLO). No kernel-side candidate list exists; `wpa_supplicant` bgscan/`bgscan-simple`/`bgscan-learn` modules implement background scanning for roaming.
- **Association protection during (re)association**: `iwl_mvm_protect_assoc()` (`mvm/mac80211.c:2601-2624`) and `iwl_mvm_protect_session()` (`mvm/time-event.c:645+`) reserve firmware time events / **session protection** (`SESSION_PROTECTION_CMD`, `time-event.c:756,1157,1462-1488`) so the BSS is not dropped mid-auth; scheduled-scan match profiles can wake the host to roam (`MATCH_FOUND`).
- Fork comparison: roaming effectively disabled — `IEEE80211_F_DESBSSID` latched for the association blocks both bgscan triggers and candidate selection (DRV-11C-002); roam is always full AUTH + 4-way handshake, no 11r/11v (DRV-11D-017); driver-internal reassociation only; association is protected only by its own session-protect commands; no CQM/beacon-loss contract to a supplicant because the supplicant is in-driver.

### 5. Power management

- **Per-vif MAC power (PS)**: `iwl_mvm_power_build_cmd()` (`mvm/power.c:345-464`) sends `MAC_PM_POWER_TABLE` (v2): keep-alive ≥ 3×DTIM (`:365-368`), `POWER_SAVE_ENA` always when PS enabled, `POWER_MANAGEMENT_ENA` + SMPS when vif->ps, **LPRX** (long-preamble RX, low-power listen) with RSSI threshold at 10/60 Mbps beacons (`:389-394`), PS rx/tx data timeouts (default vs. D3 vs. short-P2P), skip-DTIM (LP scheme: 2 periods; D3: up to 900 TU DTIM interval, `:297-343`). Compare fork: PS always-on with fixed flags, beacon-filter and DTIM-skip effectively dead (DRV-IWX-016).
- **U-APSD**: `iwl_mvm_power_configure_uapsd()` (`power.c:122-212`): per-AC `uapsd_ac_flags` from the AP's WMM, QNDP TID selection, `ADVANCE_PM_ENA`, **snooze** mode when all 4 ACs are U-APSD (snooze interval/window, heavy TX/RX thresholds), `UAPSD_MISBEHAVING_ENA` + runtime detection of misbehaving APs (`iwl_mvm_power_uapsd_misbehaving_ap_notif`, `:548`; re-check on every assoc via `iwl_mvm_power_vif_assoc`, `:515-523`); per-vif allowance rules (`iwl_mvm_power_allow_uapsd` + iterators `:219-296`). Fork: none (DRV-IWX-016).
- **Device power**: `iwl_mvm_power_update_device()` (`:481-514`) — `POWER_TABLE_CMD` device flags (PS enable, 32 kHz clock validity, `NO_SLEEP_TILL_D3` on cmd ver ≥ 7), coordinated with `mvm->ps_disabled` (set by low-latency/debugfs).
- **PS/BA interplay**: `iwl_mvm_power_update_ps/ba()` (`:880-991`) re-sends device power and BA-wait parameters when PS state changes.
- **Beacon filter**: `iwl_mvm_enable_beacon_filter()` (`:845+`) installs `BEACON_FILTER_CONFIG` with CQM RSSI hysteresis (`bf_energy_delta`, `bf_roaming_energy_delta`, `bf_roaming_state`, `bf_temp_threshold`...) — firmware forwards only beacons that matter (big power saver). Fork: beacon filter compiled out (`#ifdef notyet`, DRV-IWX-016).
- **WoW (D3)**: `mvm/mac80211.c:737-755` advertises `WIPHY_WOWLAN_MAGIC_PKT | DISCONNECT | EAP_IDENTITY_REQ | RFKILL_RELEASE | NET_DETECT | SUPPORTS_GTK_REKEY | GTK_REKEY_FAILURE | 4WAY_HANDSHAKE`, plus packet patterns (20 patterns, 16–128 B) and net-detect match sets. `mvm/d3.c` implements it: `iwl_mvm_suspend()` (`d3.c:1370+`), D3 image switch `iwl_mvm_switch_to_d3()` (`:883`), RSC/TSC programming (`iwl_mvm_wowlan_config_rsc_tsc`, `:451`), KEK/KCK rekey material (`iwl_mvm_wowlan_config_key_params`, `:994`), TKIP handling (`:515`), wake-packet reporting `iwl_mvm_report_wakeup_reasons()` (`:1447`), net-detect query (`:2507-2617+`), key-counter/IGTK/BIGTK conversion on resume (`:2027-2134`, `:1817`). Sleep is a **D3 image + offloads**, not a firmware reload. Wake restores keys/RSC and reports reasons.
- **Protocol offloads**: `mvm/offloading.c` — ARP/IPv6-NS offload via `iwl_mvm_send_proto_offload()`, IPv6 address change tracking (`iwl_mvm_ipv6_addr_change`, `d3.c:41`).
- **LTR**: PCIe LTR is read from devcap (`pcie/trans.c:220-223`), `iwl_pcie_is_ltr_enabled()`; gen-2+ devices use fw-based LTR: `iwl_mvm_config_ltr()` (`mvm/fw.c:843-853`) sends `LTR_CONFIG` only when the trans LTR is enabled, and the call is **skipped entirely when capa `SET_LTR_GEN2` exists** (`fw.c:1883-1884`, firmware handles LTR itself). Integrated (CNVi) init also programs `SOC_CONFIGURATION_CMD` with xtal latency and LTR delay values from the MAC cfg (fork has this too, DRV-IWX-013).
- **SAR / BIOS power tables**: `fw/acpi.c` reads `WRDS` (static SAR, profile 1), `EWRD` (dynamic SAR profiles), `WGDS` (geo SAR), `PPAG`, `WSTS/WGDS`-adjacent tables, plus **DSM functions** (`fw/regulatory.h:134-149`: disable SRD, Indonesia 5.2, **enable 6E**, regulatory config, 11ax enablement, UNII-4, energy-detection threshold, RFI config...). Application in `mvm/fw.c`: `iwl_mvm_sar_select_profile()` (`fw.c:856-924`, default profile 1,1 at `iwl_mvm_sar_init`, `:1696-1698`), `iwl_mvm_sar_geo_init()` (`:987-1055`), `iwl_mvm_get_sar_geo_profile()` (`:926`), `SAR_OFFSET_MAPPING_TABLE_CMD` (`:525-548`), reduce-power via `iwl_pnvm_load_reduce_power_to_trans()` (UEFI `UEFI_WRDS/EWRD` equivalents in `fw/uefi.c`). PPAG gated by a DMI approved-vendor list (`fw/regulatory.c:46,339-351`). Fork: **zero SAR/PPAG/GEO support** (DRV-IWX-016) — TX power on the macOS side is unmanaged by BIOS SAR limits (regulatory-compliance exposure on a SAR-constrained chassis).

### 6. TX/RX & aggregation

- **TVQM queue lifecycle**: AX211 (gen3, `iwl_mvm_has_new_tx_api()`) allocates queues dynamically per TID via `iwl_mvm_sta_alloc_queue_tvqm()` (`mvm/sta.c:895-927`) → `iwl_mvm_tvqm_enable_txq()` (`:845-893`) → `iwl_trans_txq_alloc()` → `iwl_pcie_gen2_txq_alloc()` (`pcie/tx-gen2.c:1016-1106`): DMA ring + bc-table allocated, then `SCD_QUEUE_CONFIG_CMD` (v3/v4: `IWL_SCD_QUEUE_ADD` with tfdq/bc dram addresses, cb_size, sta_mask, tid) or legacy `SCD_QUEUE_CFG` (`TX_QUEUE_CFG_ENABLE_QUEUE`); **on firmware failure the allocation retries with the queue size halved down to 16** (`tx-gen2.c:1044-1055`); response carries the assigned queue id (`iwl_pcie_txq_alloc_response`).
- **Release**: `iwl_mvm_disable_txq()` (`sta.c:351-442`) — for the new TX API sends `SCD_QUEUE_CONFIG_CMD` with `IWL_SCD_QUEUE_REMOVE` (sta_mask+tid) when `sta_remove_requires_queue_remove`, then `iwl_trans_txq_free()` → `iwl_txq_dyn_free()` (`tx-gen2.c:1108-1131`) → `iwl_txq_gen2_free()` (DMA freed, queue_used bit cleared). Every agg-stop/sta-removal path funnels here (`iwl_mvm_sta_tx_agg_stop` `:3341-3412`, `iwl_mvm_rm_sta` `:2075+`, `iwl_mvm_remove_sta_queue` `:484-590`).
- **Queue sizing**: base `max_tfd_queue_size = 65536` with per-STA negotiated `IWL_DEFAULT_QUEUE_SIZE_HE` for BA queues (`cfg/ax210.c:59`), i.e. full-size aggregation queues; mgmt queue min size 128/`min_txq_size` (`sta.c:852-858`).
- **ADDBA/agg**: mac80211 initiates; `iwl_mvm_mac_ampdu_action()` (`mvm/mac80211.c:1007-1070`) dispatches TX_START/STOP/FLUSH/OPER/RX_START/STOP/...; `iwl_mvm_sta_tx_agg_start/oper/stop/flush` (`sta.c:3083/3188/3341/3414`) maintain a per-TID state machine (IWL_AGG_OFF→STARTING→ON), SSN bookkeeping from reclaimed frames, and re-enable aggs after queue re-mapping (`sta.c:1466-1471`). After roam/disassoc, mac80211's `ieee80211_stop_tx_ba_cb_irqsafe` completes teardown and a new association re-runs ADDBA — queue IDs are **reused** because removal returns them to the firmware allocator.
- **Rate control**: firmware TLC — `iwl_mvm_rs_fw_rate_init()` (`mvm/rs-fw.c:573`) builds the per-sta `TLC_MNG_CONFIG_CMD` with supported HT/VHT/HE/EHT MCS-NSS tables (`rs_fw_set_supp_rates`, `:366`), chains, bandwidth/sgi flags (`:12-111`), and receives `TLC_MNG_UPDATE_NOTIF` feedback (`:414`). Linux exposes no minstrel for this device (fw-owned), consistent with the fork (DRV-11D-007).
- Fork comparison: fork never removes TVQM queues (`iwx_ampdu_tx_stop` sets only `qid = INVALID`, DRV-IWX-011) → fwqid monotonically increases; after ~64 roam/sleep cycles allocation fails and ADDBA is refused permanently. Linux's matched ADD/REMOVE lifecycle plus `sta_remove_requires_queue_remove` handling directly evidences that the leak is a fork defect, not a firmware limitation. Additionally the fork caps gen3 agg rings at 256 TFDs due to an unresolved freeze bug (DRV-IWX-010) where Linux uses the full HE BA queue size.

### 7. Recovery

- **FW error containment**: `iwl_mvm_nic_error()` (`mvm/ops.c:1964-1989`) aborts notification waits, deletes debug timers, dumps the fw error log, and sets `HW_RESTART_REQUESTED` — but **does not itself reinit**. `iwl_mvm_sw_reset()` (`:2008-2064`) decides: for modern families (> 8000, incl. AX211) the driver **does not call `ieee80211_restart_hw()`** unless the debug policy requires a restart — the firmware performs internal recovery (fw self-reset) and the driver merely reports the event; explicit `ieee80211_restart_hw` is limited to family ≤ 8000 or debug-required restarts (`:2053-2061`). INIT-ucode and WoWLAN-image asserts never restart (`:2033-2037`).
- **Dump collection**: `iwl_mvm_dump_error()` → `iwl_fw_error_collect()` (`fw/dbg.c:2220+`, dump work `iwl_fw_error_dump_wk`, `:2303`), with error-log buffer capture for post-restart recovery info (`ops.c:2039-2051`).
- **Command-queue safety**: transport reports `IWL_ERR_TYPE_CMD_QUEUE_FULL` separately (`ops.c:1972-1973`); notification-wait machinery (`fw/notif-wait.c`) is aborted wholesale on error so no waiter sleeps forever — contrast the fork's per-slot `commandSleep` leak (DRV-IWX-009).
- **RFKILL**: `iwl_mvm_set_rfkill_state()` (`ops.c:1901+`) maps hw/sw rfkill to `wiphy_rfkill_set_hw_state()`; ME/CSME can override rfkill (`iwl_mvm_mei_rfkill`, `:1112-1126`); rfkill transitions stop/start the device through the normal interface state machine, not an error reinit.
- **CSME/COEX**: full `mei/` layer (SAP protocol) + `mvm/coex.c` BT coex; `iwl_mvm_mei_scan_filter_init` / mei scan work (`scan.c:2745-2790`), ownership handoff on rfkill, connection info sharing for CSME-owned sessions. Fork: BT coex hard-coded to WIFI-only (DRV-IWX-013 evidence), no MEI.
- Fork comparison: any error (SW_ERR/HW_ERR/CT_KILL/state-machine failure) triggers full stop + firmware reload via `init_task` (DRV-IWX-017), visible as link flaps; Linux contains errors and lets the fw self-recover while keeping the interface up.

### 8. Crypto/keys

- **Key install**: `iwl_mvm_mac_set_key` → per-sta `STA_KEY` commands; cipher coverage includes CCMP, **GCMP-128/256** (`STA_KEY_FLG_GCMP`, `mvm/sta.c:3602-3606`), TKIP, WEP; **IGTK/BIGTK for MFP are offloaded to firmware** (`iwl_mvm_send_mgmt_igtk`, `sta.c:3690-3760`: keyidx 4-7, CMAC/BIP-GMAC-128/256, receive_seq_cnt PN), and hw-decrypt status is honored on RX. MFP is implemented in mac80211 (`net/mac80211/mfp` handling in `mlme.c`; AES-CMAC/GMAC SW fallback in `aes_cmac.c`/`aes_gmac.c`) with the driver only installing keys.
- **GTK rekey offload**: `iwl_mvm_set_rekey_data()` (`mvm/d3.c:19-39`) stores KEK/KCK/replay_ctr from wpa_supplicant; during D3 the firmware performs group rekey and 4-way handshake offload (`WOWLAN_KEK_KCK_MATERIAL`, GTK_REKEY_FAILURE wake); on resume `iwl_mvm_d3_update_keys()` (`d3.c:1817`) reads back new keys/counters into mac80211.
- **SAE**: not in the kernel. wpa_supplicant does SAE (WPA3-Personal) and passes only the resulting PMK; mac80211 merely carries auth frames (`WLAN_AUTH_SAE` external auth API, `mlme.c:5431` sae_need_confirm handling). OWE/FILS similarly host-side (FILS offload exists in mac80211 for capable drivers: `fils_aead.c`).
- Fork comparison: in-driver OpenBSD supplicant (PSK/EAPOL only), no SAE (DRV-11D-003), no PMF/IGTK path (DRV-11D-004), no GCMP cipher representation (DRV-11D-002); GTK rekey handled in-driver host-side (works, DRV-11C-020) but no WoW rekey.

### 9. PNVM & GEO

- **PNVM load flow** (`fw/pnvm.c`): `iwl_pnvm_load()` (`:468-493`): if sku_id empty → return 0 (**skip entirely**); `iwl_pnvm_load_pnvm_to_trans()` (`:372-417`) selects source via `iwl_select_pnvm_source()` (`:297-318`): non-Intel SKU → BIOS(UEFI) package; family < AX210 → none; family > AX210 → embedded; **AX210 family (AX211) + GF RF → EXTERNAL file** `iwlwifi-so-a0-gf-a0.pnvm` (`iwl_pnvm_get_from_fs`, `:253-293`, `firmware_request_nowarn`). The TLV walker (`iwl_pnvm_parse`, `:180-252`) matches the fused `sku_id` against `IWL_UCODE_TLV_PNVM_SKU` sections; **on mismatch it records `trans->fail_to_parse_pnvm_image` and returns -ENOENT, and all later calls short-circuit** (`:382-393`) — no repeated parse attempts. `iwl_pnvm_load_reduce_power_to_trans()` (`:419-466`) loads the UEFI reduced-power table similarly. Only then is the **doorbell kicked** (`UREG_DOORBELL_TO_ISR6_PNVM`, `:487-489`) and the completion awaited with `MVM_UCODE_PNVM_TIMEOUT = HZ/4` (**250 ms**, `fw/pnvm.h:12`). Timeout propagates as a hard init failure (`mvm/fw.c:407-413`).
- **GEO/SAR integration**: GEO profiles are not a separate command flow — `WRDS/EWRD` tables + `WGDS` geo table are read from ACPI (`fw/acpi.c:605-1123`) and pushed via `iwl_mvm_sar_geo_init()`/`iwl_mvm_sar_select_profile()` (`mvm/fw.c:856-1055`) with firmware-version-dependent command shapes (`IWL_UCODE_TLV_API_SAR_TABLE_VER`). UEFI variants exist for all tables (`fw/uefi.c`).
- Fork comparison (DRV-IWX-008): the fork's PNVM has a dead `goto out` (both paths fall through), kicks the doorbell even after a failed read, and burns a **2000 ms** workloop-gate sleep waiting for a notification that cannot arrive on SKU mismatch — then treats the timeout as a fatal init error. Linux's 250 ms timeout, fail-flag short-circuit, and per-source fallback (BIOS→FS, and skip when sku_id empty) evidence that the fork's 2 s dead-wait is a defect (not required by the firmware), though the *hard-error-on-timeout* behavior is equivalent (both fail init when the fw never signals PNVM complete).

---

## Findings

### LINUX-001: MAC+RF runtime-derived config vs. fork's hard-coded device/firmware tables
- Classification: **ARCHITECTURAL DIFFERENCE**
- Severity: Info / Confidence: High
- Evidence (Linux): `pcie/drv.c:491-498` (0x51F0/0x51F1/0x54F0 → so MAC cfgs), `cfg/ax210.c:100-110` (`iwl_so_long_latency_mac_cfg`, integrated CNVi), `iwl-drv.c:187-292` (`iwl_drv_get_fwname_pre` composes `iwlwifi-so-a0-gf-a0` from silicon straps).
- Evidence (fork): DRV-IWX-001/002/003 (19-ID static table; 4 advertised IDs with no embedded firmware; last-match-wins matching loop).
- Analysis: Linux cannot select a firmware that doesn't match the silicon because both fw name and cfg derive from `hw_rev`/`hw_rf_id`. The fork's static tables permit mismatch (some advertised IDs can never attach). This is structural, not a per-bug fix, though it motivates Tier-2 trimming of the fork's table to the two AX211-relevant blobs.

### LINUX-002: Firmware currency — Linux pins API 89 (matched pair), fork frozen at API 68
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY (fork)** (currency/maintenance dimension)
- Severity: Medium / Confidence: High
- Evidence (Linux): `cfg/ax210.c:13-16,74-75` + `iwl-drv.c:298-323` (API min=max=89 for so-a0-gf-a0); WHENCE:1080-1081 (`iwlwifi-so-a0-gf-a0-89.ucode`, version 86.a67023b2.0); API 68 absent from WHENCE.
- Evidence (fork): embedded `iwlwifi-so-a0-gf-a0-68.ucode` (AUDIT-1; 00-repo-state.md:87).
- Analysis: see "Firmware version analysis" — 21 API versions of fixes/features are unavailable to the fork without a HAL port; conversely Linux's strict pinning means its driver cannot run the fork's 68 blob either (would refuse: "no suitable firmware found").

### LINUX-003: Versioned scan command family (v12–v17) with adaptive dwell vs. fork's fixed single-shot SCAN_REQ_UMAC
- Classification: **ARCHITECTURAL DIFFERENCE**
- Severity: Info / Confidence: High
- Evidence (Linux): `mvm/scan.c:2736-2743` (handler table), `:1292-1389` (adaptive dwell + budgets), `:220-267` (traffic-dependent scan type incl. FRAGMENTED/FAST_BALANCE).
- Evidence (fork): `ItlIwx.cpp:7979-8000` (v1/v8/v12/v14 sizes), DRV-11C-001 (firmware-driven single scan per state machine step).
- Analysis: Linux treats scan cost as a function of current traffic (TCM load) and firmware capability version; the fork always issues one full-size request regardless. Behavioral gap, not a defect per se — but the fork's lack of a scan watchdog (`iwl_mvm_scan_timeout_wk` force-NMI, `scan.c:2698-2707`) means a wedged scan wedges the interface instead of the firmware.

### LINUX-004: 6 GHz discovery (RNR/colocated + PSC + passive fallback) is a first-class subsystem; fork has no 6 GHz at all
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY (fork)**
- Severity: High (feature) / Confidence: High
- Evidence (Linux): `mvm/scan.c:1682-1754` (short-SSID/BSSID filter arrays), `:1757-1960` (per-channel RNR mapping, non-PSC skip), `:2001-2088` + `:2464-2493` (passive 6 GHz PSC fallback), `cfg/rf-gf.c:32` (`uhb_supported`), DSM `DSM_FUNC_ENABLE_6E` (`fw/regulatory.h:138`).
- Evidence (fork): DRV-11C-014 / DRV-11D-001 (6 GHz excluded at NVM channel table `#ifdef notyet`; net80211 has no 6 GHz band).
- Analysis: On the same AX211 silicon, Ubuntu can see 6 GHz APs; macOS-fork cannot. Fixing this in the fork requires net80211 band support + scan-API plumbing well beyond the HAL (cfg80211 parses RNR and computes colocated params in Linux; the fork's net80211 has no equivalent parser). This is the single largest capability gap.

### LINUX-005: Scheduled scan with firmware match profiles (LOOKUP triggers) vs. fork's busy re-scan loop
- Classification: **ARCHITECTURAL DIFFERENCE** (with a defect-flavored fork consequence)
- Severity: Medium / Confidence: High
- Evidence (Linux): `mvm/scan.c:521-604` (`SCAN_OFFLOAD_UPDATE_PROFILES_CMD` profile upload), `:3077-3165` (sched-scan start, plans, 6 GHz PSC-only filter), `iwl_mvm_rx_scan_match_found` (`:353-358`).
- Evidence (fork): DRV-11C-003 (no pending join → driver scans forever; 30 s dead-BSSID lockout; no idle park).
- Analysis: Linux's answer to "keep looking without burning the radio" is firmware offload with host wakeups; the fork's answer is an infinite host-driven scan loop that monopolizes the single workloop gate. The fork could emulate bounded scheduled-scan semantics on API 68 (the command exists there) without a firmware upgrade.

### LINUX-006: Host-driven roaming with 11r/11v + beacon-loss contract vs. fork's latched F_DESBSSID and full re-auth
- Classification: **ARCHITECTURAL DIFFERENCE** (with missing capability components in the fork)
- Severity: High / Confidence: High
- Evidence (Linux): mac80211 `mlme.c:71-73,4346,4945-4947` (beacon loss → CQM), `:5521,9989-9990` (FT auth), `mvm/ops.c` (no fw roaming engine — only `bf_roaming_*` beacon-filter hysteresis, `power.c:39-42`), `mvm/scan.c:2097-2106` (directed scan = roaming scan, all-RX-chains), session protection `mvm/time-event.c:1415+`.
- Evidence (fork): DRV-11C-002 (F_DESBSSID latch disables roaming), DRV-11D-017 (no 11r; roam = full AUTH+4WHS).
- Analysis: Linux's roaming quality comes from the stack (wpa_supplicant) not the driver; the fork's design (in-driver everything) makes parity require implementing candidate selection, FT, and BTM inside the kext. The F_DESBSSID latch is a fork policy decision that must be undone first (prior finding) before any roaming improvement is possible.

### LINUX-007: WoWLAN offload vs. fork's sleep = full stop + firmware reload
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY (fork)**
- Severity: Medium / Confidence: High
- Evidence (Linux): `mvm/mac80211.c:737-755` (advertised WoW flags), `mvm/d3.c:883` (D3 image switch), `:994` (kek/kck), `:1370` (suspend), `:1447` (wakeup reasons), `:2507+` (net detect), `mvm/offloading.c` (ARP/NS offload).
- Evidence (fork): DRV-IWX-016 (no WoW/D3; sleep = disable → wake = full re-enable + reload, PNVM wait included).
- Analysis: Wake latency on Ubuntu is sub-second with the D3 image; the fork reloads the full regular image chain (seconds) and depends on macOS re-issuing `enable()`. Structural to the port (OpenBSD if_iwx has no D3 either).

### LINUX-008: U-APSD/snooze/LPRX/skip-DTIM station power toolbox vs. fork's unconditional fixed PS
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY (fork)**
- Severity: Medium / Confidence: High
- Evidence (Linux): `mvm/power.c:122-212` (U-APSD config incl. QNDP TID + snooze + misbehaving-AP detection), `:297-343` (skip-DTIM policies), `:345-464` (LPRX, keep-alive, PM flags), `:845+` (beacon filter w/ CQM).
- Evidence (fork): DRV-IWX-016 (PS always on; beacon filter `#ifdef notyet`; U-APSD only TLV constants).
- Analysis: The fork neither saves maximal power (no U-APSD/snooze/beacon-filter) nor offers low-latency mode (no PS disable path). Given the target is a laptop, this is a real battery/experience gap, but porting beacon-filter alone (its command exists in API 68) is self-contained.

### LINUX-009: BIOS SAR/PPAG/GEO/TAS/DSM regulatory-power stack vs. fork's absence
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY (fork)** — regulatory-compliance exposure
- Severity: High (compliance) / Confidence: High
- Evidence (Linux): `fw/acpi.c:605-1123` (WRDS/EWRD/WGDS/PPAG readers), `fw/regulatory.h:134-149` (DSM functions incl. ENABLE_6E), `mvm/fw.c:856-1055,1696-1698,1924-1926` (SAR/geo apply at init), `fw/regulatory.c:339-351` (PPAG DMI gate).
- Evidence (fork): DRV-IWX-016 ("zero matches for SAR/PPAG/GEO in the HAL").
- Analysis: On the same chassis Ubuntu enforces BIOS SAR limits; the fork transmits with unmanaged TX power. Whether MSI's BIOS actually ships WRDS/EWRD for this SKU is a runtime question (UNRESOLVED), but the driver-side capability gap is source-verifiable. macOS lacks the ACPI DSM/UEFI interfaces anyway, so a fix would need to embed or parse tables from elsewhere — non-trivial on this OS.

### LINUX-010: TVQM queue lifecycle (ADD→REMOVE→free) vs. fork's never-released queues
- Classification: **CONFIRMED DEFECT (of the fork, evidenced by Linux's different+working approach)** — corroborates DRV-IWX-011
- Severity: High / Confidence: High (fork side), High (Linux side)
- Evidence (Linux): `mvm/sta.c:351-442` (`iwl_mvm_disable_txq`: `IWL_SCD_QUEUE_REMOVE` + `iwl_trans_txq_free`), `:3341-3412` (agg stop → state machine → disable), `pcie/tx-gen2.c:1016-1106` (alloc with size-halving retry) and `:1108-1131` (`iwl_txq_dyn_free`).
- Evidence (fork): DRV-IWX-011 (`iwx_ampdu_tx_stop` = two lines; no remove cmd; monotonic fwqid; aggregation refused after ~64 cycles).
- Analysis: Linux proves the firmware expects explicit queue removal and that a balanced lifecycle survives unlimited roam/sleep cycles. The fork's leak is a driver defect with a concrete fix (send remove + free ring), not a firmware limitation.

### LINUX-011: TVQM queue sizing — full HE BA queue size vs. fork's 256-slot cap with unresolved freeze
- Classification: **UNRESOLVED** (fork-side DMA/freeze issue) / Severity: Medium / Confidence: Medium
- Evidence (Linux): `cfg/ax210.c:59` (`min_ba_txq_size = IWL_DEFAULT_QUEUE_SIZE_HE`), `pcie/tx-gen2.c:1044-1055` (graceful size-halving on alloc failure — no freeze workaround needed).
- Evidence (fork): DRV-IWX-010 (explicit TODO: gen3 256-frame aggregation freeze on macOS; ring capped to 256 as workaround).
- Analysis: Linux runs the same TVQM allocator with much larger rings on the same firmware family without special handling; the fork's freeze is therefore plausibly host-side (IOMMU/coalescing/alignment in the kext), but cannot be root-caused from source alone. Runtime triage required.

### LINUX-012: Error containment (fw self-recovery, no default reinit) vs. fork's full-reinit-on-any-error
- Classification: **ARCHITECTURAL DIFFERENCE** (amplifying fork defect consequences)
- Severity: Medium / Confidence: High
- Evidence (Linux): `mvm/ops.c:1964-1989` (nic_error: abort waits, dump, request restart bit), `:2008-2064` (`iwl_mvm_sw_reset`: no `ieee80211_restart_hw` for family > 8000 unless debug policy), `fw/notif-wait.c` (central abort of all waiters).
- Evidence (fork): DRV-IWX-017 (any SW_ERR/HW_ERR/CT_KILL/state error → stop + reload), DRV-IWX-009 (1 s sync-command slot leak on timeout).
- Analysis: Linux's model keeps the interface up across firmware self-recovery and aborts pending waits wholesale; the fork converts transients into multi-second link flaps and leaks command-ring slots when they time out. The wait-abort pattern (`iwl_abort_notification_waits`) is the blueprint for fixing DRV-IWX-009 without touching command timeouts.

### LINUX-013: Crypto parity — GCMP/IGTK/MFP + GTK-rekey offload + host SAE vs. fork's CCMP-only in-driver supplicant
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY (fork)**
- Severity: High (WPA3-era interop) / Confidence: High
- Evidence (Linux): `mvm/sta.c:3602-3606` (GCMP), `:3690-3760` (IGTK/BIGTK fw offload), `mvm/d3.c:19-39,1817` (rekey offload + resume key sync), `net/mac80211/mlme.c:5431` (SAE external auth to wpa_supplicant).
- Evidence (fork): DRV-11D-002 (no GCMP), DRV-11D-003 (no SAE), DRV-11D-004 (no MFP/IGTK), DRV-11C-020 (in-driver GTK rekey works).
- Analysis: The firmware (even API 68) supports GCMP/IGTK — the fork's net80211 simply cannot represent the ciphers. SAE requires a supplicant rework (SAE commit/confirm frames + PWE derivation) that the OpenBSD-derived code never had.

### LINUX-014: PNVM flow — 250 ms timeout, fail-flag short-circuit, source fallback vs. fork's dead-goto + 2 s dead-wait
- Classification: **CONFIRMED DEFECT (of the fork, evidenced by Linux's different+working approach)** — corroborates DRV-IWX-008
- Severity: Medium / Confidence: High
- Evidence (Linux): `fw/pnvm.c:372-417` (fail flag short-circuits retries), `:297-318` (source selection incl. FS file for AX211+GF), `:477-478` (skip when sku_id empty), `fw/pnvm.h:12` (`MVM_UCODE_PNVM_TIMEOUT = HZ/4`), `mvm/fw.c:407-413` (timeout = init failure, same as fork).
- Evidence (fork): DRV-IWX-008 (dead `goto`, doorbell kicked after failed read, 2000 ms gate-held wait, hard failure loop).
- Analysis: Linux proves the doorbell-kick-after-failure is not fatal *if* the wait is short and cached-failure prevents repeat burns; both stacks treat a true PNVM timeout as fatal. The fork's 2 s × retry-loop burn on the shared workloop gate is the defect; fix is 4 lines (respect the failed-read path + shorten wait).

### LINUX-015: Synchronous-command infrastructure — central notif-wait + cmd-queue-full handling vs. fork's per-slot sleeps
- Classification: **ARCHITECTURAL DIFFERENCE** (that makes a fork defect visible)
- Severity: Medium / Confidence: Medium-High
- Evidence (Linux): `fw/notif-wait.c` + `iwl_abort_notification_waits` (`mvm/ops.c:1969`), `IWL_ERR_TYPE_CMD_QUEUE_FULL` path (`ops.c:1972`), per-command timeouts up to seconds (e.g. scan/alive waits), RX handler table `mvm/ops.c:200+`.
- Evidence (fork): DRV-IWX-009 (1 s `commandSleep`, ring slot leaks on timeout, ENOSPC lockout), DRV-IWX-018 (single workloop gate).
- Analysis: Linux never sleeps a shared gate per-command — waits are waiter-objects aborted centrally. The fork can adopt a similar pattern (pending-response list + abort sweep on error) without changing its threading model.

### LINUX-016: MSI-X per-CPU RX vectors vs. fork's compiled-out MSI-X
- Classification: **ARCHITECTURAL DIFFERENCE**
- Severity: Low-Medium (perf) / Confidence: High
- Evidence (Linux): `pcie/trans.c:1607-1670` (`iwl_pcie_set_interrupt_capa`: `pci_enable_msix_range`, num_rxqs scaling, shared-vector masks), `:1137+` (`iwl_pcie_conf_msix_hw`).
- Evidence (fork): DRV-IWX-005 (MSI-X implemented but `if (0)` — single-vector MSI).
- Analysis: Same silicon, Linux gets RSS-scaled RX queues across CPUs; fork serializes all RX on one interrupt source on the single workloop. Contributes to the fork's throughput ceiling under load. Enabling the existing MSI-X code is a candidate fork fix if stability is validated.

### LINUX-017: LED, RFKILL, CSME/MEI — platform integration surface
- Classification: **ARCHITECTURAL DIFFERENCE** (LED/RFKILL) + **UNSUPPORTED OR INCOMPLETE CAPABILITY (fork)** (CSME)
- Severity: Low / Confidence: High
- Evidence (Linux): `mvm/led.c` (fw LEDS_CMD or rf-state blink), `mvm/ops.c:1901+` (rfkill → wiphy), `mei/` SAP protocol + `mvm/ops.c:1129-1136,1191` (CSME rfkill/roaming-forbidden/scan-filter).
- Evidence (fork): DRV-IWX-013 (BT coex WIFI-only), no LED/rfkill infra (airportitlwm uses native airport status).
- Analysis: Mostly N/A on macOS (WCL owns status LED/rfkill UX), but CSME coexistence matters on vPro chassis: if the ME owns the radio, Linux negotiates; the fork would just fail. The MSI Modern 14 is consumer (non-vPro), so practical impact is likely nil — UNRESOLVED without runtime DMI check.

### LINUX-018: Beacon filter with CQM hysteresis — biggest single PS win the fork leaves disabled
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY (fork)** (subsumed under LINUX-008 but called out: command exists in API 68)
- Severity: Medium / Confidence: High
- Evidence (Linux): `mvm/power.c:845-878` (`iwl_mvm_enable_beacon_filter`), `:22-84` (bf cmd build incl. `bf_roaming_energy_delta/state`, escape/less-match thresholds), MISSED_BEACONS handling feeding CQM.
- Evidence (fork): DRV-IWX-016 (`#ifdef notyet` around beacon filter; directed probe on missed-beacon instead).
- Analysis: Independent of U-APSD, the beacon filter alone cuts beacon-processing wakeups; the fork's missed-beacon → directed-probe path (`ItlIwx.cpp:6205-6248`) is a poor substitute that consumes airtime. Low-risk fork fix since the API-68 firmware supports it.

### LINUX-019: Rate control — both stacks delegate to firmware TLC; equivalence confirmed
- Classification: **ARCHITECTURAL DIFFERENCE (none — parity)**
- Severity: Info / Confidence: High
- Evidence (Linux): `mvm/rs-fw.c:573` (`iwl_mvm_rs_fw_rate_init`), `:414` (`iwl_mvm_tlc_update_notif`); minstrel unused for this device.
- Evidence (fork): DRV-11D-007 (fw TLC sole controller; MiRA/AMRR dead code).
- Analysis: No gap. The fork's TLC feedback handling (`TLC_MNG_UPDATE_NOTIF` → ni_txmcs) mirrors Linux's. Dead host rate-ctrl code in the fork is hygiene, not behavior.

### LINUX-020: Recovery of BA sessions after roam — explicit mac80211 teardown/restart contract vs. fork's silent teardown
- Classification: **ARCHITECTURAL DIFFERENCE** (with fork defect DRV-11D-009/010 adjacent)
- Severity: Medium / Confidence: High
- Evidence (Linux): `mvm/sta.c:3341-3412` (stop → `ieee80211_stop_tx_ba_cb_irqsafe` → driver disables agg + queue), mac80211 `agg-tx.c` drives the full ADDBA/DELBA exchange so the AP is always told; restart on new assoc re-runs ADDBA.
- Evidence (fork): DRV-11D-010 (roam/deauth tears TX BA with no DELBA to AP), DRV-11D-009 (RX reorder buffers leak), DRV-11D-023 (dangling driver state on roam).
- Analysis: Linux's BA lifecycle is symmetric (notify peer, free fw/driver resources, rebuild); the fork's is silent+leaky. Combined with LINUX-010 this explains "degrades after roaming/sleep" reports better than any firmware-age hypothesis.

---

## Correspondence table

| Feature | Linux mainline iwlwifi (what / where) | AirportItlwm fork (prior-audit facts) | Difference classification |
|---|---|---|---|
| Scan types + 6 GHz | Versioned UMAC scan v12–v17 (`mvm/scan.c:2736`); 5 scan types incl. FRAGMENTED/FAST_BALANCE chosen by traffic load (`:220-267`); adaptive dwell + budgets (`:1292-1444`); RNR/colocated 6 GHz short-SSID/BSSID filtering, PSC-only for non-RNR (`:1682-1960`); passive-6GHz PSC fallback (`:2001-2088`) | Single SCAN_REQ_UMAC (v8/12/14 shapes) per net80211 state step; no dwell adaptation; scans loop forever with no pending join (DRV-11C-001/003); 6 GHz excluded at NVM `#ifdef notyet` (DRV-11D-001) | ARCHITECTURAL DIFFERENCE + UNSUPPORTED CAPABILITY (6 GHz) |
| Scheduled scan | Full NL80211 sched-scan: plans, delay, match profiles uploaded via SCAN_OFFLOAD_UPDATE_PROFILES (`scan.c:521-604`), MATCH_FOUND ntf → host (`:353`), 6 GHz non-PSC stripped (`:3147`) | None; emulated by infinite rescan loop on host (DRV-11C-003) | ARCHITECTURAL DIFFERENCE |
| Roaming + 11r/k/v | Host-driven (wpa_supplicant); mac80211 beacon-loss/CQM (`mlme.c:4945`), FT auth (`:9989`), BTM in supplicant; directed scan = all-chains RX (`scan.c:2097-2106`); session protection during assoc (`time-event.c:1415+`); CSME roaming-forbidden events | Roaming disabled: F_DESBSSID latched (DRV-11C-002); roam = full AUTH+4WHS, no 11r/11v (DRV-11D-017); driver-internal reassociation only | ARCHITECTURAL DIFFERENCE + MISSING CAPABILITY |
| WoW | D3 image + magic/disconnect/net-detect/GTK-rekey/4-way/patterns/ARP-NS offloads (`mac80211.c:737-755`, `d3.c`, `offloading.c`) | None; sleep = full stop + firmware reload on wake (DRV-IWX-016) | MISSING CAPABILITY |
| U-APSD | Per-AC config, QNDP TID, snooze mode, misbehaving-AP detection (`power.c:122-296`) | None (TLV constants only) (DRV-IWX-016) | MISSING CAPABILITY |
| SAR (WRDS/EWRD) | ACPI/UEFI tables read + applied at init, profile 1 default, geo (WGDS) (`fw/acpi.c`, `mvm/fw.c:856-1055,1696`) | None (DRV-IWX-016) — TX power unmanaged by BIOS SAR | MISSING CAPABILITY (compliance exposure) |
| LTR | PCIe LTR detect (`trans.c:220`); fw LTR_CONFIG when trans LTR on, skipped with capa SET_LTR_GEN2 (`fw.c:843-853,1883-1884`); LTR delay from MAC cfg in SOC_CONFIGURATION | Present (CSR write + fw cmd gated on sc_ltr_enabled, SET_LTR_GEN2 skip) (DRV-IWX-013/016) | Rough parity (architectural similarity) |
| PNVM / GEO | External .pnvm file for AX211+GF, fail-flag short-circuit, empty-SKU skip, 250 ms wait (`fw/pnvm.c`); GEO/SAR via ACPI | Embedded .pnvm; dead goto, doorbell after failed read, 2 s gate-held wait, hard-fail loop (DRV-IWX-008); no GEO/SAR | CONFIRMED DEFECT (fork) for flow; MISSING CAPABILITY for GEO |
| FW API version | Driver pins API 89 (min=max) so-a0-gf-a0 (`cfg/ax210.c:13-16` + `iwl-drv.c:298-323`); WHENCE ships 72→89, latest 89 (v86.a67023b2.0) | Embedded API 68 (core66 build) — 21 versions stale; HAL matches only API-68 TLV layout | UNSUPPORTED/INCOMPLETE (currency); upgrade requires HAL port |
| Rate control | Firmware TLC (`rs-fw.c:573,414`); minstrel unused | Firmware TLC; host RA dead code (DRV-11D-007) | Parity |
| Aggregation lifecycle | mac80211 ADDBA/DELBA + driver state machine; agg stop → DELBA + queue disable + free (`sta.c:3341`, `mac80211.c:1007`); re-ADDBA on new assoc | Silent teardown, no DELBA (DRV-11D-010); RX reorder leak (DRV-11D-009); 1 s agg-enable delay/30 s backoff (DRV-11D-008) | ARCHITECTURAL DIFFERENCE + SUSPECTED DEFECT (fork) |
| TVQM/queues | ADD/REMOVE balanced; size-halving retry; free on stop (`sta.c:351-442`, `tx-gen2.c:1016-1131`); HE-size BA queues | Queue leak on ampdu_tx_stop (DRV-IWX-011); 256-slot cap freeze workaround (DRV-IWX-010); one shared non-agg queue | CONFIRMED DEFECT (fork, LINUX-010) + UNRESOLVED (freeze) |
| Recovery | FW self-recovery; driver aborts waits + dumps; no default restart for AX211 family (`ops.c:1964-2064`) | Any error → full stop/reload (DRV-IWX-017); 1 s sync sleeps leak slots (DRV-IWX-009) | ARCHITECTURAL DIFFERENCE (amplifies fork defects) |
| MFP/SAE/GCMP | GCMP in fw (`sta.c:3602`), IGTK/BIGTK offload (`:3690`), MFP in mac80211, SAE in wpa_supplicant | No MFP/SAE/GCMP (DRV-11D-002/003/004); in-driver supplicant | MISSING CAPABILITY |
| GTK rekey | FW offload during D3 (KEK/KCK), resume sync (`d3.c:19-39,1817`) | Host-side in-driver rekey works (DRV-11C-020); no offload | Parity while awake; MISSING during sleep |
| MSI-X | `pci_enable_msix_range`, per-CPU RX queues, shared-vec fallback (`trans.c:1607-1670`) | Implemented but `if (0)` → single MSI (DRV-IWX-005) | ARCHITECTURAL DIFFERENCE (perf) |
| LED | fw LEDS_CMD / rf-state LED (`mvm/led.c`) | None (WCL owns UI status) | Architectural difference (N/A on macOS) |
| RFKILL | hw/sw rfkill → wiphy; ME override (`ops.c:1901,1112`) | rfkill toggle → full reinit (DRV-IWX-017 evidence) | Architectural difference |
| Coex/CSME | Full mei/SAP: ownership, scan filter, rfkill, roaming-forbidden (`mei/`, `scan.c:2745-2790`) | BT coex WIFI-only, no MEI (DRV-IWX-013) | MISSING CAPABILITY (impact unverified on this chassis) |
| Power management (general) | Per-vif MAC power cmd v2: keep-alive, LPRX, skip-DTIM, PS timeouts, SMPS; device power cmd; beacon filter + CQM (`power.c:22-991`) | Fixed always-on PS; beacon filter dead; wake = reload (`DRV-IWX-016`) | MISSING CAPABILITY (substantial battery/perf surface) |

---

## Firmware version analysis

**Facts verifiable from the repos:**

1. Current mainline iwlwifi supports **exactly API 89** for so-a0-gf-a0 (`cfg/ax210.c:13-16` base params intersected with `iwl_rf_gf` in `iwl-drv.c:298-323`). The driver firmware-selection loop (`iwl-drv.c:350-355`) starts at max and decrements; with min==max there is no fallback.
2. Current linux-firmware (WHENCE, snapshot 2026-11-18) ships `iwlwifi-so-a0-gf-a0-{72,73,74,77,78,79,81,83,84,86,89}.ucode` + `iwlwifi-so-a0-gf-a0.pnvm`. Latest: **API 89, version 86.a67023b2.0**. **API 68 has been removed** from linux-firmware (superseded).
3. The fork embeds **API 68** (one coherent build, `core66_LinADLPV::01d30b0c`) — 21 API versions behind the newest shipped firmware.

**Ubuntu 2024-2026 (inferred, not verifiable from these repos):** Ubuntu ships mainline-based kernels plus matching `linux-firmware` snapshots; since the kernel driver pins min=max per release, the shipped API follows the kernel's pin at that time. By the same driver-source rule, Ubuntu releases of 2024–2026 would ship roughly: 24.04 LTS era → API 72–74; 24.10 → 77–78; 25.04 → 81–83; 25.10+ → 86–89. These numbers cannot be confirmed from the local snapshots (no distro package metadata present) — treat as **moderate-confidence inference**. What is certain: any 2024+ Ubuntu on this machine runs firmware substantially newer than API 68, and "works well" per the audit context.

**What API 68→89 implies for the fork (source-verifiable deltas):** the driver side of this snapshot contains capability/API gates introduced after 68 that the fork's HAL cannot even parse, e.g. scan v14+ channel config with per-channel flags/PSD (`scan.c:1787-1811`), `IWL_UCODE_TLV_CAPA_PASSIVE_6GHZ_SCAN` path, hidden-6GHz scan, SET_LTR_GEN2, SAR table v2, IGTK/BIGTK command shapes, `sta_remove_requires_queue_remove` semantics, plus years of fw-internal fixes (6 GHz/MLO-era power, EMLSR-era infra, security/regulatory corrections) that are not itemizable from source since firmware changelogs are not in the repos. Concretely for the fork: staying on 68 forfeits post-2022 firmware fixes but guarantees TLV/command-struct compatibility with the ported OpenBSD code.

**Upgrade risk vs. benefit for the fork:**
- Benefit: unknown-magnitude stability/power/aggregation fixes; possibly the fw-side of the TVQM/aggregation edge cases; 6 GHz regulatory handling (only useful if net80211 gains 6 GHz).
- Risk (high): every API bump changes command/ntf layouts (scan v12→v17 alone re-shapes four parameter blocks); the fork's HAL must port each structure or pin capa gates; a half-port wedges bring-up. Historical OpenBSD if_iwx practice (single API per device family) exists precisely to avoid this.
- Recommendation implied by evidence: **fix driver-side lifecycle defects first (LINUX-010/014, DRV-IWX-008/009/011) — they reproduce on API 68 and are the credible root causes of the field symptoms; treat a firmware upgrade as a separate, large work package.**

---

## Open questions

1. **Ubuntu firmware confirmation** — exact `linux-firmware` version / API on the Ubuntu partition (needs `dmesg | grep 'loaded firmware'` or dpkg query; not derivable from these repos).
2. **MSI Modern 14 C12MO BIOS tables** — does its ACPI expose WRDS/EWRD/WGDS/PPAG (would quantify the SAR-compliance exposure of the fork)? Runtime-only.
3. **PNVM SKU match** — does the fork's embedded `iwlwifi-so-a0-gf-a0.pnvm` (41,808 B) match this unit's fused sku_id, or does every boot burn the 2 s DRV-IWX-008 timeout? (Firmware logs at runtime would settle it.)
4. **Gen3 256-TFD freeze root cause** (DRV-IWX-010 / LINUX-011) — host-side DMA vs. firmware-side? Would need controlled runtime reproduction; Linux's larger rings + size-halving allocator suggest host-side suspicion.
5. **CSME presence** — whether this specific chassis's ME asserts ownership/rfkill paths the fork can't negotiate (non-vPro consumer SKU suggests no, unverified).
6. **Firmware behavioral changelog 68→89** — Intel does not publish per-API changelogs in linux-firmware; the precise fix list the fork is missing is unknowable from source alone (mark any claim accordingly).

---

*End of AUDIT-2d. Companion documents: 00-repo-state.md, 10-iwx-hal-audit.md, 11-airport-integration-audit.md, 12-itl80211-controlplane-audit.md, 13-itl80211-dataplane-audit.md.*
