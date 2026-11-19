# AUDIT-3: Reference-fork comparison — AirportItlwm (AX211 / Sequoia 15.8.2)

**Audit date:** 2026-11-18
**Audited tree:** `/home/z/my-project/AirportITLWM` @ `e4857ff` (`v2.4.0-ax211-reduced`), base laobamac/itlwm `7204c69` (2026-11-01, "fix/wpa3-transition-and-amsdu" merge)
**References (read-only clones, no code copied):**
- `refs/ForbiddenItlwm` — retropineaple/ForbiddenItlwm, 0.6.0-beta.2 (shallow @ 6e15195, 2026-11-18)
- `refs/Eric-AirportItlwm` — Ersiter/Eric-AirportItlwm (shallow @ e258fb8, 2026-11-16)
- `refs/AirportItlwm-AX211` — ElicoftZ/AirportItlwm-AX211 (shallow @ 030ef90, 2026-10-14)
- `refs/upstream-itlwm` — laobamac/itlwm @ `7204c69` (full clone, 858 commits — the audited tree's own upstream)
**Directive honored:** inspect approaches and documented behavior only; no merges/copies; a reference fork is not assumed correct.

---

## Method

1. **Lineage first.** All three forks are shallow (single-commit) clones, so parentage was established from their own documentation: FI `README.md` credits + `tools/build.py` (`ITLWM_VERSION="2.4.1"`); Eric `README.md` §Lineage (itlwm → laobamac → Eric); AX211 `AX211-DEVELOPMENT.md` ("starts from laobamac d695c97"). No `.git/config` was read; no remote URLs printed; nothing committed; no repository file modified.
2. **Baseline diffing.** Because every fork shares laobamac as base, each fork was diffed **against `refs/upstream-itlwm@7204c69`** (not against the reduced audited tree) using `diff -rq` per directory plus targeted `diff -U3` on WCL.cpp/WCL.hpp, `AirportItlwmSkywalkInterface.cpp`, `AirportItlwmV2.cpp`, net80211, `hal_iwx`, and plists. This isolates *fork-introduced* change from *upstream-inherited* code.
3. **Reduction accounting.** `git diff 7204c69..HEAD --stat` (and per-path filters) on the main repo established exactly what the prior session's reduction changed, answering "inherited vs introduced" for every prior finding (result in REF-015).
4. **Prior findings tested.** The defect list from AUDIT-2 reports 10–13 (DRV-IWX-*, DRV-AP-*, DRV-11C-*, DRV-11D-*) was re-derived per tree by pattern search (`F_DESBSSID`, `notyet`, `ampdu_tx_stop`, `IFF_UP | IFF_RUNNING`, `SAE`, `6GHZ`, firmware inventory), then each hit verified by reading the function body in all five trees.
5. **Firmware/matrix inventory.** `ls`-based blob counts per `itlwm/firmware`; `IOPCIMatch` strings from each fork's live WCL plists; OS targets from Xcode schemes / `tools/build.py`.

---

## Per-fork overview

| | ForbiddenItlwm (FI) | Eric-AirportItlwm (ER) | AirportItlwm-AX211 (AX) | (audited tree) |
|---|---|---|---|---|
| **Base** | laobamac/itlwm **v2.4.1** (README credits: "the exact code this fork starts from"; `build.py`: `ITLWM_VERSION="2.4.1"`) | laobamac/itlwm (README §Lineage; `MODULE_VERSION 2.4.0` in pbxproj) | laobamac/itlwm @ **d695c97** (AX211-DEVELOPMENT.md) | laobamac/itlwm @ 7204c69, reduced |
| **Stated purpose** | AirDrop/AWDL for Intel Wi-Fi: makes macOS's own stack believe it has an AWDL radio (`awdl0` via `ItlAWDLInterface`, vtable-audited per-OS: 568/563/547 slots Tahoe/Sequoia/Sonoma) + `BTLEAdvFixup.kext` for BLE advertising; **AI-assisted project, openly disclosed** | AirportItlwm "from Wi-Fi 6 to Wi-Fi 7": BE200/BE201 (Wi-Fi 7) with MLD firmware API 92/86, WPA3-SAE/H2E, OWE, 6 GHz, 320 MHz, eMLSR — while keeping *every* card itlwm supports (iwm/iwn HALs intact) | Experimental AX211/Sequoia hardening: AWDL sync-template IOCTL security fixes, opt-in receive-only AWDL observer (`awdl_observe=1`), RX BlockAck timer/gap-deadline repair, opt-in scan/packet counters |
| **Activity (HEAD)** | 2026-11-18, 0.6.0-beta.2 (most active; "fixes come out often") | 2026-11-16 | 2026-10-14 (oldest; 0.6-era) | 2026-11-17 (reduction + CI) |
| **OS matrix** | Tahoe 26.7.x, Sequoia 15.8.x, Sonoma 14.8.9 (Sonoma build compiled `wcl=False` — legacy ioctl path, its own join/scan/keys/teardown) | Tahoe 26 (Darwin 25.x), Sequoia 15.2+ (24.2–24.99) | Sequoia 15.2+; Tahoe scheme present | Sequoia 15.2–15.x only (hard gate `version_major==24`) |
| **Cards (IOPCIMatch)** | same 19-ID set as upstream; Wi-Fi 6/6E for AirDrop (AX211 tested; AX201/AX210/AX200/AX1690i reported); 7000/8000/9000 run "plain Wi-Fi" via iwm | upstream 19 IDs **+ BE IDs** `0x272b 0xa840 0x7740 0x4d40` | same 19-ID set as upstream | same 19 IDs (unreduced plist) |
| **Firmware** | 12×API-68 ucode + 3 pnvm + 20 legacy iwn/iwm (upstream-identical) | **16 ucode** (12×API-68 + `bz-b0-gf-a0-92`, `bz-b0-fm-c0-92`, `gl-c0-fm-c0-92`, `gl-c0-fm-c0-86`) + 7 pnvm + 20 legacy; "hardware revision picks the firmware, highest adapted API tried first" | upstream-identical (12+3+20) | 12×API-68 + 3 pnvm only (legacy removed; AX211 needs 2 of the 15) |
| **WPA3 statement** | "On a WPA2/WPA3 transition network the Mac joins with WPA2 and without PMF, as AirportItlwm does. WPA3-only networks can't be joined" | WPA3-Personal (SAE, H2E) + OWE "✅ on BE200"; transition ✅ all | "WPA3-only … not supported" (dev doc lists SAE as *next required work*) | SAE-only rejected; transition via RSN-IE rewrite |
| **Build system** | no `.xcodeproj`; `tools/build.py` (clang, per-OS `-D__IO80211_TARGET`, Sonoma `wcl=False`) | Xcode schemes incl. `-Tahoe`, `-Sequoia`, `(all)` | Xcode (Sequoia/Tahoe/(all)) + host test suites under `tests/` | Xcode, Sequoia only |

All three forks share the upstream WCL architecture (message-201 push, WCL.cpp within ±1 line of upstream for AX; +200 lines FI; +835 lines ER).

---

## Key-area comparison tables

Legend per cell: **SAME** = byte-identical/upstream-inherited · **FIXED** = fork addresses it · **DIFF** = fork diverges (other direction) · **ABS** = absent.

| Focus area | Audited tree (reduced) | ForbiddenItlwm | Eric-AirportItlwm | AirportItlwm-AX211 | upstream 7204c69 |
|---|---|---|---|---|---|
| WCL.cpp / WCL.hpp vs upstream | identical (1014/566 ln) | +200 ln (LQM machinery, scan stats, channel-info under gate) | +835 ln (SAE/6GHz/user-EAPOL/deferral) | −1 ln (counters, AKM fix, Fast Lane) | — (baseline) |
| ScanDone can overtake final ScanResults (DRV-AP-011) | SAME (0-ms timer hop) | **instrumented** (`wclScanStats`, `beaconsWhilePending`; "scans end with results=0 while beacons arrive" — issue #20/#24/#34) | **FIXED by design**: results held (`keepWCLScanResult`, dedup by BSSID+spec), replayed as 201s *before* 237 in `finishWCLScan`; `completeWCLScan` succeeds if `wclScanResultCount>0`; legacy `APPLE80211_M_SCAN_DONE` re-posted for Tahoe airportd | SAME | SAME |
| `scanSkipCompletion` one-shot guard (DRV-AP-009) | SAME (one-shot consume) | SAME (+ `doneSkipped` counter) | **FIXED**: replaced by state flags `scanDeferred \|\| ic->ic_wcl_scan_restart` (`EVT_SCAN_DONE` break) | SAME | SAME |
| Scan/join Busy contract (DRV-AP-008) | SAME (kIOReturnBusy; 20-s window) | SAME (+ refusal statistics) | **DIFF**: deferred scans (`scanDeferred`) replayed at DRIVER_READY *before* deferred join; deferred join survives DRIVER_STOPPED if `IFF_UP`; enterprise join timer 60 s | SAME | SAME |
| Roam blocked by latched `F_DESBSSID` (DRV-11C-002) | SAME (WCL.cpp:515 region) | SAME (`WCL.cpp:598` latch / `:699` clear on leave) | SAME (`WCL.cpp:1225/:1347`) | SAME (`WCL.cpp:520/:616`) | SAME |
| WCL state staleness after roam/link-flap (DRV-AP-005; joinBSSID-keyed freshness) | SAME | PARTIAL: link-quality reset on down/DRIVER_STOPPED; periodic RSSI-only LqmUpdate (2 s) — but `joinBSSID` still the only freshness key | PARTIAL: associated-AP beacon republish removed (dup spam gone); `joinBSSID` still gates first-beacon/LinkStatus; adds `setWCLNativeLinkReady` for enterprise | SAME | SAME |
| LQM / link-quality metric to macOS (DRV-AP-021; −2 "off" kills push/iMessage) | SAME (3-tier, 8-beacon cadence) | **FIXED**: `itlReportLinkQuality` → `IOSkywalkNetworkInterface::reportLinkQuality` (sets ifnet LQM; configd/apsd path) + `itlwm_lqmint` rate-limit | DIFF (MLO/RSNXE fields; per-beacon RSSI injection) | SAME | SAME |
| `setPOWER` OR-logic on `IFF_UP\|IFF_RUNNING` (DRV-AP-006) | SAME (V2.cpp:1152 region) | SAME (`V2.cpp:2683`) | SAME (`V2.cpp:1366`) | SAME (`V2.cpp:1228`) | SAME (V2.cpp:1152; STAIOCTL.cpp:1006) |
| WPA3-SAE join (DRV-11D-003; `#ifndef AIRPORT_WCL` dead block) | SAME (SAE bit → Invalid → Unsupported) | SAME (README: "WPA3-only can't be joined"; net80211 SHA-256 preference comment added) | **FIXED**: live SAE path — `classifyLegacyAuth→PersonalSAE`, raw SAE password (cipher 10), net80211 `ieee80211_sae.c` + `IEEE80211_AUTH_ALG_SAE` (input.c:3473), BearSSL-derived P-256 (`ec_p256_m31.c`, `i31.c`), `clearWCLSAE` on reset; H2E + hunting-and-pecking | SAME (dev doc: SAE is *next required work*) | SAME |
| WPA3→WPA2 transition hack (`selectWPA2TransitionMode`) | SAME (live; upstream 7204c69 fix) | SAME | SAME (kept; plus native SAE alongside) | SAME | SAME (introduced by 7204c69 merge #36) |
| 6 GHz / UHB (`#ifdef notyet`; DRV-11D-001/DRV-AP-003) | SAME (excluded) | SAME (notyet intact) | **FIXED (BE-qualified)**: `notyet` removed from `iwx_nvm_channels_uhb` (ItlIwx.cpp:637–652); `IEEE80211_CHAN_6GHZ` + `chan2number`/`ieee2chanidx` (6GHz idx = 181+…); WCL `channels6GHz[32]` bitmap + `NativeChannelInfo.sixGHz`; RNR/PSC discovery in v17 scan; AX211 path present but unqualified ("✅ on BE200") | SAME | SAME |
| TVQM TX queues never released on `ampdu_tx_stop` (DRV-IWX-011) | SAME | SAME (adds `stationId`+`CoexBaQueueOwner` to `tvqm_enable_txq` for AWDL — still no release) | SAME (adds `!sc_use_mld_api` guard only) | SAME | SAME (body identical) |
| Single shared non-aggregation TX queue (DRV-IWX-010) | SAME | SAME | SAME (gen3 freeze TODO comment retained; `notyet` 256-slot block intact) | SAME | SAME |
| RX BA timer teardown / gap deadline (DRV-11D-023) | SAME | SAME | DIFF (MLD path reworks) | **FIXED-approach**: `RxTiming.hpp` (overflow-safe deadlines, "disabled timeout must never tear down", gap-timer re-arm rules, 4096-wrap indexing) + host tests; honest negative: "timer repairs have not established a working speed fix" | SAME |
| Node cache / `getSCAN_RESULT` cursor (DRV-AP-016/017; DRV-11C-025) | SAME (`HalService` typo; `asr_nrates` zero-loop) | **FIXED**: `ItlScanCursor.hpp` address-keyed cursor (no node pointers across requests) + join-target protected from cache eviction (`node.c` `des_bssid` guard, issue #69); log hardening (no `%s` of non-NUL-terminated SSID) | DIFF (result-ring model) | SAME | SAME |
| EAPOL input validation (key-length wrap) | SAME (`paylen > totlen - sizeof(*key)` wraps) | **FIXED**: `EAPOLKeyLength.hpp` + `tests/eapol_key_length.cpp` ("comparing against totlen - sizeof(*key) wrapped … any key data length passed") | SAME (line retained at pae_input.c:138) | SAME (pae_input.c:136) | SAME |
| Firmware payload (15 blobs for AX211 needing 2) | reduced-legacy only (12+3 API-68) | unreduced (12+3+20 legacy) | 16+7+20 (adds API 92/86) | unreduced | unreduced |
| Fast Lane accept-and-ignore (DRV-AP-023) | SAME (return Success) | SAME | SAME | **DIFF**: returns Unsupported when fast-lane bytes non-zero | SAME |

---

## Findings

### REF-001: The roaming-killing `F_DESBSSID` latch is universal — no fork fixes it
- **Classification: UPSTREAM-INHERITED DEFECT (present in laobamac 7204c69 and all forks)**
- Severity/Confidence: High (capability) / High
- Evidence: latch set in `startWCLJoin`, cleared only on leave — audited WCL.cpp:515 (identical to upstream); FI `ForbiddenItlwm/WCL/WCL.cpp:598/:699`; ER `AirportItlwm/WCL/WCL.cpp:1225/:1347`; AX `AirportItlwm/WCL/WCL.cpp:520/:616`. All consult the same net80211 gate (upstream `ieee80211_node.c:604/951/1097`; ER `:610/:968/:1114/:1466`).
- Analysis: DRV-11C-002's premise correction holds across the entire family: driver-internal roaming is disabled by design in every AirportItlwm descendant; WCL's roam surface stays stubbed everywhere (ER adds MLO plumbing, not roam). Any "make roaming work" project must first decide *where* to un-latch (WCL join vs bgscan), and no reference demonstrates it. Do not treat any fork as a roaming reference.

### REF-002: The ScanDone-overtakes-ScanResults race is fixed by *restructuring*, not by scheduling patches — Eric
- **Classification: REFERENCE FIX AVAILABLE (Eric; FI provides instrumentation only)**
- Severity/Confidence: Medium (matches "network list missing my 5 GHz AP") / High (design-level)
- Evidence (ER `WCL/WCL.cpp`): `keepWCLScanResult` dedups by channelSpec+BSSID into `wclScanCopies[]`; `finishWCLScan` posts every held 201 **then** 237; `completeWCLScan` returns Success when `scanCompleted || wclScanResultCount`; plus re-post of legacy `APPLE80211_M_SCAN_DONE` ("the legacy scan-complete notification still drives airportd's result fetch on Tahoe; without it the cached results never reach the UI"). FI instead *measures* the same race: `wclScanStats` (`results=0 while beacons arrive`, issues #20/#24/#34), `ItlwmScanStats`/`ItlwmScanLast` IORegistry properties, `beaconsWhilePending`.
- Analysis: Eric's ordering guarantee is structural — the race cannot occur because completion is defined by *held results*, not by which thread wins. FI's counters are exactly the instrumentation AUDIT-2b asked for (open question 2) but change no behavior. Both merit study; neither should be copied blind (Eric's batch replay changes WCL-visible timing semantics; verify against airportd on 15.8 before adopting).

### REF-003: The single-shot `scanSkipCompletion` guard is replaced by state flags — Eric
- **Classification: REFERENCE FIX AVAILABLE**
- Severity/Confidence: Medium / Medium-High
- Evidence: audited/FI/AX/upstream consume one completion (`scanSkipCompletion=false`); ER `EVT_SCAN_DONE`: `if (scanDeferred || ic->ic_wcl_scan_restart) break;` — a *state* predicate (multiple spurious completions all skipped) instead of a one-shot. FI counts `doneSkipped` but keeps the one-shot.
- Analysis: directly addresses AUDIT-2b DRV-AP-009 ("guard is one-deep"). Eric's `ic_wcl_scan_restart` lives in net80211 (`ieee80211com`), i.e. they extended the *net80211* contract rather than patching WCL — an architectural lesson.

### REF-004: Real WPA3-SAE exists only in Eric — full stack, crypto included
- **Classification: REFERENCE FIX AVAILABLE (qualified on BE200; AX211 path untested by them)**
- Severity/Confidence: High (capability) / High (code present) · hardware-qualified only on BE200
- Evidence (ER): `WCL.hpp:579-675` (`LegacyAuth::PersonalSAE`, `DerivedCredentialKind::SAE`, "Native WCL carries the raw SAE password (cipher 10), not a PMK"); net80211 `ieee80211_sae.c` + `ic_sae_*` state (`ieee80211_var.h:751-760`); `IEEE80211_AUTH_ALG_SAE` accepted in `ieee80211_input.c:3473` (`ieee80211_auth_sae`); AKM selector 8 → `IEEE80211_AKM_SAE` (input.c:1963); crypto `ec_p256_m31.c`/`i31.c` (BearSSL P-256, per credits); `clearWCLSAE` on DRIVER_STOPPED. FI/AX keep the audited tree's behavior (README/dev-doc statements).
- Analysis: this is the reference for closing DRV-11D-003/004 (SAE + H2E). Note the split: *auth algorithm* (net80211+crypto) is card-independent; their hardware qualification is BE200-only, and their OWE ("EnhancedOpen") rides the same join-classification seam. GCMP still absent even in ER (no `crypto_gcmp.c`) — SAE-Personal uses CCMP, so WPA3-Personal works without GCMP; WPA3-Enterprise remains blocked (DRV-11D-002 persists in all trees).

### REF-005: 6 GHz is implemented end-to-end in Eric — including deleting the exact `#ifdef notyet` line
- **Classification: REFERENCE FIX AVAILABLE (BE200-qualified; AX211 unqualified)**
- Severity/Confidence: High (capability) / High
- Evidence (ER): `iwx_nvm_channels_uhb` now contains the 6–7 GHz PSC list **un-guarded** (ItlIwx.cpp:637-652; upstream keeps `#ifdef notyet` at :416); `IEEE80211_CHAN_6GHZ` flag + `ieee80211_chan2number` + `ieee80211_ieee2chanidx` (6GHz indices 181+, band-checked; `ieee80211.c:344+`); WCL scan decode carries a separate `channels6GHz[32]` bitmap ("a 6 GHz channel is also above 14, so without this byte every 6 GHz channel we publish is advertised as 5 GHz"); `NativeChannelInfo.sixGHz` at 0x1aa0 (`static_assert`ed); RNR-hinted/PSC scanning (`ItlIwxApi86.cpp:175-317`, "an empty 6 GHz list is a symptom, not an instruction"); `supports6GHz` in WCL channel info.
- Analysis: the complete answer to DRV-11D-001 + DRV-AP-003. The band-aware channel *indexing* (not the firmware table alone) is the load-bearing idea — upstream's overlapping-numbering hack (WCL.hpp "Do not confuse 6 GHz channel numbers…") is what made 6 GHz unrepresentable. On AX211 the same net80211/WCL plumbing applies, but the discovery path (RNR/PSC v17 scan) is exercised by them only on MLD firmware; qualification on API-68/AX211 is still open.

### REF-006: TVQM TX-queue leak on `ampdu_tx_stop` — identical everywhere
- **Classification: UPSTREAM-INHERITED DEFECT (no fork addresses it)**
- Severity/Confidence: High (progressive degradation) / High
- Evidence: `iwx_ampdu_tx_stop` bodies byte-identical (UP :4715, AX :4727, FI :4993; ER :5401 adds only `if (!sc->sc_use_mld_api)` around the same two lines). No fork ever sends `IWX_TX_QUEUE_CFG` disable/remove; only `ENABLE_QUEUE` exists (grep across all trees). FI's `tvqm_enable_txq` gains `stationId`/`CoexBaQueueOwner` (AWDL coex) — still no release.
- Analysis: DRV-IWX-011 (queue leak → `fwqid` monotonic → aggregation refused after ~64 cycles) is untouched by the entire fork family, including the two most advanced ones. The fix must be designed from the firmware spec (Linux `mld`/`mvm` tx queue removal), not from any reference implementation.

### REF-007: `setPOWER` OR-logic bug — identical everywhere
- **Classification: UPSTREAM-INHERITED DEFECT (no fork addresses it)**
- Severity/Confidence: Medium / High
- Evidence: `bool isRunning = (…if_flags & (IFF_UP | IFF_RUNNING)) != 0;` — UP `V2.cpp:1152`, AX `:1228`, ER `:1366`, FI `:2683` (plus dead STAIOCTL copies at :1006 in each). The correct `== (IFF_UP|IFF_RUNNING)` form exists only inside WCL.cpp:146 (all trees).
- Analysis: DRV-AP-006 confirmed universal; no reference fix exists. The one-liner (`& ==` both flags) remains ours to make.

### REF-008: LQM/link-quality reporting — FI solves the "link quality off (−2)" class
- **Classification: REFERENCE FIX AVAILABLE (FI; partial for the DRV-AP-005 cluster)**
- Severity/Confidence: Medium-High / High (documented user impact: push/iMessage dead over Wi-Fi)
- Evidence (FI `WCL.cpp` +709-800 region): `itlReportLinkQuality` binds `IOSkywalkNetworkInterface::reportLinkQuality` (`__asm__` symbol) — "Nothing set it on Tahoe: … `IO80211SkywalkInterface::setLQM` is an empty stub, so en0 stayed 'off' and push, iMessage and other Apple services never connected over Wi-Fi"; periodic RSSI-only LqmUpdate every 2 s while port up (firmware beacon filtering starves the beacon-driven path); `resetLinkQuality` on link-down and DRIVER_STOPPED; `itlwm_lqmint` boot-arg rate-limit ("Apple's drivers report on change"); Tahoe-only struct layout for the RSSI-only update, with per-OS `#if`.
- Analysis: complements the audited tree's 3-tier LQM (DRV-AP-021) with the *transport* that was missing: the ifnet link-quality metric configd/apsd consume. This is the strongest single user-visible fix in the comparison and it is *outside* the WCL message layer — a reminder that "native integration" is also BSD-ifnet-level contracts.

### REF-009: Scan/join mutual exclusion — Eric's deferral model
- **Classification: REFERENCE FIX AVAILABLE (contract redesign)**
- Severity/Confidence: Medium / Medium-High
- Evidence (ER `WCL.cpp`): requests arriving while the driver restarts are *deferred* (`scanDeferred`, `deferredJoin`); at DRIVER_READY the deferred scan is issued "before a deferred join so the join has a fresh result list to pick from"; a deferred join is *not* killed by DRIVER_STOPPED if the interface is still `IFF_UP`; `DriverAvailable` (55) is posted twice — once via WCL route, once via interface route "message 55 there branches to IO80211ControllerMonitor::setDriverAvailable… airportd reads it when it asks the driver for the country code"; enterprise joins extend the timer to 60 s.
- Analysis: addresses DRV-AP-008's "WCL must retry" gap and part of DRV-AP-007 (wake/recovery). The dual-posting of message 55 is a discovered wire fact worth recording in our WCL contract notes regardless of adoption.

### REF-010: EAPOL key-length validation — FI only; new upstream-inherited defect surfaced by this comparison
- **Classification: REFERENCE FIX AVAILABLE (fixes an UPSTREAM-INHERITED defect not in AUDIT-2's list)**
- Severity/Confidence: Medium (input validation on the 4-way handshake path) / High
- Evidence: UP/audited/AX `ieee80211_pae_input.c`: `if (paylen > totlen - sizeof(*key))` — unsigned wrap when the frame is shorter than the header ("any key data length passed"); ER retains it (pae_input.c:138). FI replaces it with `ItlEAPOL::keyLengthsValid(mbuf_pkthdr_len, bodylen, paylen, sizeof(*key), MCLBYTES)` (`EAPOLKeyLength.hpp`), host-tested in `tests/eapol_key_length.cpp`.
- Analysis: add to the master defect list as a new item (supplicant-side robustness); FI's helper is testable in userspace — the pattern (extract validation into a kernel-type-free header + host test) recurs across FI (ItlScanCursor, EAPOLKeyLength) and AX (RxTiming) and is the most transferable *engineering* practice seen here.

### REF-011: Join target can be evicted by the node-cache make-room sweep — FI only
- **Classification: REFERENCE FIX AVAILABLE (upstream-inherited defect)**
- Severity/Confidence: Medium (join reliability) / High
- Evidence: FI `ieee80211_node.c` (+10 at :2254): in the cache make-room sweep, skip nodes matching `(ic_flags & F_DESBSSID) && ADDR_EQ(ni_bssid, ic_des_bssid)` — "Room for a new scan result must not cost the BSS a join is waiting to find… the join never reached AUTH (#69)". UP/audited/ER/AX keep the sweep unconditional.
- Analysis: a distinct mechanism from DRV-11C-025 (the BSSID+SSID compare quirk) but in the same function family; matters under AP-dense environments where the cache churns mid-join.

### REF-012: `getSCAN_RESULT` cursor staleness — FI's address-keyed cursor
- **Classification: REFERENCE FIX AVAILABLE (legacy-path defect cluster DRV-AP-016/017 adjacent)**
- Severity/Confidence: Low-Medium (legacy/compat path; live on FI's Sonoma build) / High
- Evidence: FI `include/ItlScanCursor.hpp` + `tests/scan_cursor.cpp`: cursor = last returned MAC address, next result = first node above it ("no node pointer is kept across requests — audit ST02"); kills the held-`fNextNodeToSend`-across-requests pattern (and the `HalService` typo's blast radius) rather than patching it.
- Analysis: for our WCL-native Sequoia target this path is secondary, but the redesign (state = address, not pointer) is the correct shape if the legacy walker must survive.

### REF-013: RX BlockAck timer/gap-deadline math — AX's testable repair (with an honest negative)
- **Classification: REFERENCE FIX AVAILABLE (approach); NOT APPLICABLE to WCL-layer findings**
- Severity/Confidence: Medium (RX robustness) / High (math) · hardware benefit unproven by the fork itself
- Evidence: AX `hal_iwx/RxTiming.hpp`: overflow-safe deadline planning ("A disabled negotiated BA timeout must never tear down the session"), gap-timer re-arm only when `stored && !removed && !pending`, 4096-wrap sequence indexing for non-power-of-two windows; host tests `tests/iwx_rx_timing_tests.cpp`, `iwx_rx_timer_integration.cpp`. AX211-DEVELOPMENT.md: "The timer repairs have not established a working speed fix" — an explicit negative result on the physical machine.
- Analysis: maps to the DRV-11D-023/013 neighborhood. The lesson is the *method*: pure functions in a header, host-side unit tests, then integration — and reporting the negative result. Do not assume the repair fixes our throughput symptom; AX's own data says it did not.

### REF-014: Fast Lane handling — AX diverges from the load-bearing accept-and-ignore
- **Classification: fork-specific behavior (NOT APPLICABLE to the audited tree's contract; risk noted)**
- Severity/Confidence: Low / High
- Evidence: UP/audited/FI/ER return `kIOReturnSuccess` unconditionally, with upstream's comment ("returning an error makes WCL treat it as Update Bss fail and tear the link down ~0.4 s after LINK_STATE_IS_UP"). AX `WCL.cpp:905-908` returns Unsupported when the fast-lane bytes are non-zero.
- Analysis: upstream's mimicry is deliberate and evidence-based (DRV-AP-023 validated it); AX's stricter answer is *untested against that teardown path* by anything in-tree. Treat AX here as a hypothesis, not a fix.

### REF-015: The reduction introduced none of the found defects — everything behavioral is upstream-inherited
- **Classification: AUDITED-TREE-SPECIFIC (better/reduced) — inherited-vs-introduced question answered**
- Severity/Confidence: — / High
- Evidence: `git diff 7204c69..HEAD` on live paths shows only: `itlwm/hal_iwx/if_iwxreg.h +9` (shared `IWM_MIN_DBM` constant, commit a454f64), plist rewrites (reduction: non-Sequoia personalities removed), dead-code whitespace in `AirportItlwm.cpp` (legacy file, not compiled), and deletions of iwm/iwn HALs + standalone itlwm + macOS26 headers. WCL.cpp/WCL.hpp, SkywalkInterface.cpp, AirportItlwmV2.cpp, net80211, and `AirportItlwm.cpp`'s live siblings are **byte-identical to 7204c69**; the F_DESBSSID latch, TVQM leak, scan-forever, `scanSkipCompletion`, `#ifndef AIRPORT_WCL` SAE-dead-block, `#ifdef notyet` 6 GHz, setPOWER OR-bug, `notyet` 256-slot queue and beacon-filter blocks all pre-exist upstream.
- Analysis: consequently the defect set found by AUDIT-2 (reports 10-13) is 100% upstream-inherited; the prior session's reduction changed scope, not behavior. Residual reduction opportunity: the tree still embeds 12 API-68 ucode blobs of which AX211 (`0x51F0`, so-a0-gf-a0) needs exactly 2 (`iwlwifi-so-a0-gf-a0-68.ucode` + `.pnvm`) — 10 blobs are dead weight (DRV-IWX-002's "four advertised IDs can never load firmware" persists unreduced); no fork practices firmware reduction at all (all carry 20 legacy iwn/iwm blobs on top).

---

## Lessons for future engineering (study, do not blind-copy)

1. **Eric's completion-by-held-results scan model (REF-002)** — the general principle: define completion by *consumable state*, not by thread timing. Verify airportd's 15.8 behavior before adopting; the legacy `APPLE80211_M_SCAN_DONE` re-post is a Tahoe-specific wire fact.
2. **Eric's band-aware channel indexing (REF-005)** — solve representational gaps (6 GHz numbering) in the data model (`chan2number`/`ieee2chanidx`, `channels6GHz[32]`), not with per-callsite filters. This is the single largest capability unlock in the comparison.
3. **FI's link-quality transport (REF-008)** — the ifnet `reportLinkQuality` path is outside WCL and was invisible to all prior audits; "native integration" includes BSD-level contracts consumed by configd/apsd.
4. **The shared testable-header pattern (FI `EAPOLKeyLength`/`ItlScanCursor`, AX `RxTiming`)** — extract invariants into kernel-type-free headers + host unit tests. Cheap, portable, and it converts kernel-audit claims into regression tests.
5. **State-machine flags over one-shot guards (REF-003)** — Eric's `scanDeferred`/`ic_wcl_scan_restart` in *net80211* (extending the HAL contract) beats WCL-side boolean consumables.
6. **Honest negative results (AX)** — "a throughput improvement has not yet been established" and "timer repairs have not established a working speed fix" set the reporting standard our audit should follow.
7. **Explicit caveat:** none of these forks is a reference *correctness* oracle. FI is AI-assisted (disclosed), self-described beta; ER's Wi-Fi 7 path is marked experimental per-device; AX is a research fork. Every approach above must be re-derived against our own target (AX211/API-68/Sequoia 15.8.2), re-qualified on hardware, and never transplanted by copy-paste — per the audit directive.

---

## Open questions

1. Does Eric's result-batching (REF-002) hold on Sequoia 15.8 airportd, where (per upstream WCL.cpp) results are consumed as push messages — i.e., does *deferring* 201s to ScanDone time regress perceived scan latency?
2. Eric qualified 6 GHz only on BE200/MLD (API 92): does the RNR/PSC discovery path work at all on API-68 (AX211), or does it need the v17 scan request the older firmware lacks? (Their `iwlwifi-so-a0-gf-a0` config carries `.uhb_supported` — untested.)
3. FI's `itlReportLinkQuality` (REF-008) is exported by IOSkywalkFamily on *Tahoe*; their Sequoia note says only en0's metric is reported on 24H241. Does 15.8.2 expose the same symbol (their build ran `__MAC_15_2`)?
4. FI's base is laobamac **2.4.1** while ours is 7204c69 (2.4.0-era + WPA3 fix): is 2.4.1 a *later* laobamac revision (post-7204c69) containing fixes we have not seen? A dated comparison of FI's base against 7204c69 would settle whether FI inherits extra upstream fixes.
5. AX's base d695c97 predates 7204c69's WPA3-transition merge — AX inherited the *older* transition behavior; does any AX release actually join WPA2/WPA3-transition networks on hardware?
6. No fork releases TVQM queues (REF-006) and no fork fixes the shared non-aggregation TX queue: is the 256-slot freeze TODO (upstream comment, retained verbatim by ER) the actual blocker for both? A Linux `mld`-spec-derived design is the only route; nothing in the reference set can be reused there.
7. Eric keeps `selectWPA2TransitionMode` *and* native SAE: on a PSK/SAE transition network, which does their join path actually take (credential-kind dispatch)? If both are live, there is a policy seam worth understanding before we ever touch ours.

---

*AUDIT-3 complete. Companion reports: 00/10/11/12/13/20/21 in `research/ax211-audit/`. No repository files were modified; only this report (and its `download/` copy) was written.*
