# AUDIT-2c-2: itl80211 Data-Plane & Security-Layer Forensic Source Audit — AirportItlwm (AX211 / Sequoia 15.8.2)

**Task ID:** AUDIT-2c-2
**Repo:** `/home/z/my-project/AirportITLWM` (AirportItlwm-Sequoia / WCL target)
**Target hardware:** MSI Modern 14 C12MO, Intel Wi-Fi 6E AX211 (8086:51F0, So MAC + GF RF, gen3 TVQM), native Airport integration
**Scope:** `itl80211/openbsd/net80211/` data plane, crypto, rate adaptation, aggregation, power save, regulatory — plus the exact interplay points in `itlwm/hal_iwx/ItlIwx.cpp` and `AirportItlwm/` (WCL) that sit on top of the IWX HAL (prior audit AUDIT-2a).

---

## Method

| File | Lines | Coverage |
|---|---:|---|
| `net80211/ieee80211_output.c` | 2,323 | **100%** read fully (TX encap, mgmt builders, EDCA, BA window helpers) |
| `net80211/ieee80211_input.c` | 3,726 | **~90%** read fully: inputm/hwdecrypt/BA reorder/decap/A-MSDU/RSN+EDCA parse/auth/assoc/ADDBA/DELBA/BAR/SA-Query/PS-Poll; beacon/probe parser skimmed for data-path interplay (control-plane auditor covers scan) |
| `net80211/ieee80211_crypto.c` | 695 | **100%** |
| `net80211/ieee80211_crypto_ccmp.c` | 516 | **100%** |
| `net80211/ieee80211_crypto_bip.c` | 235 | **100%** |
| `net80211/ieee80211_ra.c` | 954 | **100%** (MiRA-derivative with VHT/HE ratesets) |
| `net80211/ieee80211_regdomain.c` | 197 | **100%** |
| `net80211/ieee80211.c` | 1,597 | ~55% targeted: channel_init, ifattach, watchdog, rate tables, media |
| `net80211/ieee80211_node.c` | 3,522 | ~40% targeted: BA functions, node cleanup/copy/roam, RSN param selection, addba trigger |
| `net80211/ieee80211_proto.c` | 1,794 | ~30% targeted: BA timeouts, addba/delba request, keyrun/setkeys |
| `net80211/ieee80211_pae_input.c` | 1,216 | ~60% targeted: eapol_key_input, 4-way msg1/msg3, GTK/IGTK install |
| `net80211/ieee80211_pae_output.c` | 679 | ~30% targeted: send_eapol_key queueing |
| `itlwm/hal_iwx/ItlIwx.cpp` | 13,919 | targeted (~1,800 lines re-read): set_key/delete_key, iwx_tx, tx_fill_cmd, TLC/rs_init/rs_update, ba_task, ampdu_*_start/stop, power, channel map/6 GHz exclusion, scan config, rm_sta/run_stop/deauth, _iwx_start_task, rx TX-status/BA-notif/bmiss, MCC/LAR |
| `AirportItlwm/AirportItlwmSkywalkInterface.cpp` | 1,078 | targeted: setASSOCIATION/setPTK/setGTK/setCIPHER_KEY |
| `AirportItlwm/WCL/WCL.cpp`, `WCL.hpp` | — | targeted: enterprise flag, probeChannel, decodeScan, country update |
| Build config | — | `itlwm.xcodeproj/project.pbxproj` (AirportItlwm target: `AIRPORT_WCL, AIRPORT_VTD, AIRPORT, __IO80211_TARGET=__MAC_15_2, IO80211FAMILY_V2`; itl80211 lib: `IEEE80211_STA_ONLY`) |
| Git archaeology | — | `git show 0b07dee`, `cd0687a` (history of the ADDBA-trigger caps check), `git show 7204c69` (upstream itlwm comparison for `ieee80211_ba_del`) |

NetBSD/OpenBSD provenance: files carry `$OpenBSD$` tags from **2015–2021** (e.g. crypto files 2018, node.c 1.173/2019, regdomain 1.10/2015). Several upstream OpenBSD fixes made after those dates (notably BA reorder-buffer freeing in `ieee80211_ba_del`) are absent.

---

## Architecture summary

The data plane is a port of OpenBSD net80211 (STA-only build) running as a kernel C++ library under IOKit: macOS TX mbufs are drained by `_iwx_start_task` (single FIFO `ifq`, `ac` hardcoded BE), run through `ieee80211_encap` (ethernet→802.11, LLC/SNAP, QoS header **only** once a TX BA session is AGREED), and pushed to the IWX HAL, which sends CCMP via firmware hardware crypto and everything else via the net80211 software encryptors. RX frames come up through the HAL (firmware A-MPDU reordering for gen3, hardware CCMP decrypt with per-TID PN replay counters maintained in `ieee80211_input_hwdecrypt`), then `ieee80211_inputm` → A-MSDU/decap → `ml` list → the WCL/Airport stack. Security is a hybrid: the **internal OpenBSD supplicant** (`ieee80211_pae_input/output.c`) performs the 4-way/group handshakes under the WCL build and installs PTK/GTK directly into the HAL; the net80211 software rate-adaptation module (MiRA) is **dead code** — gen3 firmware TLC owns rate selection. Aggregation is initiated by net80211 timers after per-TID traffic is seen, deferred to `iwx_ba_task` which allocates a TVQM queue and lets the firmware run the ADDBA exchange.

---

## Findings

