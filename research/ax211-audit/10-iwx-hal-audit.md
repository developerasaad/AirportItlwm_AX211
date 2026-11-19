# AUDIT-2a: IWX HAL Deep Forensic Source Audit — AirportItlwm (AX211 / Sequoia 15.8.2)

**Task ID:** AUDIT-2a
**Date:** 2026-11-18
**Repo:** `/home/z/my-project/AirportITLWM` @ `e4857ff` (tag `v2.4.0-ax211-reduced`)
**Target hardware:** MSI Modern 14 C12MO, Intel Wi-Fi 6E AX211 (PCI 8086:51F0, "So"-family MAC + "GF" RF), x86_64, Debug build
**Scope:** `itlwm/hal_iwx/` — the sole remaining HAL in this reduced fork

---

## Method

| File | Lines | Coverage |
|---|---:|---|
| `itlwm/hal_iwx/ItlIwx.cpp` | 13,919 | **100%** — read in full, sequential chunks (lines 1–13,920) |
| `itlwm/hal_iwx/ItlIwx.hpp` | 496 | 100% |
| `itlwm/hal_iwx/if_iwxvar.h` | 789 | 100% |
| `itlm/hal_iwx/if_iwxreg.h` | 8,145 | targeted skim (~15%): queue/family constants, RF-ID/REV macros, power/LTR flags, TLV IDs, notification structs |
| `include/FwData.h` | 73 | 100% (fw embedding + zlib inflate helpers) |
| `include/HAL/*` (ItlHalService/ItlDriverInfo/ItlDriverController/ItlTx) | 341 | 100% (HAL upward contract; `ItlIwm.hpp` does not exist — hal_iwm was deleted by reduce commit `eb815e4`) |
| `itlwm/firmware/` | 15 blobs | full listing + byte counts (AUDIT-1 verified) |
| Context | — | `AirportItlwm/AirportItlwm.cpp` power/enable paths (lines 500–930), `itl80211/openbsd/net80211/timeout.c` (splnet/timer model), cross-checks vs `refs/upstream-itlwm@7204c69` for inheritance analysis |

All line numbers below refer to `ItlIwx.cpp` unless another file is named. Classifications are **source-only**; no runtime evidence was available in this audit.

---

## Architecture summary

The IWX HAL is a single 13.9k-line C++ class `ItlIwx : ItlHalService, ItlDriverInfo, ItlDriverController` (`ItlIwx.hpp:144`) — a mechanical port of OpenBSD `if_iwx.c` (rev 1.45, 2020) onto IOKit, wrapping one giant `struct iwx_softc com` (`if_iwxvar.h:595-770`). **Upward contract** (`include/HAL/ItlHalService.hpp`): `attach/detach(IOPCIDevice*)`, `enable/disable(IONetworkInterface*)` (mapped to BSD `DVACT_*` activation at `ItlIwx.cpp:260-285`), plus `ItlDriverInfo` getters (fw version/name/country, noise, NSS, TX queue size) and `ItlDriverController` (scan flags, multicast). It registers itself as the net80211 (OpenBSD stack, ported under `itl80211/`) callback table at `iwx_attach` (`13758-13774`: newstate/ampdu/key/edca/prot/chw hooks). **Downward**: direct CSR/PRPH MMIO (`IWX_READ/IWX_WRITE` on one mapped BAR), a single MSI vector via `IOFilterInterruptEventSource` (`13519-13533`), zlib-embedded firmware pulled from `fwList[]` (`FwData.h:36-44`), and a mailbox command protocol on TX queue 0 (`iwx_send_cmd`, `6510-6728`). All concurrency is serialized on one IOWorkLoop gate: every task/command/timer entry re-dispatches through `getMainCommandGate()->runAction` when `!inGate()`; the OpenBSD `splnet()/splx()` calls are **no-ops** (`itl80211/openbsd/net80211/timeout.c:32-39`).

---

## Findings

### DRV-IWX-001: PCI device support table — 19 IDs, AX211 correctly present as So-family
- Classification: VALIDATED CORRECT BEHAVIOR
- Severity: Info, Confidence: High
- Evidence: `iwx_devices[]` `12377-12406` (19 `{IWL_PCI_DEVICE(dev, PCI_ANY_ID, trans_cfg)}` entries); trans cfgs `12175-12227` (`iwl_so_trans_cfg`, `iwl_so_long_latency_trans_cfg` family=AX210, integrated); full `iwl_dev_info_table[]` `12765-13338` (~230 entries keyed by device/subdevice/MAC-type/RF-type/step/CDB); `iwx_match()` `13340-13346`; attach-time matching `13550-13643`.
- Analysis: AX211 on 0x51F0 → `iwl_so_long_latency_trans_cfg` (device_family=AX210 ⇒ all "gen3" paths) and, after dev_info matching, `iwlax211_2ax_cfg_so_gf_a0` → firmware `iwlwifi-so-a0-gf-a0-68.ucode` (`12243-12249`). Family split at runtime: `IWX_DEVICE_FAMILY_22000` (Qu/QuZ/AX200/AX201, gen2) vs `IWX_DEVICE_FAMILY_AX210` (So/SnJ/Ty/Ma = AX210/AX211/AX411, gen3) — every gen-specific branch keys off `sc->sc_device_family >= IWX_DEVICE_FAMILY_AX210`. The 19 driver-table IDs exactly equal the 19 IDs in `AirportItlwm/Info.plist` `IOPCIMatch` (AUDIT-1 §6). Verified trace for the audit target (0x51F0 + GF RFID): final cfg = `iwlax211_2ax_cfg_so_gf_a0` — correct.

### DRV-IWX-002: Four advertised PCI IDs can never load firmware (blobs not embedded)
- Classification: CONFIRMED DEFECT
- Severity: Medium, Confidence: High
- Evidence: `Info.plist IOPCIMatch` includes `0x2720, 0x2726, 0x2729, 0x7E40` (AUDIT-1 §6). Device cfgs referenced by these IDs use firmware that is **not** in `itlwm/firmware/`:
  - 0x2720 (QnJ) → `iwl_qnj_b0_hr_b0_cfg`/`iwl9560_qnj_b0_jf_b0_cfg` → `iwlwifi-QuQnj-b0-*-48.ucode` (`12504-12516`, `12668-12680`)
  - 0x2726 (SnJ) stock subdevices → `iwlax211_cfg_snj_gf_a0`/`iwl_cfg_snj_hr_b0`/`iwl_cfg_snj_a0_jf_b0` → `iwlwifi-SoSnj-a0-*-63.ucode` (`12295-12315`)
  - 0x2729 / 0x7E40 (MA) → `iwl_cfg_ma_a0_*` → `iwlwifi-ma-a0-*-63.ucode` (`12317-12357`, dev entries `13181-13206`)
  `iwx_read_firmware` fails at `getFWDescByName(sc->sc_fwname) == NULL` (`1461-1466`) → `iwx_preinit` fails (`13780-13782: goto fail5`) → `attach()` returns false.
