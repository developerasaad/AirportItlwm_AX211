# AUDIT-6a: Hardware Inventory - MSI Modern 14 C12MO / Intel AX211 (honest fact split)

**Task ID:** AUDIT-6a
**Date:** 2026-11-18
**Purpose:** Split everything this audit knows about the target hardware into (1) owner-declared facts, (2) source-verifiable facts, and (3) unknowns that require runtime evidence. No runtime evidence exists in this audit (see `23-environment-access.md`, ENV-001), so category (1) is trust-based, (2) is evidence-based, and (3) is the open gap list.

---

### Owner-declared facts

Declared by the owner in the audit directive (and consistent with the repository README). Not independently verifiable in this audit - no runtime access, no DMI/PCI enumeration performed.

| Item | Declared value |
|---|---|
| Machine | MSI Modern 14 C12MO |
| Wireless adapter | Intel Wi-Fi 6E AX211 160MHz |
| Boot configuration | Triple-boot Ubuntu / macOS / Windows |
| macOS version | Sequoia 15.8.2, x86_64 (Darwin 24.x) |
| macOS driver | Native AirportItlwm (kext) with the IWX HAL |
| Owner runtime testing (prior session) | Baseline build hardware-validated (basic Wi-Fi OK); reduced build physically tested: ordinary Wi-Fi connectivity works, ~60-70 Mbps stable (on their internet plan); "wider wireless experience and native macOS integration appear unreliable or insufficiently polished" - user observations, **not** diagnoses (see MAC-002 in `macos-analysis.md`) |
| Build provenance (declared and repo-verified) | Baseline tag `ax211-baseline-validated` (`aa19316`) = clean laobamac upstream `7204c69`; reduced tree HEAD `e4857ff` = tag `v2.4.0-ax211-reduced`, CI-verified, built from parent `f588ecd` (docs-only difference, verified in git) |

---

### Source-verifiable facts

Facts established from the repository, its build artifacts, and the reference source clones (evidence IDs cited).

**Build/kext identity (21-ci-artifact-verification.md):**
- Kext binary: x86_64 Mach-O kext bundle, Debug configuration, **7,622,312 B** (7.27 MiB); CI run `44145096042` (head `f588ecd`), binary sha256 `30a3ce590b8c137faa0e7f593733bacb15dd1c1c2e5f98773b4f6b350a6b674a`; release `v2.4.0-ax211-reduced` asset byte-identical to the CI artifact (CI-001/CI-002/CI-008).
- Baseline binary (same CI, run 22): 16,262,720 B; reduction = -53.13% (CI-003).

**Adapter nature - CNvi integrated (10-iwx-hal-audit.md DRV-IWX-001; 20-linux-iwlwifi-analysis.md section 1, LINUX-001):**
- The AX211 is a **CNvi (integrated connectivity) part**: the Wi-Fi MAC is integrated on package with the platform (PCH), with the RF module on the same package - there is **no separate PCIe Wi-Fi card** in this machine. Linux marks the So-family MAC configs `integrated = true` (the CNvi marker); discrete cards (e.g. AX200) lack the flag and set different latency/LTR parameters.
- Consequence: the **device-to-adapter mapping is subdevice-dependent**. The kext/README Tier-2 device-table trimming is explicitly deferred "pending the MSI's exact PCI device+subsystem identity".

**Firmware family (00-repo-state.md section 4; 21 CI-003; 20 LINUX-002):**
- AX211 firmware family: **so-a0-gf-a0**, API 68, **embedded** in the kext: `iwlwifi-so-a0-gf-a0-68.ucode` (1,533,812 B) + `iwlwifi-so-a0-gf-a0.pnvm` (41,808 B), one coherent build (`core66_LinADLPV::01d30b0c`). 15 blobs total embedded (12 ucode + 3 pnvm).
- Mainline Linux pins API 89 for this family; linux-firmware WHENCE ships 72 through 89 and has pruned 68 - the fork's blob is 21 API versions behind current.

**PCI ID candidates (see table below):** the kext advertises 19 PCI IDs (00-repo-state.md section 6); of the AX211/CNvi-relevant set, four candidate device IDs have embedded firmware and four advertised IDs are broken (no embedded blob, DRV-IWX-002).

---

### UNKNOWN - requires runtime evidence

None of the following can be answered from source; all need live output from the machine (owner-run kit: `tools/ubuntu-diagnostics.sh` probes 01-03, `tools/macos-diagnostics.sh` probes 01-04).