### DRV-11D-001: 6 GHz band excluded at the exact line of an `#ifdef notyet`
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY** (exclusion confirmed; prior audit predicted it)
- Severity: High (functional) / Confidence: High
- Evidence: `itlwm/hal_iwx/ItlIwx.cpp:409-423`:
  ```c
  static const uint8_t iwx_nvm_channels_uhb[] = {
     /* 2.4 GHz */ 1..14, /* 5 GHz */ 36..181,
  #ifdef notyet
     /* 6-7 GHz */ 1, 5, 9, ... 233
  #endif
  };
  ```
  Device configs set `.uhb_supported = 1` (ItlIwx.cpp:12246-12326) and `iwx_init_channel_map` selects the `uhb` table (3908-3914), but the compiled table is identical to the 2.4/5 GHz `iwx_nvm_channels_8000` table. Additionally `ieee80211_ieee2mhz()` (ieee80211.c:342-362) maps any channel ≥27 to `5000 + chan*5` and no `IEEE80211_CHAN_6GHZ` flag exists anywhere in `itl80211/`. The WCL scan-request decoder also drops entries carrying the 6 GHz flag (`WCL.hpp` `decodeScan`: `if (!channel || channel > 196 || (flags & 0x2000)) continue;`).
- Analysis: the AX211 radio is operated as a Wi-Fi 6 (not 6E) device. All 6 GHz BSSes are invisible. Because 6 GHz mandates WPA3-SAE, this exclusion also masks the SAE/GCMP gaps below.

### DRV-11D-002: No GCMP cipher — WPA3 cipher suites unrepresentable
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY**
- Severity: High (security/interop) / Confidence: High
- Evidence: cipher set implemented = WEP40/104, TKIP, CCMP, BIP only: `ieee80211_crypto.c:133-149` (`ieee80211_cipher_keylen()`), `ieee80211_set_key()` 151-182; there is no `ieee80211_crypto_gcmp.c` in the tree; `ieee80211_parse_rsn_cipher()` (input.c:1423-1457) accepts selectors {0,1,2,4,5,6} only — GCMP-128/256 (selector 8/9) parse as `IEEE80211_CIPHER_NONE`, causing `parse_rsn_body` to fail the AKM/IE checks.
- Analysis: any GCMP-only AP (typical WPA3-Enterprise, all 6 GHz) cannot be negotiated. On GCMP-capable WPA2/WPA3-mixed APs the stack silently falls back to CCMP if offered.

### DRV-11D-003: WPA3-SAE cannot authenticate; the WPA3→WPA2 "fake" hack is compiled out of the WCL target
- Classification: **CONFIRMED DEFECT** (capability)
- Severity: High / Confidence: High
- Evidence: `ieee80211_input.c:2330-2344` `ieee80211_recv_auth()`: "only 'open' auth mode is supported" — SAE (algorithm 3) frames are counted `is_rx_auth_unsupported` and dropped. `AirportItlwmSkywalkInterface.cpp:128-141`: the block mapping `APPLE80211_AUTHTYPE_WPA3_SAE → WPA2_PSK` is inside `#ifndef AIRPORT_WCL` — **not compiled** for the Sequoia WCL build (pbxproj:1893-1901 defines only `AIRPORT_WCL, AIRPORT_VTD, AIRPORT, IO80211FAMILY_V2`).
- Analysis: on a WPA3-SAE network the join request leaves the driver with no RSN protos/PSK (`setASSOCIATION` sets `ic_psk` only for WPA/WPA2/SHA256 PSK authtypes, SkywalkInterface.cpp:147-154); the stack attempts an open/no-encryption style flow that the AP rejects. WPA3-only SSIDs (and all 6 GHz) are unjoinable; WPA2/WPA3 transition-mode networks still work via WPA2.

### DRV-11D-004: MFP/PMF (802.11w) not advertised; IGTK path dead
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY**
- Severity: Medium (security) / Confidence: High
- Evidence: IWX capabilities list `ItlIwx.cpp:13693-13700` — `IEEE80211_C_WEP | IEEE80211_C_RSN | ... ` **no `IEEE80211_C_MFP`**. Consequently `ieee80211_add_rsn_body()` (output.c:1082-1086) never sets MFPC/MFPR in assoc RSN IEs; `ieee80211_choose_rsnparams()` (node.c:1630-1633) never sets `NODE_MFP`; the SA-Query machinery (output.c:1901-1922, input.c:3414-3480) and BIP IGTK handling (pae_input.c:471-474, 641-658 — IGTK KDE only parsed `if (ni->ni_flags & IEEE80211_NODE_MFP)`; crypto_bip.c entire file) are unreachable. The WCL `setCIPHER_KEY` (SkywalkInterface.cpp:372-406) has **no IGTK/BIP case at all** (only NONE/WEP/TKIP/AES_CCM/PMK/MSK/PMKSA).
- Analysis: PMF-required networks refuse association. On PMF-optional networks the client remains exposed to unicast deauth/disassoc spoofing — a standard 802.11w threat, relevant on enterprise/campus APs that enable PMF-capable. No throughput impact.

