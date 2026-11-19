# AUDIT-6a: macOS Runtime Analysis - NOT EXECUTED (gap documentation)

**Task ID:** AUDIT-6a
**Date:** 2026-11-18
**Machine (owner-declared):** MSI Modern 14 C12MO, Intel Wi-Fi 6E AX211 160MHz, macOS Sequoia 15.8.2 x86_64, native AirportItlwm with IWX

---

### Status: NOT EXECUTED

The directive's live investigation of the macOS partition (Phases 4-5) required remote access to the machine over the network via a relay client tool. That access method is blocked by the sandbox policy and is impossible from this execution environment (see `23-environment-access.md`, ENV-001 / ENV-BLOCK-001; reproduced 3 times, HTTP 403 session kill). **No macOS runtime evidence exists in this audit.** Everything below is either source-derived (with report IDs) or an owner-reported observation (explicitly labeled). No log line, ioreg entry, or kextstat output from this machine has been seen by the audit.

---

### Source-derived macOS-side facts

From reports 10 (IWX HAL), 11 (Airport/WCL integration), 12 (control plane), 13 (data plane), and 21 (CI artifact verification).

**Native integration architecture (V2 + Skywalk + WCL; report 11):**
- Layer stack: airportd / WiFiAgent / WCL (userspace) -> IO80211FamilyV2 + IOSkywalkFamily (Apple kexts) -> `AirportItlwmSkywalkInterface` (IO80211InfraProtocol subclass) -> `AirportItlwm` (IO80211ControllerV2 subclass; en0 published via `AirportItlwmEthernetInterface`; corecapture pipes) -> ItlHalService / ItlIwx -> itl80211 / net80211 -> `IOPCIEDeviceWrapper` -> IOPCIDevice. Two-stage match/attach (wrapper personality + NetworkController personality) is what makes the OS treat the kext as the native AirPort controller (DRV-AP-002).
- **apple80211 ioctl path severed**: `apple80211_ioctl()` returns `kIOReturnUnsupported` in WCL mode; every native interaction is a WCL message or an IO80211InfraProtocol virtual call (DRV-AP-001). All legacy ioctl code is dead on this target.
- **~264 Skywalk methods stubbed** `return kIOReturnUnsupported` (roam, WoW, AWDL, BTCoex, 6G, ...) vs ~20 implemented (SSID/BSSID/RSSI/CHANNEL/scan/join/WCL) (DRV-AP-012/013/014; report 11 architecture summary).
- **WCL message contract**: upward events posted via `postMessage` with msgIds 49 ResetInterface, 55 DriverAvailable, 201 ScanResult, 203 Deauth, 211 AssocComplete, 212 FirstBeacon, 213 ConnectComplete, 214 JoinAbortComplete, 216 LinkStatus, 39 LqmUpdate, 237 ScanDone (WCL.hpp:57-69). The wire format is hand-reverse-engineered with magic numbers and raw offsets (DRV-AP-018).
- **In-driver supplicant**: the 4-way/group handshake, RSN, and key installation live in net80211 inside the kext; WCL only delivers PMK/MSK for enterprise networks (DRV-AP-020); EAPOL is never forwarded to macOS on PSK networks (DRV-11D-012).
- Join path: `setWCL_ASSOCIATE` -> `beginWCLJoin` -> forced S_SCAN -> net80211 auth/assoc -> in-driver 4WHS -> ConnectComplete; 30-s join timeout; hard OS gate at start (refuses anything except macOS 15.2-15.x; 15.8.2 passes) (DRV-AP-002).

**Kext identity / versions (report 21):**
- CI-verified artifact: run `44145096042` (head `f588ecd`), x86_64 Debug kext binary **7,622,312 B**, sha256 `30a3ce590b8c137faa0e7f593733bacb15dd1c1c2e5f98773b4f6b350a6b674a`, bundle `com.zxystd.AirportItlwm` v2.4.0; release `v2.4.0-ax211-reduced` asset byte-identical to the CI artifact (CI-001/CI-002/CI-008). Build provenance traceable via the embedded `_f588ecd` string, not via plist metadata (CI-004/CI-007).
- **Unsigned build -> Sequoia install blocker (CI-005)**: no code signature at all; on stock Sequoia 15.8.2 with SIP enabled, `kmutil` will refuse to load it. Installation requires ad-hoc signing + recovery approval or OpenCore injection - not documented in the release notes.
- **19 PCI IDs advertised** in `IOPCIMatch` (CI-006; DRV-IWX-001), of which 4 are broken-advertised (no embedded firmware, DRV-IWX-002); AX211-family coverage verified at binary level (CI-003).

