# AUDIT-2b: Native macOS Integration Layer — AirportItlwm (AX211 / Sequoia 15.8.2, x86_64, Debug)

**Audit date:** 2026-11-18
**Repo:** `/home/z/my-project/AirportITLWM` @ `e4857ff` (`v2.4.0-ax211-reduced`), tree clean
**Target under audit:** the only buildable native target, **`AirportItlwm-Sequoia`** (x86_64, Debug, `AIRPORT_WCL` + `__IO80211_TARGET=__MAC_15_2` + `IO80211FAMILY_V2` + `__PRIVATE_SPI__` + `IEEE80211_STA_ONLY`)
**Machine context:** MSI Modern 14 C12MO, Intel AX211 (`iwlwifi-so-a0-gf-a0-68`), basic Wi-Fi physically validated; symptoms under investigation: scan/join/switch/status/power polish.

---

## Method (files + coverage)

Files read **in full** (unless noted), with the compiled-status of each verified against the Sequoia target's `PBXSourcesBuildPhase` (`itlwm.xcodeproj/project.pbxproj:1632-1693`):

| File | Lines | In Sequoia target? | Notes |
|---|---:|---|---|
| `AirportItlwm/AirportItlwmV2.cpp/.hpp` | 1387/289 | **YES (controller class `AirportItlwm`)** | Live IOKit controller (IO80211Controller V2) |
| `AirportItlwm/AirportItlwmSkywalkInterface.cpp/.hpp` | 1079/487 | **YES** | Live Skywalk/WCL interface (~380 virtuals: ~20 real, ~264 stubs, rest header-inline) |
| `AirportItlwm/WCL/WCL.cpp/.hpp` | 1015/566 | **YES** | Live WCL message layer + reverse-engineered wire structs |
| `AirportItlwm/AirportItlwmEthernetInterface.cpp/.hpp` | 201/57 | **YES** | Live en0 (BSD attach) path |
| `AirportItlwm/IOPCIEDeviceWrapper.cpp/.hpp` | 123/36 | **YES** | Live PCI match stage 1 |
| `AirportItlwm/AirportItlwm.cpp/.hpp` | 1046/287 | **NO — dead code** | Legacy (≤macOS 13) controller |
| `AirportItlwm/AirportSTAIOCTL.cpp` | 1532 | **NO — dead code** | Legacy Apple80211 ioctl handlers |
| `AirportItlwm/AirportVirtualIOCTL.cpp` | 534 | **NO — dead code** | Legacy AWDL/P2P ioctls |
| `AirportItlwm/AirportAWDL.cpp` | 58 | **NO — dead code** | Legacy AWDL stubs |
| `AirportItlwm/AirportItlwmInterface.cpp/.hpp` | 50/34 | **NO — dead code** | Legacy IO80211Interface |
| `AirportItlwm/Info.plist` (61) + `WCL/Info.plist` (80) + `WCL/Sequoia-Info.plist` (87) | | live plist = `WCL/Sequoia-Info.plist` (pbxproj:1902) | |
| `include/Airport/*` (28 headers) + `include/Airport/macOS15/*` (9 headers) | | headers | incl. `Apple80211.h`, `apple80211_var.h`/`_ioctl.h`, `IO80211ControllerV2.h`, `IO80211SkywalkInterface.h`, `IO80211InfraInterface/Protocol.h`, `CCPipe/CCStream/CCLogPipe/CCLogStream/FaultReporter`, `IOSkywalk*` |
| `include/ClientKit/Common.h`, `IoctlId.h` | | headers | Skywalk client contract |
| `include/HAL/ItlHalService.hpp` | | header | HAL service abstraction |

Cross-layer evidence (partial reads, targeted): `itlwm/hal_iwx/ItlIwx.cpp` (scan request build `iwx_umac_scan*` ×3, `iwx_umac_scan_fill_channels:7681-7732`, `iwx_scan:8966`, `iwx_bgscan:9011`, `iwx_endscan:10299`, RX notif dispatch `11698-11710`, driver events `10777/10834/10977/13857`), `itlwm/hal_iwx/ItlIwx.hpp:156-161`, `itl80211/openbsd/net80211/ieee80211_var.h:442-453,587-600,687-700`, `ieee80211.c:100-164` (bgscan/cache-bgscan), `ieee80211_node.c:1380-1411` (end_scan), `ieee80211_input.c:2100-2202` (beacon/RSN parse + `EVT_BEACON` emit), `itl80211/openbsd/sys/tree.h:725` (`RB_NEXT`), `sys/_malloc.h`, `itlwm/PrivateSPI.pch`, `itlwm.xcodeproj/project.pbxproj` (targets/defines/phases). Upstream cross-check: `refs/upstream-itlwm@7204c69` (identical `HalService` typo confirmed at SkywalkInterface.cpp:1042).

Prior-fix context honored: `812ea1c` "directed-request abort completion no longer consumes the request" (→ `scanSkipCompletion`, WCL.cpp:260-262, 766-775), `cb027f5`/`22e98fc` restricted-scan snapshot/kScan hoisting (the `kScanSnapshotMax` symbol no longer exists in-tree; its mechanism survives as `ic_wcl_scan_restricted`/`ic_wcl_scan_channels`, ieee80211_var.h:449-450), `59958b4` fast-join hardening, upstream `7204c69` = "fix/wpa3-transition-and-amsdu" (→ `selectWPA2TransitionMode`, WCL.hpp:343-425).

---

## Architecture summary (layer stack)

```
airportd / WiFiAgent / WCL (userspace, Sequoia)
   │  WCL "PostOffice" messages + IO80211InfraProtocol get/set calls
   ▼
IO80211FamilyV2 / IOSkywalkFamily (Apple kexts)
   │  IO80211InfraProtocol ≈ 380 virtual requests (Apple80211 ioctls reborn as C++ vtable)
   ▼
AirportItlwmSkywalkInterface (IO80211InfraProtocol subclass)      ← AirportItlwmSkywalkInterface.cpp/.hpp
   ├── ~20 methods implemented (SSID/BSSID/RSSI/CHANNEL/scan-req/join/WCL_*)
   ├── ~264 methods stubbed `return kIOReturnUnsupported` (roam, WoW, AWDL, BTCoex, 6G, …)
   └── WCL.cpp: message decode/encode (raw-offset wire structs), event pump (handleWCLEvent),
       join state machine (beginWCLJoin/finishWCLJoin/abort/leave), scan state machine
       (beginWCLScan/finishWCLScan), LQM/beacon/BEACON_INFO snapshots
   │  posts upward via IO80211ControllerV2::postMessage(interface, msgId, buf, len, true)
   │  msgIds: 49 ResetInterface, 55 DriverAvailable, 201 ScanResult, 203 Deauth,
   │          211 AssocComplete, 212 FirstBeacon, 213 ConnectComplete, 214 JoinAbortComplete,
   │          216 LinkStatus, 39 LqmUpdate, 237 ScanDone        (WCL.hpp:57-69)
   ▼
AirportItlwm (IO80211Controller V2 subclass, AirportItlwmV2.cpp)
   ├── CC pipes: DriverLogs / DatapathEvents / StateSnapshots + CCFaultReporter (initCCLogs)
   ├── en0 via AirportItlwmEthernetInterface (IOEthernetInterface; deferBSDAttach, provider spoof)
   └── power: IOPM 2-state, thread_call off/on; airplane mode via setPOWER ioctl
   ▼
ItlHalService → ItlIwx (iwlwifi port: firmware, scan cmds, RX) → itl80211/net80211
   (embedded supplicant: 4-way/group handshake, RSN, TKIP/CCMP/BIP crypto, node cache,
    bgscan/roam state machine, WCL scan/join plumbing fields in ieee80211com)
   ▼
IOPCIEDeviceWrapper (IOService, matches IOPCIDevice, MSI setup) → IOPCIDevice (AX211 0x51F0…)
```