### DRV-11D-005: CCMP core (SW + HW-offload paths) is correct — per-TID replay counters, 11w AAD rules, KRACK guards
- Classification: **VALIDATED CORRECT BEHAVIOR**
- Severity: — / Confidence: High
- Evidence: `ieee80211_crypto_ccmp.c:93-176` phase1 AAD construction (masks subtype for 11w data, Retry/PS/MoreData, Order for QoS; nonce carries TID + mgmt bit); PN extraction & per-TID RSC selection `ieee80211_ccmp_get_pn()` 322-359 (`*prsc = &k->k_rsc[tid]`, mgmt uses `k_mgmt_rsc`); replay discard `pn <= *prsc` (396-401) with MIC check before RSC update (499-507). HW-offload path `ieee80211_input_hwdecrypt` (input.c:168-261) reuses the same counters with `IEEE80211_RXI_HWDEC_SAME_PN` allowing equal PN across A-MSDU subframes. HAL-side duplicate check `iwx_detect_duplicate` + `iwx_ccmp_decap` (ItlIwx.cpp:5247-5303) implement the same per-TID rule pre-reorder. KRACK protections: `IEEE80211_NODE_RSN_NEW_PTK` gate (pae_input.c:556-599) and `ieee80211_must_update_group_key()` (366-373) prevent key/counter reinstall.
- Analysis: the primary data-confidentiality engine is the well-audited OpenBSD implementation; no defect found.

### DRV-11D-006: Non-CCMP ciphers run in software on the command gate; TKIP countermeasures are a no-op
- Classification: **CONFIRMED DEFECT** (performance no-op part) + UNSUPPORTED (SW crypto part)
- Severity: Medium / Confidence: High
- Evidence: `iwx_set_key()` ItlIwx.cpp:10060-10062 "Fallback to software crypto for other ciphers"; `iwx_tx()` 7073-7086: non-CCMP frames are `ieee80211_encrypt()`-ed in software then flagged `IWX_TX_FLAGS_ENCRYPT_DIS`. TKIP Michael-MIC failure countermeasures are explicitly stubbed: `ieee80211_encap` output.c:623-625 `if ((ic->ic_flags & IEEE80211_F_COUNTERM) && ni->ni_rsncipher == TKIP) /* XXX TKIP countermeasures! */;` and the MIC-failure timeout is hostap-only (crypto.c:84-87).
- Analysis: on TKIP networks every frame is RC4+Michael'd on the single workloop gate — throughput collapses to low-tens of Mbps and CPU burns; MIC-failure storms (an active attack or a noisy link) can never trigger the mandated 60-second shutdown, leaving a legacy network attackable. WPA/WPA2-CCMP (the common case) is unaffected.

### DRV-11D-007: Host rate adaptation (MiRA + AMRR + rssadapt) is dead code; firmware TLC is the sole rate controller
- Classification: **VALIDATED CORRECT BEHAVIOR** (fw owns rates) with **UNVERIFIED IMPLEMENTATION RISK** (dead-code hazards)
- Severity: Low / Confidence: High (for the dead-code fact)
- Evidence: no caller of `ieee80211_ra_add_stats_ht`/`ieee80211_ra_choose`/`ieee80211_ra_node_init` exists in `ItlIwx.cpp` (rg across repo: only definitions in `itl80211/openbsd/net80211/`). Rate flow: `iwx_rs_init()` sends `IWX_TLC_MNG_CONFIG_CMD` (ItlIwx.cpp:9375-9434, HE mode for AX211, per-BW rate masks 9211-9270); firmware reports decisions via `IWX_TLC_MNG_UPDATE_NOTIF` → `iwx_rs_update()` 9574-9631 which merely records `ni->ni_txmcs`/`ni_txrate`/`ni_he_txrate_kbps` for status; `iwx_tx_fill_cmd()` 6885-6887 uses `ni_txmcs` only as an initial-rate seed without `IWX_TX_FLAGS_CMD_RATE`. TX status retry counters are parsed but only printed: `iwx_rx_tx_cmd()` 6176-6187 (DPRINTFN), `iwx_rx_tx_cmd_single()` 5988-6008 just bumps `outputErrors`.
- Analysis: consistent with the prior audit (gen3 firmware TLC). Risk residue: (1) `ieee80211_ra_get_rateset()` ends in `panic("... rate==NULL!!!!")` (ra.c:278) and `ieee80211_ra_next_rateset`/`next_mcs` panic on probing mode — any future caller wiring MiRA back in can kernel-panic; (2) if the firmware TLC stalls (e.g. after the DRV-IWX-011 queue freeze) there is no host watchdog on rate state.

### DRV-11D-008: TX aggregation enable is slow and fragile — 1 s initial delay, 30 s backoff, open networks never aggregate
- Classification: **STRONGLY SUSPECTED DEFECT** (throughput ramp)
- Severity: High (user-visible throughput) / Confidence: High
- Evidence: chain of gates before a frame rides an A-MPDU:
  1. `ieee80211_encap` output.c:629-646 — only QoS-eligible **data** frames (not EAPOL) with `ba_state != AGREED` call `ieee80211_node_trigger_addba_req(ni, tid)`; the caps check is `(ic->ic_caps & IEEE80211_C_TX_AMPDU_SETUP_IN_RS) == 0` (640) — IWX never sets `_IN_RS`, so net80211's timer path is active even though the driver also sets `_IN_HW`.
  2. `ieee80211_node_trigger_addba_req` node.c:2887-2895 arms `ni_addba_req_to[tid]` at `ni_addba_req_intval[tid]` — initialized to **1 s** (node.c:1762-1763), backoff doubling to **30 s** max on each failure (`IEEE80211_ADDBA_REQ_INTVAL_MAX`, node.h:439; incremented in `recv_addba_resp` input.c:3272-3274 and `tx_ba_timeout` proto.c:1062-1064).
  3. `ieee80211_addba_request` proto.c:1104-1144 → `iwx_ampdu_tx_start` (ItlIwx.cpp:4690-4712) returns EBUSY → `iwx_ba_task` 4604-4636 allocates the TVQM queue and calls `ieee80211_addba_resp_accept` immediately (4623) — the *firmware* runs the actual ADDBA exchange.
  4. Aggregation is additionally forbidden on open networks: `ieee80211_can_use_ampdu` output.c:490-507 requires `IEEE80211_F_RSNON && PROTO_RSN` (deliberate anti-injection policy).
