# AUDIT-1: Repo State Verification + Reference Material — AX211/AirportItlwm Forensic Source Audit

**Audit date:** 2026-11-18
**Working repo:** `/home/z/my-project/AirportITLWM` (reduced AirportItlwm fork)
**Task ID:** AUDIT-1

---

## 1. Git state

| Item | Value |
|---|---|
| HEAD | `e4857ff53a3dfbc7d9eddf41b6d92a94b9b64b54` (short `e4857ff`) |
| `git describe --tags --always` | `v2.4.0-ax211-reduced` (HEAD is exactly on this tag) |
| HEAD subject | `docs: record AX211 reduced-build state, measurements, and comparison vs baseline` |
| Working tree | **CLEAN** (`git status --porcelain` → empty) |
| Current branch | `main` (only local branch) |

**Tags (5):**
- `ax211-baseline-validated` → `aa193163c2a8c36fbaa86fea2113e7f74e4fdf96` ✓ (expected `aa19316` — verified)
- `v2.4.0-ax211-reduced` → `e4857ff53a3dfbc7d9eddf41b6d92a94b9b64b54` ✓ (exists, == HEAD)
- `v2.4.0-baseline-ax211` (baseline-era tag)
- `v2.5.0-alpha`
- `dell-ac9462-v2.5.0-alpha-final`

**Branches:**
- Local: `main` (*)
- Remote: `origin/main`, `origin/HEAD -> origin/main`, `origin/baseline-validated`, `origin/archive/dell-ac9462-v2.5.0-alpha`

**Recent history (baseline → HEAD):**
```
e4857ff docs: record AX211 reduced-build state, measurements, and comparison vs baseline
f588ecd ci(verify): lower binary-size floor to 4MB for reduced firmware payload
a454f64 fix(iwx): provide shared IWM_MIN_DBM constant in if_iwxreg.h
e982fe9 fix(pbxproj): wrap single-element array fields in parens (Xcode requires NSArray)
eb815e4 reduce(AX211): remove non-AX211 HALs, standalone itlwm, non-Sequoia OS, iwm/iwn firmware
26a0c8c docs: record AX211 Sequoia baseline build facts (commit, run, sha256, device match)
aa19316 baseline: fresh laobamac upstream (7204c69) for AX211 Sequoia Debug
```
Baseline→HEAD delta: **76 files changed, 1,077 insertions(+), 44,526 deletions(-)** (hal_iwm + hal_iwn fully deleted; standalone itlwm.cpp/hpp/pm.cpp deleted; `itlwm/hal_iwx/if_iwxreg.h` +9 lines for shared `IWM_MIN_DBM`).

---

## 2. Source tree inventory

File count pattern: `*.cpp *.hpp *.c *.h *.plist`; line count pattern: `*.cpp *.hpp *.c *.h` only.

| Directory | Files (incl. .plist) | Lines (C/C++/H) | Notes |
|---|---:|---:|---|
| `AirportItlwm/` | 20 | 8,774 | Kext classes + `Info.plist` + `WCL/` (WCL.cpp/hpp, WCL Info.plist, WCL Sequoia-Info.plist) |
| `include/` | 45 | 7,785 | `Airport/` (28) + `Airport/macOS15/` (9) + `ClientKit/` (2) + `HAL/` (5) + `FwData.h` |
| `itl80211/` | 111 | 43,923 | `openbsd/` 95 files / 41,303 lines; `linux/` 4 files / ~893 lines; root: ItlDma, compat, zutil + `Info.plist` |
| `itlwm/` | 4 | 23,348 | **HAL only**: `hal_iwx/` (4 files); firmware blobs not counted here |
| `scripts/` | 0 | 0 | 4 files, none matching source pattern: `fw_gen.sh`, `zlib_compress_fw.py`, `load.sh`, `unload.sh` |
| **TOTAL** | **180** | **83,830** | |

---

## 3. itlwm/ HAL file listing (line counts)

```
   496  itlwm/hal_iwx/ItlIwx.hpp
 13919  itlwm/hal_iwx/ItlIwx.cpp
  8145  itlwm/hal_iwx/if_iwxreg.h
   788  itlwm/hal_iwx/if_iwxvar.h
 14415  (total .cpp/.hpp; 23,348 incl. the two .h regs/vars files)
```
Non-source files in `itlwm/`: `PrivateSPI.pch` (30 lines) and `firmware/` (15 blobs, below).

Upstream (`laobamac/itlwm@7204c69`) `itlwm/` for contrast contains: `hal_iwx`, `hal_iwm`, `hal_iwn`, `ItlNetworkUserClient.cpp/hpp`, `itlwm.cpp/hpp`, `pm.cpp`, `Info.plist`, `PrivateSPI.pch`, `firmware/` (35 items). The fork keeps **only hal_iwx + firmware subset + pch**.

---

## 4. Firmware inventory