**Match/attach chain (2-stage):** `WCL/Sequoia-Info.plist` personality "itlwm" (`IOClass=IOPCIEDeviceWrapper`, `IOPCIMatch` 19 IDs, probe score 70000) wraps the PCI device, enables MSI (`IOPCIEDeviceWrapper.cpp:58-91`), then personality "NetworkController" (`IOClass=AirportItlwm`, `IOMatchCategory=WiFiDriver`, `IONetworkRootType=airport`, `IOResourceMatch=IOBSD`) attaches to the wrapper — this is what makes the OS treat the kext as the *native* AirPort controller. **All legacy Apple80211 ioctl plumbing is dead on this build**: `apple80211_ioctl()` returns `kIOReturnUnsupported` in WCL mode (AirportItlwmV2.cpp:1171-1180), so every native interaction is a WCL message or an `IO80211InfraProtocol` virtual call.

**Scan path (native):** WCL → `setWCL_SCAN_REQ` → command gate → `beginWCLScan` (decode 0x1550-byte request at raw offsets) → sets `ic_wcl_scan_*` fields → firmware UMAC scan (channel bitmap filter in `iwx_umac_scan_fill_channels`, probe/passive decision via `AirportWCL::probeChannel`, off-channel timing via `scanTiming`) → each received beacon → `ieee80211_input.c:2186 EVT_BEACON` → `publishWCLBeacon` → **async WCL message 201 (ScanResult)** per BSS → firmware `SCAN_COMPLETE_UMAC` → `iwx_endscan` → `ieee80211_end_scan` → `EVT_SCAN_DONE` → message 237 (ScanDone) or 20-s timeout. Results are async push messages, *not* snapshot-buffer polling (the old legacy ioctl `getSCAN_RESULT` cache-walk survives only in dead/compat code).

**Join path (native):** WCL → `setWCL_ASSOCIATE` → `beginWCLJoin` (decode 0x2cc candidates at raw offsets) → `startWCLJoin`: classify auth (open/WEP/personal/enterprise only), set net80211 wpa params/PSK/PMKSA, set desired SSID+BSSID, force `S_SCAN` → net80211 auth/assoc → `EVT_STA_ASSOC_DONE` → message 211 → first beacon of target → messages 216 (LinkStatus up) + 212 (FirstBeacon) → 4-way handshake **in-driver** (net80211 supplicant; WCL only delivers PMK/MSK for enterprise via `installWCLKey`) → link up → message 213 (ConnectComplete). Abort: `setWCL_JOIN_ABORT` → message 214. Leave: `setWCL_LEAVE_NETWORK`. 30-s join timeout → ConnectComplete(status=1, reason=1004).

---

## Findings

### DRV-AP-001: Native integration is WCL-message-native; legacy ioctl path intentionally severed
- Classification: **VALIDATED CORRECT BEHAVIOR** (architecture)
- Severity / Confidence: — / High
- Evidence: `AirportItlwmV2.cpp:1171-1180` — `SInt32 AirportItlwm::apple80211_ioctl(...) { ... #ifdef AIRPORT_WCL return kIOReturnUnsupported; #else return super::apple80211_ioctl(...)`; `apple80211SkywalkRequest` ×2 always `kIOReturnUnsupported` (`:1182-1194`). Upward events via `instance->postMessage(this, AirportWCL::ScanResult, metadata, messageSize, true)` (WCL.cpp:343) using `IO80211ControllerV2::postMessage(IO80211SkywalkInterface*, unsigned int, void*, unsigned long, bool)` (include/Airport/macOS15/IO80211ControllerV2.h:131).
- Analysis: On Sequoia the driver speaks the real WCL PostOffice protocol (scan results as async beacon messages, join as candidate lists, driver availability lifecycle). This is a fundamentally more "native" contract than legacy itlwm's ioctl emulation. All remaining findings about ioctls (`AirportSTAIOCTL.cpp`) concern **dead code** on this target unless stated.

### DRV-AP-002: Probe/start lifecycle and interface publication are sound; hard OS version gate
- Classification: **VALIDATED CORRECT BEHAVIOR** (with one sharp edge)
- Severity / Confidence: — / High
- Evidence: Two-stage match: `IOPCIEDeviceWrapper::probe` (`IOPCIEDeviceWrapper.cpp:58-91`) — single branch `ItlIwx::iwx_match(device)` (reduction commit removed ItlIwm/ItlIwn), MSI-X disabled/MSI enabled, stores `pciNub`/`fHalService` for reuse; `AirportItlwm::probe` (AirportItlwmV2.cpp:148-163) adopts them from the wrapper (no re-probe of PCI). `start()` (`:266-469`): version gate `if (version_major != 24 || version_minor < 2) return false;` (`:268-271`), CC pipes before `super::start` (`:279-284`), `fHalService->attach` → watchdog/scan timers → `AirportItlwmSkywalkInterface` created+`initWCL` (`:374-384`) → `attachInterface(fNetIf)` + `IONetworkController::attachInterface(bsdInterface, false)` (`:402-419`) → `RegistrationInfo` + `deferBSDAttach(true)` + `fNetIf->start(this)` (`:420-460`) → `bsdInterface->registerService()` then `registerService()` (`:464-467`). en0 appears at `AirportItlwmEthernetInterface::attachToDataLinkLayer` (AirportItlwmEthernetInterface.cpp:44-87). `stop()` (`:471-487`) calls `stopWCL`, `disableAdapter`, `detachInterface`, `OSSafeReleaseNULL(fNetIf)`, `releaseAll()`; `releaseAll` (`:25-84`) stops CC pipes in reverse-start order, frees workloop/gate/timers, `unregistPM`. `free()` (`:489-510`) frees syncFrameTemplate/roamProfile/btcProfile.
- Analysis: Ordering is correct (HAL attach before interface creation; BSD attach deferred and gated). The version gate means the kext **refuses to start on anything except macOS 15.2–15.x** — correct for this machine (15.8.2, version_minor=8), and it protects against accidental Tahoe loads, but it makes the binary non-portable (see DRV-AP-015). Note `stop()`/`releaseAll()` are only exercised at kext unload; no evidence of teardown races there.

### DRV-AP-003: 6 GHz (Wi-Fi 6E) band entirely excluded from the native scan/channel path
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY**
- Severity / Confidence: High (functional gap) / High
- Evidence: `WCL.hpp:464-468` (`decodeScan`): `if (!channel || channel > 196 || (flags & 0x2000)) continue;` — 6 GHz entries dropped ("Do not confuse 6 GHz channel numbers with overlapping 2.4 GHz ones"); `set6G_MODE(apple80211_6G_mode*)` stub `kIOReturnUnsupported` (SkywalkInterface.hpp:357); `getWCL_FW_HOT_CHANNELS`, `getCOUNTRY_BAND_SUPPORT` stubbed (`:231-232`); channel publication only distinguishes 2/5 GHz: `entry.channelSpec = channel | (5GHz ? 0xd000 : 0x1000)` (WCL.cpp:935, 323); `getSUPPORTED_CHANNELS` maps only `IEEE80211_CHAN_2GHZ/5GHZ` flags (SkywalkInterface.cpp:836-851).
- Analysis: AX211 hardware is 6E-capable, but the WCL integration never advertises or scans 6 GHz. macOS will not show any 6 GHz networks. This is a deliberate scope cut, not a bug — but it caps the "native experience" for 6E APs and should be documented to the user.