- Analysis: every association/reassociation pays ≥1 s of non-aggregated legacy-framed TX before A-MPDU starts; after a failed ADDBA the TID can wait up to 30 s. Combined with DRV-11D-011 (non-aggregated frames are not even QoS-marked) the post-roam throughput ramp is minutes-scale worst case. On open/guest SSIDs throughput is permanently capped at legacy non-aggregated levels.

### DRV-11D-009: BA teardown on roam/deauth leaks the RX reorder buffers and any mbufs inside them
- Classification: **CONFIRMED DEFECT** (memory leak)
- Severity: Medium / Confidence: High
- Evidence: `ieee80211_ba_del()` node.c:2029-2051 resets `ba_state` and cancels timers but **never frees `ba->ba_buf`** (allocated in `recv_addba_req` input.c:3155-3159, `malloc(IEEE80211_BA_MAX_WINSZ * sizeof(struct ieee80211_ba_buf))` ≈ 64 × (mbuf_t + rxinfo) per TID) and never frees mbufs parked in the window. `ieee80211_node_cleanup()` (node.c:1660-1686) and `node_copy()` (1695-1713) call only `ba_del`/`ba_free` (timeout_free only). Every roam executes this via `ieee80211_node_join_bss → ic_node_copy` (node.c:1255) and every deauth via newstate cleanup. Verified against upstream itlwm (`git show 7204c69`) — inherited divergence; current OpenBSD frees the buffer here.
- Analysis: leak rate ≈ up to 8 TIDs × ~2 KB + up to 64 held mbufs per roam. On a machine that roams frequently (weak RF, bgscan auto-roam enabled) this is a slow kernel-memory/mbuf leak → prolonged uptime degradation, contributing to "wider unreliability". Cleanly torn-down sessions (DELBA path input.c:3382-3389) do free correctly.

### DRV-11D-010: Roam/deauth tears TX BA down silently — no DELBA to the AP, no driver notification from net80211
- Classification: **STRONGLY SUSPECTED DEFECT** (interplay with DRV-IWX-011)
- Severity: Medium-High / Confidence: Medium-High
- Evidence: `iwx_rm_sta()` ItlIwx.cpp:7647-7678 loops agreed TX BAs with `ieee80211_delba_request(ic, ni, /*reason=*/0, 1, i)` — reason 0 means **no DELBA frame is transmitted** (proto.c:1161-1165). net80211's own `ba_del` (node.c:2044-2051) never calls `ic_ampdu_tx_stop` either. The only path that would release the HAL TVQM queue, `iwx_ampdu_tx_stop` (ItlIwx.cpp:4714-4729), merely sets `sc_tid_data[tid].qid = IWX_INVALID_QUEUE` — it never frees the queue (DRV-IWX-011) and early-returns if `ba_state != AGREED`.
- Analysis: after each roam the AP-side BA state is stale until it times out, and the driver-side aggregation queue leaks (prior audit). Sequence restart at the new AP starts from `ba_winstart` from the freshly allocated queue (ba_task 4620-4621). Net effect: repeated roams accumulate leaked queues until `iwx_tvqm_alloc_txq` fails → aggregation permanently refused (`addba_resp_refuse` 4632) → throughput pinned at legacy rates until reboot. This is the strongest systemic explanation candidate for progressive degradation.

### DRV-11D-011: Non-aggregated TX frames are sent without QoS headers; per-AC scheduling does not exist
- Classification: **CONFIRMED DEFECT** (by design upstream, but consequential here) 
- Severity: Medium / Confidence: High
- Evidence: `ieee80211_encap` output.c:636-646: "We use QoS data frames for aggregation only." — before BA AGREED, frames get a plain `struct ieee80211_frame` header and sequence numbers from the shared non-QoS counter `ni->ni_txseq` (684-686); after agreement, per-TID `ni_qos_txseqs[tid]` (680-682). `_iwx_start_task` ItlIwx.cpp:10850 `int ac = EDCA_AC_BE; /* XXX */`, ifq is FIFO (`ifq_dequeue` 10884), and `ieee80211_classify()`'s DSCP→UP result is used only for the TID field. All non-aggregated traffic (including EAPOL and all management) shares the single non-aggregation TX ring (iwx_tx 6996-7014, `qid = sc->first_data_qid`).
- Analysis: pre-ADDBA and EAPOL frames cannot use WMM priority at all, and any AC differentiation only exists once per-TID aggregation queues are up. A bulk BE/BK burst on the shared ring can delay VO/mgmt/EAPOL — handshake frames time out (100 ms EAPOL timeout, pae_output.c:139) and the association restarts. Amplifies DRV-IWX-010.