- **Exact PCI device ID + subsystem ID of THIS unit** (mapping is subdevice-dependent; determines the precise cfg, e.g. gf vs gf4 RF variant - see HW-002 and the table below).
- **RF front-end config** of this unit (RF ID: GF vs GF4; antenna chains) - read from silicon straps at runtime on Linux.
- **BIOS version** of this unit.
- **SAR tables**: whether this MSI BIOS exposes WRDS/EWRD/WGDS/PPAG (quantifies the fork's SAR-compliance exposure, LINUX-009).
- **Actual negotiated link capabilities** (bands used, channel width, MCS/NSS, real PHY rate) on either OS.
- **Ubuntu side**: exact kernel version, loaded iwlwifi driver version, loaded firmware version string.
- **macOS side**: loaded kext path and version (is the running kext the CI artifact? - MAC-001), OpenCore config (kext injection vs manual install; relevant to the unsigned-build install path, CI-005).
- **CSME presence/ownership behavior** on this chassis (LINUX-017; consumer non-vPro SKU suggests no, unverified).

---

### PCI ID candidate table

Vendor 8086 (Intel) throughout. "Embedded" = the firmware blob the ID maps to is embedded in the kext binary (so the driver can actually load on that ID); "broken-advertised" = the ID is in `IOPCIMatch` but its firmware is NOT embedded, so attach always fails at firmware load (DRV-IWX-002).

| PCI device ID | Mapping (source audit) | Embedded firmware | Status for THIS unit | Report / finding |
|---|---|---|---|---|
| `0x51F0` | So long-latency MAC -> AX211 config (`iwlax211_2ax_cfg_so_gf_a0`); the ID most commonly associated with AX211 and used as the reference target in the audits (sub 0x1691 maps to gf4/AX411-class) | **Yes** (`so-a0-gf-a0-68.ucode`, + gf4 blob for AX411 subdevices) | **Candidate** (exact ID unverified) | 10 DRV-IWX-001/006; 21 CI-003; 20 section 1 |
| `0x7F70` | So MAC config (`iwl_so_mac_cfg`) | Yes (so family blob) | **Candidate** | 20 section 1 |
| `0x2725` | Fork dev_info: `IWL_DEV_INFO(0x2725, 0x0090, iwlax211_2ax_cfg_so_gf_a0)` - Alder-Lake CNVi AX211 path (21 CI-003); mainline maps 0x2725 to a Ty/AX411-class MAC cfg | **Yes** (`so-a0-gf-a0-68.ucode`) | **Candidate** | 21 CI-003; 20 section 1 |
| `0x7AF0` | So MAC config (`iwl_so_mac_cfg`) | Yes (so family blob) | **Candidate** | 20 section 1 |
| `0x2720` | QnJ -> `iwlwifi-QuQnj-b0-*-48.ucode` | **No** - blob absent | Broken-advertised | 10 DRV-IWX-002 |
| `0x2726` | SnJ -> `iwlwifi-SoSnj-a0-*-63.ucode` | **No** - blob absent | Broken-advertised | 10 DRV-IWX-002 |
| `0x2729` | MA -> `iwlwifi-ma-a0-*-63.ucode` | **No** - blob absent | Broken-advertised | 10 DRV-IWX-002 |
| `0x7E40` | MA -> `iwlwifi-ma-a0-*-63.ucode` | **No** - blob absent | Broken-advertised | 10 DRV-IWX-002 |

Practical implication: whichever of the four CNvi candidates this unit actually is, the kext embeds a loadable firmware for it, so the adapter works - but the exact device+subsystem ID is still required (a) to confirm the precise cfg/RF variant actually in use, and (b) before any Tier-2 device-table/firmware trimming (README defers it for exactly this reason).

---

## Findings

### HW-001: Machine identity is owner-declared only - not independently verified

- Classification: **UNRESOLVED**
- Severity: Info (for interpretation) / Confidence: Medium (owner-declared, unverified)
- Evidence: Audit directive + repository README table (MSI Modern 14 C12MO, Intel Wi-Fi 6E AX211 160MHz, triple-boot, macOS Sequoia 15.8.2 x86_64, native AirportItlwm + IWX). No runtime evidence exists (23-environment-access.md ENV-001); no DMI readout, no PCI enumeration, no `ioreg`/`system_profiler` output was obtained.
- Analysis: All machine-specific conclusions in this audit rest on the owner's declaration. That is adequate for source-level work - the kext is built for exactly this declared configuration, and the CI-verified artifact matches it (21 CI-002) - but any runtime-dependent claim (loaded state, actual IDs, live behavior) must be re-anchored once the owner runs the diagnostic kit (probes 01-04 on either OS would confirm machine, adapter enumeration, and OS build).

### HW-002: Adapter mapping - candidate PCI IDs identified from source; exact device + subsystem ID of this unit unknown

- Classification: **UNRESOLVED**
- Severity: Medium (blocks Tier-2 reduction and precise cfg confirmation) / Confidence: High (candidate set is source-verified; the unit's actual ID is unknown)
- Evidence: Candidate table above. 10 DRV-IWX-001 (verified trace `0x51F0` + GF RF ID -> `iwlax211_2ax_cfg_so_gf_a0` -> `so-a0-gf-a0-68.ucode`); 10 DRV-IWX-002 (four advertised IDs `0x2720/0x2726/0x2729/0x7E40` can never load firmware - blobs not embedded); 21 CI-003 (0x2725 sub 0x0090 -> so-a0-gf-a0 path covered; AX211-family IDs checked by CI: 0x51F0/0x51F1/0x54F0/0x7E40/0x7F70); 20 LINUX-001 (mainline derives cfg + firmware name from silicon straps at runtime, so it cannot mismatch - unlike the fork's static tables). README: Tier-2 specialization deferred "pending the MSI's exact PCI device+subsystem identity (the device->adapter mapping is subdevice-dependent)".
- Analysis: The kext will attach and load firmware on any of the four CNvi candidates (`0x51F0`, `0x7F70`, `0x2725`, `0x7AF0`), so Wi-Fi working does not discriminate between them. The exact device + subsystem ID determines the precise config and RF variant (gf vs gf4, AX211 vs AX411-class module) and is a prerequisite for the deferred Tier-2 device-table trim. Obtainable in minutes at runtime: Ubuntu `lspci -nn` (kit probe `03-pci.txt`) or macOS `system_profiler`/`ioreg` (kit probes 02/07); the Windows partition could also answer it via Device Manager. Until then, every per-device statement in this audit refers to the *candidate set*, not to a confirmed ID.

---

*End of AUDIT-6a hardware inventory. Companion files: `23-environment-access.md`, `ubuntu-analysis.md`, `macos-analysis.md`.*