### DRV-AP-004: WPA3-SAE-only and PMF-required networks are unsupported; only PSK/SAE transition mode is made to work (via on-the-fly RSN IE rewrite)
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY** (SAE-only) + **VALIDATED CORRECT BEHAVIOR** (transition)
- Severity / Confidence: High / High
- Evidence: `WCL.hpp:506-529` `classifyLegacyAuth` — accepted `upperAuth` bits are only WPA/WPA2/PSK/SHA256-PSK/8021X/SHA256-8021X; "anything else" (SAE bit, FT bits) ⇒ `LegacyAuth::Invalid` ⇒ `startWCLJoin` returns `kIOReturnUnsupported` (WCL.cpp:442-444). PMF is never advertised: WCL capability path zeroes the MFP bit (AirportItlwmV2.cpp:981-995 sets bytes 0/1/2/5/17 only; legacy commented-out `1 | //MFP capable` at `:1000-1005`). Transition networks are handled by `selectWPA2TransitionMode` (WCL.hpp:343-425): rewrites the *scan-message copy* of the RSN IE so a PSK/SAE transition AP presents WPA2-PSK only, preserves PMF-capable (0x80) RSN caps, strips IE 244 — and per the code comment "SAE-only, mandatory PMF and other AKM combinations must not be converted". `validRSNOverride` (WCL.hpp:497-504) gates the WCL RSN write path; `accessWCLRSN(write)` returns `kIOReturnUnsupported` ("net80211 constructs negotiated IEs for its own key handshake", WCL.cpp:396-401).
- Analysis: This is the upstream "WPA3 transition fix" (`7204c69`, merged in baseline) properly integrated: mixed-mode WPA2/WPA3 networks connect using the in-driver PSK supplicant. Pure-SAE (WPA3-only) and PMF-required networks will fail to join with an unsupported status — macOS may show them (from scan IEs) but joins will not succeed. Users on WPA3-only SSIDs will report "cannot join" as a native-integration defect.

### DRV-AP-005: Autonomous net80211 roam leaves WCL state stale (frozen BEACON_INFO/LQM, no LinkStatus-up, LQM forced to −2)
- Classification: **STRONGLY SUSPECTED DEFECT**
- Severity / Confidence: **High** (matches reported "network switching / status" symptoms) / Medium-High
- Evidence: After a completed join, all freshness is keyed to `joinBSSID` captured at join time:
  - `WCL.cpp:709-711`: beacon snapshot only when `IEEE80211_ADDR_EQ(beacon->node->ni_bssid, joinBSSID)`;
  - `WCL.cpp:744-746`: `publishWCLBeacon` for the current network only when `portAuthorized && bssid == joinBSSID`;
  - `WCL.cpp:722`: LQM updates only inside the same joinBSSID branch;
  - `WCL.cpp:145-151` (`updateWCLLinkQualityGated`): quality = −2 unless `ic->ic_bss->ni_bssid == joinBSSID` ⇒ `setLQM(-2)` after roaming to a different BSSID;
  - `WCL.cpp:624-640` (`handleWCLLink`): LinkStatus-up is only ever posted inside the *first-beacon join completion* path (`if (up && joinPending && firstBeaconNotified) finishWCLJoin(...)`); after join completion (`joinPending == false`) a roam-driven down→up cycle posts LinkStatus **down** (reason hardcoded 255) but never LinkStatus **up**;
  - nothing in the tree updates `joinBSSID` on an internal roam; `startWCLJoin` is the only writer (WCL.cpp:436, 514).
  Roaming itself is alive and well inside net80211: periodic `ieee80211_bgscan_timeout` → `ieee80211_begin_bgscan` → roamscan selection in `ieee80211_end_scan` (ieee80211.c:100-128; ieee80211_node.c:1400+), independent of WCL.
- Analysis: When the driver roams by itself (RSSI-triggered bgscan roam — exactly what happens when moving between APs), macOS/WCL keeps the *old* BSSID's beacon snapshot, stops receiving LQM updates, sees LQM go invalid (−2), and (if the roam flaps the link) sees link-down with no matching link-up. Plausible user-visible outcomes: menu bar Wi-Fi shows wrong network/no bars after a switch, "self-assigned IP"/captive re-check loops, or airportd declaring the interface down while it is actually associated. This is the single most likely code-level explanation for the reported switching/status unreliability.

### DRV-AP-006: `setPOWER` radio-on path uses OR-logic on IFF_UP|IFF_RUNNING — can skip re-enable when interface is UP but firmware stopped
- Classification: **CONFIRMED DEFECT** (logic; conditional impact)
- Severity / Confidence: Medium / High
- Evidence: `AirportItlwmV2.cpp:1129-1143`: `bool isRunning = (…if_flags & (IFF_UP | IFF_RUNNING)) != 0;` … power-on: `if (!isRunning) enableAdapter(bsdInterface);`. A single flag (e.g. `IFF_UP` set, `IFF_RUNNING` clear — precisely the state after a firmware failure/stop with the interface left administratively up) makes `isRunning == true`, so radio-on will **not** call `enableAdapter`. Contrast the correct form used elsewhere in the same integration: `(ifnet_flags(interface) & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)` (WCL.cpp:146). The same OR bug exists in the dead legacy path (AirportSTAIOCTL.cpp:1006) and in the non-WCL V2 branch (AirportItlwmV2.cpp:1152).
- Analysis: Airplane-mode/radio toggles performed while the firmware is down-but-interface-up (a common post-error state; the driver emits `EVT_DRIVER_STOPPED` on firmware failure, ItlIwx.cpp:10977-10981) will appear to succeed but leave the radio dead until some other event re-enables. Directly relevant to "radio off/on doesn't bring Wi-Fi back" symptoms.

### DRV-AP-007: System-wake path acknowledges power-on without re-enabling the adapter — recovery depends entirely on WCL follow-up
- Classification: **UNVERIFIED IMPLEMENTATION RISK**
- Severity / Confidence: Medium-High / Medium
- Evidence: `setPowerState(On)` → thread call → gated `setPowerStateOn()` = `pmPowerState = kPowerStateOn; pmPolicyMaker->acknowledgeSetPowerState();` only (AirportItlwmV2.cpp:1381-1386); contrast `setPowerStateOff()` which does `disableAdapter(bsdInterface)` (`:1373-1379`). The `enable(IO80211SkywalkInterface*)` hook also gates on `power_state` (`:542-550`). Re-enable therefore requires airportd/WCL to issue `setPOWER(on)` after wake (→ `enableAdapter`, `:1196-1208`) or an interface re-enable. The comments at `:866-870` show WCL "replays the current address after every driver-available notification", and `setPOWER(0)` explicitly clears `ic_wcl_mac_reconfig` (`:1132`), evidencing that WCL does run a power cycle around sleep — but nothing in-kernel guarantees the on-transition if WCL's state machine believes the radio was already on.
- Analysis: If any wake path skips the WCL power-on replay (e.g. fast-user-switch, lid-wake race, or WCL crash/restart), the firmware stays stopped while IOKit reports power on — "Wi-Fi dead after wake until toggled". Sleep racing an in-flight scan/join is additionally bounded: `stopWCL` cancels the join timer and clears pending flags (WCL.cpp:86-109), and DRIVER_STOPPED finishes scan/join offline (`:673-680`), so pending WCL operations at least fail cleanly.

### DRV-AP-008: Scan/join mutual exclusion returns `kIOReturnBusy` — WCL must retry; 20-s scan window can delay joins
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY** (contract design)
- Severity / Confidence: Medium / High
- Evidence: `beginWCLScan`: `if (scanPending || joinPending || (ic->ic_flags & IEEE80211_F_BGSCAN)) return kIOReturnBusy;` plus `S_AUTH/S_ASSOC → Busy` (WCL.cpp:245-248); `startWCLJoin`: `if (!supported || !(if_flags & IFF_RUNNING) || joinPending || scanPending) … return kIOReturnBusy` (`:442-445`); scan watchdog `scanSource->setTimeoutMS(20000)` (`:269`); aborts exist: `setWCL_SCAN_ABORT` → `finishWCLScan(kIOReturnAborted)` (`:213-216, 201-203`), `setWCL_JOIN_ABORT` → `leaveWCLNetwork` + message 214 (`:617-622`).
- Analysis: The kext cannot preempt its own scan for an incoming join; it relies on WCL issuing SCAN_ABORT/JOIN_ABORT first. Apple's native drivers accept join-during-scan by aborting internally. If WCL (or a corner of its state machine) does not abort, user-visible join latency of up to 20 s (scan window) or outright Busy failures can occur — consistent with "slow/unreliable joining when opening the Wi-Fi menu" (menu open triggers a scan; immediate click-to-join races it).