**Capability facts (reports 11/12/13):**
- **No SAE** (WPA3-only networks fail to join; PSK/SAE transition mode works via RSN-IE rewrite, DRV-AP-004 / DRV-11D-003), **no PMF/MFP** (DRV-11D-004), no GCMP (DRV-11D-002), **no 6 GHz band at all** (DRV-AP-003 / DRV-11D-001).
- **Roaming disabled**: `IEEE80211_F_DESBSSID` latched for the whole association blocks bgscan and candidate selection; roam is always full AUTH + 4-way handshake, no 11r/11v (DRV-11C-002 / DRV-11D-017); the WCL roaming-assistance surface is entirely stubbed (DRV-AP-012).
- Other notable source-level issues mapped to user-visible classes: infinite idle scan loop (DRV-11C-003), aggregation lifecycle leaks on roam/sleep (DRV-IWX-011, DRV-11D-009/010), sleep = full stop + firmware reload (DRV-IWX-016), setPOWER OR-logic defect (DRV-AP-006), wake re-enable dependent on WCL follow-up (DRV-AP-007), stale WCL state after internal roam (DRV-AP-005).

---

### Owner-reported runtime observations

From the prior session (owner physically tested the reduced build; user observations, **not** diagnoses):

- **Ordinary Wi-Fi connectivity works.**
- **~60-70 Mbps, stable**, on their internet plan (the plan itself may be the ceiling; the driver's ceiling cannot be distinguished from the plan's without a faster path or a known-good comparison - source-level candidates for a driver-imposed ceiling exist: DRV-11D-008/011, DRV-IWX-005/010).
- **"Wider wireless experience and native macOS integration appear unreliable or insufficiently polished."**

The directive enumerated the symptom classes to investigate live. None was observed by the audit; the owner's phrasing maps to these classes, each of which has source-level candidate explanations (hypotheses only):

| Symptom class (per directive) | Owner-observable behavior | Source-level candidates (unconfirmed) |
|---|---|---|
| Scan list behavior | network list changing/refreshing, fewer networks than Ubuntu | DRV-11C-003 (infinite rescan loop), DRV-AP-011 (scan truncation) |
| Joining | slow or unreliable joins, especially right after opening the Wi-Fi menu | DRV-AP-008 (scan/join Busy race, 20-s window), DRV-11C-005 (assoc-retry loop) |
| Switching (moving between APs) | no seamless transition, drops when walking away | DRV-11C-002 (roam disabled), DRV-11D-017 (full re-auth roam) |
| Status display | wrong network / no bars after a switch | DRV-AP-005 + DRV-11C-002 (stale joinBSSID, LQM forced to -2) |
| Power events | Wi-Fi dead after wake until toggled | DRV-AP-006 (setPOWER OR-logic), DRV-AP-007 (wake re-enable), DRV-IWX-016/017 (reload on sleep/error) |

---

### What runtime evidence would have provided

Per the directive (Phases 4-5), all of the following were supposed to be collected live and were not:

- **Loaded kext identity vs source match** - the directive *required* verifying that the kext actually loaded on the machine is the audited build: kextstat/`kmutil` output (path, version) plus a hash of the loaded binary against the CI artifact sha256 `30a3ce59...` and the embedded `_f588ecd` build string. Not performed - see MAC-001.
- **`log show` kernel itlwm lines** - driver banner/version, firmware load and PNVM wait, scan/join/roam event sequences, EVT_DRIVER_STOPPED errors, aggregation teardowns, command timeouts.
- **ioreg** - the two-stage attach chain (IOPCIEDeviceWrapper -> AirportItlwm), Skywalk interface registration, en0 publication, PCI ID as seen by macOS (contributes to HW-002).
- **Sleep/wake correlation** - pmset log + kernel log around wake windows: firmware reload loops, power-state acknowledgments, whether the WCL power-on replay happens.
- **Symptom correlation** - the guided checks (walk between APs, WPA3 join attempt, 5-min idle scan, sleep/wake speed tests) tied to each symptom class above.

