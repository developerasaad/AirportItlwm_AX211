# AUDIT-2c-1: itl80211 CONTROL-PLANE Forensic Audit — Scan / Association / Roaming / Node Lifecycle

**Audit date:** 2026-11-18
**Repo:** `/home/z/my-project/AirportITLWM` @ `e4857ff` (`v2.4.0-ax211-reduced`), tree clean
**Target under audit:** `itl80211/` — the OpenBSD net80211 port (STA-only, `IEEE80211_STA_ONLY` defined, `AIRPORT_WCL` defined) sitting between the IWX HAL (`itlwm/hal_iwx/`) and the Airport/WCL integration (`AirportItlwm/`).
**Machine context:** MSI Modern 14 C12MO, Intel AX211, macOS Sequoia 15.8.2. Basic Wi-Fi works; symptoms under investigation: scan lists, joining, network switching, status.

---

## Method (files read fully / skimmed, coverage)

All paths relative to `itl80211/openbsd/net80211/` unless noted. "Full" = every line of the control-plane-relevant content; data-path-only sections noted as skimmed.

| File | Lines | Coverage | Notes |
|---|---:|---|---|
| `ieee80211.c` | 1597 | **FULL** | bgscan entry points, watchdog, channel init/mode machinery, media |
| `ieee80211_proto.c` | 1795 | **FULL** | newstate state machine, auth handling, BA setup/teardown helpers, link-state |
| `ieee80211_input.c` | 3727 | **FULL except 595–1230** (A-MPDU reorder/decap — data path, covered by audit 13) | beacon/probe/auth/assoc/deauth/disassoc/action processing, RSSI/bgscan trigger |
| `ieee80211_node.c` | 3523 | **FULL** | node table, ESS list/join, begin/end scan, choose_bss, roam switch, aging, HT/VHT/HE IE installers |
| `ieee80211_pae_input.c` | 1216 | **FULL** | EAPOL input, 4-way msg1/3, group rekey |
| `ieee80211_pae_output.c` | 680 | **FULL** | EAPOL TX, msg2/4, (AP-side msg1/3) |
| `ieee80211_output.c` | 2324 | **FULL except encap/classify internals** | mgmt frame builders (probe req/assoc req/auth), send_mgmt, mgt_timer |
| `ieee80211_ioctl.c` | 992 | **Skimmed (handlers)** | join/wpapsk/nwkey used by WCL join path; SIOCS80211SCAN disabled |
| `ieee80211_regdomain.c` | 197 | **FULL** | name↔code tables only; no enforcement layer |
| `timeout.c` / `CTimeout.cpp/.hpp` | 82+129+53 | **FULL** | macOS timer shim (IOTimerEventSource + command gate) |
| `../sys/_task.cpp` | 323 | **FULL** | taskq implementation (kernel threads) |
| `../../compat.cpp` / `compat.h` | 420/… | **Skimmed** | PCI/bus shims; `splnet()` no-op lives in `timeout.c` |
| `ieee80211_var.h`, `ieee80211_node.h`, `ieee80211.h`, `ieee80211_proto.h` | ~3900 | **Key sections** | constants, `ic_wcl_*` fields, event enum |
| Cross-layer (evidence only): `itlwm/hal_iwx/ItlIwx.cpp` | 13920 | **Targeted reads** | attach/caps/hooks (13440–13800), newstate/newstate_task (10149–10297), scan/bgscan/umac_scan/abort (8966–8267), bmiss (6205–6248), watchdog/ioctl (11021–11111), channel NVM (3900–3992, 400–423), set_key (10053–10114), auth/session protection (9675–9787) |
| `AirportItlwm/AirportItlwmV2.cpp`, `AirportItlwm/WCL/WCL.cpp/.hpp` | 1387/1015/566 | **Targeted reads** | event wiring, join/leave/scan requests, watchdog timer creation, link-status path |

Note: **there is no `ieee80211_scan.c`** in this tree. This is a modern OpenBSD net80211 (2020) in which scanning was moved into the driver; net80211 retains only result ingestion (`ieee80211_recv_probe_resp`), selection (`ieee80211_node_choose_bss`), and the bgscan trigger/roam decision (`ieee80211_begin_bgscan` / `ieee80211_end_scan`). All findings below account for that split.

---

## Architecture summary (state machines, timers, thread model)

**State machine.** Classic OpenBSD 5-state MLME: `INIT → SCAN → AUTH → ASSOC → RUN` (`ieee80211_proto.c:ieee80211_newstate`, 1428–1737). The HAL **overrides** `ic_newstate` with `iwx_newstate` (ItlIwx.cpp:13765) which makes every transition **asynchronous**: it stashes `ns_nstate`/`ns_arg` and queues `iwx_newstate_task` (10149–10257); the task runs hardware ops (deauth/run_stop/iwx_scan/iwx_auth/iwx_rs_init/iwx_run) and only then calls the real `ieee80211_newstate`. Transitions *to* `S_SCAN` **never** reach `ieee80211_newstate` — the task calls `iwx_scan()` and returns (10222–10228); `iwx_scan` itself sets `ic->ic_state = IEEE80211_S_SCAN` directly (ItlIwx.cpp:9005). Consequently the entire software scan loop of net80211 (`ieee80211_begin_scan`/`next_scan` per-channel probing, `IEEE80211_F_ASCAN`) is dead code in this build; scanning is a single firmware `SCAN_REQ_UMAC` command (`iwx_umac_scan`, 8061+) with dwell times configured once (`dwell.active=10, passive=110, fragmented=44, extended=90` TU, 7928–7931).

**Join.** A WCL join (`WCL.cpp:startWCLJoin`, 442–538) sets PSK/PMK + `ic_des_essid` + `ic_des_bssid` + `F_DESBSSID`, then forces `new_state(SCAN)`. Firmware scan → `iwx_endscan` → `ieee80211_end_scan` (node.c:1400) → `ieee80211_node_choose_bss` → `ieee80211_node_join_bss` (1237) copies the winner into `ic_bss` → `new_state(S_AUTH)` → async `iwx_auth` (session protection) → `ieee80211_newstate` sends AUTH seq 1 → AP replies → `S_ASSOC` → ASSOC_REQ → ASSOC_RESP → `S_RUN`. With RSN, link-UP is deferred until the in-driver supplicant completes the 4-way handshake (`ieee80211_pae_input.c` msg3 SECURE bit → `ni_port_valid=1` → `ieee80211_set_link_state(UP)`, 681–698).