### DRV-AP-009: Directed-scan abort handling is guarded by a single-shot `scanSkipCompletion` — a second spurious SCAN_DONE completes the WCL scan early
- Classification: **UNVERIFIED IMPLEMENTATION RISK** (residual race after prior fix)
- Severity / Confidence: Medium / Medium
- Evidence: `WCL.cpp:260-262` sets `scanSkipCompletion` at request time when `ic_state == S_SCAN` and (directed request or an existing directed SSID); `WCL.cpp:766-775`: on `EVT_SCAN_DONE`, `if (scanSkipCompletion) scanSkipCompletion = false; else { scanCompleted = true; scanSource->setTimeoutMS(0); }`. Firmware completions arrive from both `IWX_SCAN_COMPLETE_UMAC` and `IWX_SCAN_ITERATION_COMPLETE_UMAC` (ItlIwx.cpp:11698-11710, both funnel into `iwx_endscan`), and `iwx_scan()` aborts a BGSCAN before starting a directed scan (ItlIwx.cpp:8974-8981) — i.e. multiple `iwx_endscan` calls per logical scan are possible.
- Analysis: The prior fix (`812ea1c`) stops the *first* abort-completion from consuming the WCL request, but the guard is one-deep. An iteration-complete during the new scan (fragmented scans produce them) would complete the WCL scan with partial results. Menu would then show a truncated list until the next scan. Needs runtime confirmation (a Debug kext log of `scanCompleted` timing vs. `IWX_SCAN_ITERATION_COMPLETE_UMAC` would settle it).

### DRV-AP-010: Scan-result fidelity: fresh beacons are pushed per-BSS, but WCL messages carry no age; cache-bgscan retains nodes up to 5 minutes
- Classification: **UNVERIFIED IMPLEMENTATION RISK** (staleness) / **VALIDATED CORRECT BEHAVIOR** (freshness of pushed results)
- Severity / Confidence: Low-Medium / Medium
- Evidence: `publishWCLBeacon` (WCL.cpp:307-345) fires only from real received beacon/probe frames (`EVT_BEACON` emit at ieee80211_input.c:2179-2189; RSSI preference for probe responses on 5 GHz at `:2158-2171`), validates IEs (`validIEs`), channel 1-196, SSID ≤ 32 — so each message 201 is a fresh frame. However `BeaconMetadata` (WCL.hpp:118-136) has **no timestamp/age field**, and `ieee80211_begin_cache_bgscan` keeps the node cache unless the last cache scan was > 5 min ago (ieee80211.c:145-150). `asr_age` exists only in the dead legacy `apple80211_scan_result` path.
- Analysis: WCL cannot distinguish a 0.5-s-old from a beacon just received at scan start; Apple's native drivers stamp scan results. Combined with the 5-min node retention (which mostly affects the legacy snapshot walkers, not the push path), the risk is bounded but real for WCL-side ranking (e.g. an AP that vanished mid-scan still shows). Residual impact: stale entries in the menu after an AP is turned off, until the next scan cycle evicts.

### DRV-AP-011: Event delivery ordering across threads is not serialized — ScanDone (timer/workloop) can overtake ScanResult (RX thread)
- Classification: **STRONGLY SUSPECTED DEFECT** (ordering)
- Severity / Confidence: Medium / Medium
- Evidence: ScanResult messages are posted from `handleWCLEvent` executing on the net80211/RX context (`ic_event_handler` invoked directly from `ieee80211_input.c:2186`), while lifecycle events are re-gated through `_fCommandGate` when not already in-gate (WCL.cpp:646-653), and ScanDone is posted from `scanSource` timer on the workloop (`finishWCLScan` ← `completeWCLScan` ← `fakeScanDone`, WCL.cpp:290-305; AirportItlwmV2.cpp:124-136). `EVT_SCAN_DONE` itself arrives from the firmware RX path (`iwx_endscan`, ItlIwx.cpp:11698-11710) but the final ScanDone message is posted after the `setTimeoutMS(0)` timer hop.
- Analysis: The last beacon(s) received on the final scanned channel race the 0-ms timer posting ScanDone. If the timer wins, the menu loses the last networks of the sweep (typically the 5 GHz tail — the last channels in the request). This can present as "network list missing my 5 GHz AP until I rescan". A Debug-build instrumented timestamp comparison (postMessage 201 vs 237) would confirm.

### DRV-AP-012: Roaming assistance surface is entirely stubbed — no 11k/v, no BTM/roam hints, no roam profiles, no BSS blacklist
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY**
- Severity / Confidence: Medium / High
- Evidence: SkywalkInterface.hpp stubs (all `kIOReturnUnsupported`): `setROAM` (`:306`), `setROAM_PROFILE`/`getROAM_PROFILE` (`:102-103, 172, 316`), `setWCL_LEGACY_ROAM_PROFILE_CONFIG` (`:46`), `setWCL_ROAM_PROFILE_CONFIG/V1` (`:365-366`), `setWCL_ROAM_USER_CACHE` (`:367`), `setWCL_SET_MULTI_AP_ENV` (`:368`), `get/setBSS_BLACKLIST` (`:29, 45`), `setOFFLOAD_SCAN`, `setSCAN_CONTROL`, `setSUPPRESS_SCANS` (`:311, 340, 333`), `getBGSCAN_CACHE_RESULTS` (`:171`). Legacy `setROAM` logged and returned `kIOReturnError` (AirportSTAIOCTL.cpp:463-468, dead code). All roaming is therefore driver-internal (see DRV-AP-005 for the consequence).
- Analysis: macOS's native roaming engine (RSSI thresholds, 11k neighbor reports, 11v BSS transition) has no channel to steer this driver; conversely the driver roams silently underneath macOS (with stale WCL state per DRV-AP-005). This is the root "network switching feels wrong" capability gap.

### DRV-AP-013: AWDL/P2P completely absent on Sequoia — no awdl0, AirDrop/Handoff/Watch unlock dead; legacy AWDL/P2P code is dead weight
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY** (+ dead code)
- Severity / Confidence: High (feature) / High
- Evidence: No virtual-interface creation anywhere in the live path: `AirportItlwmV2.cpp` never creates `IO80211VirtualInterface`/P2P; legacy `setVIRTUAL_IF_CREATE` returns `kIOReturnUnsupported` for ≥ macOS 13 ("temporary disabled … This fix the issue of delaying start time of associating to AP", AirportSTAIOCTL.cpp:1456-1458 — dead code on this target); AWDL request handlers (`setAWDL_*`, `setP2P_*`, AirportVirtualIOCTL.cpp / AirportAWDL.cpp) are not compiled (absent from pbxproj Sources phase 1632-1693); `getAWDL_RSDB_CAPS`, `setAWDL_*` stubs Unsupported in the live header; `fAWDLInterface` members exist only in the dead legacy class.
- Analysis: No awdl0 will ever exist; every macOS feature that pins to AWDL (AirDrop, AirPlay, Handoff, Apple Watch unlock) will be missing or degraded. Users perceive this as "Wi-Fi doesn't behave like a real Mac". The dead AWDL/P2P/VirtualIOCTL files (≈2,100 lines) should be deleted to prevent confusion (see DRV-AP-024).

