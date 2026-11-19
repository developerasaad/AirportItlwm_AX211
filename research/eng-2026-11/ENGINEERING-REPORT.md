# AirportItlwm AX211 — Engineering Investigation & Change Record

Date: 2026-11-19/20
Baseline: `baseline-2026-11-19` (commit `6039eb6`, CI-verified by run 44591987929)
Method: Observe → inspect → reconstruct → hypothesize → verify/falsify → implement → validate.
All findings below were independently verified against the current tree by the
coordinator (line numbers re-read at the cited locations), using five
read-only subsystem investigations (A: HAL/firmware, B: net80211/MLME,
C: macOS/WCL integration, D: data path, E: concurrency/lifecycle) that
cross-check the earlier `research/ax211-audit/` dossier. Where the earlier
dossier was wrong or imprecise, it is corrected here.

---

## A. Source coverage (Phase I/II)

Machine-readable inventory: `inventory.json` (232 files). Summary:

| Category | Files | Lines | Notes |
|---|---|---|---|
| Active sources (compiled, 57 TUs incl. generated FwBinary.cpp) | 55 | 47,201 | ItlIwx.cpp 13,919; net80211 port; WCL/Skywalk/V2 integration |
| Headers | 117 | 33,441 | Apple private SPI mirrors (macOS15), HAL/net80211 headers |
| Inactive V1 sources | 5 | 3,218 | AirportItlwm.cpp, AirportSTAIOCTL.cpp, AirportVirtualIOCTL.cpp, AirportAWDL.cpp, AirportItlwmInterface.cpp — in build phase "None", not compiled (verified in project.pbxproj) |
| Firmware blobs | 15 | — | 12 API-68 ucode + 3 pnvm; embedded via generated FwBinary.cpp |
| Build/project | 6 | — | project.pbxproj, scheme, fw_gen.sh, zlib_compress_fw.py, load/unload |
| Docs/research/tools | 26 | — | README, prior audit, diagnostics kit |

Build facts (verified): single target `AirportItlwm-Sequoia`; preprocessor
`AIRPORT_WCL AIRPORT_VTD AIRPORT __IO80211_TARGET=__MAC_15_2 __PRIVATE_SPI__
IO80211FAMILY_V2 IEEE80211_STA_ONLY` (+`DEBUG=1` in Debug config); SDK
MacOSX15.5; x86_64; `AIRPORT_VTD` compiles in the ItlDmaArena bounce-buffer
layer (full TX copy + RX copy/zero per packet — architectural, see D-9).
Coverage of active source: ItlIwx.cpp analyzed by function region (A+D+E,
with coordinator spot-checks); net80211 control plane fully read (B); WCL/
Skywalk/V2/EthernetInterface/IOPCIEDeviceWrapper fully read (C); ItlDma/
_ifq/_mbuf/_task/crypto-pae paths fully read (D); timeout.c/CTimeout read
in full (E). Generated firmware arrays verified by provenance/hash workflow
(CI), not narrated line-by-line.

## B. Reconstructed architecture (Phase III)

1. **Match/init**: IOPCIEDeviceWrapper (personality `itlwm`, 19 PCI IDs)
   wraps the IOPCIDevice, creates the shared IO80211WorkQueue, publishes
   AirportItlwm (class in AirportItlwmV2.cpp, extends IO80211Controller).
   AirportItlwm::start → ItlHalService::initWithController → ItlIwx::attach
   → firmware load (iwlwifi-so-a0-gf-a0-68 for 8086:51f0 sub 0094, verified
   via the dev_info table walk) → iwx_init → DRIVER_READY.