**Roam.** net80211's roam engine: RX-thread RSSI check arms `ic_bgscan_timeout` at `500 ms × (bgscan_fail+1)` (input.c:441–450) → `ieee80211_begin_bgscan` (ieee80211.c:95) frees all nodes, sets `F_BGSCAN` → firmware bgscan → `ieee80211_end_scan` roam path → stop AMPDU + DEAUTH + `F_TX_MGMT_ONLY` + `ni_unref_cb = ieee80211_node_switch_bss` → roam commits when `ic_bss`'s last reference drops (node.c:1194–1234). **As shown in DRV-11C-002, on macOS none of this can ever trigger.**

**Timers.** Two mechanisms. (1) `CTimeout` (OpenBSD `timeout(9)` shim): each timer is an `IOTimerEventSource` on the **main workloop**; add/del/pending are marshalled through `_fCommandGate->runAction` (timeout.c:41–75), so timer fire and gate actions are serialized on one workloop. Used for: bgscan timeout, BA inactivity/gap timers, ADDBA request timers, SA-Query, EAPOL (AP mode), rxba session timers. (2) The **watchdog**: `AirportItlwmV2` creates a **separate** `IOWorkLoop` (`fWatchdogWorkLoop`, V2.cpp:345–361) with a 1 s `IOTimerEventSource` calling `watchdogAction → if_watchdog → iwx_watchdog → ieee80211_watchdog` (V2.cpp:116–122; ItlIwx.cpp:11021–11057). `ic_mgt_timer` (5 s, `IEEE80211_TRANS_WAIT`) counts auth/assoc/probe timeouts on this ungated thread (see DRV-11C-004).

**Threads/contexts touching the control plane:** main workloop (RX interrupt → `ieee80211_input*`, CTimeout fires, gated HAL commands, newstate/ba/chan tasks via `_task.cpp` kernel threads that re-gate); the **separate watchdog workloop**; the BSD output thread (`if_start`, EAPOL/data TX); WCL command path (`_fCommandGate->runAction`); taskq kernel threads. `splnet()/splx()` are compiled to no-ops (timeout.c:32–39) — the real mutex is "everything on the main workloop except the watchdog".

---

## Findings

### DRV-11C-001: Scan execution lives entirely in firmware; the net80211 scan state machine is dead code, and `ic_state=S_SCAN` is assigned directly by the HAL
- Classification: **VALIDATED CORRECT BEHAVIOR** (architecture; with side effects)
- Severity / Confidence: Informational / High
- Evidence: `iwx_newstate_task` case `S_SCAN` calls `iwx_scan(sc)` and returns *without* invoking `sc->sc_newstate` (ItlIwx.cpp:10221–10228); `iwx_scan` sets `ic->ic_state = IEEE80211_S_SCAN` (ItlIwx.cpp:9005) and, for non-bgscans, forces link DOWN and `ieee80211_node_cleanup(ic->ic_bss)` (9001–9004). `ieee80211_newstate`'s S_SCAN case (proto.c:1529–1584, incl. `ieee80211_begin_scan` and per-channel PROBE_REQ generation) is reachable only from `iwx_init` (ItlIwx.cpp:10812). Firmware dwell config: ItlIwx.cpp:7928–7931; channel list = full `ic_channels[]` walk (7689–7729). `SIOCS80211SCAN` is disabled (ieee80211_ioctl.c:865–867).
- Analysis: Explains why dwell/channel-iteration logic cannot be tuned from the 802.11 layer and why scan behavior differs from native drivers. Also means `ic_state == S_SCAN` is true during firmware scans, which the beacon parser relies on (input.c:2075, 2158). No user-visible defect by itself; frames the rest of the scan findings.

### DRV-11C-002: Autonomous roaming is fully disabled on macOS — `IEEE80211_F_DESBSSID` is latched for the whole association, blocking both the bgscan trigger and candidate selection (corrects prior audit DRV-AP-005's premise)
- Classification: **CONFIRMED DEFECT** (capability/behavior)
- Severity / Confidence: **High** / High
- Evidence: Both macOS join paths pin the BSSID: WCL `startWCLJoin` does `memcpy(ic->ic_des_bssid, join.bssid, 6); ic->ic_flags |= IEEE80211_F_DESBSSID;` (WCL.cpp:513–515); legacy `associateSSID` does the same when a BSSID is supplied (AirportItlwmSkywalkInterface.cpp:119–122). The flag is cleared only in `leaveWCLNetwork` (WCL.cpp:611) and the SIOCS80211BSSID ioctl (ieee80211_ioctl.c:726) — **never during RUN**. Two independent blocks follow:
  1. The RX-path bgscan armer refuses to arm while pinned: input.c:441–450 `else if (!timeout_pending(...) && (ic->ic_flags & IEEE80211_F_BGSCAN) == 0 && (ic->ic_flags & IEEE80211_F_DESBSSID) == 0) timeout_add_msec(&ic->ic_bgscan_timeout, ...)`.
  2. Even if a bgscan ran, `ieee80211_match_bss` rejects every other BSSID: node.c:1097–1099 `if ((ic->ic_flags & IEEE80211_F_DESBSSID) && !IEEE80211_ADDR_EQ(ic->ic_des_bssid, ni->ni_bssid)) fail |= IEEE80211_NODE_ASSOCFAIL_BSSID;`.
  The only scans while associated are WCL-requested ones, which go through `ieee80211_begin_cache_bgscan` — that sets `F_DISABLE_BG_AUTO_CONNECT` (ieee80211.c:143), making `roamscan` false in `ieee80211_end_scan` (node.c:1407–1408), so they can never roam either.
- Analysis: The net80211 roam engine (bgscan_timeout → `ieee80211_begin_bgscan` → roam selection → `ieee80211_node_switch_bss`) is unreachable in the Sequoia WCL build. Prior audit DRV-AP-005 assumed "roaming is alive and well inside net80211" — it is not; the stale-`joinBSSID` symptoms it predicts actually arise from this pin plus the re-auth paths (DRV-11C-007). User-visible: no seamless BSS transitions when moving between APs; the driver stays on a deteriorating AP until it fully drops (beacon-miss → full rescan), then — still pinned to the dead BSSID (see DRV-11C-003) — cannot fail over to another BSSID of the same ESS. This is the primary code-level explanation for "network switching feels wrong".