### DRV-AP-014: Wake-on-WiFi/WoW stubbed while magic-packet support is still advertised
- Classification: **UNSUPPORTED OR INCOMPLETE CAPABILITY** + **CONFIRMED DEFECT** (capability honesty)
- Severity / Confidence: Low-Medium / High
- Evidence: `getWOW_PARAMETERS`/`setWOW_PARAMETERS` return errors (AirportSTAIOCTL.cpp:632-643, dead; live SkywalkInterface.hpp:149-150 Unsupported; `setWOW_TEST`, `setWOW_LOW_POWER_MODE`, `getWOW_ENABLED` Unsupported `:62, 149-150, 302`). Meanwhile `getPacketFilters` advertises `kIOEthernetWakeOnMagicPacket` whenever the PCI PM cap reports D3Cold PME (AirportItlwmV2.cpp:905-915; `initPCIPowerManagment` `:1252-1259` sets `magicPacketSupported`), and `setWakeOnMagicPacket` merely stores the flag (`:1312-1316`). No WoW patterns are ever programmed into the firmware.
- Analysis: macOS may offer/attempt "wake for network access" against a driver that can never wake the machine; sleep behavior may include expectations (e.g. keeping association in DKM) that the firmware path doesn't implement. Minor, but a native-contract honesty issue on the power axis.

### DRV-AP-015: Version/OS-conditional hygiene: single hard gate at start, but macOS 12/13/14 conditionals litter live files
- Classification: **UNVERIFIED IMPLEMENTATION RISK** (hygiene) / **VALIDATED** (gate)
- Severity / Confidence: Low / High
- Evidence: Gate: `AirportItlwmV2.cpp:268-271` (`version_major != 24 || version_minor < 2 → no start`). Build defines: `__IO80211_TARGET=__MAC_15_2`, `AIRPORT_WCL`, `AIRPORT_VTD` (pbxproj:1893-1901). `PrivateSPI.pch` fabricates `__MAC_12_0/13_0/14_0/14_4/26_0/15_2` fallbacks (PrivateSPI.pch:8-30) so `#if __IO80211_TARGET >= __MAC_13_0` style checks still compile: e.g. SkywalkInterface.hpp:35/93/104/108/112/223/376/382/396/418 switch on `__MAC_15_2` vs "other"; V2.cpp:268 uses `__MAC_15_2`; WCL.hpp:132/201 dual BeaconMetadata layouts (0x40 Sequoia vs 0x44 other). Dead legacy files still carry `__IO80211_TARGET < __MAC_12_0/13_0` branches (e.g. AirportSTAIOCTL.cpp:1118-1122, 1414-1424, 1433-1437).
- Analysis: On this exact build (`__MAC_15_2`), every `#if` resolves deterministically; the risk is maintenance/next-OS: the `!= __MAC_15_2` branches (Tahoe-shaped `mloAddrArray`, 0x214 extended-BSS, `LqmBeaconUpdate` 0x1dc) are compiled-out but imply someone prepared a Tahoe variant; with the start() gate refusing `version_major != 24`, those branches can never execute. Recommend deleting or clearly marking them; also the pch fake `__MAC_26_0` is unused.

### DRV-AP-016: Scan-result conversion zeroes the legacy rate array (`asr_nrates` read before assignment)
- Classification: **CONFIRMED DEFECT** (cosmetic; live-but-secondary path)
- Severity / Confidence: Low / High
- Evidence: `convertNodeToScanResult` (AirportItlwmSkywalkInterface.cpp:979-1005): `bzero(result, sizeof(*result)); … for (int i = 0; i < result->asr_nrates; i++) result->asr_rates[i] = …; result->asr_nrates = fNextNodeToSend->ni_rates.rs_nrates;` — the loop bound is read from the just-zeroed struct, so `asr_rates[]` is always empty while `asr_nrates` is nonzero. Affects live `getCURRENT_NETWORK`/`getSCAN_RESULT` (`:1007-1047`). Same pattern in dead code (AirportSTAIOCTL.cpp:1426-1428). Related, in the *non-WCL* branch of `getRATE_SET` the rates are written to a **by-value local** and discarded: `struct apple80211_rate apple_rate = ad->rates[i];` (SkywalkInterface.cpp:557; also AirportSTAIOCTL.cpp:804) — the WCL branch fixed this with a reference (`:555`).
- Analysis: Any WCL/legacy consumer of `apple80211_scan_result` rates (e.g. legacy `getCURRENT_NETWORK` consumers, or tools) sees 0 rates. WCL's primary scan path (message 201 with full IEs) is unaffected, so impact is limited; still a real transcription bug worth fixing for contract fidelity.

### DRV-AP-017: Undeclared identifier `HalService` in live `getSCAN_RESULT` — masked only by `RB_NEXT` discarding its 2nd macro argument
- Classification: **CONFIRMED DEFECT** (latent, currently harmless; inherited from upstream)
- Severity / Confidence: Low (latent build hazard) / High
- Evidence: AirportItlwmSkywalkInterface.cpp:1042: `fNextNodeToSend = RB_NEXT(ieee80211_tree, &HalService->get80211Controller()->ic_tree, fNextNodeToSend);` — no `HalService` symbol exists anywhere (repo-wide search; only `fHalService`). It compiles because `tree.h:725` `#define RB_NEXT(name, x, y) name##_RB_NEXT(y)` never expands `x`. Identical line in upstream `refs/upstream-itlwm@7204c69` (same file:1042).
- Analysis: Any future edit that uses the tree head argument (or a different RB macro) turns this into an instant compile error; more importantly it shows the live `getSCAN_RESULT` walker is untested upstream. Fix is a one-liner (`fHalService`).

### DRV-AP-018: WCL wire contract is hand-reverse-engineered with magic numbers and raw offsets — static_asserts are the only guard
- Classification: **UNVERIFIED IMPLEMENTATION RISK** (structural fragility)
- Severity / Confidence: Medium / High (fragility), High (that asserts exist)
- Evidence: WCL.hpp: message IDs (49/55/201/203/211/212/213/214/216/39/237, `:57-69`); `DriverAvailability` with fabricated reasons `0xe0821803/0xe0821804` (WCL.cpp:694-698); `decodeScan` reads at fixed offsets `0x14/0x1c/0x20/0x40/0x54`, 12-byte channel entries (`WCL.hpp:444-472`); `decodeJoin` at `0x10/0x14/0x1c/0x20/0x44/0x48/0x4e/0x50/0xd4/0xd6/0x21c/0x228`, candidate stride 18 (`:531-562`); `BeaconMetadata` 0x40 with offset asserts (`:201-209`); `NativeChannelInfo` 0x2720 with per-field asserts (`:232-243`); `installWCLKey` asserts `sizeof(apple80211_key) == 0x94` (WCL.cpp:365). All sizes/offsets pinned via `static_assert`.
- Analysis: This is the price of native integration without Apple headers: any Sequoia point release that reshapes these private structs will trip a compile-time assert (good) or, worse, silently change semantics without a size change (bad). The `version_minor < 2` gate partially protects (15.2 baseline), but 15.3…15.8 compatibility is asserted only by testing, not by code. For 15.8.2 specifically, the physical validation of basic connectivity is the only evidence the offsets still hold.