- Analysis: On those machines the kext matches the PCI device (IOProbeScore 2000), then fails during firmware load, leaving Wi-Fi dead and potentially blocking a competing driver. Harmless to the AX211 target but a correctness defect and prime Tier-2 reduction target (see inventory).

### DRV-IWX-003: dev_info matching loop never breaks — "last match wins" instead of Linux's "first match wins"
- Classification: STRONGLY SUSPECTED DEFECT
- Severity: Medium, Confidence: Medium
- Evidence: `13560-13594`: `for (i = 0; i < ARRAY_SIZE(iwl_dev_info_table); i++) { if (all-fields-match) { sc->sc_cfg = dev_info->cfg; ...log... } }` — **no `break;`**. Linux `iwlwifi/pcie.c` (and OpenBSD `if_iwx.c`) stop at the first (most specific) match; here every subsequent less-specific wildcard entry that also matches overwrites `sc->sc_cfg`.
- Analysis: I traced all matching entries for the audit target: 0x51F0+GF lands on `iwlax211_2ax_cfg_so_gf_a0` whether or not Killer subdevice entries (0x1671/0x1672, `12899-12900`) matched earlier, because the generic "So with GF" entry (`13294-13298`) maps to the same cfg — so AX211 is *accidentally* correct. But for Qu-family devices, subdevice entries (`12781+`, Qu-b0 cfgs) are silently overwritten by later silicon-step generic entries (`13093-13114`, Qu C0 cfgs), making firmware selection depend on table ordering rather than specificity; any future table edit can silently change which ucode a given laptop loads. Inherited verbatim from upstream laobamac (refs/upstream-itlwm@7204c69, same lines).

### DRV-IWX-004: Qu C0 / QuZ step-fixup hack compares raw `sc_hw_rev` against a type-constant
- Classification: CONFIRMED DEFECT
- Severity: Low, Confidence: High
- Evidence: `13611`: `if (sc->sc_hw_rev == CSR_HW_REV_TYPE_QU_C0)` — should be `CSR_HW_REV_TYPE(sc->sc_hw_rev) == CSR_HW_REV_TYPE_QU_C0` (the constant `0x0000338` includes reserved bit positions; raw register value also carries step bits 0-3 after the transformation at `13547-13548`). Same pattern at `13621` for QuZ.
- Analysis: The fixup at `13612-13617` is effectively dead code — equality on the raw value will almost never hold. Inherited from upstream. Mitigated in practice because the generic mac_step-matching entries (DRV-IWX-003) perform the equivalent C0 selection. Qu-family only; no AX211 impact.

### DRV-IWX-005: MSI-X fully implemented but hard-disabled (`if (0)`) — single-vector MSI only
- Classification: UNSUPPORTED OR INCOMPLETE CAPABILITY
- Severity: Low, Confidence: High
- Evidence: `13483-13489`: `if (0) { sc->sc_msix = 1; ... } else if (pci_intr_map_msi(pa, &sc->ih))` — `sc_msix` is always 0. Yet `iwx_conf_msix_hw` (`3127-3212`, full IVAR programming, ~85 lines), `iwx_intr_msix` (`12059-12146`), and MSIX branches in rfkill/interrupt helpers (`2811-2820`, `2859-2895`, `2909-2920`) are all retained.
- Analysis: Functional but single-interrupt: RX, TX completions, ALIVE, RFKILL, and errors all share one vector and one workloop serialization point (contributes to latency under load). The MSIX code is dead weight and a Tier-2 removal candidate. Not an AX211-specific regression.

### DRV-IWX-006: Firmware selection chain and the 15 embedded blobs — AX211 needs only 2
- Classification: VALIDATED CORRECT BEHAVIOR (with Tier-2 reduction opportunity)
- Severity: Info, Confidence: High
- Evidence: fwname chosen at `13638` (`sc->sc_fwname = sc->sc_cfg->fwname`); blob resolved by name from the zlib-compressed `fwList[]` (`1461-1469`, `FwData.h:33-44`); `.pnvm` companion derived by string surgery on the fwname (`2072-2081`); PNVM section applied only if SKU-id + mac_type/rf_id match (`2130-2139`, `1957-1959`). Embedded set (15 files, **16,700,476 raw bytes**): 12 `.ucode` + 3 `.pnvm`, all API-68 `core66_LinADLPV::01d30b0c` (AUDIT-1 §4).
- Analysis: For device 0x51F0 the *only* reachable firmwares are: `iwlwifi-so-a0-gf-a0-68.ucode` (+`.pnvm`) for GF radios — the actual AX211; `so-a0-gf4-a0-68` (+`.pnvm`) for Killer-AX411 subdevices (0x1691/0x1692); `so-a0-hr-b0-68` (AX203-on-So) and `so-a0-jf-b0-68` (9560-on-So) for the exotic HR/JF RF combinations. **A strict AX211(0x51F0+GF) build needs 2 of 15 blobs (1,575,620 bytes of 16,700,476 = 9.4%)**; the other 13 blobs serve only non-target DIDs.

### DRV-IWX-007: Firmware decompression uses a `compressed_size * 4` output-buffer heuristic; inflate return value ignored
- Classification: UNVERIFIED IMPLEMENTATION RISK
- Severity: Low, Confidence: Medium
- Evidence: `1467-1469`: `fw->fw_rawsize = fwData->getLength() * 4; fw->fw_rawdata = malloc(...); uncompressFirmware(...)` — return value not checked (`uncompressFirmware` `FwData.h:46-70` returns false on `Z_BUF_ERROR`/corruption and leaves `*destLen` unchanged). Same pattern for PNVM with `* 20` (`2090-2092`).
- Analysis: If a future ucode inflates to >4× its compressed size, inflate fails silently and the TLV parser walks a partially-initialized heap buffer. The magic check at `1481-1487` then almost certainly rejects it (EINVAL), so blast radius is a failed load rather than memory corruption; but the missing error check hides the root cause. With the current API-68 blobs the heuristic holds.