### DRV-11C-003: With no pending join, the driver scans forever — no idle park, no failover, 30 s dead-BSSID lockout
- Classification: **CONFIRMED DEFECT**
- Severity / Confidence: Medium-High / High
- Evidence: `ieee80211_end_scan` "notfound" path: node.c:1456–1484 — when no candidate matches, `ieee80211_reset_scan` + `ieee80211_next_mode` + `ieee80211_next_scan` restart the firmware scan, with the comment "This will loop forever until an access point is found" (1472–1475). On macOS nothing breaks the loop: `ieee80211_match_bss` returns `ASSOCFAIL_ESSID` for every node when `!ic->ic_wcl_join_requested` (node.c:1058–1061), and WCL clears that flag in `finishWCLJoin`(failure) / `leaveWCLNetwork` / `stopWCL` (WCL.cpp:574, 599, 105). So after a leave/failed join/idle radio-on, the firmware scans at full rate indefinitely. After beacon-miss the same loop is entered *with the pin from DRV-11C-002 still active*, so the driver cannot even reselect a sibling AP; recovery waits for the 30 s WCL join timer (WCL.cpp:527, 581–588) or for macOS to re-issue the join.
- Analysis: Explains (a) "Wi-Fi menu network list keeps changing/refreshing even when idle" (every `ieee80211_end_scan` also fires `EVT_SCAN_DONE`, node.c:1410–1411, and beacons continuously push `EVT_BEACON`), (b) elevated idle power/heat vs native (continuous off-channel scanning), and (c) the multi-second dead zone when walking away from an AP: beacon loss (~3 s, `ieee80211_set_beacon_miss_threshold` caps at `30×TU`, proto.c:1363–1382) + 5 s probe wait (watchdog) + pinned rescans until WCL/macOS intervene.

### DRV-11C-004: The 1 s watchdog runs on a dedicated workloop outside the command gate — it mutates MLME state concurrently with the RX thread and all other timers
- Classification: **CONFIRMED DEFECT** (concurrency)
- Severity / Confidence: High / High (structure), Medium / Medium (manifestation)
- Evidence: `fWatchdogWorkLoop = IOWorkLoop::workLoop(); watchdogTimer = IOTimerEventSource::timerEventSource(this, ...watchdogAction); fWatchdogWorkLoop->addEventSource(watchdogTimer);` (AirportItlwmV2.cpp:345–361); `watchdogAction` calls `(*ifp->if_watchdog)(ifp)` and rearms every 1000 ms (`kWatchDogTimerPeriod`, V2.hpp:37; V2.cpp:116–122). `iwx_watchdog` → `ieee80211_watchdog` (ItlIwx.cpp:11056) which **decrements `ic_mgt_timer`** and on zero calls `ieee80211_new_state(ic, S_SCAN, -1)` (ieee80211.c:906–929) — a full state transition (stop AMPDU, `ieee80211_free_allnodes`, mgmt queue purge) executed on the watchdog thread with no lock. Meanwhile the RX thread on the main workloop sets `ic->ic_mgt_timer = 0` on every beacon (input.c:2056–2057) and issues its own transitions (assoc resp → `new_state(S_RUN)`, input.c:2917). `splnet()` provides nothing (timeout.c:32–39). All *other* net80211 timers go through `CTimeout` on the main workloop (timeout.c:46–49), which is what makes this one the outlier; prior audit DRV-IWX-018 verified the HAL-side gating but did not cover the watchdog path.
- Analysis: A decrement/zero race is narrow but real: e.g. auth response lands (RX thread, sets `S_ASSOC`) in the window where the watchdog has just read `ic_mgt_timer == 1` — the watchdog then calls `new_state(SCAN)`, `iwx_newstate` queues a SCAN task that can land after the RUN task, tearing down a just-established association (or the dedup at ItlIwx.cpp:10273 silently eats one of the transitions, leaving `ic_state` and hardware out of sync). Plausible contributor to rare "join succeeded then immediately dropped" and "stuck in SCAN" reports; also fires during system wake while firmware is still stopped (power-event symptom class). Needs runtime confirmation, but the structural violation (ungated state mutation) is unambiguous.

### DRV-11C-005: Association rejection is never retried directly and never poisons the AP — 5 s stall → full rescan → same AP re-selected → loop until the 30 s WCL timer
- Classification: **STRONGLY SUSPECTED DEFECT**
- Severity / Confidence: Medium-High / High (code path), Medium (frequency)
- Evidence: `ieee80211_recv_assoc_resp` failure path only does `if (ni != ic->ic_bss) ni->ni_fails++;` then returns (input.c:2745–2755) — for the normal case `ni == ic_bss` so **no failure is recorded and no retry is scheduled**; state stays `S_ASSOC` with `ic_mgt_timer` still counting down from the ASSOC_REQ (set in `ieee80211_send_mgmt`, output.c:2024, `IEEE80211_TRANS_WAIT`=5, node.h:54). The watchdog then does `ieee80211_new_state(ic, S_SCAN, -1)` (ieee80211.c:928) — a complete rescan. `ieee80211_node_choose_bss` skips nodes only when `ni_fails` is set (node.c:1336–1345), so the freshly-rejected AP (no fails) is selected again. Contrast the AUTH path, which retries up to 3 times in place: ieee80211.c:921–924 (`if (ic->ic_state == IEEE80211_S_AUTH && ni && ni->ni_fails < 3) ieee80211_node_join_bss(ic, ni)`).
- Analysis: Against an AP that answers auth but rejects association (band-steering, client limit, 802.11r-only SSID, transient TRY_AGAIN_LATER), the join degenerates into scan→auth→reject→5 s→rescan cycles until WCL's 30 s `joinTimer` fails the join (WCL.cpp:527, 581–588). User-visible as "joining spins for ~30 s then fails". Also floods the RF environment with rescans. The correct behavior would be an immediate in-place assoc retry (2–3 attempts) before rescanning, and recording `ni_fails` on the bss node.

### DRV-11C-006: Auth-timeout `ni_fails` poisoning removes failed APs from subsequent scan results
- Classification: **UNVERIFIED IMPLEMENTATION RISK** (inherited OpenBSD semantics, user-visible on macOS)
- Severity / Confidence: Medium / High
- Evidence: Watchdog auth timeout: `ni = ieee80211_find_node(ic, ic->ic_bss->ni_macaddr); if (ni) ni->ni_fails++;` (ieee80211.c:917–919). `ieee80211_node_choose_bss`: `if (ni->ni_fails) { if (ni->ni_fails++ > 2) ieee80211_free_node(ic, ni); continue; }` (node.c:1336–1345). `ni_fails` is cleared only on reaching RUN (proto.c:1725–1728) or when the node is re-created.
- Analysis: After 1–3 auth timeouts (e.g. AP briefly overloaded, or the DRV-11C-005 rescan loop timing out at AUTH), the AP's node is skipped in selection and, worse, **freed from the node table on the next scan round** — and nodes are what WCL beacon-push uses (`EVT_BEACON` per frame), so the network can vanish from the Wi-Fi menu for one or more scan cycles after a failed join attempt. "Network disappears from list after failed attempt, comes back later" symptom class.