### DRV-AP-019: Join robustness machinery is genuinely solid (deferred join across MAC reconfig, abort/leave semantics, timeout with 802.11 reason)
- Classification: **VALIDATED CORRECT BEHAVIOR**
- Severity / Confidence: — / High
- Evidence: Deferred join: if WCL associates while a private-MAC firmware restart is in flight, the request is held (`deferredJoin`, `joinDeferred=joinPending=true`, 30 s timer) and replayed on `EVT_DRIVER_READY` (WCL.cpp:433-441, 540-554, 682-700); failure replay posts ConnectComplete with the error (`:550-553`). MAC plumbing: `setHardwareAddress` differentiates replay (`MacUpdate::Unchanged` — no firmware restart) vs real change, updates the BSD lladdr directly because "WCL calls this directly, bypassing IOEthernetInterface's normal MAC ioctl" (AirportItlwmV2.cpp:844-883; `planMacUpdate`/`consumeMacReconfiguration` WCL.hpp:18-35). Timeout: `wclJoinTimeout` → `finishWCLJoin(1, 1004, kIOReturnTimeout)` + `leaveWCLNetwork` (WCL.cpp:581-588). Abort → message 214 (`:617-622`). Leave/disassociate clears PSK/PMKSA/enterprise flag with `explicit_bzero` (`:590-615`). Secrets hygiene: `explicit_bzero(&join)` after use throughout (`:437, 443, 481, 495, 520, 545, 549, 567, 597`).
- Analysis: The join lifecycle handles the nastiest WCL interactions (MAC reconfig race, abort, timeout, secret zeroing) deliberately. This area looks like the most mature part of the WCL layer.

### DRV-AP-020: Key/supplicant model: 4-way handshake in-driver; WCL delivers only PMK/MSK for enterprise; PTK/GTK path is legacy-only
- Classification: **VALIDATED CORRECT BEHAVIOR** (model) — with a documented capability cut
- Severity / Confidence: — / High
- Evidence: `installWCLKey` accepts only cipher 6/7/9 (PMK/PMKSA/MSK), 32-byte keys, requires `ic_wcl_enterprise` and 802.1X AKM, else `kIOReturnUnsupported`/`BadArgument` (WCL.cpp:363-390; `validCipherKey` WCL.hpp:489-495 — "Native WCL accepts PMK/MSK for enterprise, not legacy PTK/GTK"). Personal WPA: PSK carried inside the join request and installed via `ic_psk` + `IEEE80211_F_PSK` (WCL.cpp:484-486); handshake performed by net80211 (`ieee80211_pae_input/output.c` compiled; `setPTK`/`setGTK` install keys via `ic_set_key`, SkywalkInterface.cpp:179-271 — these are reached from the net80211 supplicant path, not from WCL `setCIPHER_KEY`, which routes to `wclCommand` case 8 in WCL mode, SkywalkInterface.cpp:346-347). PMKSA cache managed with compat malloc/free pairing (ieee80211_crypto.c:657; WCL.cpp:347-356 with `::free` matching `_malloc.h` inline).
- Analysis: The split is coherent: macOS supplicant is *not* used (`useAppleRSNSupplicant` semantics gone in V2; USE_APPLE_SUPPLICANT not defined in target), the in-driver supplicant owns EAPOL. Group-key rekey and EAPOL pass-through over en0 are therefore native-stack-visible only as data frames — macOS captive/802.1X UI flows that expect to drive the supplicant will not engage for personal networks (password prompt caching is WCL-side, key material is kernel-side). This is the intended design and matches "basic connectivity works".

### DRV-AP-021: Status reporting: live getters return errno-style codes; association status is binary; LQM is a 3-step RSSI mapping updated every 8 beacons
- Classification: **PARTIAL / UNVERIFIED IMPLEMENTATION RISK** (fidelity)
- Severity / Confidence: Low-Medium / Medium-High
- Evidence: Not-run getters return BSD errnos as IOReturn: `return 6;` (ENXIO) when not associated — getSSID/getCHANNEL/getBSSID/getRSSI/getNOISE/getRATE (SkywalkInterface.cpp:308-324, 461-474, 645-656, 658-673, 733-747, 590-643); `getASSOCIATION_STATUS` collapses to SUCCESS/UNAVAILABLE (`:876-891`); `getLINK_CHANGED_EVENT_DATA` reports isLinkDown from `currentStatus` + `disassocIsVoluntary` + hardcoded reason DEAUTH (`:924-940`). LQM: `quality = rssi >= -70 ? 100 : (rssi >= -85 ? 50 : 20)` else −2, pushed via `setLQM` only on change or force (WCL.cpp:143-159); beacon-count LQM snapshots every 8th beacon (`:722-742`); Sequoia LQM struct = RSSI only (`SequoiaLqmUpdate` 0x150, WCL.hpp:71-78). RSSI scaling is consistent everywhere: `-(0 - IWM_MIN_DBM - ni_rssi)` = `ni_rssi − 100` with `IWM_MIN_DBM −100` (if_iwxreg.h:8111-8115; getRSSI SkywalkInterface.cpp:666-669; beacon metadata `IWM_MIN_DBM + ni_rssi` WCL.cpp:328; LQM WCL.cpp:149).
- Analysis: Coarse LQM (3 tiers) means macOS's link-quality UI (and its auto-join ranking) sees quantized quality — bars may sit at thresholds and not reflect subtle degradation; combined with DRV-AP-005's −2-after-roam, status display is the weakest reporting axis. The errno-as-IOReturn pattern mirrors Apple's airport cards (ENXIO when disassociated) and appears intentional.

### DRV-AP-022: Country/regulatory reporting is layered but locale is hardcoded FCC; channel lists are active-set only
- Classification: **PARTIAL / UNSUPPORTED OR INCOMPLETE CAPABILITY**
- Severity / Confidence: Low-Medium / High
- Evidence: `getCOUNTRY_CODE`: boot-arg `itlwm_cc` > firmware MCC > geo-location (AirportItlwmV2.cpp:1066-1081); firmware MCC updates arrive via `IWX_MCC_CHUB_UPDATE_CMD` → `EVT_COUNTRY_CODE_UPDATE` (ItlIwx.cpp:8530-8531) → deferred thread-call + gated post (WCL.cpp:28-76 — deliberately never runs synchronous WCL ioctls on the workloop thread); `setCOUNTRY_CODE` stores geo cc (excluding 'X') and reposts (`:1083-1104`). `getLOCALE` hardcoded `APPLE80211_LOCALE_FCC` (SkywalkInterface.cpp:853-862). Channel surfaces: `getWCL_CHANNELS_INFO` (0xc86 struct) and `getCHANNELS_INFO`/`copyWCLChannels` (0x2720 native) enumerate **only `ic_chan_active`** with DFS/passive flags, no indoor flag, no 6 GHz (WCL.cpp:922-975); `getSUPPORTED_CHANNELS` uses the Ventura-restricted flag translation (`ieeeChanFlag2appleScanFlagVentura`, which intentionally drops DFS/bandwidth flags: "airport/wifiagent … don't like to accept extra channel flags … wifi list … will not refresh after system boot", SkywalkInterface.cpp:35-44 & AirportSTAIOCTL.cpp:313-326).
- Analysis: Country updates flow correctly end-to-end (a genuinely hard part). The hardcoded FCC locale and flag-stripped channel lists are mimicry trade-offs from the Ventura era — they can misshape the menu (e.g. DFS channels shown as active) but are known-stable with airportd.

### DRV-AP-023: Fast Lane is deliberately accepted-and-ignored to prevent WCL tearing down the link; low-latency/P2P reports zeroed
- Classification: **VALIDATED CORRECT BEHAVIOR** (workaround) / UNSUPPORTED (feature)
- Severity / Confidence: — / High
- Evidence: `setWCL_UPDATE_FAST_LANE` returns success unconditionally with the rationale: "returning an error here makes WCL treat it as 'Update Bss fail' and tear the link down ~0.4 s after LINK_STATE_IS_UP" (WCL.cpp:899-911). `getWCL_LOW_LATENCY_INFO` zeroes 4 bytes ("No low-latency or P2P session is implemented", `:913-920`).
- Analysis: Good example of contract-compliance-by-mimicry: the native stack's post-associate queries must be answered benignly or the association is dropped. This class of workaround is scattered through the WCL layer and each one is a potential future tripwire (see DRV-AP-018).