### DRV-IWX-008: PNVM load flow — dead `goto`, doorbell kicked even when PNVM read failed, 2 s wait
- Classification: STRONGLY SUSPECTED DEFECT
- Severity: Medium, Confidence: Medium
- Evidence: `iwx_load_pnvm` `2154-2184`:
  ```c
  if (!iwx_read_pnvm(sc)) { goto out; };   /* both paths fall into out: */
  out:
      sc->sc_init_complete &= ~IWX_PNVM_COMPLETE;
      ... iwx_write_umac_prph(sc, IWX_UREG_DOORBELL_TO_ISR6, IWX_UREG_DOORBELL_TO_ISR6_PNVM);
      err = iwx_wait_notification(sc, &sc->sc_init_complete, IWX_PNVM_COMPLETE, 2000);
  ```
  The `goto out` is a no-op; when `iwx_read_pnvm` fails (e.g. SKU mismatch, `2014-2026` returns `-ENOENT`) the driver still rings the PNVM doorbell and blocks the workloop gate for up to 2 s waiting for a notification that cannot come.
- Analysis: Every boot on hardware whose fused SKU-id doesn't match a PNVM section burns a 2-second timeout inside the gated bring-up path (EWOULDBLOCK is returned but `iwx_load_ucode_wait_alive` `5041-5043` propagates it as a hard failure of `iwx_run_init_mvm_ucode` → `iwx_init_hw` failure → full stop/retry loop at `10779-10791`). This is a plausible contributor to slow/unreliable interface bring-up. Needs runtime log confirmation ("PNVM complete notification" vs timeout) on the MSI unit.

### DRV-IWX-009: Synchronous command path — 1 s sleep timeout leaks the ring slot if firmware never answers
- Classification: STRONGLY SUSPECTED DEFECT
- Severity: High, Confidence: Medium-High
- Evidence: `iwx_send_cmd` `6510-6728`. Sync completion at `6695-6706`: `commandSleep(desc, deadline /*1 s*/, THREAD_UNINT)`; on `THREAD_TIMED_OUT` → `err = EWOULDBLOCK; break;`. Cleanup at `out:` (`6721-6726`) frees the response buffer, but `txdata->flags & IWX_TXDATA_FLAG_CMD_PENDING` and `ring->queued++` (`6688-6691`) are **only** undone by `iwx_cmd_done` (`6799-6829`, from the RX thread) or `iwx_reset_tx_ring` (`2736-2776`, from stop/reset). Slot-admission check `6555-6557`: `if (ring->queued >= ring->ring_count - 1 || (txdata->flags & (PENDING|WAITING))) return ENOSPC;`
- Analysis: If the firmware acknowledges a command late, the slot self-heals when the late response arrives (response copy is skipped, `11659-11663`, then `iwx_cmd_done` runs). But if the firmware wedges *without* raising SW_ERR/HW_ERR (e.g. stuck UMAC), every timed-out command permanently consumes one of the 128 gen3 cmd-ring slots; after enough failures `iwx_send_cmd` returns ENOSPC for **all** commands, and since state-machine errors trigger full reinit via `init_task` (`10248-10254`), the visible symptom is the association/scan failure loop described in the field reports. The 1 s timeout itself is also short relative to iwlwifi's per-command timeouts for scan-related responses. Recovery ultimately depends on the 15 s TX watchdog (`10914`, `11021-11057`) or error interrupts firing.

### DRV-IWX-010: TX data path — one shared 1024-slot queue for all non-aggregated traffic; gen3 aggregation capped to 256 slots with an acknowledged freeze bug
- Classification: CONFIRMED DEFECT (known, worked around) + architecture limitation
- Severity: High, Confidence: High
- Evidence:
  - Queue selection in `iwx_tx` `6996-7014`: default `qid = sc->first_data_qid` (queue 2, the "MGMT" queue enabled in `iwx_enable_mgmt_queue` `9054-9075`); per-TID queues are used **only** when `sc_tid_data[tid].qid` valid **and** `ba_state == IEEE80211_BA_AGREED`. So pre-aggregation, management and all 4 ACs share one ring.
  - `iwx_alloc_tx_ring` `2661-2672`: for family ≥ AX210, non-cmd rings get `IWX_MIN_256_BA_QUEUE_SIZE_GEN3` = **1024** slots (reg `if_iwxreg.h:1823`).
  - The freeze workaround at `iwx_tvqm_alloc_txq` `3501-3506`: `//TODO: Here is a bug, for gen3 devices which support 256 frame aggregate into 1 A-MPDU like ax210, if the TfDs count larger than 256 than it would trigger system freeze on macOS ... here I just limit the size to 256 as the temporary solution.` with `#ifdef notyet` disabling the 1024-slot gen3 size.
  - Backpressure: `iwx_tx` `7179-7182` sets `sc->qfullmsk` past `hi_mark`; `_iwx_start_task` `10860-10863` stops the whole interface (`ifq_set_oactive`) when **any** ring is full; wake in `iwx_clear_oactive` `6045-6061` only when the ring drains below `low_mark` and the mask empties.
- Analysis: Two consequences for native macOS operation: (1) until ADDBA completes (which itself can fail, see DRV-IWX-011), all data frames contend with management frames on a single ring — a burst of traffic can block EAPOL/association frames and stall `if_start`; (2) the 256-TFD cap plus the unexplained "system freeze" note means gen3 aggregation throughput is deliberately halved vs Linux (1024) and the underlying DMA issue is unresolved. The `ac` parameter of `_iwx_start_task` is pinned `EDCA_AC_BE /* XXX */` (`10850`) — no per-AC queueing exists anywhere in the HAL.

### DRV-IWX-011: TX aggregation teardown never releases firmware/driver queues — leak across BA cycles
- Classification: STRONGLY SUSPECTED DEFECT
- Severity: High, Confidence: Medium
- Evidence: `iwx_ampdu_tx_stop` `4714-4729` in its entirety:
  ```c
  sc->sc_tid_data[tid].qid = IWX_INVALID_QUEUE;
  ic->ic_stats.is_ht_tx_ba_agreements--;
  ```
  No `IWX_SCD_QUEUE_CFG` remove/disable is sent, no `iwx_free_tx_ring` on the old queue. Each ADDBA start calls `iwx_tvqm_alloc_txq` (`3497-3526`) → `iwx_tvqm_enable_txq` (`3528-3696`) which allocates a **fresh** TVQM queue from the firmware (`IWX_TX_QUEUE_CFG_ENABLE_QUEUE`) and installs it at the returned `fwqid` (`3674-3676`, freeing the old ring only if the same index is re-issued). `iwx_rm_sta` (`7646-7679`) also sends no queue removal.