2. **macOS → driver**: on Sequoia, WCL (airportd's Wi-Fi control layer).
   Requests arrive as IO80211InfraProtocol virtual calls on
   AirportItlwmSkywalkInterface (e.g. `setWCL_SCAN_REQ`,
   `setWCL_ASSOCIATE`, `setPOWER`), dispatched through the single command
   gate (`wclCommand`). The legacy apple80211 ioctl surface returns
   kIOReturnUnsupported in this build.
3. **Scan**: `beginWCLScan` (WCL.cpp:237) → new_state(SCAN) → `iwx_scan`
   → ONE firmware UMAC scan command covering all channels of both bands,
   firmware-driven dwell (active 10 TU, passive 110 TU, adaptive dwell
   budget 300 TU full / 100 TU directed; fragmented only on low-latency
   requests). Beacons/probe-resps → `ieee80211_recv_mgmt` merges into the
   node RB-tree; every frame posts `EVT_BEACON` → `publishWCLBeacon` → one
   WCL `ScanResult` message per beacon frame (no dedup/age). Sweep end →
   `EVT_SCAN_DONE` → 0-ms timer hop → WCL `ScanDone`.
4. **Join**: `setWCL_ASSOCIATE` → `startWCLJoin` (WCL.cpp:423): configure
   RSNA/PSK, latch `ic_des_bssid` + `IEEE80211_F_DESBSSID`, 30 s joinTimer,
   → SCAN → `choose_bss` → `node_join_bss` → AUTH (5 s mgt timer) → ASSOC
   (5 s) → RUN. 4-way handshake runs in the in-driver supplicant
   (`ieee80211_pae_input`); `setWCL_LINK_STATE_UPDATE`/link-up marks
   `portAuthorized`. WCL is informed via AssocComplete/ConnectComplete/
   FirstBeacon/LinkStatus messages.
5. **Failure paths**: assoc *rejection* posts `EVT_STA_ASSOC_DONE` even on
   failure (WCL translates to ConnectComplete(fail)). Auth/assoc *timeouts*
   and 4-way failures are silent to macOS: the watchdog retries in-driver
   (AUTH, ≤3), then rescans; only the 30 s joinTimer produces a
   user-visible failure. AP deauth posts Deauth; AP **disassoc is silent**
   and auto-re-associates.
6. **Data**: Skywalk outputThread → `outputStart`/`enqueuePacket` →
   if_snd (FIFO) → gate-serialized `_iwx_start_task` → `ieee80211_encap`
   → `iwx_tx`: one shared non-aggregated ring for ALL non-BA frames
   (mgmt `IWX_MGMT_TID` and data alike, `first_data_qid`), per-TID TVQM
   rings (256 slots) once BA AGREED. RX: MSI interrupt → ICT →
   `iwx_rx_pkt` (bounce copy+zero) → `iwx_rx_mpdu_mq` (driver-side
   reorder, fw decrypt verify, CCMP PN check) → `ieee80211_inputm` →
   EAPOL to supplicant / data to Skywalk via gated `_if_input`.
7. **Concurrency**: ONE main workloop + command gate carries RX interrupt
   processing, TX drain, newstate/ba tasks (via single-threaded systq
   re-entering the gate), CTimeout callbacks (raw on the workloop), WCL
   requests, and PM trampolines. TWO exceptions outside that
   serialization: the 1 s watchdog on a **separate** workloop (fixed in
   this change set), and WCL country-update thread_calls. `splnet()` is a
   no-op; KASSERT compiles away.
8. **State ownership**: `ic_state`/MLME owned by net80211 (mutated from
   RX, watchdog, ioctl/WCL, timers); WCL view keyed to `joinBSSID` +
   `assocNotified`/`firstBeaconNotified`/`portAuthorized`/`wclLinkIndicated`;
   BSD link layer mirrored to en0 via `setLinkState`.

## C. Findings register (Phase IV) — verified, with symptom mapping

User symptoms: **S1** slow discovery/connection/switching; **S2** Settings
vs menu-bar divergence/stale info; **S3** first join attempt fails, retry
connects without password re-entry; **S4** suspected overhead.

### C.1 Confirmed defects (fixed in this change set)

| ID | Finding | Evidence (current tree) | Symptom | Fix |
|---|---|---|---|---|
| F-01 | Unconditional per-frame `XYLog` in the TX rate computation, incl. two function calls in the format args | ItlIwx.cpp:6913 (in the rate helper called from `iwx_tx` per frame) | S4 | CS1 |
| F-02 | Unconditional per-frame `XYLog` in software-crypto TX | ieee80211_crypto.c:283 | S4 | CS1 |
| F-03 | Scan-result conversion zeroes the rate array (loop bound read from just-zeroed struct; rates always empty) | AirportItlwmSkywalkInterface.cpp:981,990-992 | S2 (degraded CURRENT_NETWORK/SCAN_RESULT data) | CS2 |
| F-04 | Undeclared identifier `HalService` in live `getSCAN_RESULT` (compiles only because RB_NEXT discards arg 2; latent landmine) | AirportItlwmSkywalkInterface.cpp:1042; tree.h:725 | — | CS2 |
| F-05 | `setLinkState(down)` is a no-op (`ifnet_set_flags(..., 0)` — mask 0 clears nothing): en0 keeps IFF_RUNNING forever after link loss | AirportItlwmEthernetInterface.cpp:126 | S2 (configd/System Settings stale "connected") | CS3 |
| F-06 | RX BA teardown leaks reorder buffers + parked mbufs per roam/deauth (ba_buf overwritten on next ADDBA) | ieee80211_node.c:2029-2057 (no free) vs the correct pattern proto.c:1189-1196 | resource leak | CS4 |
| F-07 | Off-by-one bounds checks in rate pretty-printers (OOB read; `bw==5` reachable from every TLC notification) | ItlIwx.cpp:527-528, 543-544 | memory safety | CS5 |
| F-08 | EAPOL key-length check unsigned wrap: `totlen - sizeof(*key)` wraps when `totlen < 99`; any `paylen` passes; OOB walk up to 64 KB pre-MIC | ieee80211_pae_input.c:129-137 (guard at 109 checks the mbuf, not totlen) | kernel memory safety | CS6 |
| F-09 | PNVM loader: dead `goto`, doorbell kicked after failed read, 2 s gate-held wait for a notification that cannot arrive | ItlIwx.cpp:2164-2177 | failure-path latency | CS7 |
| F-10 | 1 s watchdog runs on a separate workloop with zero gate serialization and mutates MLME state concurrently with RX/newstate; `releaseAll` frees the HAL before cancelling the watchdog; re-arm derefs possibly-NULL member | AirportItlwmV2.cpp:116-122, 345-361, 54-57 vs 72-79; ieee80211.c:906-929 | reliability (all symptoms' error paths) | CS8 |
| F-11 | Link recovery outside a WCL join never posts `LinkStatus(up)`; WCL view stays "down" while the driver is associated and traffic flows | WCL.cpp:624-640 (up branch only finishes pending joins; up message only at 747-759 during join) | **S2** | CS9 |
| F-12 | Auth/assoc timeout double-increments `ni_fails` (watchdog + SCAN transition), and `choose_bss` skips on ANY `ni_fails` (upstream OpenBSD tolerates < 2): one transient assoc timeout makes the target AP unselectable and evicted within 2 sweeps; join then idles until the 30 s WCL timeout | ieee80211.c:917-928; ieee80211_proto.c:1575-1581; ieee80211_node.c:1334-1346 | **S3** (and S1 switching) | CS10 |
| F-13 | gen3 fw-load error path (`!iwx_nic_lock` → return EBUSY) bypasses fail labels, leaking 3 DMA allocations per failed attempt (retry loop compounds) | ItlIwx.cpp:1255-1267 | resource leak | CS4b |

### C.2 Demonstrated inefficiencies (driver-wide, assessed)

- Per-beacon WCL `ScanResult` message with full IE copy + RSN rewrite parse,
  no dedup/throttle/age — while idle-scanning forever and ~10/s while
  associated (WCL.cpp:307-345, 744-746). Real driver+userspace cost (S4),
  but throttling changes what macOS sees per sweep; deferred pending runtime
  measurement (D-1).
- RX bounce path memcpy(used) + bzero(4096-used) per buffer; TX full-packet
  copy (AIRPORT_VTD design, compat.cpp:398-419). The zero-fill is
  **documented intentional behavior** (comment 393-397: stale recycled-mbuf
  bytes must never be parsed as packets) — not removed on speculation (D-2).
- Idle scan-forever loop with no backoff when no join is pending
  (node.c:1456-1484) — burns RF/CPU and posts per-sweep events. Changing
  cadence alters discovery latency; deferred (D-3).
- `IWX_DEBUG` hard-enabled, `iwx_debug=1`: per-command DPRINTFs (e.g.
  ItlIwx.cpp:6687) at control-plane frequency. Kept: negligible rate,
  primary owner diagnostic for hardware bring-up; per-frame sites removed
  instead (F-01/F-02).

### C.3 Plausible risks / unverified hypotheses (documented, not fixed)

- Sync-command timeout permanently consumes a 128-slot cmd-ring entry
  (ItlIwx.cpp:6695-6726; late response heals). Fixing requires
  sequence-verified slot recycling; current behavior is safe degradation.
- TVQM agg queues never returned to firmware on teardown; ~64 sessions
  then ADDBA refused (ItlIwx.cpp:4715-4729, 3497-3526). Fix needs the
  API-68 queue-removal command semantics verified against the firmware
  spec (Linux correspondence exists); wrong command risks firmware crash.
- qfullmsk global TX stall blocks EAPOL/mgmt (ItlIwx.cpp:10858-1083):
  architectural — mgmt and data share ONE ring (verified iwx_tx:6996-7014),
  so no per-queue reordering is possible without a second queue. Deferred.
- Stale BA tidmask can fabricate a BA agreement on re-assoc
  (ItlIwx.cpp:10286 vs 4573-4578); `iwx_run_stop` aborts on first error.
- EAPOL async key-install race (first encrypted frames may drop).
- Watchdog teardown in start() failure paths can still race (narrow).
- Prior-audit items that this investigation REFUTED or narrowed for the
  live build: DRV-AP-006 as stated (live `setPOWER` ON path checks
  IFF_RUNNING only; the quoted OR-expression is in dead non-WCL code, and
  the init-failure path clears IFF_UP — V2.cpp:1129-1144 vs
  ItlIwx.cpp:13850-13859); DRV-AP-011 as stated (both paths run on one
  workloop; the 0-ms hop serializes within a batch — the real window is
  via the one-deep skip flag, C.4); "30 s dead-BSSID lockout" (no such
  constant in net80211; the actual mechanism is F-12); ScanDone-overtake
  on 5 GHz specifically.

### C.4 Intentional behavior (verified, preserved)

- DESBSSID latched per association (roaming disabled by design in this
  single-AP fork).
- Open-network A-MPDU prohibition (anti-injection policy, output.c:490-507).
- 256-TFD agg-ring cap (author-documented macOS freeze workaround).
- Provider-identity spoof + deferred BSD attach (load-bearing Skywalk
  workaround).
- WPA2/WPA3-transition RSN-IE rewrite on scan messages only (documented).
- RX zero-fill (see C.2), EAPOL consumed by in-driver supplicant under WCL.

## D. Change contracts (Phase VI)

Each change set (CS) lists: problem → evidence → preserved behavior →
verification. Implemented as separate reviewable commits.

- **CS1 (F-01, F-02)** Remove the two per-frame kprintf sites. Preserve:
  all error-path and DPRINTF logging. Verify: build; strings absent.
- **CS2 (F-03, F-04)** Fix rate-array copy (set `asr_nrates` from node,
  bound to array size, then copy) and correct `HalService` → `fHalService`.
  Preserve: struct layout, iteration semantics (RB_NEXT walks the same
  tree). Verify: build; rates non-empty in getCURRENT_NETWORK path.
- **CS3 (F-05)** `ifnet_set_flags(..., flags & ~IFF_RUNNING, IFF_RUNNING)`
  on link-down: clear IFF_RUNNING (carrier) only; IFF_UP (admin) preserved
  as on native macOS. Verify: build; en0 RUNNING tracks association.
- **CS4 (F-06, F-13)** `ieee80211_ba_del` frees `ba_buf` + parked mbufs
  exactly as the DELBA path does (proto.c:1189-1196); fw-load error path
  jumps to existing fail labels. Preserve: timer cancel semantics, states.
- **CS5 (F-07)** `>` → `>=` in both pretty-printers.
- **CS6 (F-08)** `if (totlen < sizeof(*key) || paylen > totlen - sizeof(*key))`.
- **CS7 (F-09)** On failed PNVM read: skip doorbell + wait, return
  success (missing PNVM is non-fatal; firmware defaults apply). Remove
  dead goto. Preserve: matching-SKU path byte-for-byte.
- **CS8 (F-10)** Watchdog timer moves to the main workloop (serialized
  with RX/newstate/CTimeout — the same re-entrancy model already used by
  `if_input`'s gated runAction from interrupt context); `watchdogAction`
  re-arms via the `sender` argument and guards `fHalService`/`if_watchdog`;
  `releaseAll` cancels watchdog + scanSource BEFORE releasing the HAL;
  `fWatchdogWorkLoop` removed. Preserve: 1 s period, `iwx_watchdog`/
  `ieee80211_watchdog` call chain, PM ack deadlines.
- **CS9 (F-11)** `handleWCLLink(up)` posts `LinkStatus{up=1}` (mirroring
  the join-path message) when the link recovers outside a pending join
  with `assocNotified` set, and re-tracks `joinBSSID` to the current
  `ic_bss` if it changed. Preserve: join-path messages untouched.
- **CS10 (F-12)** Watchdog counts `ni_fails` only on the retry path (the
  SCAN transition already counts once on give-up); `choose_bss` skips at
  `ni_fails >= 2` (upstream OpenBSD tolerance) instead of any nonzero.
  Preserve: free-at->2 sweep eviction, RUN clears fails, retry budget 3.

## E. Deferred work (with rationale)

D-1 ScanResult throttling; D-2 RX zero-fill elision; D-3 idle-scan
backoff; D-4 TVQM queue return (firmware-spec dependency); D-5 cmd-slot
recycling; D-6 EAPOL/mgmt second queue (qfullmsk stall); D-7 softc ring
array downsizing (indexing invariants, no measured runtime cost); D-8
scan-completion epoch restructure (narrow window, runtime confirmation
needed); D-9 ADDBA backoff in HW-setup mode; D-10 disassoc event surfacing.
All require runtime evidence and/or firmware-spec verification; none block
the fixes above.

## F. Verification (Phase VII)

- Build: GitHub Actions "Build AX211 Sequoia Debug" (macos-15-intel,
  Xcode 16.4, x86_64) — the only supported toolchain (no local macOS).
- CI gate already verifies: kext bundle presence, x86_64-only lipo,
  OSBundleLibraries, IOSkywalkFamily/corecapture linkage, embedded
  iwlwifi firmware families, AX211 PCI IDs, artifact checksums.
- Static: all edits re-read post-application; independent review of the
  full diff (see review record).
- Runtime/hardware: NOT available in this environment. All behavioral
  fixes are source-verified + build-verified only; hardware verification
  on the MSI target remains pending (see final report).

## G. Independent review record

Two adversarial reviewers examined the complete diff
(6039eb6..31fbdab + the correction commit):

- **REVIEW-1 (HAL + net80211)**: verdicts SOUND for the TX-log removal
  (variables still used, no -Werror), the `>=` printer guards (arrays
  are 4/5 entries; IWX_ANT_C was the old OOB value), the fw-load
  `goto fail1` (fail1 falls through to fail0 — all three DMAs freed),
  the watchdog single-count (budget identical: 3 AUTH retries; give-up
  counts once via the SCAN transition; task-drop only via iwx_stop which
  frees the table anyway), the `>= 2` selection threshold (match_bss has
  no fails check of its own; eviction still terminates; RUN clears
  fails), the EAPOL guard (struct is 99 bytes packed; conformant frames
  always have totlen ≥ 99), and compile sanity (precedents for every
  declaration).
  **It found one CRITICAL defect in my initial PNVM change**: I had
  inverted the polarity — `iwx_read_pnvm()` returns 0 on SUCCESS
  (including the SKU-matched, data-loaded path), so my early return
  would have skipped the PNVM doorbell on the actual AX211 target,
  silently never applying regulatory data. **Corrected**: read_pnvm now
  tracks whether a section was actually loaded and reports ENOENT for
  the no-match case; load_pnvm restores the doorbell+wait for the
  loaded path (byte-identical to the validated baseline on target),
  skips it only when nothing was loaded, and propagates hard errors.
  This is exactly the class of error the review process exists to catch.
  Its R7 concern (ba_del free vs in-flight CTimeout callback) was
  analyzed and is SOUND in the current design: every ba_del caller is
  either on the workloop thread or holds the workloop gate without
  sleeping (iwx_newstate_task re-enters the gate; IOKit timer callbacks
  hold the workloop gate; ba_del performs no sleep), so no interleaving
  window exists — and the watchdog-on-workloop fix (CS8) removed the one
  ungated caller that existed before.
- **REVIEW-2 (macOS integration)**: verdict SHIP. Confirmed the watchdog
  path contains no blocking calls (task_add is enqueue-only; the entire
  join_bss→new_state chain already runs on the main workloop today from
  RX context — decisive proof of tolerance); the re-arm-via-sender is the
  canonical pattern; start()/releaseAll failure paths are consistent; the
  WCL recovery post only fires where intended (assocNotified is set only
  by a WCL join and reset by the next one; link-up implies port_valid,
  i.e. the 4-way handshake completed); the struct mirrors the join-path
  event field-for-field; the rates fix matches the in-tree V1 precedent
  (raw u8→u32 element copy); en0 RUNNING drops only on real
  disassociation (bgscan never calls new_state) and the LQM -2 behavior
  is the designed semantic. Follow-ups applied: gate-serialized watchdog
  cancel in releaseAll (closes the in-flight re-arm teardown window) and
  a comment documenting the open-network autonomous-rejoin edge case.
  It correctly noted the stored CI artifact predates these commits —
  CI was re-run on the final tree (see final report).

## H. Correction ledger

- Initial CS7 implementation had the read_pnvm polarity inverted
  (caught by REVIEW-1, corrected same session — see G).
- An intermediate edit pass introduced tab→space churn in five files;
  caught by diff review and repaired to byte-precise edits before
  committing (no whitespace noise in the final history).
- The proposed mgmt-queue-before-qfullmsk reorder was REJECTED after
  verifying that management and data frames share one TX ring
  (iwx_tx:6996-7014): the reorder would drop frames instead of
  deferring them. Documented as deferred (D-6).
- Prior-audit claims refuted for the live build (see C.3) were not
  "fixed" — including setPOWER, which analysis showed cannot reproduce
  the stated failure in the WCL build.