### DRV-11D-012: EAPOL is consumed by the in-driver supplicant under WCL; never forwarded to macOS on PSK networks
- Classification: **VALIDATED CORRECT BEHAVIOR** (as designed) with noted risk
- Severity: Info/Low / Confidence: High
- Evidence: input.c:1136-1155: under `AIRPORT_WCL`, an EAPOL frame is duplicated to the stack **only** `if (ic->ic_wcl_enterprise)`; the original always goes to `ieee80211_eapol_key_input()` — the OpenBSD supplicant, which performs the 4-way handshake (msg2/msg4 via `ieee80211_send_eapol_key` pae_output.c:75-148, queued on `if_snd`) and installs PTK/GTK through `ic_set_key` (pae_input.c:587, 629). `ic_wcl_enterprise` is set only by WCL join requests (WCL.cpp:453) and cleared on stop/join paths (WCL.cpp:533,576,610,679). PSK is injected via `setASSOCIATION` → `ic->ic_psk` (SkywalkInterface.cpp:151-153).
- Analysis: works, but macOS's own supplicant is bypassed for PSK; any macOS-side diagnostic/roaming logic that expects to see EAPOL sees nothing. Combined with DRV-11D-011 (EAPOL on the congested shared ring at legacy framing), handshakes under load are the fragile point.

### DRV-11D-013: TX BA sessions have no inactivity timeout — `ba_timeout_val` forced to 0
- Classification: **CONFIRMED DEFECT** (lifecycle gap)
- Severity: Low-Medium / Confidence: High
- Evidence: `ieee80211_addba_request` proto.c:1119 `ba->ba_timeout_val = 0;` and `iwx_ba_task` ItlIwx.cpp:4622 `ba->ba_timeout_val = 0;`. Both `ieee80211_input_ba` (input.c:847-848) and `ieee80211_addba_resp_accept` (input.c:3319-3320) only arm the inactivity timer `if (ba->ba_timeout_val != 0)`. ADDBA requests therefore advertise a timeout value of 0 ("no timeout") to the AP.
- Analysis: stale TX BA state persists until DELBA/roam; a queue that wedges (DRV-IWX-011) is never reaped by inactivity. Conversely RX-side timeouts use the AP-provided value and work.

### DRV-11D-014: RX A-MSDU/A-MPDU deaggregation, reordering and duplicate/replay detection validated correct
- Classification: **VALIDATED CORRECT BEHAVIOR**
- Severity: — / Confidence: High
- Evidence: A-MSDU: `ieee80211_amsdu_decap` input.c:1270-1362 — 3-byte pad handling (1354-1355), subframe length checks (1298-1330), FragAttacks mitigations `ieee80211_amsdu_decap_validate` 1223-1265 (LLC-header-MAC blackhole, STA DA==self). Reorder: `ieee80211_input_ba` 832-916 with window slide/jump heuristics (`ba_winmiss` ≤ 8, stats counters), `input_ba_seq`/`flush`/`gap_skip` 922-1030, gap timeout 300 ms (`IEEE80211_BA_GAP_TIMEOUT`, node.h:289). Fragments are dropped entirely (input.c:399-411, citing vanhoef usenix2021) — defrag code is `#ifdef notyet` (736-826). Duplicate detection per-TID `ni_qos_rxseqs` with `IEEE80211_RXI_SAME_SEQ` for fw deaggregated subframes (input.c:413-435) plus the HAL-side `iwx_detect_duplicate` (ItlIwx.cpp:5454-5477) which understands A-MSDU subframe indices.
- Analysis: no defect found in the deaggregation/reorder engine (the net80211 layer is only in the loop for non-fw-reordered frames on this gen3 hardware — firmware reorder data path short-circuits with `RXI_AMPDU_DONE`).

### DRV-11D-015: No station power-save at the 802.11 layer: no PS bit, no TIM decode for own AID, no PS-Poll; PS fully delegated to firmware
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY** (by delegation)
- Severity: Medium / Confidence: High
- Evidence: TX frames never set `IEEE80211_FC1_PWR_MGT` (grep across output.c/pae_output.c — zero hits; the only PS-bit code is hostap RX handling input.c:453-481 and `ieee80211_pwrsave` for AP buffering output.c:2275-2322, both STA_ONLY-compiled-out). Beacon TIM parsing extracts only `dtim_count`/`dtim_period` (input.c:1820-1825) to feed `ic_updatedtim` → `iwx_updatedtim` (ItlIwx.cpp:4539-4547, re-sends MAC context). PS-Poll is hostap-only (`ieee80211_recv_pspoll` input.c:3583+, `#ifndef IEEE80211_STA_ONLY`). Firmware PS: `iwx_power_build_cmd` ItlIwx.cpp:7363-7391 sets only `IWX_POWER_FLAGS_POWER_SAVE_ENA_MSK` (no `POWER_MANAGEMENT_ENA` → `ba_enable=0`, beacon-abort off), keep-alive ≥ 3×DTIM; `iwx_power_update_device` 7414-7426 always enables device PS when not monitor.
- Analysis: net80211's own PS machinery is intentionally inert; all AP-buffering behavior is firmware LAR/MVM PS. U-APSD absent (prior audit DRV-IWX-016) — APs see a non-U-APSD STA and buffer/queue accordingly. Multicast/DTIM delivery depends entirely on fw keep-alive; user-visible risk is delayed IPv6 SLAAC/ND multicast during doze.