---

### How to obtain it now

- Run **`tools/macos-diagnostics.sh`** on macOS (owner-run, in Terminal; read-only; no root needed; probe 08's log query can take a few minutes; output: sanitized bundle `AX211-MACOS-EVIDENCE-<UTC>.tar.gz` with probes 01-10 + `REDACTION-LOG.txt`; sanitization happens host-side - see `tools/README.md`).
- Optional root-only read commands: **`tools/OPTIONAL-privileged.md`** (run by hand, only if desired).
- The **evidence-to-finding mapping is already in the kit README** (`tools/README.md`): DRV-11C-002 (roaming disabled - walk between APs), DRV-IWX-011 (aggregation leak - speed tests across sleep/wake cycles), DRV-AP-011 (scan truncation - macOS vs Ubuntu network counts), DRV-11D-003 (WPA3 join), DRV-11D-001 (6 GHz missing), DRV-AP-006/007 (power handling - one sleep/wake cycle), DRV-11C-003 (infinite scan loop - 5 min idle).
- For MAC-001 specifically: probes `04-kexts.txt` (loaded kext path/version) and `05-kext-strings.txt` (embedded strings incl. the `_f588ecd` build marker) directly support the identity check; a manual `shasum` of the loaded binary vs `30a3ce59...` completes it.

---

## Findings

### MAC-001: Loaded-kext-identity-vs-source verification not performed

- Classification: **UNRESOLVED** (blocked by ENV-001)
- Severity: **Critical (for the directive's Phase 4 verification requirement)** / Confidence: High (that it is unverified)
- Evidence: No macOS runtime evidence exists in this audit (23-environment-access.md, ENV-001: 3 deterministic reproductions of the policy block, HTTP 403 session kill). Report 21 verifies the *artifact* end-to-end (CI run `44145096042`, binary sha256 `30a3ce59...`, release byte-identical) but cannot verify what the owner's machine actually loads. The kext is **unsigned** (CI-005), so nothing cryptographically ties the machine's loaded copy to the audited build, and typical Hackintosh injection (OpenCore) makes an older/other AirportItlwm variant (baseline, v2.5.0-alpha, another fork) equally loadable. The release title itself says "awaiting hardware validation" (CI-009).
- Analysis: The directive required proving the loaded kext matches the audited source before attributing any runtime behavior to that source. That verification is missing, so every source-to-symptom mapping in this audit *assumes* identity. This is the top-priority item for the follow-up evidence collection: kit probes 04/05 plus a `shasum` of the loaded binary against `30a3ce59...` (and the `_f588ecd` marker) close it in minutes. Until then, the loaded-kext identity - and therefore the applicability of reports 10-13 to the machine's observed behavior - remains unverified.

### MAC-002: Owner symptom set is observations only, not diagnoses

- Classification: **UNRESOLVED**
- Severity: Medium / Confidence: Medium
- Evidence: Owner statements from the prior session: basic Wi-Fi OK; ~60-70 Mbps stable on their internet plan; "wider wireless experience and native macOS integration appear unreliable or insufficiently polished". No structured symptom log, no kernel logs, no reproduction steps, and no per-symptom-class record exist; nothing was observed by the audit itself (ENV-001).
- Analysis: The observations are consistent with several *distinct* source-level defect clusters (scan loop DRV-11C-003; roaming latch + stale WCL state DRV-11C-002/DRV-AP-005; join busy-race DRV-AP-008; power/wake DRV-AP-006/007; aggregation DRV-IWX-010/011), but nothing distinguishes which of them actually manifest on this machine, and the 60-70 Mbps figure cannot be attributed (plan-limited vs driver-limited). The kit's guided checks and evidence-to-finding mapping (`tools/README.md`) are designed to convert these observations into evidence-backed findings; combined with the Ubuntu bundle as the known-good baseline, each symptom class in the table above gets a concrete discriminator. Until that evidence exists, all symptom attributions in this audit are hypotheses, not diagnoses.

---

*End of AUDIT-6a macOS gap documentation. Companion files: `23-environment-access.md`, `hardware-inventory.md`, `ubuntu-analysis.md`.*