### DRV-11C-007: AP-initiated deauth triggers silent auto-reauth while WCL/airportd are told the link died — and never told it came back
- Classification: **STRONGLY SUSPECTED DEFECT**
- Severity / Confidence: High / Medium-High
- Evidence: `ieee80211_recv_deauth` (STA): `if (!(roamscan || stay_auth)) ieee80211_new_state(ic, S_AUTH, DEAUTH)` (input.c:2951–2962); `ieee80211_newstate` S_AUTH-from-RUN with mgt=DEAUTH sends AUTH seq 1 immediately — "try to reauth" (proto.c:1618–1634). Upward, only `EVT_STA_DEAUTH` is emitted (input.c:2946–2948). WCL's handler sets `portAuthorized=false`, forces LQM invalid, posts `Deauth`, and — because `joinPending` is false while associated — `finishWCLJoin` no-ops (WCL.cpp:788–797, 556–559). The subsequent successful re-auth/re-assoc runs entirely below WCL: `EVT_STA_ASSOC_DONE` is ignored when `!joinPending` (WCL.cpp:776–786), and `handleWCLLink(up)` (restoring `portAuthorized`) only posts a WCL `LinkStatus` **up** message inside the first-beacon join-completion path; outside a join it posts nothing (WCL.cpp:624–640, 747–763). `ieee80211_set_link_state` additionally asserts LINK_STATE_DOWN at the top of *every* state transition (proto.c:1445), so `AirportItlwmV2::setLinkStatus` stops the output thread and flushes queues on each reauth (V2.cpp:654–662).
- Analysis: For a transient deauth (AP reboot, band-steer, 802.11r BSS transition), the chip re-associates within ~1–2 s, but airportd saw Deauth + Link-down and never a Link-up; it will typically drop the DHCP lease, show "connection lost", or trigger its own rejoin that then fights the driver's in-flight reauth (scan/join `kIOReturnBusy`, cross-ref AP-008). This is the same-BSSID twin of the roam staleness in AP-005 and a direct "status staleness / spurious disconnect" mechanism.

### DRV-11C-008: Upward notification inventory is minimal — no disassoc, roam, beacon-miss, or port-authorized events exist
- Classification: **CONFIRMED** (contract gap; see dedicated section below)
- Severity / Confidence: High (for symptom classes) / High
- Evidence: The complete event set is `IEEE80211_EVT_STA_ASSOC_DONE/STA_DEAUTH/COUNTRY_CODE_UPDATE/SCAN_DONE/BEACON/DRIVER_READY/DRIVER_STOPPED/DRIVER_RESET_BEGIN` (ieee80211_var.h:687–695). Emitters: `end_scan` (SCAN_DONE, node.c:1410), `recv_probe_resp` (BEACON, input.c:2179–2189), `recv_assoc_resp` (ASSOC_DONE incl. failures in the WCL variant, input.c:2735–2743), `recv_deauth` (DEAUTH, input.c:2946), `recv_auth` (resets `ic_deauth_reason`/`ic_assoc_status`, 2345–2346, no event), HAL (DRIVER_*). **`ieee80211_recv_disassoc` emits nothing** (input.c:3012–3023). Beacon-miss (`iwx_rx_bmiss` → directed probe, ItlIwx.cpp:6205–6248) emits nothing. 4-way completion (`ni_port_valid=1`, pae_input.c:688–693) emits nothing.
- Analysis: macOS learns about link life almost exclusively by polling and the IOKit link-status side channel; every recovery the driver performs on its own (reauth, rekey, rescan) is invisible. Enumerated in the contract-gap section with the WCL consumer for each.