### DRV-AP-024: Dead legacy integration files (~4,100 lines) remain in-tree and mislead auditing/maintenance
- Classification: **CONFIRMED DEFECT** (hygiene)
- Severity / Confidence: Low / High
- Evidence: pbxproj Sources phase (1632-1693) compiles only: ItlDma, _mbuf, ieee80211/* (incl. ra/mira/rssadapt/amrr), crypto, `AirportItlwmV2.cpp`, `AirportItlwmEthernetInterface.cpp`, `AirportItlwmSkywalkInterface.cpp`, `WCL/WCL.cpp`, `IOPCIEDeviceWrapper.cpp`, `ItlHalService.cpp`, `ItlIwx.cpp`, compat, _ifq, CTimeout. NOT compiled: `AirportItlwm.cpp` (1,046), `AirportSTAIOCTL.cpp` (1,532), `AirportVirtualIOCTL.cpp` (534), `AirportAWDL.cpp` (58), `AirportItlwmInterface.cpp` (50) — these still reference the legacy `AirportItlwm` class from `AirportItlwm.hpp` and are only kept as "None" build-phase entries (pbxproj:75-247). They contain the infamous **fake-scan** design: `setSCAN_REQ` starts a 100-ms timer and posts `APPLE80211_M_SCAN_DONE` regardless of the actual firmware scan (AirportItlwm.cpp:437-441, AirportSTAIOCTL.cpp:1343-1359), plus `eventHandler`'s `#if 0`-ed SCAN_DONE passthrough (AirportSTAIOCTL.cpp:1208-1212) — the historical cause of itlwm's stale scan menus on older macOS.
- Analysis: Two classes named `AirportItlwm` exist in-tree (AirportItlwm.hpp vs AirportItlwmV2.hpp); the dead one contains defect patterns (fake scan, silent join drops at S_AUTH/S_ASSOC returning success, AirportSTAIOCTL.cpp:1044-1048, OR-flag power bug) that a future maintainer could resurrect by re-adding a target. Recommend deletion (or an explicit `legacy/` quarantine + README), matching the reduction philosophy of `eb815e4`.

### DRV-AP-025: `en0` publication relies on a provider-identity spoof and deferred gated BSD attach — fragile but guarded
- Classification: **UNVERIFIED IMPLEMENTATION RISK** (private-SPI workaround)
- Severity / Confidence: Low-Medium / Medium
- Evidence: `AirportItlwmEthernetInterface::getProvider()` returns the *Skywalk interface* as provider after attach "to avoid skywalkfamily instance cast panic" (AirportItlwmEthernetInterface.cpp:96-103); BSD attach is deferred (`deferBSDAttach(true)`, AirportItlwmV2.cpp:438) and `prepareBSDInterface` is executed under the command gate with explicit in-gate/not-on-thread checks (`:31-41`, `:66-74`); `setInterfaceSubType(3)` gates success (`:50-52`); interface name/unit/MAC are mirrored onto the Skywalk interface properties for WCL discovery (`:55-65`); `setLinkState` force-toggles IFF_UP|IFF_RUNNING on the ifnet (`:120-129`).
- Analysis: This is the load-bearing hack that lets a classic IOEthernetInterface masquerade under an IOSkywalkNetworkInterface world. The gated-attach dance is careful (failures detach from the data-link layer), but any Sequoia update that changes Skywalk's expectations of provider identity turns this into a panic path. Notably `getProvider()` lying about the provider is exactly the kind of thing that breaks across OS updates silently.

### DRV-AP-026: Power-state thread-call ack deadline (5 s) vs actual firmware stop/start cost
- Classification: **UNVERIFIED IMPLEMENTATION RISK**
- Severity / Confidence: Low-Medium / Medium
- Evidence: `setPowerState` returns `5000000` µs (5 s) as the PM ack delay for both off and on transitions (AirportItlwmV2.cpp:1294, 1302); off path performs `disableAdapter` → full `fHalService->disable` (firmware stop) inside the gated thread call (`:1318-1334`); on path acks immediately (`:1336-1352`).
- Analysis: If the firmware stop ever exceeds 5 s (firmware wedge during scan — the code comments in WCL.hpp:296-312 note firmware resets on AX210-class hardware under aggressive scan timing), the PM root domain will power-manage the device anyway, potentially mid-teardown. Combined with DRV-AP-007 this is the cluster of sleep/wake risks worth instrumenting on the physical machine.

### DRV-AP-027: Scan while associated uses cache-bgscan semantics — node cache retained, auto-roam suppressed for WCL scans, off-channel timing tuned for stability
- Classification: **VALIDATED CORRECT BEHAVIOR** (design) with a documented trade-off
- Severity / Confidence: — / High
- Evidence: `beginWCLScan` in S_RUN → `ieee80211_begin_cache_bgscan` (WCL.cpp:270-277), which sets `IEEE80211_F_DISABLE_BG_AUTO_CONNECT` (no roam from a user scan) and retains nodes for 5 min (ieee80211.c:131-156); failure to start bgscan → Busy and state rollback (`:272-277`). Off-channel timing: `scanTiming` returns 120 TU out / 120 TU home by default, fragmented 44/95 TU only when WCL asks for a short away time, with the comment that a 30 TU home time "coincided with firmware resets on AX210" (WCL.hpp:290-312). `setWCL_SET_SCAN_HOME_AWAY_TIME` feeds `ic_wcl_scan_away_time_ms` (WCL.cpp:997-1004; ItlIwx.hpp:156-161). Directed/restricted scan plumbing: channel bitmap (`ic_wcl_scan_channels`) filters firmware channel list (ItlIwx.cpp:7697-7702), probe decision `probeChannel(active, passive, dfs)` replaces the legacy `n_ssids != 0 && !bgscan` (ItlIwx.cpp:7720-7726), SSID-directed probes from `ic_wcl_scan_ssid` (ItlIwx.cpp:8068-8075, duplicated in v12/v14 builders at 8278+, 8406+).
- Analysis: The restricted-scan/snapshot mechanism (prior fixes `cb027f5`/`22e98fc`/`812ea1c`) is now a coherent design: WCL's channel list and SSID steer the actual firmware scan, results are pushed live. The trade-off: a full-band scan while associated costs ~2× (120 TU home between channels) — menu refresh while connected is slower than Apple native, but stable.

### DRV-AP-028: Capability advertisement is tuned per-OS-release with non-obvious bit semantics (HE bit for Tahoe, scan-completion bit, TKIP group-cipher re-enable)
- Classification: **VALIDATED CORRECT BEHAVIOR** (deliberate mimicry) / note for maintenance
- Severity / Confidence: — / High
- Evidence: `getCARD_CAPABILITIES` WCL branch (AirportItlwmV2.cpp:981-995): TKIP re-advertised because "net80211 handles TKIP/MIC in software; hiding it makes Apple80211 reject these networks before it submits an association request" (`:982-986`); byte 5 = 0x40 "Scan completion events" (`:988`); byte 17 bit 7 = HE support "Tahoe WCLDeviceConfiguration::isHeSupported reads byte 17, bit 7" (`:992-995`); WME/SGI bits (`:989-991`). HE itself is **opt-in via boot-arg**: `itlwm_he=1` sets `IEEE80211_F_HEON` (AirportItlwmV2.cpp:333-337) — default build connects as 802.11ac even to AX APs.
- Analysis: The capability bytes are hand-tuned against observed airportd/WCL behavior (rejection paths, tear-downs). They are load-bearing: changing any bit can break join or menu behavior. Wi-Fi 6 (HE) being disabled by default on an AX211 is a notable user-visible "not like native" gap (no 11ax rates unless boot-arg set), presumably for stability (AMSDU/HE issues per the upstream merge title "fix/wpa3-transition-and-amsdu").

---

## Feature support matrix (native macOS Wi-Fi features vs this driver, Sequoia build)

| Native feature | Status | Evidence / Notes |
|---|---|---|
| SSID scan (menu open, background) | **Supported** (WCL message 201 push, directed + channel-restricted) | WCL.cpp:237-345; restricted channels ItlIwx.cpp:7697-7702 |
| Fast/passive scan types | Partial — WCL only distinguishes active vs passive (`scan.type != 2`); legacy FAST type was fake | WCL.cpp:264-265; dead: AirportSTAIOCTL.cpp:1347-1352 |
| Scan abort | Supported (`SCAN_ABORT` → Aborted completion) | WCL.cpp:213-216, 201-203 |
| Join/associate (open/WEP/WPA-PSK/WPA2-PSK/SAE-transition) | Supported (in-driver supplicant) | WCL.cpp:414-538; WCL.hpp:343-425 |
| WPA3-SAE (SAE-only networks) | **Missing** (join rejected `kIOReturnUnsupported`) | WCL.hpp:506-529; no SAE in net80211 |
| WPA3 ↔ WPA2 transition mode | Supported via RSN IE rewrite to PSK (scan-copy only) | WCL.hpp:343-425 |
| PMF/MFP (protected management) | **Missing** (capability bit not advertised; PMF-required nets unreachable) | V2.cpp:981-995 |
| 802.1X enterprise (EAP) | Supported (PMK/MSK via `installWCLKey`; EAPOL over en0) | WCL.cpp:363-390 |
| 4-way handshake / GTK rekey | Supported in-driver (net80211 PAE; `ic_set_key` PTK/GTK install) | SkywalkInterface.cpp:179-271 |
| 11r FT (fast transition) | **Missing** (FT auth bits → Invalid → join rejected) | WCL.hpp:518-521 mask |
| 11k/11v (RRM/BTM) | **Missing** (all related handlers stubbed) | SkywalkInterface.hpp stubs; no action-frame path (bpfOutput → free, legacy) |
| Roaming (macOS-assisted) | **Missing** (setROAM/roam profiles/blacklist Unsupported) | SkywalkInterface.hpp:46, 102-103, 172, 306, 316, 365-368 |
| Driver-internal roam (bgscan) | Supported but invisible/stale to WCL after roam | DRV-AP-005 |
| 6 GHz / Wi-Fi 6E band | **Missing** (channels dropped everywhere) | DRV-AP-003 |
| HE / Wi-Fi 6 (2.4/5 GHz) | **Opt-in** (`itlwm_he=1` boot-arg; cap bit 17×0x80 only then) | V2.cpp:333-337, 992-995 |
| VHT/HT rates & NSS reporting | Supported (rate sets, MCS/VHT maps, HE MCS intersection) | SkywalkInterface.cpp:485-566; WCL.cpp:854-897 |
| AWDL (AirDrop/Handoff/Watch unlock) | **Missing** (no virtual interfaces on Sequoia) | DRV-AP-013 |
| P2P / Instant Hotspot / softAP | **Missing** (P2P/softAP/GAS/Hotspot-2.0 handlers stubbed; `getGAS_RESULTS`, `setSOFTAP_*`, `setP2P_*` Unsupported) | SkywalkInterface.hpp:164, 207-209, 302-314, 336-338 |
| Wake-on-WiFi (WoW) | **Missing** (params Unsupported; magic-packet filter falsely advertised) | DRV-AP-014 |
| Low-latency mode / Fast Lane | Stubbed / accepted-and-ignored | WCL.cpp:899-920 |
| TKIP group cipher (WPA2 mixed) | Supported (re-advertised deliberately) | V2.cpp:982-986 |
| WEP | Supported (shared-key auth rejected; open-system WEP keys via nwkey) | WCL.cpp:499-510; legacy comment AirportItlwm.cpp:193-196 |
| Country/regulatory reporting | Partial (fw MCC + geo + boot-arg; locale hardcoded FCC; DFS flags stripped in supported-channels) | DRV-AP-022 |
| LQM / link quality to macOS | Partial (3-tier RSSI mapping, 8-beacon cadence, RSSI-only Sequoia struct) | DRV-AP-021 |
| Traffic counters to WCL | Supported (per-AC TX/RX aggregated) | WCL.cpp:986-995; ieee80211_var.h:452-453 |
| CC logging / diagnostics (CoreCapture) | Supported (3 pipes + fault reporter; wired to native `getLogPipes`/`getFaultReporterFromDriver`) | V2.cpp:169-264, 926-942 |
| Private/random MAC | Supported (planMacUpdate, WCL replay-safe, firmware restart path) | V2.cpp:844-883; WCL.hpp:18-35 |
| Captive-network assistant | Works at IP layer (en0 traffic); no driver hooks (none required) | — (n/a by design) |
| MLO / multi-link (future) | Headers prepared (`mloAddrArray`, AssociationEvent.mlo) but unimplemented; setMacAddress(ether_addr) on 15.2 | SkywalkInterface.cpp:1060-1069; WCL.hpp:138-147 |

---

## Open questions

1. **Roam staleness (DRV-AP-005):** Does an actual RSSI-triggered net80211 roam occur on the physical machine (check `XYLog` "roam scan"/`end roam scan` lines, ieee80211_node.c:1413-1417), and does the menu/RSSI freeze afterward? Needs a runtime log capture of `postMessage 216/39` vs. BSSID change.
2. **ScanDone vs ScanResult ordering (DRV-AP-011):** Instrument `finishWCLScan` timestamp vs. last `publishWCLBeacon` per scan generation to confirm/deny the tail-loss race.
3. **Wake path (DRV-AP-007):** On lid-open/wake on the MSI, does airportd reliably issue `setPOWER(on)` (watch `itlwm: setPOWER:` IOLog, V2.cpp:1128)? If not, the "no Wi-Fi after wake" class is confirmed in-kernel.
4. **setPOWER OR-bug (DRV-AP-006):** Reproduce by toggling airplane mode right after a firmware failure (force with `EVT_DRIVER_STOPPED` conditions) and observe whether the radio recovers.
5. **`scanSkipCompletion` depth (DRV-AP-009):** Enable firmware scan notifications logging (`IWX_SCAN_ITERATION_COMPLETE_UMAC`, ItlIwx.cpp:11705) and count completions per WCL scan; more than one skip-needing completion breaks the single-shot guard.
6. **15.8.2 wire-contract drift (DRV-AP-018):** The struct layouts were reverse-engineered against 15.2. Since basic join works on 15.8.2, the core offsets hold, but has anyone verified `getCHANNELS_INFO` (0x2720) and `LqmUpdate` (0x150) consumers end-to-end on 15.8? A `wifiutil`/diagnostics capture comparing WCL's view of channels/LQM vs. `airport -I` would validate.
7. **Unsolicited ScanResult messages:** `publishWCLBeacon` also fires during net80211's own auto-join scans (`ic_state == S_SCAN`, WCL.cpp:744) outside any WCL scan request — does WCL ignore or append these? (Determines whether boot-time scans pollute the menu.)
8. **`enable()` no-op when `power_state == 0`:** Who is expected to call setPOWER(on) first on a fresh boot — verify ordering between WCL power-on and interface enable in the boot log.
9. **Dead code removal:** Confirm no packaging step (CI/distribution scripts) references the uncompiled legacy files before deletion (DRV-AP-024).
10. **HE opt-in:** Was `itlwm_he` default-off chosen for AMSDU stability on AX211 (upstream "wpa3-transition-and-amsdu" fix lineage)? If so, document the boot-arg for users wanting 11ax rates.

---

*AUDIT-2b complete. Companion reports: `00-repo-state.md` (AUDIT-1). Suggested next: runtime log capture on the MSI targeting DRV-AP-005/006/007/011 to convert STRONGLY SUSPECTED → CONFIRMED.*