### DRV-11D-016: Regulatory: LAR/firmware MCC with NVM channel tables; DFS passive-only in WCL scans; a global `PRE_SCAN_PASSIVE2ACTIVE` flag is a compliance question mark
- Classification: **UNVERIFIED IMPLEMENTATION RISK** (flag) / **VALIDATED** (DFS handling)
- Severity: Low-Medium / Confidence: Medium
- Evidence: channels from NVM `iwx_init_channel_map` ItlIwx.cpp:3894-3992 — `IEEE80211_CHAN_PASSIVE` when `!IWX_NVM_CHANNEL_ACTIVE` (3951-3952), `IEEE80211_CHAN_DFS` (3981-3983); LAR init `iwx_send_update_mcc_cmd(sc, "ZZ")` (10691-10698) and geo-located country updates (WCL `deferWCLCountryUpdate` → MCC_UPDATE_CMD, WCL.cpp:28-64, ItlIwx.cpp:10498-10558, refreshed channel map at 8523-8537). WCL active-probe decision excludes DFS/passive: `probeChannel(active, passiveOnly, dfs) { return active && !passiveOnly && !dfs; }` (WCL.hpp:426-428). However `iwx_config_umac_scan` sets global `scan_config->channel_flags = ... | IWX_CHANNEL_FLAG_PRE_SCAN_PASSIVE2ACTIVE` (ItlIwx.cpp:7963-7966).
- Analysis: DFS channels are not actively probed by host decision (good), but the passive2active flag invites the firmware to convert passive channels to active after the first scan — if that applies to DFS channels in ETSI domains this is a regulatory exposure needing fw-behavior confirmation. The regdomain.c module itself is only a name↔code mapping table (2015 vintage) — actual rules live in firmware geo profiles; no host-side CAC/radar handling exists (fine for STA; DFS-master impossible anyway).

### DRV-11D-017: Roaming is always full AUTH + 4-way handshake — no 802.11r/FT, no fast path
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY**
- Severity: Medium (roam latency) / Confidence: High
- Evidence: no MDIE/FTIE/FT AKM handling anywhere (`rg -i "11r|FT |MDIE|fast.*transition"` → nothing in net80211 or WCL); roam path `ieee80211_node_switch_bss`/`join_bss` (node.c:1192-1321) always transitions to `IEEE80211_S_AUTH` (1319) and re-runs the full handshake. PMKID caching exists (`choose_rsnparams` node.c:1612-1618, PMKSA cache crypto.c:643-695, `pmk_lifetime /* XXX not used yet */` at 664) which skips 802.1X but never the 4-way.
- Analysis: every roam costs auth + assoc + EAPOL 4-way (~100-400 ms typical, worse if EAPOL starves per DRV-11D-011/012), then ≥1 s aggregation ramp (DRV-11D-008). This chain is the per-roam "burst of unusability" users experience.

### DRV-11D-018: `qfullmsk`-induced global TX stall: one full ring stops every queue including management
- Classification: **CONFIRMED DEFECT** (head-of-line blocking at the 802.11/driver boundary)
- Severity: High (stall contributor) / Confidence: High
- Evidence: `_iwx_start_task` ItlIwx.cpp:10858-10863: `if (!sc->qfullmsk.empty()) { ifq_set_oactive(&ifp->if_snd); break; }` — the drain loop halts for **all** frames (mgmt queue included) whenever any TX ring (e.g. one stuck aggregated TID per DRV-IWX-011) exceeds `hi_mark`. Wake-up only via `iwx_clear_oactive` from TX completions (6010-6108) or flush (7255).
- Analysis: with a frozen aggregation queue, the driver wedges the entire TX path — EAPOL, deauth, SA-Query all included — until the watchdog (`sc_tx_timer` 15 s → full reinit per prior audit DRV-IWX-017). Plausible direct cause of multi-second total stalls seen as "unreliable".

### DRV-11D-019: Raw 802.11 TX injection path disabled
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY**
- Severity: Low / Confidence: High
- Evidence: `ieee80211_output` output.c:123-170 — the mbuf-tag DLT path is commented out and the encap raw-frame branch is `if (0)` (549-586); everything falls through to `if_enqueue`.
- Analysis: no monitor-mode TX, no BPF write injection, no tooling (Wireshark injection, fuzzing). Diagnostic capability only.