### DRV-11C-009: The in-driver supplicant has no STA-side handshake timeout; wrong-PSK and stalled handshakes are bounded only by WCL's 30 s timer or the AP's patience
- Classification: **CONFIRMED** (gap) + **UNVERIFIED IMPLEMENTATION RISK** (recovery stall)
- Severity / Confidence: Medium-High / High (gap), Low-Medium (stall)
- Evidence: After successful association with RSN, `ieee80211_recv_assoc_resp` sets `ni_rsn_supp_state = RSNA_SUPP_PTKSTART` and — with the OpenBSD `ic_mgt_timer = 5` line commented out — leaves no timeout (input.c:2911–2913). `S_RUN` entry clears `ic_mgt_timer` (proto.c:1729). The EAPOL retry machinery (`ni_eapol_to`, `ni_rsn_retries > 3` deauth) exists only on the AP side: `timeout_set(&ni->ni_eapol_to, ...)` and all senders of msg1/msg3 are `#ifndef IEEE80211_STA_ONLY` (node.c:1750–1753; pae_output.c:139, 276–290, 389+). If msg1/4 never arrives, nothing in net80211 recovers; WCL's `joinTimer` (30 s) is the sole backstop (WCL.cpp:527). Wrong-PSK flow: msg3 MIC check fails → silent `return` (pae_input.c:425–429) → AP retransmits msg3 (same replay counter — passes the `<=` check only while `ni_replaycnt` was not updated; it is updated at 544 *after* MIC success, so MIC-fail retries do work) → eventually AP deauths with reason 15/16 → DRV-11C-007 path. If msg4 is lost after a *successful* msg3, the replay counter is already advanced (544–545) and retransmitted msg3s are discarded as replays (401–406) — recovery then depends entirely on the AP deauthing.
- Analysis: "Wrong password" and "AP ignores handshake" cases take up to 30 s to surface as a join failure, and present to macOS as a deauth/disconnect rather than an auth failure with a reason code. Contributes to join-unreliability perception. (Cross-ref AP-020's observation that WCL only supplies PMK/MSK; PSK→PMK conversion happens in userland — `ic_psk` is filled directly, WCL.cpp:485, AirportItlwmSkywalkInterface.cpp:151.)

### DRV-11C-010: PTK/GTK installation into the firmware is asynchronous and unacknowledged — first encrypted downstream traffic can race the key install
- Classification: **UNVERIFIED IMPLEMENTATION RISK**
- Severity / Confidence: Low-Medium / Medium
- Evidence: `iwx_set_key` sends `IWX_ADD_STA_KEY` with `IWX_CMD_ASYNC` and returns immediately (ItlIwx.cpp:10053–10084). In msg3 processing, msg4 is sent *before* the key install (pae_input.c:552–554 then 580–596), and the `EBUSY → deferlink` path (590–592, 632–634) exists but iwx never returns EBUSY; there is no completion callback that would re-check `deferlink`.
- Analysis: EAPOL msg4 itself is unencrypted so the classic race is harmless; the residual risk is the AP's first encrypted data/GTK-dependent multicast arriving before the firmware has the key (dropped frames immediately after join — "first ping/ARP after connect lost" reports). Small window; flag for runtime verification rather than as a confirmed defect.

### DRV-11C-011: Scan-result cache lifecycle is split-brained: roam-bgscans wipe the node table, WCL cache-bgscans retain it for 5 minutes, and STA-mode aging timers are never armed
- Classification: **STRONGLY SUSPECTED DEFECT** (scan-list behavior)
- Severity / Confidence: Medium / High
- Evidence: `ieee80211_begin_bgscan` calls `ieee80211_free_allnodes(ic, 0 /* keep ic->ic_bss */)` before every roam-capable bgscan (ieee80211.c:111–119). `ieee80211_begin_cache_bgscan` (the only one WCL triggers, WCL.cpp:270–271) keeps nodes unless the last cache scan was > 5 min ago (ieee80211.c:145–150). The STA-mode inactivity timers are not installed: `timeout_set(&ic->ic_inact_timeout/…cache_timeout)` is inside `if (ic->ic_caps & (IEEE80211_C_HOSTAP | IEEE80211_C_IBSS))` (node.c:741–755) — iwx sets neither cap — so `ni_inact` advances only via `ieee80211_node_raise_inact` at `begin_scan` (node.c:843–847, 879–882) and `ieee80211_clean_inactive_nodes(INACT_SCAN=10)` at each `end_scan` (node.c:1422–1423, 2341–2362). `ni_age_ts` is only maintained under `#ifdef AIRPORT` (input.c:1956–1958), which the WCL build does not define.
- Analysis: There is no coherent "result age" the upper layer can rely on: mid-roam-bgscan the table is empty except `ic_bss` (any snapshot walk sees almost nothing), while WCL cache-scans serve nodes up to 5 minutes old with no age field (cross-ref AP-010). Nodes seen only in beacons during a scan can persist across multiple menu-open refreshes. Explains stale/missing entries in the Wi-Fi menu and the "AP I turned off still shows" report class.

### DRV-11C-012: RSSI handling is last-frame-wins on 2.4 GHz and max-hold on 5 GHz — no smoothing; band choice at selection time prefers 5 GHz above fixed thresholds
- Classification: **UNVERIFIED IMPLEMENTATION RISK** (quality/fidelity)
- Severity / Confidence: Low-Medium / High (code), Low (impact)
- Evidence: `ieee80211_recv_probe_resp`: on 5 GHz during scan, probe-response RSSI is preferred and beacons can only *raise* the stored value (input.c:2158–2169); on 2.4 GHz (and all bands outside scan) `ni->ni_rssi = rxi->rxi_rssi` — every beacon overwrites (2170–2171). Selection prefers the best-5 GHz AP when it passes `ieee80211_node_checkrssi` (thresholds −70 dBm / 40 % for 5 GHz, −60 dBm / 50 % for 2.4 GHz; node.c:1378–1391, 1722–1742; var.h:220–223). ESS scoring adds +32 for a known SSID, +21 for zero past failures, +16/+8 for RSN/WPA, 5 GHz bonus (node.c:466–506).
- Analysis: 2.4 GHz RSSI jumps frame-to-frame, so the menu's ordering of 2.4 GHz networks can shuffle between scans, and the WCL-published `rssi` (WCL.cpp:328) inherits the jitter. Not a defect per se (upstream behavior) but a plausible source of "signal bars keep changing" reports; native drivers average.

### DRV-11C-013: Hidden-SSID handling works only via directed probes, and an SSID whose first byte is NUL can never be learned
- Classification: **VALIDATED CORRECT BEHAVIOR** (directed path) + **CONFIRMED minor DEFECT** (NUL-first-byte SSID)
- Severity / Confidence: Low / High
- Evidence: Node SSID is learned only from a non-empty SSID IE when the stored one is empty: `if (ssid[1] != 0 && ni->ni_essid[0] == '\0')` (input.c:2151–2156) — the probe-response override for hidden networks (comment at 2144–2150). Directed probes are firmware-generated from `ic_wcl_scan_ssid` (WCL scans, ItlIwx.cpp:8068–8074, 8206–8219) or `ic_des_essid` (join-triggered scans, 8065–8067); broadcast (wildcard) scans set `IWX_UMAC_SCAN_GEN_FLAGS_PASSIVE` when `scanActive` is false (8220–8221). A network whose real SSID begins with `0x00` keeps `ni_essid[0]=='\0'` forever, so a *second* beacon/probe can never update it and join matching (`memcmp` against `ic_des_essid`, node.c:1093–1096) compares against a truncated name.
- Analysis: Hidden networks are joinable (verified logic), but are absent from broadcast scans (by design) — if macOS asks for a broadcast scan only, hidden APs don't appear until airportd issues the directed scan. The NUL-first-byte quirk is an edge case mostly affecting exotic SSIDs.

### DRV-11C-014: 6 GHz (Wi-Fi 6E) is excluded at the NVM channel table; net80211 has no 6 GHz band support at all
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY** (confirms AP-003 at the 802.11 layer)
- Severity / Confidence: High (feature) / High
- Evidence: The ultra-high-band channel list is compiled out: `static const uint8_t iwx_nvm_channels_uhb[] = { …14×2.4 GHz, 40×5 GHz, #ifdef notyet … 6–7 GHz … #endif }` (ItlIwx.cpp:409–423); `sc_uhb_supported` selects that (identical) list (3908–3914). In net80211, `ieee80211_mhz2ieee`/`ieee80211_ieee2mhz` only understand 2.4/5 GHz mappings (ieee80211.c:299–362), there is no `IEEE80211_CHAN_6GHZ`-style flag anywhere, and `iwx_umac_scan_fill_channels` maps everything non-2.4 GHz to `IWX_PHY_BAND_5` (ItlIwx.cpp:7708–7711). `ieee80211_he_supported` additionally refuses any AP whose HE Operation advertises `HE_OPERATION_6GHZ_OP_INFO` (proto.c:931–933).
- Analysis: AX211 hardware + API-68 firmware can do 6 GHz; the port cannot even represent it. 6E APs are invisible in scans. Enabling requires the `notyet` channel list, band plumbing in net80211 (freq↔chan maps, flags, probe/EDCA handling), and scan band fields — a substantial feature port, not a bugfix.

### DRV-11C-015: Regulatory control is passive-by-NVM only — no regdomain enforcement layer; DFS/passive channels are never probed (WCL path), and country changes never reshape the channel list
- Classification: **VALIDATED CORRECT BEHAVIOR** (safety) / **UNSUPPORTED OR INCOMPLETE CAPABILITY** (policy)
- Severity / Confidence: Low (safety) / Medium (capability) / High confidence
- Evidence: `ieee80211_regdomain.c` contains only name↔country-code↔domain lookup tables (59–197); nothing in the tree applies a domain mask to `ic_chan_active`. Channel flags come straight from NVM (`IWX_NVM_CHANNEL_VALID/ACTIVE/DFS`, ItlIwx.cpp:3916–3985) with `IEEE80211_CHAN_PASSIVE`/`CHAN_DFS` set (3951–3983). Probe gating: `AirportWCL::probeChannel(active, passiveOnly, dfs) = active && !passiveOnly && !dfs` (WCL.hpp:426–428) applied per channel (ItlIwx.cpp:7720–7726); the non-WCL fallback `n_ssids != 0 && !bgscan` would probe passive channels on directed scans (7724). Country IE/`EVT_COUNTRY_CODE_UPDATE` flows to WCL (WCL.cpp:656–657) but does not modify scanning. World-roaming defaults therefore equal the NVM SKU profile.
- Analysis: Regulatorily conservative (good), but macOS's "country code" setting is cosmetic for this driver; users in domains with more 5 GHz spectrum see no benefit, and passive-channel-only discovery (110 TU dwell beacons) makes sparse-DFS environments feel slow to populate the menu.

### DRV-11C-016: Timer framework is sound on the main workloop, but stop/free ordering has latent hazards and the watchdog is the odd one out
- Classification: **VALIDATED CORRECT BEHAVIOR** (CTimeout) + **UNVERIFIED IMPLEMENTATION RISK** (ordering)
- Severity / Confidence: Low-Medium / Medium
- Evidence: `timeout_add/del/pending` marshal through `_fCommandGate->runAction` (timeout.c:41–75); callbacks (`CTimeout::timeoutOccurred`, CTimeout.cpp:25–39) run as workloop event sources, serialized with the gate and RX. `timeout_free` removes and releases the event source (CTimeout.cpp:79–95). Teardown order at detach: `ieee80211_ifdetach` deletes/frees `ic_bgscan_timeout` (ieee80211.c:276–277); node timers are freed in `ieee80211_ba_free`/`node_cleanup` (node.c:2059–2078, 1661–1686). Hazards: (a) `ieee80211_node_detach` frees `ic_bss` **before** `ieee80211_free_allnodes` (node.c:795–800) — any pending `ni_addba_req_to` on ic_bss was deleted in `ba_del`, OK, but a *firing* timer on another node during `free_allnodes` is prevented only by the workloop serialization; (b) `iwx_stop` clears state on the gate while the watchdog workloop can be mid-`ieee80211_watchdog` (DRV-11C-004); (c) on sleep, `disableAdapter` stops the firmware but the watchdog keeps ticking and can fire `new_state(SCAN)` against a dead radio (bounded by `iwx_newstate_task`'s SHUTDOWN check, ItlIwx.cpp:10170–10175, but `ieee80211_watchdog`'s read-modify of `ic_mgt_timer` is unprotected).
- Analysis: The CTimeout design is actually the port's strongest piece; the risk is concentrated in the watchdog (11C-004) and sleep/wake transitions. Symptom class: "weird state right after wake" reports.

### DRV-11C-017: Every MLME transition forces LINK_STATE_DOWN at entry — link flaps during auth→assoc→run and on every reauth
- Classification: **VALIDATED CORRECT BEHAVIOR** (design) with **user-visible side effect**
- Severity / Confidence: Low-Medium / High
- Evidence: `ieee80211_newstate` line 1 of substance: `ieee80211_set_link_state(ic, LINK_STATE_DOWN)` (proto.c:1445). `set_link_state` maps DOWN to `controller->setLinkStatus(kIONetworkLinkValid)` (proto.c:1766–1774), which in V2 stops the BSD output thread and flushes both the data and mgmt queues (V2.cpp:654–662). UP is restored only at RUN entry (non-RSN) or at 4-way completion (RSN; pae_input.c:688–693, gated `AIRPORT_WCL` early-return in `set_link_state` at proto.c:1745–1750).
- Analysis: During a join each state hop bounces en0's link; during the auto-reauth of DRV-11C-007 the interface drops and rises while airportd was never told why. macOS tolerates it, but link flap events are exactly what airportd uses to invalidate its association state — feeding the "status staleness" symptom.

### DRV-11C-018: `iwx_newstate` silently drops duplicate transitions — pending-state overwrite can lose a transition and desync `ic_state` from hardware
- Classification: **UNVERIFIED IMPLEMENTATION RISK**
- Severity / Confidence: Low-Medium / Medium
- Evidence: `if (sc->ns_nstate == nstate && nstate != IEEE80211_S_SCAN && nstate != IEEE80211_S_AUTH) return 0;` (ItlIwx.cpp:10273–10275). `sc->ns_nstate/ns_arg` are single slots written by `iwx_newstate` (10291–10292) and consumed by the task (10163–10166); a second transition request queued before the task runs overwrites both (no queueing).
- Analysis: Fast sequences generated by the watchdog/RX race of DRV-11C-004 (e.g. SCAN requested while a RUN task is pending, or two different-arg AUTH requests) can collapse into one hardware action while net80211's `ic_state` advances twice (or vice versa). Candidate for the rare "driver says associated, firmware never authed" wedge that only a radio toggle fixes. Needs runtime tracing to confirm frequency.

### DRV-11C-019: Directed-scan abort semantics are handled WCL-side with a one-shot guard; net80211 has no abort notion at all
- Classification: **VALIDATED CORRECT BEHAVIOR** (current state) / residual risk cross-ref AP-009
- Severity / Confidence: Medium / Medium
- Evidence: The upstream "directed-request abort completion" fix is present: `scanSkipCompletion` is set when a WCL scan starts while `ic_state == S_SCAN` with a directed SSID in flight (WCL.cpp:260–262) and consumes exactly one `EVT_SCAN_DONE` (766–775). The abort itself: `iwx_scan` aborts an in-flight bgscan before issuing the foreground scan (ItlIwx.cpp:8974–8981); the aborted scan's completion funnels through `iwx_endscan` → `ieee80211_end_scan` (10300–10317) with net80211's `F_BGSCAN` still set, which the bgscan path clears (node.c:1494–1498). Both `IWX_SCAN_COMPLETE_UMAC` and `IWX_SCAN_ITERATION_COMPLETE_UMAC` feed `iwx_endscan` (ItlIwx.cpp:11698–11710).
- Analysis: Net80211's scan state is abort-agnostic (it only reacts to end_scan), so correctness rests entirely on the WCL guard's single-shot depth; a fragmented scan emitting an extra ITERATION_COMPLETE during the *new* scan still completes the WCL scan early (AP-009's residual). No new defect found at the 802.11 layer; documented to close the loop on the prior fix.

### DRV-11C-020: GTK/IGTK group rekey handling in STA mode is complete and correct, including re-marking the port and re-asserting link-up
- Classification: **VALIDATED CORRECT BEHAVIOR**
- Severity / Confidence: — / High
- Evidence: `ieee80211_recv_rsn_group_msg1` (pae_input.c:833–994): replay check, MIC, KEK decrypt, GTK KDE parse, `ieee80211_must_update_group_key` anti-reinstall check (366–373), `ic_set_key` install, `ni_port_valid=1` + `ieee80211_set_link_state(UP)` on SECURE, replay counter advance, msg2 sent. WPA1 variant at 999+ mirrors it. IGTK (MFP) handled at 934–966. 4-way msg3 carries GTK/IGTK KDEs with encrypted-key enforcement (pae_input.c:495–504, 604–677).
- Analysis: Group rekey (the common 1 h–24 h AP rotation) will not drop the link; `set_link_state(UP)` re-runs are no-ops when already up (proto.c:1766). No user-visible defect expected from GTK handling.

### DRV-11C-021: Association status reporting is binary and lossy — auth failures produce no assoc event, failure reasons reach WCL only as a status word
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY**
- Severity / Confidence: Low-Medium / High
- Evidence: `ic_assoc_status` is set from the assoc resp status (input.c:2735) and `ic_deauth_reason` from deauth (2945); `recv_auth` resets both before dispatch (2345–2346). `EVT_STA_ASSOC_DONE` fires for assoc resp success *and* failure in the WCL build (`#ifndef AIRPORT_WCL` removed the success gate, input.c:2736–2743), but nothing is emitted for: auth rejection (`ieee80211_auth_open` status≠0 → `ieee80211_try_another_bss`, proto.c:1341–1352, no event), auth/assoc *timeout* (watchdog path, no event), or the WCL join timeout itself. WCL's `AssociationEvent` carries only `status` (WCL.cpp:776–786).
- Analysis: macOS error reporting for failed joins ("incorrect password", "timeout", "cannot connect") has almost nothing to work with; airportd must infer from Deauth reason codes after the fact. Contributes to unhelpful join-failure UX.

### DRV-11C-022: Beacon processing in RUN deliberately freezes RSN/HE parameters — correct against beacon loss, but security/HE changes require a rescan to be noticed
- Classification: **VALIDATED CORRECT BEHAVIOR** (with documented limitation)
- Severity / Confidence: — / High
- Evidence: RSN/WPA IE parsing runs only `if (ic->ic_state == IEEE80211_S_SCAN || (ic->ic_flags & IEEE80211_F_BGSCAN))` (input.c:2075–2142); `ieee80211_update_he_params` refuses to erase a live association's HE context on beacon omission (`if (ni != ic->ic_bss || ic->ic_state != IEEE80211_S_RUN) ni->ni_flags &= ~(HECAP|HEOP|…)`, 1656–1689); ERP/HT-protection/slot-time updates *are* applied live from beacons (1964–2058).
- Analysis: Once associated, the driver cannot see an AP that changes its RSN IE (e.g. toggles WPA3-transition) until the next scan — acceptable and upstream-faithful; listed so future auditors don't flag it as a bug.

### DRV-11C-023: Auth retry policy is 3 in-place attempts with 5 s spacing, then full rescan — total worst-case latency budget ~20 s before the WCL 30 s timer
- Classification: **VALIDATED CORRECT BEHAVIOR** (latency note)
- Severity / Confidence: — / High
- Evidence: `ieee80211_send_mgmt` arms `ic_mgt_timer = IEEE80211_TRANS_WAIT` (5) for PROBE_REQ/AUTH/ASSOC_REQ (output.c:1989, 2003, 2024; node.h:54). Watchdog: auth timeout → `ni_fails++`, retry `ieee80211_node_join_bss` while `ni_fails < 3` (ieee80211.c:917–924); assoc timeout → straight to SCAN (925–928). Beacon-miss → directed probe (ItlIwx.cpp:6244) with its own 5 s timer; beacons reset the timer (input.c:2050–2057).
- Analysis: A full join against a slow AP can legitimately take 3×(auth 5 s) + rescan time; combined with DRV-11C-005's non-retrying assoc this is the mechanical reason joins on this hardware feel much slower than native (~1–2 s). Latency budget, not corruption.

### DRV-11C-024: `EVT_BEACON` is emitted for *every* beacon/probe frame on every channel — WCL pushes each as a scan result while scanning, with no dedup window
- Classification: **VALIDATED CORRECT BEHAVIOR** / load note
- Severity / Confidence: Low / High
- Evidence: `ieee80211_recv_probe_resp` tail: `ic_event_handler(ic, IEEE80211_EVT_BEACON, &event)` with the raw IE blob (input.c:2179–2189); WCL publishes a `BeaconMetadata` message per event while `scanPending || joinPending || state==SCAN || (portAuthorized && bssid==joinBSSID)` (WCL.cpp:744–746, 307–345). With the DRV-11C-003 idle scan loop this is a continuous message stream even when the menu is closed.
- Analysis: Correct-but-chatty: per-beacon allocation (`IOMalloc` per message, WCL.cpp:317–318) and PostOffice traffic scale with beacon rate × channels swept; on the idle scan loop this is a steady background cost (power/log volume — cross-ref DRV-IWX-021's unconditional debug logging amplifying the same paths).

### DRV-11C-025: `ieee80211_free_allnodes`'s "keep current BSS" test compares BSSID **and** `strncmp` of SSIDs — a matching pair on another channel can be freed while a *differing* SSID on the same BSSID is kept
- Classification: **UNVERIFIED IMPLEMENTATION RISK** (minor logic wart)
- Severity / Confidence: Low / Medium-High (code reading)
- Evidence: node.c:2144–2149: `if (!clear_ic_bss && ic->ic_bss != NULL) { if (memcmp(ic->ic_bss->ni_bssid, ni->ni_bssid, 6) == 0 && strncmp(ic->ic_bss->ni_essid, ni->ni_essid, IEEE80211_NWID_LEN) == 0) continue; }` — `strncmp` stops at the first NUL, so SSIDs equal up to the shorter one's NUL compare equal (e.g. "Net" vs "Net\0x41…"), and any node whose BSSID differs is freed even if it is the *same network* multi-BSSID set the driver might want cached.
- Analysis: Edge-case cache churn during bgscan; no crash risk. Noted for completeness; fixing it would use length-aware comparison (`ni_esslen`).

---

## Roam/notification contract gaps (upward notifications missing or late)

Enumerated net80211 → Airport/WCL events, with the WCL consumer and the gap:

| # | Notification | Emitted? | Consumer | Gap |
|---|---|---|---|---|
| 1 | Scan completed | Yes — `EVT_SCAN_DONE` at *every* `ieee80211_end_scan` (node.c:1410), including firmware-aborted and background scans | WCL.cpp:766–775 (only honored while `scanPending`) | Idle-scan loop (DRV-11C-003) emits these forever; WCL must filter. Abort-completion double-fire guarded only one-deep (AP-009). |
| 2 | Beacon/probe received (per BSS) | Yes — `EVT_BEACON` (input.c:2186) | `publishWCLBeacon` → WCL message 201 | No age, no dedup; only pushed under the four conditions at WCL.cpp:744–746 |
| 3 | Association response (success/fail) | Yes — `EVT_STA_ASSOC_DONE` (input.c:2741) | WCL.cpp:776–786 (only while `joinPending`) | **Ignored outside a join** — a (hypothetical) roam re-assoc or auto-reauth re-assoc is invisible |
| 4 | Deauth received | Yes — `EVT_STA_DEAUTH` (input.c:2947) | WCL.cpp:788–797 | No matching "re-connected" event; auto-reauth (DRV-11C-007) leaves airportd stale |
| 5 | **Disassoc received** | **NO** — `ieee80211_recv_disassoc` posts nothing (input.c:3012–3040) | — | macOS never learns the AP disassociated; the driver's auto-reassoc runs silently |
| 6 | **Roam / BSSID change** | **NO** — nothing in `ieee80211_node_switch_bss`/`join_bss` notifies upward (node.c:1194–1234, 1237–1321) | — | Root cause of AP-005's frozen `joinBSSID` (moot while DRV-11C-002 pins joins, but must exist if pinning is fixed) |
| 7 | **Beacon miss / link degradation** | **NO** — `iwx_rx_bmiss` acts internally only (ItlIwx.cpp:6205–6248) | — | macOS cannot do proactive roaming; LQM only updates every 8 beacons of the *join-time* BSSID (WCL.cpp:722) |
| 8 | **Port authorized (4-way complete)** | **NO** — `ni_port_valid=1`/link-UP (pae_input.c:688–693) goes only through IOKit `setLinkStatus` | V2.cpp:640–690 → `handleWCLLink` | No WCL message; join completion is instead inferred from the *first beacon* (WCL.cpp:747–763) — join success is reported only after a post-handshake beacon arrives (adds ~100 ms and a failure mode: join "succeeds" only if a beacon is heard) |
| 9 | Auth attempt / auth failure / timeouts | NO events (ieee80211.c:902–934; proto.c:1341–1352) | — | Join progress invisible; failures surface only at the 30 s WCL timer |
| 10 | Country/regdomain change | `EVT_COUNTRY_CODE_UPDATE` (HAL MCC path) | WCL.cpp:656 | Name-only; no channel-set update (DRV-11C-015) |
| 11 | Link state change | Via `ieee80211_set_link_state` → `setLinkStatus` → `handleWCLLink` (proto.c:1740–1775; V2.cpp:640–690) | WCL LinkStatus message | `LinkStatus up` posted only during join (`joinPending && firstBeaconNotified`); down posted on every transition (DRV-11C-017) — asymmetric by construction |

---

## Open questions

1. **Watchdog race frequency (DRV-11C-004/018):** needs runtime tracing (Debug kext log of `ieee80211_watchdog` SCAN transitions vs. `iwx_newstate_task` completions) to determine whether the ungated 1 s tick ever actually interleaves with RX-driven transitions on this hardware.
2. **Does airportd re-issue a join when it sees the LinkStatus-down of DRV-11C-007?** If yes, the symptom becomes "join storm" (Busy conflicts, AP-008) rather than "silent reconnect"; log WCL `setWCL_ASSOCIATE` timing vs. `EVT_STA_DEAUTH`.
3. **Idle-scan loop power impact (DRV-11C-003):** measure off-channel duty cycle and `EVT_BEACON` message rate while associated-and-idle and while disconnected; compare with radio-off behavior.
4. **DRV-11C-005 loop reproduction:** join an AP that rejects association (hostapd `max_num_sta=0` or deny-MAC) and record whether the 30 s failure path always shows scan→auth→reject cycles as predicted.
5. **Msg4-loss replay stall (DRV-11C-009):** needs a controlled AP that drops msg4 once; confirm the retransmitted msg3 is replay-discarded and the AP deauth timer governs recovery.
6. **`ic_state` during firmware scan (DRV-11C-001):** confirm `ic_state == S_SCAN` (set by `iwx_scan`) at the time beacons arrive, i.e. that the RSN-parse gate at input.c:2075 is always satisfied during scans initiated from INIT (it is set *after* the firmware accepts the scan — beacons received between `iwx_umac_scan` success and line 9005 would be parsed with stale state; window is one gated function, likely nil).
7. **6 GHz enablement scope (DRV-11C-014):** whether the API-68 firmware's `IWX_UCODE_TLV_API_SCAN_EXT_CHAN_VER` band field and `uhb_supported` config bit would suffice if the `notyet` list were compiled in, or whether PHY-context/binding changes are also required — worth a scoped spike before promising Wi-Fi 6E.
8. **BSD ioctl path gating:** `iwx_ioctl` calls `ieee80211_ioctl` with `splnet()` only (ItlIwx.cpp:11077–11107); in the WCL build the live callers are the Skywalk/WCL command paths (gated) — confirm no remaining ungated `if_ioctl` entry (e.g. from `bsdInterface` MTU/flags ioctls) touches node tables.

---

*AUDIT-2c-1 complete. Companion reports: `10-iwx-hal-audit.md` (HAL), `11-airport-integration-audit.md` (Airport/WCL), `13-itl80211-dataplane-audit.md` (data path).*
