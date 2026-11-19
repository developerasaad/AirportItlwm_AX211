# AX211 / AirportItlwm audit - owner-run diagnostic kit (v1)

Two small scripts that collect **runtime evidence** for the AirportItlwm /
Intel AX211 wireless audit on your machines (MSI Modern 14 C12MO, Intel AX211,
Ubuntu 24.x and macOS Sequoia 15.8.2 with OpenCore). The audit team has no
live access to the machines, so you run these locally and share the resulting
bundle back.

| File | Run it on | Command |
|------|-----------|---------|
| `ubuntu-diagnostics.sh` | Ubuntu 24.x | `bash ubuntu-diagnostics.sh` |
| `macos-diagnostics.sh`  | macOS Sequoia | `bash macos-diagnostics.sh` (in Terminal; the default zsh also works) |

Run each script from a writable scratch folder (it creates its output there).
The run takes about a minute on Ubuntu; on macOS the log query in probe 08
can take a few minutes. Re-run the script right after each guided check
below - each run produces a fresh timestamped bundle.

---

## Safety statement

- **Read-only.** The scripts only read system state. They never change
  network settings, never toggle Wi-Fi or Bluetooth, never load or unload
  kernel modules or kexts, never write NVRAM (macOS nvram is only queried),
  never touch the EFI partition, and never download anything.
- **No network disruption.** No connection is dropped, no interface is
  brought down, no scan is forced; the association you have stays as it is.
- **No system changes.** No packages, no config files, no kext caches.
- **No elevated rights needed.** The scripts run as a normal user. A few
  optional root-only *read* commands are listed separately in
  `OPTIONAL-privileged.md` - run them by hand only if you want to.
- **Sanitized output.** Network names, hardware addresses, and IP addresses
  are replaced with stable pseudonyms on your machine before anything is
  packed (details below).

## How to run

```sh
# Ubuntu (in any writable folder):
bash ubuntu-diagnostics.sh

# macOS (Terminal, in any writable folder):
bash macos-diagnostics.sh
```

Optional escape hatch: if a network name or other private string survives
redaction in an unusual form, delete the bundle, add that string (one per
line) to a file `extra-redact-list.txt` next to the script, and re-run.

## What to share back

- `AX211-UBUNTU-EVIDENCE-<UTC>.tar.gz`
- `AX211-MACOS-EVIDENCE-<UTC>.tar.gz`
- your short notes from the guided checks below (throughput numbers, what
  you observed while walking between APs, join results)

Each bundle contains the numbered probe files (01..11 or 01..10) plus
`REDACTION-LOG.txt` describing what was replaced.

## What is redacted

- Hardware addresses `xx:xx:xx:xx:xx:xx` become `BSSID1`, `BSSID2`, ...
  (stable within a bundle, so cross-file correlation still works).
- Wi-Fi network names (SSIDs) become `AP1`, `AP2`, ...
- IPv4 addresses become `10.240.0.1`, `10.240.0.2`, ...
- macOS serial-number values become `REDACTED-SERIAL`.
- Hostname: Ubuntu stores only a one-way digest plus a placeholder;
  both scripts replace hostname-like names in log files with `HOSTn`.
- The mapping is temporary, destroyed after the run, and never written to
  the bundle; `REDACTION-LOG.txt` lists per-file replacement counts only.
- Not rewritten: IPv6 addresses (usually randomized by both OSes) - check
  them yourself if you are cautious.

## Evidence to finding mapping

| Finding | Guided check (what you do) | Evidence to collect | What confirms it |
|---------|----------------------------|---------------------|------------------|
| **DRV-11C-002** roaming disabled | With Wi-Fi associated, walk between two APs of the same network name, as you normally would | macOS bundle collected right afterwards (esp. `08-kernel-log.txt`) | Log shows **no roam/transition events** (802.11k/v/r or BSS switch) while the signal degrades; the link sticks to the far AP or drops entirely. Ubuntu `05`/`07` serve as the known-good baseline |
| **DRV-IWX-011** aggregation leak | Run a speed test right after a fresh boot and note the throughput. Then sleep + wake and run a speed test again; repeat for 3 wake cycles, writing down each number | macOS bundle right after the last wake (`08-kernel-log.txt`, `09-power.txt`) plus your throughput notes | Throughput steps down after each sleep/wake cycle; log shows block-ack / aggregation session teardowns or failures around the wake |
| **DRV-AP-011** scan truncation | From the **same spot**, compare how many networks macOS shows (Wi-Fi menu, or `06-wifi-state.txt`) with what Ubuntu shows in the same location | macOS `06-wifi-state.txt` vs Ubuntu `04-wifi-caps.txt` / `05-wifi-state.txt` | macOS consistently lists noticeably fewer networks than Ubuntu at the same position |
| **DRV-11D-003** WPA3 join | Try to join a WPA3-SAE network on macOS, then collect immediately | macOS `08-kernel-log.txt` | Join fails, silently falls back to WPA2, or produces auth-error lines from the driver; note what the Wi-Fi menu reported |
| **DRV-11D-001** 6GHz missing | On Ubuntu, confirm the AX211 exposes 6GHz channels; on macOS, stand near an active 6GHz AP and scan | Ubuntu `04-wifi-caps.txt` (look for 5955-7115 MHz channels), macOS `06-wifi-state.txt` | Ubuntu lists 6GHz channels but the macOS scan never shows the 6GHz AP |
| **DRV-AP-006/007** power handling | Do one sleep/wake cycle, then immediately run the collector so the 2h log window covers the wake | macOS `08-kernel-log.txt`, `09-power.txt` (and Ubuntu `07`/`11` for ASPM comparison) | Wake-window log shows firmware reload loops, command timeouts, or ASPM-related messages |
| **DRV-11C-003** infinite scan loop | Leave Wi-Fi enabled but **not connected** for 5 minutes, then collect | macOS `08-kernel-log.txt` | Repeating scan-start / scan-done cycles with no user trigger during those 5 idle minutes |

## Files in this kit

- `ubuntu-diagnostics.sh` - Ubuntu 24.x collector (no root)
- `macos-diagnostics.sh` - macOS Sequoia collector (no root)
- `OPTIONAL-privileged.md` - optional root-only read commands, by hand
- `README.md` - this file