- Analysis: The firmware never learns the old queue is gone, so `fwqid` monotonically increases. After ~512/8 = 64 association/roam cycles (every RUN→SCAN→AUTH transition calls `ieee80211_stop_ampdu_tx` + `ieee80211_ba_del`, `10277-10285`), TVQM allocation must fail, after which `iwx_ba_task` refuses ADDBA (`4615-4618` → `ieee8021111_addba_resp_refuse`) and the link drops to non-aggregated throughput permanently until reboot. Additionally each abandoned queue leaves its `desc_dma/cmd_dma/bc_tbl/maps` allocated until the index is reused. This is a credible mechanism for "Wi-Fi degrades after sleep/wake or roaming" reports. Needs runtime confirmation (log line "Failed allocating TXQ" after N roams).

### DRV-IWX-012: Gen3 firmware-load error path leaks three DMA allocations
- Classification: CONFIRMED DEFECT
- Severity: Low, Confidence: High
- Evidence: `iwx_ctxt_info_gen3_init` `1157-1268`: at `1255-1258`, `if (!iwx_nic_lock(sc)) return EBUSY;` — returns without freeing `sc->prph_scratch_dma`, `sc->prph_info_dma`, `sc->iml_dma` (the `fail1/fail0` labels at `1262-1267` are bypassed). The image sections also remain via `iwx_init_fw_sec` (freed later by `iwx_load_firmware`'s `4934` only on the error path it knows about).
- Analysis: Only reachable when MAC-access handshake fails during load; leaks a few hundred KB per occurrence and, more importantly, leaves `prph_scratch_dma.vaddr` non-NULL so a subsequent `iwx_dma_contig_alloc` in the retry loop (`10779-10791`) overwrites the pointer and leaks again. Bounded by reinit frequency; contributes to long-uptime memory growth.

### DRV-IWX-013: Hardware init sequence — correct and complete for So/AX211 (gen3 path)
- Classification: VALIDATED CORRECT BEHAVIOR
- Severity: Info, Confidence: High
- Evidence (full chain, with AX211-specific branches):
  - `iwx_attach` `13441-13799`: PCIe cap lookup, "PCI retry timeout" reg 0x40 clear (`13464`), bus-master + INTx-disable clear (`13468-13474`), BAR0 map (`13476-13482`), MSI map + `IOFilterInterruptEventSource` (`13486-13533`), ICT 4 KB (`13661`), `ctxt_info_dma` sized `iwx_context_info_gen3` for family ≥ AX210 (`13648-13653`), TX rings (cmd=128 slots gen3, qid 2 = 1024, qid > 2 lazy `IWX_INVALID_QUEUE`) (`13668-13675`, `2648-2734`), RX ring 512 × 4 KB (`13677`, `2498-2558`), taskqs (`13683-13686`).
  - `iwx_preinit` `13348-13422` (first boot only, `static int attached`): `iwx_start_hw` (SW reset, persistence-bit clear skipped for ≥ AX210 `1289-1290`, APM init, L0s/L1 ASPM **disable** `3011-3018`, MSIX-conf in MSI mode `3132-3139`), `iwx_run_init_mvm_ucode(readnvm=1)` → `iwx_nvm_get` (`4785-4870`, NVM_GET_INFO rsp, regulatory v3 16-bit / v4 32-bit channel profiles, MAC from CSR strap/OTP `4746-4775`), then full `iwx_stop_device`.
  - `iwx_init_hw` `10585-10718` (per up): preinit → start_hw → `iwx_run_init_mvm_ucode(0)` → `iwx_load_ucode_wait_alive` `5027-5048` = `iwx_read_firmware` (TLV parse `1497-1865`) → `iwx_start_fw` `4946-4980` (nic_init, `IWX_CSR_MAC_SHADOW_REG_CTRL` `3413`) → `iwx_load_firmware` `4889-4944` → **gen3** `iwx_ctxt_info_gen3_init` `1157-1268`: prph_scratch (RB 4 KB + MTR 256 B format `1183-1185`), fw LMAC/UMAC/paging sections DMA'd (`iwx_init_fw_sec` `811-895`), `IWX_CSR_CTXT_INFO_ADDR/IML_DATA_ADDR/IML_SIZE` + `IWX_CSR_AUTO_FUNC_BOOT_ENA` (`1244-1251`), `IWX_UREG_CPU_INIT_RUN=1` via umac prph (`1257`); alive wait 1 s on `sc_uc.uc_intr` (`4909`); PNVM (DRV-IWX-008); `iwx_post_alive` `3698-3710` (ICT reset, full interrupt enable); then TX-ant cfg, BT coex `WIFI`-only (`10446-10456`), `SOC_CONFIGURATION_CMD` (discrete flags, LTR delay, xtal latency `10458-10495`), DQA (if capa), aux station (`7579-7617`), 3 PHY contexts, LTR config or `SET_LTR_GEN2` skip (`10669-10676`), temp thresholds, device power, LAR MCC "ZZ" (`10691-10698`), scan config, beacon filter off.
  - Alive parsing `11550-11597`: v4/v5 discrimination by payload length; v5 extracts `sku_id[]` used for PNVM matching.
- Analysis: The sequence matches iwlwifi's gen3 self-init flow (context-info + IML) closely; AX211-specific branches (`>= IWX_DEVICE_FAMILY_AX210`, `GEN3_UMAC_PRPH_OFFSET` `2210-2235`, `iwx_prph_msk` 24-bit `2186-2192`, `IWX_UMAG_SB_CPU_*` PC dump `4918-4928`) are all correctly gated. No defect found in the happy path.

### DRV-IWX-014: Command allocation/queueing mechanics — TX ring 0, wide-header, narrow-group hack
- Classification: VALIDATED CORRECT BEHAVIOR
- Severity: Info, Confidence: High
- Evidence: All host commands go through `sc->txq[IWX_DQA_CMD_QUEUE]` (=0) (`6521`); responses are copied out of the RX mbuf into a pre-allocated per-slot buffer (`6567-6583` alloc, `11681` copy, ownership handoff at `6716-6718`); "Intel inside" remap of legacy group-0 commands into `IWX_LONG_GROUP` for fw API ≥ 50 (`6585-6596`) with the inverse remap on RX (`11478-11484`, `IWX_TXDATA_FLAG_CMD_IS_NARROW`); TFD TB0/TB1 split at `IWX_FIRST_TB_SIZE`=20 B (`6662-6672`); ring kick via `IWX_HBUS_TARG_WRPTR` (`6693`). Async commands (`IWX_CMD_ASYNC`) never sleep; `IWX_CMD_WANT_RESP`+async is rejected (`6558-6559`). Error propagation: `ENXIO` when SHUTDOWN/HW_ERR/ring-unallocated (`6545-6547`), `ENOSPC` when ring full or slot pending, `EINVAL` for oversized payloads (> `IWX_MAX_CMD_PAYLOAD_SIZE` `6605-6610`).
- Analysis: Sound design; the risk is concentrated in the timeout path (DRV-IWX-009) and in the per-slot response buffer being freed while a late response is in flight (handled by the NULL check at `11659-11663`).

### DRV-IWX-015: RX path — ring, replenishment, dispatch table
- Classification: VALIDATED CORRECT BEHAVIOR (with noted gaps)
- Severity: Info, Confidence: High
- Evidence: 512-entry RX ring, 4 KB buffers via `getController()->allocatePacket` + `bus_dmamap_packet` (`5142-5194`); gen3 uses 16-byte `iwx_rx_transfer_desc` free-list + `iwx_rx_completion_desc` used-ring (`5124-5140`, `2503-2535`). Interrupt → `iwx_notif_intr` `11876-12004`: reads HW closed-idx from the 2-byte gen3 status (`11885-11889`), processes each buffer with `iwx_rx_pkt`, then writes `IWX_RFH_Q0_FRBDCB_WIDX_TRG hw & ~7` (`11902-11903`). `iwx_rx_pkt` `11433-11874` walks multiple packets per buffer for gen2 but breaks after the first for ≥ AX210 (`11866-11869`, `11427-11428` — matches gen3 one-frame-per-RB). Handled notifications (full switch `11499-11853`): `REPLY_RX_PHY_CMD`, `REPLY_RX_MPDU_CMD` (→ `iwx_rx_mpdu_mq` `5827-5986`: CRC/overrun check, A-MSDU bit clear, padding shift `memmove+mbuf_adj`, hw-decrypt status → `IEEE80211_RXI_HWDEC`, dup detection, reorder), `BA_NOTIF` (compressed BA `6063-6110` with tfd_cnt bounds check), `TX_CMD` (`6152-6203`, with `itlTxCompletionValid` window check), `MISSED_BEACONS_NOTIFICATION` (→ directed probe `6205-6248`), `ALIVE`, `STATISTICS_NOTIFICATION` (noise floor), `CT_KILL` (→ HW_ERR + reinit), PNVM/INIT complete, scan complete/iteration complete, `MCC_CHUB_UPDATE`, `REPLY_ERROR`, `TIME_EVENT_NOTIFICATION`, session-protection notif, `BAR_FRAME_RELEASE` (bounds-checked `11807-11844`), `TLC_MNG_UPDATE_NOTIF` (rate feedback → ni_txmcs/ni_txrate `9574-9631`), plus a large pass-through response-copy case for ~24 command IDs. Unhandled IDs log loudly (`11846-11852`).
- Analysis: Replenishment happens inside the processing loop (`iwx_rx_addbuf` at `11492`) so the ring never starves under load. Gaps: `RX_NO_DATA_NOTIF` ignored (`11771-11772`); no checksum validation on RX — "offload assist" on TX is only the payload-offset word (`ItlTx.hpp:58-60`), so the HAL does not actually perform HW checksum offload in either direction (must stay consistent with what the Airport layer advertises). Reorder logic is a faithful OpenBSD port with timeout-driven release (`iwx_reorder_timer_expired` `4093-4155`) and the old-SN delba workaround (`5576-5624`).

### DRV-IWX-016: Power management — always-on station PS; no WoW, no U-APSD, no SAR; sleep = full firmware reload
- Classification: UNSUPPORTED OR INCOMPLETE CAPABILITY
- Severity: Medium, Confidence: High
- Evidence:
  - Station PS unconditionally enabled: `iwx_power_build_cmd` `7389-7390` sets `IWX_POWER_FLAGS_POWER_SAVE_ENA_MSK` whenever opmode != MONITOR; `iwx_power_update_device` `7421-7422` same. No interface exists to disable PS for low latency.
  - WoW: `IWX_UCODE_TLV_SEC_WOWLAN` parsed into `IWX_UCODE_TYPE_WOW` sections (`1585-1590`) but `iwx_load_ucode_wait_alive` only ever loads `IWX_UCODE_TYPE_REGULAR` (`4899`). No D3/wowlan command anywhere (only the `IWX_CSR_UCODE_DRV_GP1_BIT_D3_CFG_COMPLETE` constant exists, reg `:815`).
  - U-APSD: only TLV capability bit definitions exist (`if_iwxreg.h:1210-1245`); no code references them.
  - SAR/BIOS: zero matches for SAR/PPAG/GEO in the HAL — no SAR profile enforcement (Linux applies ACPI SAR on AX211; absent here ⇒ TX power may exceed regulatory limits on SAR-constrained chassis, or is simply unmanaged).
  - LTR: `iwx_set_ltr` CSR write for non-integrated (`1052-1078`), `iwx_config_ltr` fw cmd gated on `sc_ltr_enabled` from PCIe DCSR2 (`3021-3027`, `5110-5122`), skipped when `IWX_UCODE_TLV_CAPA_SET_LTR_GEN2` (`10669`).
  - Kext sleep: `setPowerStateOff` → `disableAdapter` → HAL `disable()` → `DVACT_QUIESCE` → `iwx_stop` (full device stop, `AirportItlwm.cpp:900-906`, `ItlIwx.cpp:274-285`). Wake: `setPowerStateOn` only PM-acks (`AirportItlwm.cpp:908-913`); actual restart happens if/when the network stack re-`enable()`s the interface (`609-617`) → `DVACT_RESUME`+`DVACT_WAKEUP` → `iwx_set_hw_ready` + `init_task` full reinit (`13894-13919`, `13818-13867`).
- Analysis: Wake latency is a complete firmware reload (PNVM doorbell wait included, DRV-IWX-008), i.e. seconds, and correctness depends on macOS issuing `enable()` after wake — a fragile contract that matches the reported "events/power polish issues". Beacon-abort is also effectively never enabled: `iwx_power_mac_update_mode` `7409-7411` tests `IWX_POWER_FLAGS_POWER_MANAGEMENT_ENA_MSK` (bit 1) but the command only ever sets `POWER_SAVE_ENA` (bit 0) (`7390`) — matches upstream OpenBSD semantics (intentional given the beacon-filter is disabled, `9917-9929` `#ifdef notyet`), noted for completeness.

### DRV-IWX-017: Recovery/fault handling — interrupt-driven full reinit on any fatal event; aggressive state-machine error recovery
- Classification: UNVERIFIED IMPLEMENTATION RISK (design amplifies transients)
- Severity: Medium, Confidence: Medium
- Evidence: SW_ERR / FH_ERR → `iwx_nic_error` dump + `task_add(systq, &sc->init_task)` (`11976-12001`, `12086-12111`); HW_ERR → flag + reinit (`12003-12012`, `12118-12125`); CT_KILL → HW_ERR + reinit (`11619-11629`); RF-KILL toggle → reinit (`11967-11974`, `12113-12116`); TX watchdog (15 s, `10914`) → `iwx_nic_error` + reinit (`11021-11057`). `iwx_init_task` `13818-13867` = stop + conditional re-init. `iwx_newstate_task` `10248-10254`: **any** error in auth/assoc/run → `task_add(init_task)` → complete firmware restart. `iwx_init` retry loop `10779-10791` retries exactly once before giving up.
- Analysis: There is no in-place recovery (no fw-error-driven sysreset short of full `iwx_stop_device`), and no error is ever contained: a single failed session-protection or quota command during association restarts the radio, visible to macOS as a link flap. Combined with DRV-IWX-009's short command timeout this plausibly produces the "join unreliability" symptom: transient fw command slowness → timeout → full reinit → scan restart. Wedge audit: no unbounded loops found (all polls bounded, e.g. `iwx_poll_bit` `2300-2319`, `iwx_prepare_card_hw` 10×150 ms `2984-2996`); `iwx_nic_lock` is a counter with `panic` on underflow (`2347-2352`) — but see DRV-IWX-018 on dead KASSERTs (the `panic` here is a direct call, not KASSERT, so it remains live).

### DRV-IWX-018: Concurrency model — one workloop gate; `splnet()` is a no-op; all KASSERTs compile away
- Classification: CONFIRMED DEFECT (assertions dead) / VALIDATED (locking model)
- Severity: Medium, Confidence: High
- Evidence: `itl80211/openbsd/net80211/timeout.c:32-39`: `int splnet() { return 1; } void splx(int s) {}` — every `s = splnet(); ... splx(s);` pair in the HAL (≈25 sites: `iwx_sta_rx_agg` `4300`, `iwx_ba_task` `4567`, `iwx_newstate_task` `10167`, `iwx_stop` `10950`, …) provides zero mutual exclusion. Real serialization: every entry point checks `getMainWorkLoop()->inGate()` and re-dispatches via `getMainCommandGate()->runAction` (`iwx_send_cmd` `6513-6519`, `iwx_stop_device` `3270-3278`, `iwx_preinit` `13351-13357`, all five task bodies e.g. `10154-10161`, `4441-4411`, `4554-4561`, `13824-13831`); timers run through `CTimeout` on the command gate (`timeout.c:41-70`); the interrupt action runs on the same workloop. Proof that KASSERT is non-evaluating: `iwx_stop` `10966` executes `KASSERT(sc->task_refs.refs >= 1, ...)` while `struct refcnt task_refs` is commented out of `iwx_softc` (`if_iwxvar.h:603`) — this file compiles, therefore all ~25 `KASSERT`s (e.g. `818`, `2729`, `6653`, `11464`) are discarded by the macro.
- Analysis: The single-gate model is internally consistent *provided* nothing mutates `iwx_softc` off-gate. All paths I traced (ioctl, output thread, taskqs, timers, interrupt) funnel through the gate, so I found no provable race; however the dead assertions mean the original OpenBSD invariant checks (ring-slot ownership, `off == paylen`, `data->m != m0`) no longer guard anything, and any future ungated path (e.g. the `attemptAction` variant, DRV-IWX-019) silently becomes a race. Holding `iwx_nic_lock` (MAC_ACCESS_REQ register handshake) across `iwx_tvqm_alloc_txq`'s synchronous command sleep in `iwx_ba_task` (`4611-4630`) is unusual — the gate is released during `commandSleep` while the CSR handshake stays asserted; not provably harmful but diverges from iwlwifi where mailbox access is never held across waits.

### DRV-IWX-019: `iwx_start` uses `attemptAction` (non-WCL builds) — start attempts silently dropped when the gate is busy
- Classification: STRONGLY SUSPECTED DEFECT
- Severity: Medium, Confidence: Medium
- Evidence: `iwx_start` `10922-10932`:
  ```c
  #ifdef AIRPORT_WCL
      that->getMainCommandGate()->runAction(_iwx_start_task, ...);
  #else
      that->getMainCommandGate()->attemptAction(_iwx_start_task, ...);
  #endif
  ```
  `attemptAction` returns immediately with `kIOReturnBusy`-style failure if the gate is held (e.g. by a synchronous firmware command sleeping in `iwx_send_cmd`, or by `iwx_newstate_task`).
- Analysis: When the output thread's start attempt is dropped, transmission resumes only when something else re-kicks the queue — `iwx_clear_oactive` does call `ifp->iface->signalOutputThread()` (`6057-6059`, `__PRIVATE_SPI__`) on completions, which likely papers over this in most cases, but a dropped start immediately after the last completion (queue empty, no further completions) can leave frames parked in `if_snd` until the next event. The WCL build already switched to blocking `runAction`, which is telling. Candidate contributor to intermittent throughput stalls.

### DRV-IWX-020: ~21 MB static footprint of the HAL softc (512 TX rings × 1024 slots)
- Classification: CONFIRMED DEFECT (resource bloat)
- Severity: Medium, Confidence: High
- Evidence: `if_iwxvar.h:630` `struct iwx_tx_ring txq[IWX_MAX_TVQM_QUEUES];` with `IWX_MAX_TVQM_QUEUES` = 512 (`if_iwxreg.h:1756`) and each `iwx_tx_ring` embedding `struct iwx_tx_data data[IWX_MIN_256_BA_QUEUE_SIZE_GEN3]` = 1024 × ~40 B (`if_iwxvar.h:353`) plus `sc_cmd_resp_pkt[65536]` + `sc_cmd_resp_len[65536]` (`if_iwxvar.h:723-724`, ~1 MB) and `sc_iml[20480]` (`:686`). Arithmetic: 512 × (1024×40 + ring fields) ≈ 20.1 MB + 1 MB + 32×~5 KB rxba ≈ **~21.5 MB of wired kernel memory per instance before any runtime allocation**.
- Analysis: The AX211 target can create at most 8 aggregated TIDs + cmd + aux + mgmt queues — ~11 of 512 slots are ever used. On a Debug kext this is tolerable but it is 100× oversized for the stated AX211-only mission and inflates every allocation of `ItlIwx` (OSMetaClass instance). Tier-2 should size `txq[]` to the firmware's actual TVQM limit for a single-BSS STA (e.g. 16-32) or make ring data arrays pointers.

### DRV-IWX-021: `IWX_DEBUG` hard-enabled and `iwx_debug = 1` — every firmware command logged in all builds
- Classification: CONFIRMED DEFECT (for a shipping kext)
- Severity: Medium, Confidence: High
- Evidence: `134-139`: `#define IWX_DEBUG` … `int iwx_debug = 1;` with `DPRINTF(x) do { if (iwx_debug > 0) XYLog x; } while (0)`. `DPRINTF` (level ≥ 1) sites include the per-command send log at `6687`, rate-control log at `6913` (every TX fill!), `iwx_umac_scan_fill_channels`/`iwx_phy_ctxt_cmd` etc. Error dumps (`iwx_nic_error` `11289-11362`) are additionally wrapped in `#if 1 /* usually #ifdef IWX_DEBUG but always enabled for now */` (`11113`, `11977`, `12089`).
- Analysis: `iwx_tx_fill_cmd`'s `XYLog` at `6913` runs on the TX path of every non-aggregated frame; `iwx_send_cmd`'s at `6687` runs for every command. This is a measurable workloop-time cost and log-flood (unified log spam) in the exact paths that need to be fast for scan/join polish. For a "Debug build" this is by design, but the constant is not build-gated — Release would ship the same logging.

### DRV-IWX-022: Off-by-one bounds checks in rate pretty-printers (OOB read)
- Classification: CONFIRMED DEFECT
- Severity: Low, Confidence: High
- Evidence: `iwx_rs_pretty_ant` `518-531`: table has 4 entries (indices 0-3: NONE/A/B/AB) but guard is `if (ant > ARRAY_SIZE(ant_name))` — `ant == 4` (ANT_C, `if_iwxreg.h:5777`) passes and reads `ant_name[4]`. Same pattern in `iwx_rs_pretty_bw` `533-547` (5 entries, `bw == 5` passes). Both are invoked from `iwx_rs_update` `9593-9598` on every TLC rate notification (not debug-gated), since AX211 is 2-antenna the ant==4 case is unlikely on the target but reachable on 3-antenna radios.
- Analysis: 1-byte-past-end read of a `const char*[]` in a hot-ish logging path; cosmetic crash risk only. Fix is `>=`.

### DRV-IWX-023: Dead code / OpenBSD-isms inventory (quality)
- Classification: CONFIRMED DEFECT (hygiene)
- Severity: Low, Confidence: High
- Evidence (all verified present):
  - `#if 0` block disabling fw-debug destination application to avoid a DMA leak — author admits uncertainty (`1126-1136`, "zxystd: I don't know if it is necessary...").
  - `#ifdef notyet`: 6/7 GHz channel list (`416-422`), 1024-slot gen3 TVQM queues (DRV-IWX-010), beacon filter enable during RUN (`9917-9929`, deliberately: "Default beacon filter settings prevent net80211 from getting ERP and HT protection updates").
  - Commented-out `onLoadFW`/`OSKextRequestResource` remnant (`1406-1419`) plus its "here leaks" note — superseded by embedded fwList.
  - Unreachable statement: `return iwx_enable_txq(...); return 0;` (`7614-7616`).
  - Dead guard: `if (tid < 0 || ...)` on a `uint8_t` (`4699`).
  - Almost all `bus_dmamap_sync` calls commented out (12+ sites, e.g. `2591`, `5188`, `7163-7170`); coherency instead relies on `kIOMapInhibitCache` mappings in `allocDmaMemory2` (`2408`) — valid on x86_64 but makes the one *live* sync call at `6171` (`iwx_rx_tx_cmd`) inconsistent dead-code noise.
  - `iwx_ioctl` `11063-11074`: reads `generation` then comments show the removed `rw_enter` — the `err == 0 && generation != ...` check is now `err==0 && false` (dead), i.e. the ioctl re-entry guard is gone.
  - OpenBSD-ism: `struct device sc_dev`/`DEVNAME` plumbing, `timeout(9)` shim, `mbuf_list` all layered over IOKit — functional but the mapping of BSD `if_start` semantics onto `IOCommandGate` actions is where DRV-IWX-019 lives.
- Analysis: None individually harmful; collectively they mark every place where the port diverged from its upstream without cleanup, and they hide real behavior changes (e.g. the ioctl guard).

### DRV-IWX-024: `iwx_intr` legacy-MSI quirks and ICT fun
- Classification: VALIDATED CORRECT BEHAVIOR
- Severity: Info, Confidence: Medium
- Evidence: `iwx_intr` `11906-12057`: ICT walk with the historical bit-shuffling (`11937-11943` "don't ask"/"i am not expected to understand this"), all-ones bus-dead detection (`11946`), ALIVE → reprogram all 512 RX descriptors + `WIDX_TRG=8` (`11956-11963`), periodic-interrupt one-shot dance (`12029-12046`).
- Analysis: Faithful iwn/iwx heritage code; works on AX211 because ALIVE/RX/RFKILL all arrive on the single MSI vector. No action needed; retained for completeness of the RX/interrupt story.

### DRV-IWX-025: Station/STA removal flows leave shared state consistent; run_stop iterates rxba correctly
- Classification: VALIDATED CORRECT BEHAVIOR
- Severity: Info, Confidence: High
- Evidence: `iwx_rm_sta` `7646-7679`: flush → REMOVE_STA → reset all BA masks, delba per agreed TID; `iwx_run_stop` `9972-10044` explicitly tears down RX BA sessions synchronously ("We cannot rely on the BA task... separate thread") and drains+flushes (`iwx_flush_sta` `7262-7291`: drain on, TXPATH_FLUSH all-TIDs with response-driven `iwx_ampdu_txq_advance`, drain off); generation counters (`sc_generation`) guard every async-vs-reset race I could trace (`4329`, `4626`, `10781`, `13839`).
- Analysis: The teardown ordering is careful and matches OpenBSD's hard-won fixes. The only leak in the flow is DRV-IWX-011 (queue release).

---

## Retained-non-AX211-inventory (Tier-2 specialization targets)

**PCI IDs removable for a strict AX211 (0x51F0 + GF) build** — 18 of 19 in both `iwx_devices[]` and `Info.plist IOPCIMatch`:
- Qu/AX201/9560 (gen2): `0x02F0, 0x06F0, 0x34F0, 0x3DF0, 0x4DF0, 0x43F0, 0xA0F0` (7)
- QnJ/AX200/other So SKUs: `0x2720, 0x2723` (AX200), `0x2725, 0x2726, 0x2729` (2)
- AX210/AX411/Ma siblings of the So family — keep only if "AX211-family" is defined broadly: `0x7A70, 0x7AF0, 0x51F1, 0x54F0, 0x7F70, 0x7E40` (6)
- Keep: `0x51F0`. (All 5 "AX211-family set" IDs the CI greps for — 0x51F0/0x51F1/0x54F0/0x7E40/0x7F70 — span gen3 So+GF; decide scope first.)

**Firmware blobs removable** — 13 of 15 files, 15,124,856 of 16,700,476 raw bytes (90.6%):
- Keep (strict AX211/GF): `iwlwifi-so-a0-gf-a0-68.ucode` (1,533,812) + `iwlwifi-so-a0-gf-a0.pnvm` (41,808).
- Keep if AX411 (GF4) subdevices supported: `so-a0-gf4-a0-68.ucode` + `.pnvm` (1,573,792).
- Remove for AX211-only: `Qu-b0-hr-b0-68`, `Qu-b0-jf-b0-68`, `Qu-c0-hr-b0-68`, `Qu-c0-jf-b0-68`, `QuZ-a0-hr-b0-68`, `QuZ-a0-jf-b0-68`, `cc-a0-68` (AX200), `so-a0-hr-b0-68` (AX203-on-So), `so-a0-jf-b0-68` (9560-on-So), `ty-a0-gf-a0-68` + its `.pnvm` (AX210-on-Ty).
- Also: the cfg structs referencing **never-embedded** firmware (`QuQnj-*-48`, `SoSnj-*-63`, `ma-a0-*-63`) are pure dead weight (DRV-IWX-002) — remove their dev_info entries regardless of Tier-2 scope.

**Code branches removable without harming 0x51F0/AX211** (all keyed on `IWX_DEVICE_FAMILY_22000` / Qu-specific cfgs):
- `iwx_ctxt_info_init` (gen2 context-info load, `1082-1155`) — gen3 always used for family ≥ AX210 (`4900-4903`).
- Gen2 halves of every family split: `desc v1` parsing (`5206-5207`, `5970-5974`), `iwx_agn_scd_bc_tbl` byte-count path (`6945-6952`), `iwx_tx_cmd_gen2` (`7104-7115`), 8-byte rx free-list & `iwx_rb_status` (`2503-2509`, `2593-2598`, `11887-11888`), multi-packet-per-RB loops (`11866-11869`, `11427-11428` keep break only), `iwx_clear_persistence_bit` body (early-outs for ≥ AX210, `1289-1290`), `iwx_force_power_gating` 22000-integrated branch (`3235-3252`), `IWX_RX_DESC_SIZE_V1` handling (`5843`).
- Whole MSIX implementation (`3113-3212`, `12059-12146`, msix branches in `2808-2965`) — dead via `if (0)` (DRV-IWX-005).
- ~600 lines of Qu/QuZ/QnJ/SnJ/MA cfg structs + `iwl_dev_info_table` subdevice entries for 946x/9560/Killer-1550/1650 (`12434-12763`, `12765-13338` Qu/JF/QnJ/SnJ/MA sections), Qu C0/QuZ fixups (`13605-13628`), 9k/9560/Killer name strings (`12434-12488`).
- ICT is **shared** (MSI mode uses it: `iwx_ict_reset` `2925-2945` + `iwx_intr` `11917-11943`) — must stay.
- `cc-a0` AX200 path, JF/HR radio handling, `tx_with_siso_diversity` plumbing — removable with the IDs.

**Must stay (shared, not Qu-specific):** all `>= IWX_DEVICE_FAMILY_AX210` branches are the AX211 path itself; MSI/ICT interrupt core; command/RX/TX infrastructure; NVM/LAR/MCC; TLC rate control; PNVM.

---

## Open questions

1. **Runtime confirmation of DRV-IWX-011** — does `iwx_tvqm_alloc_txq` start failing after N roam/sleep cycles on the MSI unit (log: "Failed allocating TXQ")? Requires a log capture across ≥ 60 reassociations or a synthetic DELBA/ADDBA loop.
2. **PNVM SKU behavior on this AX211** (DRV-IWX-008) — does boot log show "PNVM complete notification received" or a 2 s timeout ("Couldn't load PNVM"/`EWOULDBLOCK`)? Determines whether every bring-up pays the penalty.
3. **The gen3 256-TFD freeze** (DRV-IWX-010) — root cause unknown per author comment; is it the 1024-slot bc_tbl DMA size (`iwx_gen3_bc_tbl` sized for `ring_count` 1024 while ring runs 256 — allocation is `sizeof(struct iwx_gen3_bc_tbl)` fixed, `2686-2687`), IOMMU coalescing, or mbuf mapping? Needs DMA tracing.
4. **Which code path re-enables the interface after system wake** — `setPowerStateOn` PM-acks without calling `enableAdapter` (AirportItlwm.cpp:908-913); confirm macOS always re-issues `enable()` post-wake, else the HAL stays stopped (this is an AirportItlwm-layer question raised by the HAL's enable/disable semantics).
5. **Upstream divergence baseline** — DRV-IWX-003/004 are inherited from laobamac@7204c69; check whether OpenBSD-current `if_iwx.c` has since added the missing `break;`/mask, which would make these confirmed regressions vs the true upstream rather than shared defects.
6. **`IWX_RATE_MCS_ANT_AB_MSK` width** — confirm whether antenna field can exceed 2 bits on AX211 TLC notifications (bounds DRV-IWX-022's reachability).
7. **Compressed-size ratios** of the 15 embedded blobs (FwBinary.cpp is generated, not in tree) to bound DRV-IWX-007's heuristic margin.

---

*AUDIT-2a complete. Companion reports: 00-repo-state.md (AUDIT-1). Suggested next: AUDIT-2b (AirportItlwm/WCL layer audit) and a runtime log-capture plan targeting open questions 1-3.*
