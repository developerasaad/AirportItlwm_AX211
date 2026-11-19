# AUDIT-6a: Ubuntu Runtime Analysis - NOT EXECUTED (gap documentation)

**Task ID:** AUDIT-6a
**Date:** 2026-11-18
**Machine (owner-declared):** MSI Modern 14 C12MO, Intel Wi-Fi 6E AX211 160MHz - Ubuntu partition of the triple-boot

---

### Status: NOT EXECUTED

The directive's live investigation of the Ubuntu partition (Phases 1-2) required remote access to the machine over the network via a relay client tool. That access method is blocked by the sandbox policy and is impossible from this execution environment (see `23-environment-access.md`, ENV-001 / ENV-BLOCK-001; reproduced 3 times, HTTP 403 session kill). **No Ubuntu runtime evidence exists in this audit.** Nothing in this file is based on live observation of the machine. What was performed instead is a **source-only Linux analysis** (20-linux-iwlwifi-analysis.md), summarized below so the gap is explicit: known reference behavior vs. missing evidence.

---

### What the Linux source analysis DID establish

From `20-linux-iwlwifi-analysis.md` (mainline kernel iwlwifi tree at `20eef29b`, snapshot 2026-11-17; linux-firmware WHENCE at `747bdda`; fork comparisons cite reports 10/12/13).

**Architecture (Linux reference for the AX211):** a three-layer stack - a **transport** layer (`pcie/`: PCIe DMA rings, MSI-X, gen3 context-info/IML firmware load, PNVM plumbing), a **firmware runtime** layer (`fw/`: firmware parsing, notification-wait machinery, ACPI/UEFI regulatory tables), and an **op-mode driver**. For AX211 the op-mode is **`iwlmvm`** (`mvm/`) - the newer `iwlmld` (`mld/`) is selected only for Wi-Fi-7-capable families, so AX211 (AX210 family + GF RF) stays on MVM. Above the driver, **mac80211** implements the MLME state machine and **wpa_supplicant** (user space) owns scanning policy, roaming decisions, SAE/FT/802.11v. Versioned UMAC commands let the firmware do channel scheduling, dwell adaptation, and power management.

**Top facts established at source level (LINUX-xxx IDs from report 20):**

1. **iwlmvm opmode selection** - AX211 is served by MVM, not MLD (report 20, architecture summary).
2. **TVQM queue lifecycle** - dynamic per-TID queue allocation ADD -> REMOVE -> free, with size-halving retry on allocation failure and full HE-size BA queues (`sta.c`, `tx-gen2.c`). This proves the fork's never-released-queue leak (DRV-IWX-011) is a driver defect, not a firmware limitation (LINUX-010); the fork's 256-TFD cap/freeze (DRV-IWX-010) has no Linux counterpart, suggesting a host-side cause (LINUX-011).
3. **Firmware API discipline** - mainline pins **API 89** for so-a0-gf-a0 (min==max, matched driver+firmware pair); linux-firmware WHENCE ships **72 -> 89** (latest 89, version 86.a67023b2.0) and has **pruned 68**; the fork is frozen at embedded **API 68** - 21 API versions behind (LINUX-002). Any 2024+ Ubuntu on this machine runs firmware substantially newer than 68 (exact number needs runtime confirmation - open question 1).
4. **Scan offloads** - versioned UMAC scan requests **v12-v17** with adaptive dwell, traffic-dependent scan types (FRAGMENTED/FAST_BALANCE), scheduled scan with firmware match profiles (MATCH_FOUND wakeups), and first-class **6 GHz discovery** via RNR/colocated filtering, PSC-only rules, and passive-6GHz fallback (LINUX-003/004/005). The fork has none of this (single fixed SCAN_REQ_UMAC; infinite idle scan loop DRV-11C-003; no 6 GHz at all DRV-11D-001).
5. **Roaming is host-side** - wpa_supplicant + mac80211 own it: beacon-loss/CQM contract, 802.11r FT auth, 11k/v neighbor reports/BTM in the supplicant, session protection during (re)association (LINUX-006). The fork latches F_DESBSSID for the whole association and cannot roam (DRV-11C-002, DRV-11D-017).
6. **Power management stack** - U-APSD with snooze and misbehaving-AP detection, LPRX, skip-DTIM policies, beacon filter with CQM hysteresis, WoWLAN via D3 image + offloads (ARP/NS, GTK rekey, net-detect), and BIOS SAR/PPAG/GEO/DSM regulatory power tables applied at init (LINUX-007/008/009/018). The fork has none of these (DRV-IWX-016) - including **no SAR enforcement**, a compliance exposure on a SAR-constrained chassis (LINUX-009).
7. **Error containment vs fork reload model** - on AX211-family errors Linux lets the firmware self-recover, aborts all notification waits centrally, and keeps the interface up (no default reinit); the fork stops and reloads firmware on any error, visible as link flaps (LINUX-012, vs DRV-IWX-017/009).
8. **Rate control parity** - both stacks delegate to firmware TLC; no gap (LINUX-019).