`itlwm/firmware/` — 15 files, **12 `.ucode` + 3 `.pnvm`** (all retained iwlwifi "Gen3+" families; iwm-*/iwn-* fully removed by reduce commit):

| File | Bytes |
|---|---:|
| iwlwifi-Qu-b0-hr-b0-68.ucode | 1,355,836 |
| iwlwifi-Qu-b0-jf-b0-68.ucode | 1,275,268 |
| iwlwifi-Qu-c0-hr-b0-68.ucode | 1,355,852 |
| iwlwifi-Qu-c0-jf-b0-68.ucode | 1,275,284 |
| iwlwifi-QuZ-a0-hr-b0-68.ucode | 1,355,800 |
| iwlwifi-QuZ-a0-jf-b0-68.ucode | 1,275,264 |
| iwlwifi-cc-a0-68.ucode | 1,314,392 |
| **iwlwifi-so-a0-gf-a0-68.ucode** (AX211) | **1,533,812** |
| iwlwifi-so-a0-gf-a0.pnvm | 41,808 |
| iwlwifi-so-a0-gf4-a0-68.ucode | 1,552,216 |
| iwlwifi-so-a0-gf4-a0.pnvm | 21,576 |
| iwlwifi-so-a0-hr-b0-68.ucode | 1,429,192 |
| iwlwifi-so-a0-jf-b0-68.ucode | 1,378,284 |
| **iwlwifi-ty-a0-gf-a0-68.ucode** (AX411) | **1,494,304** |
| iwlwifi-ty-a0-gf-a0.pnvm | 41,588 |

- All 12 `.ucode` are **API-68 firmware from one identical build**: embedded TLV human-readable version string = `release/core66_LinADLPV::01d30b0c` (header: 4×0x00 + magic `IWL\n`).
- **Embedding mechanism:** `FwBinary.cpp` is *not* in the tree (git-ignored). Xcode aggregate target **`fw_gen`** runs `scripts/fw_gen.sh -P "${PROJECT_DIR}/itlwm/firmware/"` → `scripts/zlib_compress_fw.py` walks the whole firmware dir, zlib-compresses every file into a `const unsigned char[]` array, and emits `include/FwBinary.cpp` defining `fwList[]`/`fwNumber` (declared extern in `include/FwData.h`). So **all 15 files (12 ucode + 3 pnvm) are embedded** in the Mach-O.
- CI (`.github/workflows/main.yml`, manual `workflow_dispatch` only, macOS 15 Intel runner) asserts binary > 4 MB and greps `strings` for 5 embedded fw names: `iwlwifi-so-a0-gf-a0-68, iwlwifi-ty-a0-gf-a0-68, iwlwifi-so-a0-gf4-a0-68, iwlwifi-so-a0-hr-b0-68, iwlwifi-so-a0-jf-b0-68`. Expects bundle id `com.zxystd.AirportItlwm`, links IOSkywalkFamily + corecapture, x86_64 only.
- Firmware set diff vs upstream@7204c69 (35 items): fork removed exactly 20 (`iwm-3160-17, iwm-3168-29, iwm-7260-17, iwm-7265-17, iwm-8000C-36, iwm-8265-36, iwm-9000-46, iwm-9260-46, iwn-1000/105/135/2000/2030/4965/5000/5150/6000/6005/6030/6050`), added none.

---

## 5. Xcode targets remaining

- `grep -c 'PBXNativeTarget'` → 5 string occurrences, but actual **PBXNativeTarget objects = 1**:
  - **`AirportItlwm-Sequoia`** — productType `com.apple.product-type.kernel-extension`, productName `AirportItlwm`, product `AirportItlwm.kext`; depends on `fw_gen`.
- Plus 1 **PBXAggregateTarget**: **`fw_gen`** (productName `fw`) with the "Generate Firmware" shell phase.
- `productName` unique values: `AirportItlwm`, `fw`. Configurations: Debug, Release (of the single target). Scheme used by CI: `AirportItlwm-Sequoia`. No Monterey/Sonoma/Ventura/Tahoe targets, no standalone itlwm kext target.

---

## 6. PCI IDs in the Sequoia plist (`AirportItlwm/Info.plist`)

`IOPCIMatch` contains **19 IDs** (all `8086` vendor):

```
0x02F08086  0x06F08086  0x34F08086  0x3DF08086  0x4DF08086  0x43F08086
0xA0F08086  0x27208086  0x27238086  0x27258086  0x27268086  0x27298086
0x7A708086  0x7AF08086  0x51F08086  0x51F18086  0x54F08086  0x7E408086
0x7F708086
```
AX211-family set (checked by CI): `0x51F08086, 0x51F18086, 0x54F08086, 0x7E408086, 0x7F708086`. IOProbeScore = 2000.

---

## 7. Reference clones status (`refs/`, git-ignored)