### DRV-11D-020: TX sequence-number architecture — shared legacy counter + per-TID counters, reset on ADDBA accept
- Classification: **VALIDATED CORRECT BEHAVIOR**
- Severity: — / Confidence: Medium-High
- Evidence: mgmt frames and non-QoS data share `ni->ni_txseq` (output.c:218-220, 684-686); QoS data uses `ni_qos_txseqs[tid]` (680-682); on ADDBA acceptance the TID counter is re-seeded to `ba->ba_winstart` (input.c:3313; ba_task sets winstart from the allocated queue's TFD index ItlIwx.cpp:4620). The net80211 TX-BA bitmap helpers (`ieee80211_output_ba_move_window`/`record_ack`, output.c:1751-1813) are never called by IWX — firmware owns retransmission/BlockAck tracking, so `ba_bitmap` stays zero (benign; `iwx_ampdu_txq_advance` uses TFD indices instead, 6113-6128).
- Analysis: matches upstream semantics; no defect, but confirms the net80211 TX-BA state machine is half-inert and its state is driver-coordinated (fragile coupling documented for future changes).

### DRV-11D-021: Watchdog/auth retry policy: auth timeouts retried only 3 times, then full scan
- Classification: **VALIDATED CORRECT BEHAVIOR** (with tuning note)
- Severity: Low / Confidence: High
- Evidence: `ieee80211_watchdog` ieee80211.c:901-934 — on `ic_mgt_timer` expiry in AUTH/ASSOC, `ni_fails < 3` retries join (921-924) then drops to SCAN (928); beacon-loss fallback sends a directed probe before scanning (`iwx_rx_bmiss` ItlIwx.cpp:6205-6248, threshold `IEEE80211_BEACON_MISS_THRES 30`, ieee80211_var.h:238). EAPOL supplicant timeout is 100 ms with retries from the AP side only (pae_output.c:137-140).
- Analysis: sane; the 3-strike counter combined with DRV-IWX-017's aggressive reinit is what makes transient fw slowness look like "join unreliability" (cross-reference, control plane).

### DRV-11D-022: Key installation and rekey flow (GTK/PTK) — correct, incl. group rekey replay protection; RSC of PTK hardcoded 0
- Classification: **VALIDATED CORRECT BEHAVIOR** with one noted deviation
- Severity: Low / Confidence: Medium-High
- Evidence: internal supplicant path: 4-way msg3 installs PTK with `k_rsc[0] = LE_READ_6(key->rsc)` **only when no GTK KDE present**, else 0 (pae_input.c:577) and GTK with `LE_READ_6(key->rsc)` (625); group rekey msg1 with `must_update_group_key` guard (input group handlers 849+). The WCL-side `setPTK` (SkywalkInterface.cpp:179-218, used by legacy IOCTL path) hardcodes `prsc = 0` with the rsc read commented out (196) — harmless for PTK (fresh PN space) but inconsistent with the internal path. HW key install is async (`IWX_CMD_ASYNC`, ItlIwx.cpp:10082) with no completion check — a failed fw ADD_STA_KEY surfaces later as "BUG! key unset for sw crypto" drops in `ieee80211_encrypt` (crypto.c:277-281) or unencrypted-RX failures rather than a join failure.
- Analysis: rekey storms and KRACK-class attacks are handled; the async key install error-path is a robustness gap (silent drop instead of loud failure).

### DRV-11D-023: `iwx_run_stop` handles RX-BA teardown on state exit — but net80211 state is left dangling on the driver side of roam
- Classification: **STRONGLY SUSPECTED DEFECT** (roam path ordering)
- Severity: Medium / Confidence: Medium
- Evidence: `iwx_run_stop` ItlIwx.cpp:9972-10044 iterates `sc_rxba_data` and stops fw RX AGG (9997-10004) — but `ni->ni_rx_ba[tid].ba_state` in net80211 is only reset later via `node_copy → ba_del` (node.c:1675) with `ic_ampdu_rx_stop` **not** invoked on that path (only the DELBA and `iwx_run_stop` paths notify the driver; `ba_del` doesn't). If the new association completes without passing through `iwx_rm_sta` (e.g. same-AP reassociation triggered by Apple-side rejoin rather than roam), `sc_rxba_data` entries keep stale BAIDs while net80211 believes BA_INIT — the next ADDBA from the AP re-registers with the fw; stale sessions counted against `sc_rx_ba_sessions` until expiry.
- Analysis: bounded but real state desynchronization surface on roam/rejoin; needs runtime tracing to confirm user impact.

### DRV-11D-024: Multicast/broadcast TX has no rate cap logic beyond min-basic-rate; mcast echo suppression OK
- Classification: **VALIDATED CORRECT BEHAVIOR**
- Severity: — / Confidence: Medium
- Evidence: `iwx_tx_fill_cmd` ItlIwx.cpp:6874-6878: mcast/non-data frames get `ridx = min_ridx` + `IWX_TX_FLAGS_CMD_RATE` (lowest basic rate); RX mcast echo dropped for SIMPLEX (input.c:498-509); bridge duplication for mcast is hostap-only (input.c:1094-1123).
- Analysis: standard behavior; mcast throughput poor-by-spec, no defect.

### DRV-11D-025: Memory model: KPI mbufs for frames, IOBufferMemoryDescriptor DMA arena; error paths reviewed — one leak class (DRV-11D-009) plus prior-audit HAL leaks
- Classification: **VALIDATED CORRECT BEHAVIOR** (net80211 error paths)
- Severity: — / Confidence: Medium-High
- Evidence: all net80211 encap/crypto error paths free the mbuf (`goto bad` → `mbuf_freem`, output.c:729-735; crypto nospace paths ccmp.c:315-320 etc.). HAL: TX mbufs mapped per-frame with `bus_dmamap_packet` into ≤18 segments (ItlIwx.cpp:7120-7126); DMA arena = `IOBufferMemoryDescriptor::inTaskWithPhysicalMask` blocks + `IODMACommand` (ItlDma.cpp:13-80). RX rings pre-allocated. `ieee80211_save_ie` realloc behavior correct (input.c:1618-1633); `save_ie_tlv` (1638-1653) frees only when `*accept_len > 0` — consistent pairing with `_malloc.h` inline malloc/free.
- Analysis: outside DRV-11D-009 (reorder buffers) and the HAL findings (DRV-IWX-011/012), no new leak paths found in the data plane.

---

## Security capability matrix

| Capability | Status | Evidence |
|---|---|---|
| Open (no encryption) | ✅ works | output.c:715-718 (no PROTECTED bit); aggregation disabled on open nets (DRV-11D-008) |
| WEP-40/104 | ⚠️ SW crypto only; **key cannot be set via WCL `setCIPHER_KEY`** ("Setting WEP key is not supported", SkywalkInterface.cpp:377-380) but setASSOCIATION nwkey path exists (167-176); no shared-key auth | crypto_wep.c; ItlIwx.cpp:10060 |
| TKIP (WPA/WPA2) | ⚠️ SW crypto (perf collapse), countermeasures stubbed | DRV-11D-006 |
| CCMP (WPA2-PSK/802.1X) | ✅ hardware offload, per-TID replay counters, validated | DRV-11D-005 |
| GCMP-128/256 | ❌ not implemented | DRV-11D-002 |
| BIP/IGTK (802.11w group MFP) | ❌ code present, unreachable (no C_MFP cap, no WCL IGTK path) | DRV-11D-004 |
| Unicast MFP (SA-Query, protected mgmt) | ❌ same | DRV-11D-004 |
| WPA3-SAE / SAE-PK | ❌ auth algorithm rejected; WPA3→WPA2 hack not compiled (WCL) | DRV-11D-003 |
| WPA3-Enterprise (192-bit) | ❌ (GCMP + SHA384 AKMs unrepresented) | DRV-11D-002 |
| WPA2-Enterprise 802.1X | ✅ via WCL PMK/MSK/PMKSA (`setCIPHER_KEY` cases PMK/MSK/PMKSA) + internal supplicant handshake; EAP frames duplicated up only in enterprise mode | SkywalkInterface.cpp:393-405; input.c:1136-1141 |
| SHA-256 AKMs (PMK caching w/ SHA256 KDF) | ✅ parsed & preferred when MFP cap set — but cap never set, so selection falls to plain PSK/8021X | input.c:1476-1479; node.c:1601-1606 |
| PMKID caching (OKC-lite) | ✅ PMKSA cache + PMKID in assoc req; lifetime unused | crypto.c:643-695; node.c:1612-1618 |
| 802.11r FT | ❌ absent | DRV-11D-017 |
| Suite-B / CNSA | ❌ | — |
| 6 GHz (implies WPA3) | ❌ `#ifdef notyet` | DRV-11D-001 |
| Fragmentation TX | ❌ never implemented | DRV-11D-014 |
| Fragmentation RX | ❌ deliberately dropped (fragattacks mitigation) | input.c:399-411 |
| Replay protection (CCMP/TKIP/EAPOL) | ✅ | DRV-11D-005, pae_input replay counters |
| KRACK mitigations | ✅ | pae_input.c:556-599, crypto.c:366-373 |
| A-MSDU injection guard (fragattacks) | ✅ | input.c:1223-1265 |
| Raw frame injection (monitor TX) | ❌ disabled | DRV-11D-019 |

---

## Open questions

1. **Does `iwx_tvqm_alloc_txq` actually fail after N roams?** DRV-11D-009/010 + DRV-IWX-011 predict leaked aggregation queues accumulate; needs a log capture across ≥20 forced roams watching for "Failed allocating TXQ"/ADDBA refusals and `vm_page`/mbuf pressure from reorder-buffer leaks.
2. **Does the firmware TLC (rate control) recover after a queue-freeze/reinit cycle?** No host-side rate watchdog exists (DRV-11D-007); a stuck `ni_txmcs` seed would pin the initial rate low. Check `iwx_rs_update` "new rate:" log lines after stall episodes.
3. **Is `IWX_CHANNEL_FLAG_PRE_SCAN_PASSIVE2ACTIVE` making the fw actively probe DFS channels on subsequent scans** in the user's regulatory domain (DRV-11D-016)? Needs fw-behavior confirmation or a sniffer capture on a DFS channel.
4. **Does macOS/WCL ever deliver an IGTK to the driver on PMF networks** (it would be dropped by `setCIPHER_KEY`'s switch today — DRV-11D-004)? Confirm with a PMF-optional enterprise AP whether association completes (expected failure only on PMF-required).
5. **Same-AP reassociation without `iwx_rm_sta`** (Apple-initiated rejoin, DRV-11D-023): does `sc_rx_ba_sessions` leak upward toward `IWX_MAX_RX_BA_SESSIONS`, refusing new RX BA after many rejoins?
6. **EAPOL starvation reproduction**: bulk TCP during (re)association — measure whether 4-way msg2/4 (100 ms timeout) get delayed on the shared ring enough to force re-auth loops (DRV-11D-011/012/018).

---

## Throughput-cap explanation candidates (ranked)

1. **DRV-IWX-010 + DRV-11D-008/011/013** — until per-TID ADDBA completes (~1 s+ after first frame, up to 30 s backoff, never on open SSIDs), all traffic rides one shared ring as non-QoS legacy frames; gen3 aggregated queues are capped at 256 TFDs (HAL). A session that fails ADDBA once is pinned near legacy rates for up to 30 s.
2. **DRV-11D-018 + DRV-IWX-011** — any single stuck ring sets `qfullmsk` and freezes the whole TX path (incl. EAPOL/mgmt) until TX completions or a 15 s watchdog reinit; user sees multi-second dead air.
3. **DRV-11D-009/010** — roam-driven leaks: reorder buffers + mbufs leak per roam; TVQM queues never released → after enough roams, ADDBA is permanently refused → sustained ~60-70 Mbps legacy/non-aggregated ceiling exactly matching the reported symptom.
4. **DRV-11D-006** — TKIP networks: software crypto on the single gate.
5. **DRV-11D-015/017** — PS keep-alive / full-reauth roam path adds latency bursts but not a sustained cap.