Together with report 20's correspondence table, these establish the **known-good reference behavior** that the fork was compared against - entirely at source level.

---

### What runtime evidence on Ubuntu would have provided

Per the directive (Phases 1-2), all of the following were supposed to be collected live and were not:

- **Kernel version** in use on the Ubuntu partition (`uname -r`).
- **Loaded iwlwifi driver version** (in-tree or distro package; `modinfo iwlwifi`).
- **Loaded firmware version string** (which `iwlwifi-so-a0-gf-a0-*.ucode` API the running kernel actually loaded - expected 72-89 per LINUX-002 inference, never confirmed).
- **PCI enumeration** - the exact device + subsystem ID of this unit (closes HW-002; the device-to-adapter mapping is subdevice-dependent).
- **Capabilities** - bands including 6 GHz channels (5955-7115 MHz), channel widths, cipher suites, WoW support as advertised to user space.
- **Live behavior** - association state, scan behavior, roaming behavior between APs of the same network, suspend/resume power events, and a throughput baseline: the known-good baseline for every macOS-side fork comparison in the kit's evidence-to-finding mapping.
- **BIOS tables** - whether WRDS/EWRD/WGDS/PPAG exist on this chassis (quantifies the fork's SAR-compliance exposure, LINUX-009 / open question 2).

---

### How to obtain it now

Run **`tools/ubuntu-diagnostics.sh`** on the Ubuntu partition (owner-run; read-only; no root needed; about a minute; output: sanitized bundle `AX211-UBUNTU-EVIDENCE-<UTC>.tar.gz` with numbered probe files + `REDACTION-LOG.txt`; sanitization happens host-side - see `tools/README.md`). Optional root-only read commands are listed in `tools/OPTIONAL-privileged.md`.

Specific cross-checks the bundle enables (probe file -> finding):

| Ubuntu probe | Closes / cross-checks |
|---|---|
| `01-identity.txt`, `02-platform.txt` | HW-001 (machine identity), DMI/BIOS version |
| `03-pci.txt` | **HW-002** (exact device + subsystem ID) |
| `04-wifi-caps.txt` | DRV-11D-001 baseline: 6 GHz channels present on Ubuntu; capabilities |
| `05-wifi-state.txt`, `07-kernel-log.txt` | DRV-11C-002 baseline: roaming works on Ubuntu while walking between APs (known-good for the macOS roam comparison) |
| `06-driver-fw.txt` (KEY probe) | LINUX-002 / open question 1: exact driver + firmware API loaded; DRV-IWX-006 comparison |
| `07-kernel-log.txt` (KEY probe) | PNVM SKU match (DRV-IWX-008 / open question 3); SAR table presence (LINUX-009); error/recovery behavior (LINUX-012) |
| `08-modules.txt`, `10-bt-coex.txt` | CSME/MEI presence (LINUX-017 / open question 5); coex config |
| `11-power-aspm.txt` | DRV-AP-006/007 comparison: ASPM/power behavior known-good; suspend/resume logs |
| Owner throughput notes | Throughput ceiling baseline vs the macOS-side 60-70 Mbps observation (MAC-002) |

---

### Open questions

All remain open because no Ubuntu runtime evidence exists (ENV-001). Numbering follows the open questions of `20-linux-iwlwifi-analysis.md` (IDs referenced).

1. **Ubuntu firmware confirmation** (LINUX-002; report 20 open q1) - exact linux-firmware version / API the Ubuntu partition loads (expected 72-89 by driver-source inference; `dmesg` firmware line / dpkg query would settle it). Kit probe `06-driver-fw.txt`.
2. **MSI BIOS SAR tables** (LINUX-009; open q2) - does this chassis expose WRDS/EWRD/WGDS/PPAG, which would quantify the fork's SAR-compliance exposure? Runtime-only.
3. **PNVM SKU match** (DRV-IWX-008; open q3) - does the fork's embedded `iwlwifi-so-a0-gf-a0.pnvm` match this unit's fused sku_id, or does every macOS boot burn the 2 s timeout? Firmware logs at runtime would settle it.
4. **Gen3 256-TFD freeze root cause** (DRV-IWX-010 / LINUX-011; open q4) - host-side DMA vs firmware-side? Linux runs larger rings on the same firmware family without the workaround; controlled runtime reproduction needed.
5. **CSME presence** (LINUX-017; open q5) - whether this chassis's ME asserts ownership/rfkill paths the fork cannot negotiate (consumer non-vPro SKU suggests no; unverified).
6. **Firmware behavioral changelog 68 -> 89** (open q6) - Intel does not publish per-API changelogs; the precise fix list the fork is missing is unknowable from source alone; any claim must be marked accordingly.
7. **Exact PCI device + subsystem ID of this unit** (HW-002) - the prerequisite fact for Tier-2 device-table trimming; one `lspci -nn` away.

---

*End of AUDIT-6a Ubuntu gap documentation. Companion files: `23-environment-access.md`, `hardware-inventory.md`, `macos-analysis.md`.*