| Clone | URL | Status | HEAD (short) |
|---|---|---|---|
| `upstream-itlwm` | github.com/laobamac/itlwm (full clone) | ✅ OK — checked out to pinned baseline `7204c69d1bfa7f5cc0f7864e08fb03e55d0ec29e` ("Merge pull request #36 from mingww64/fix/wpa3-transition-and-amsdu", tag `v2.4.0-alpha`, dated 2026-11-01) | `7204c69` |
| `ForbiddenItlwm` | github.com/retropineaple/ForbiddenItlwm (depth 1) | ✅ OK | `6e15195` |
| `Eric-AirportItlwm` | github.com/Ersiter/Eric-AirportItlwm (depth 1) | ✅ OK | `e258fb8` |
| `AirportItlwm-AX211` | github.com/ElicoftZ/AirportItlwm-AX211 (depth 1) | ✅ OK | `030ef90` |
| `linux-iwlwifi` | github.com/torvalds/linux (sparse: `drivers/net/wireless/intel/iwlwifi` + `net/mac80211` + `net/wireless`) | ✅ OK — full iwlwifi tree incl. cfg/, mvm/, mld/, pcie/, dvm/, fw/, mei/ | `20eef29` |
| `linux-firmware` | git.kernel.org .../linux-firmware (sparse, WHENCE) | ✅ OK (server ignored blob filter — full blobless metadata clone; warning only) | `747bdda` |

Notes:
- `linux-iwlwifi`: `include/net/mac80211.h` / `include/net/cfg80211.h` could not be added via `sparse-checkout add` ("not a directory"; needs `--skip-checks` for single files) — skipped per `|| true`. `net/mac80211/` and `net/wireless/` **are** checked out.
- `linux-firmware`: `.ucode` blobs at repo top level are symlinks (`intel/iwlwifi/…`) and were not materialized by the sparse set; **WHENCE** metadata retrieved. WHENCE shows current so-a0-gf-a0 line up to **`iwlwifi-so-a0-gf-a0-89.ucode`** — i.e. fork's API-68 firmware is **21 API versions behind** current linux-firmware; WHENCE no longer lists -68 (superseded/removed).

---

## 8. Anomalies / observations

1. **`git describe` says HEAD == `v2.4.0-ax211-reduced`** while tag `v2.5.0-alpha` and `dell-ac9462-v2.5.0-alpha-final` also exist in the same history — version semantics of the fork tree vs tags is worth a closer look in a later audit step (multiple version lines in one reduced fork).
2. **Firmware breadth vs "AX211-reduced" claim:** the reduce commit removed iwm/iwn firmware, but the kext still embeds **12 ucode + 3 pnvm for all iwlwifi Gen families** (9560/AX200/AX201/AX210/AX211/AX411), not just AX211 (so/ty/gf4). `IOPCIMatch` likewise still lists 19 device IDs (7260-era through AX211). Reduction is *driver*-level (HAL/iwx only, Sequoia-only target), not *firmware/device*-level. The 5 firmware families that CI greps include `so-a0-hr-b0` (AX210) and `so-a0-jf-b0` (AX201) — i.e. non-AX211 firmware is deliberately retained/verified too.
3. **Single-ULB build config:** only Debug exists for the Sequoia target per CI, but pbxproj carries Debug **and** Release configuration lists; CI is manual-dispatch only (no push/PR/schedule), no release job.
4. `index.html` (54,569 bytes) sits at repo root — a rendered doc page committed into the source tree (upstream-style README rendering); unusual for a kext source tree but harmless.
5. `iwlwifi-firmware-license` present at root (2,046 bytes) — firmware redistribution license is tracked. Good.
6. **`WCL/`** subdirectory inside `AirportItlwm/` (WCL.cpp/hpp + 2 plists incl. Sequoia-Info.plist) — present in upstream baseline too (not a fork addition).
7. Upstream baseline commit `7204c69` is tag `v2.4.0-alpha` dated **2026-11-01**; fork baseline tag `aa19316` was created from it directly — consistent with README "Source foundation" claims (README names baseline commit + title verbatim; verified match).
8. `refs/`, `research/`, `download/` etc. are git-ignored via the sandbox overlay section of `.gitignore` — working tree stays clean; no risk of committing reference material.
9. All 12 embedded ucode are the *same build* `core66_LinADLPV::01d30b0c` — one coherent linux-firmware release snapshot (API 68), no mixed versions.
10. `linux-firmware` clone printed `warning: filtering not recognized by server, ignoring` (kernel.org ignores `--filter`); clone still succeeded blobless+shallow.

---

*AUDIT-1 complete. Next: AUDIT-2 (HAL diff vs upstream `refs/upstream-itlwm@7204c69`) and firmware/ucode provenance cross-check vs `refs/linux-firmware/WHENCE` and `refs/linux-iwlwifi` iwl-csr/device tables.*
