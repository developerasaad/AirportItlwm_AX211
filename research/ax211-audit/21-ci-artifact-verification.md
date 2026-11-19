# AUDIT-2e — CI Artifact Verification via GitHub Actions API

**Repo:** developerasaad/AirportITLWM · **Local HEAD:** `e4857ff53a3dfbc7d9eddf41b6d92a94b9b64b54` (tag `v2.4.0-ax211-reduced`)
**Workflow:** "Build AX211 Sequoia Debug" (`.github/workflows/main.yml`, `workflow_dispatch` only, `macos-15-intel`)
**Date of audit:** all API data retrieved live; artifacts downloaded to `refs/ci-artifacts/` (git-ignored).
**Chain of custody:** artifact zip sha256 `da628dc5…e0f4fa` (verified vs `.sha256` sidecar) → inner kext binary sha256 `30a3ce590b…a6b674a` (verified vs CI `build-logs/AirportItlwm-bin.sha256` and vs README build record). Release asset byte-identical to CI artifact (same sha256).

## CI runs history

26 runs total. Runs 1–21 belong to the earlier push-triggered "Build" workflow (pre-reduction baseline work, incl. `812ea1c` v2.5.0-alpha with Sonoma variants); runs 22–26 are manual dispatches of the current "Build AX211 Sequoia Debug" workflow.

| Run # | Run ID | head_sha | Event | Status/Conclusion | Created (UTC) |
|---|---|---|---|---|---|
| 26 | 44145096042 | f588ecd | dispatch | **success** | 2026-11-17T18:11:13Z |
| 25 | 44144616381 | a454f64 | dispatch | failure (Verify step) | 2026-11-17T18:08:32Z |
| 24 | 44143916768 | e982fe9 | dispatch | failure (build) | 2026-11-17T18:04:41Z |
| 23 | 44143226065 | eb815e4 | dispatch | failure (build) | 2026-11-17T18:00:53Z |
| 22 | 44135504957 | aa19316 | dispatch | success (baseline) | 2026-11-17T17:18:23Z |
| 21 | 44134686474 | 812ea1c | push | success | 2026-11-17T17:14:00Z |
| 20 | 44134682069 | 812ea1c | push | success | 2026-11-17T17:13:59Z |
| 19 | 44124477613 | 812ea1c | push | success | 2026-11-17T16:19:39Z |
| 18 | 44124279970 | 1d67e86 | push | success | 2026-11-17T16:18:38Z |
| 17 | 44123021305 | d97bf7f | push | success | 2026-11-17T16:12:06Z |
| 16 | 44119947079 | cb027f5 | push | success | 2026-11-17T15:55:55Z |
| 15 | 44119053422 | 22e98fc | push | failure | 2026-11-17T15:51:10Z |
| 14 | 44117958543 | 59958b4 | push | cancelled | 2026-11-17T15:45:24Z |
| 13 | 44116953857 | 0c485de | push | cancelled | 2026-11-17T15:40:06Z |
| 12 | 44096570525 | 803d1b2 | push | success | 2026-11-17T13:49:22Z |
| 11 | 44095557953 | a18bdc0 | push | success | 2026-11-17T13:43:19Z |
| 10 | 44093465360 | 1301ee3 | push | failure | 2026-11-17T13:30:51Z |
| 9 | 44093403245 | 91ebe27 | push | cancelled | 2026-11-17T13:30:31Z |
| 8 | 44092780585 | 023f243 | push | failure | 2026-11-17T13:26:42Z |
| 7 | 44092613076 | a6bc141 | push | failure | 2026-11-17T13:25:40Z |
| 6 | 44091592004 | a6748e9 | push | failure | 2026-11-17T13:19:33Z |
| 5 | 44090578777 | f1bebe5 | push | failure | 2026-11-17T13:13:30Z |
| 4 | 44089820928 | f28fdf2 | push | failure | 2026-11-17T13:08:52Z |
| 3 | 44087493729 | 12d66b1 | push | success | 2026-11-17T12:54:14Z |
| 2 | 44087454305 | 12d66b1 | push | success | 2026-11-17T12:53:59Z |
| 1 | 44087443988 | df3dfdc | push | failure | 2026-11-17T12:53:55Z |

**SHA-match status:** **No CI run exists for `e4857ff`** (API query `runs?head_sha=e4857ff…` → `total_count: 0`). `e4857ff` is a **docs-only** commit (README.md +56/−18; verified via `git diff --stat f588ecd e4857ff`) pushed after the workflow was switched to dispatch-only and was never dispatched. The latest successful run on the reduced code is **run 26 on `f588ecd`** — the direct parent of the tag; source trees are identical except README. Runs 23–25 are the three failed attempts of the reduction (compile errors, then run 25 failed the "Verify kernel extension" step because the binary-size floor was still 10,000,000 B; `f588ecd` lowered it to 4,000,000 B, and run 26 passed).

## Latest successful reduced-build run details

- **Run:** #26, id `44145096042`, name "Build AX211 Sequoia Debug", `workflow_dispatch`, run_attempt 1
- **head_sha:** `f588ecd5fb396b0971fb73e3014f95aff8ec5d7a` (head_branch `main`, actor `developerasaad`)
- **Conclusion:** success · job 18:11:18Z→18:12:55Z (1m37s) on runner label `macos-15-intel`; all 11 steps green (checkout, MacKernelSDK @`3f75008`, build, **verify**, package, 2× upload-artifact)
- **Build invocation:** `xcodebuild -project itlwm.xcodeproj -scheme AirportItlwm-Sequoia -configuration Debug ARCHS=x86_64 CODE_SIGNING_ALLOWED=NO GIT_COMMIT=_f588ecd` → `** BUILD SUCCEEDED **` (120 warnings, 0 errors; SDK MacOSX15.5, Xcode 16.4/16F6, `-target x86_64-apple-macos15.2`, linked `-kext`)
- The workflow's verify step (passed) checked: x86_64-only (`lipo`), `plutil -lint`, bundle id `com.zxystd.AirportItlwm`, required OSBundleLibraries (IO80211Family/libkern/iokit + IOSkywalkFamily/corecapture), binary >4,000,000 B, 5 firmware strings embedded, 5 AX211 PCI IDs present, sha256 recorded.

## Artifact inventory + sizes

Run 26 (both not expired; expire 2027-02-15T18:11:14Z):

| Artifact | ID | Size (bytes) | Contents |
|---|---|---|---|
| AirportItlwm-Sequoia-Debug | 14355752931 | 6,821,833 (outer zip) | `AirportItlwm-v2.4.0-AX211-Sequoia-Debug-f588ecd.zip` (6,823,999 B) + `.sha256` sidecar |
| build-logs | 14356212093 | 45,636 | `AirportItlwm-Sequoia.log` (full xcodebuild log), `AirportItlwm-bin.sha256` |

Inner kext zip (ditto, `--keepParent`): **6,823,999 B**, sha256 `da628dc5a26a733e6591cc69d85e9547de4a88ff291d066e48bb42b681e0f4fa` — matches sidecar.

Kext file tree:

```
AirportItlwm.kext/
└── Contents/
    ├── Info.plist              3,172 B
    └── MacOS/
        └── AirportItlwm    7,622,312 B   (executable, mode 755)
```
Total kext ≈ 7,625,404 B (+ ~15 KB filesystem overhead for dirs). No other files. **No `Contents/_CodeSignature/`.**

## Kext verification

- **Architecture:** `Mach-O 64-bit x86_64 kext bundle, flags:<NOUNDEFS|DYLD_LINK|TWOLEVEL>`; magic `0xfeedfacf`, cputype `0x01000007` (x86_64). Single-arch, no arm64 slice. ✓ matches the Intel target (MSI Modern 14 C12MO / Sequoia 15.8.2).
- **Bundle identity:** `CFBundleIdentifier = com.zxystd.AirportItlwm`, `CFBundleName = AirportItlwm`, `CFBundlePackageType = KEXT`, `CFBundleExecutable = AirportItlwm`. ✓ upstream-compatible identity (no fork rename → drop-in replacement vs. OpenIntelWireless releases).
- **Version:** `CFBundleShortVersionString = 2.4.0`, `CFBundleVersion = 2.4.0`. **`CFBundleGetInfoString` is ABSENT** — the git SHA is *not* in the Info.plist; build identity lives in the artifact filename (`…-f588ecd.zip`) and in the embedded build-setting string `_f588ecd` (from `GIT_COMMIT=_$(git rev-parse --short HEAD)`) inside the binary. Provenance is traceable but not via standard plist metadata.
- **OSBundleLibraries (9):** `com.apple.iokit.IO80211Family` 1.5.0, `com.apple.iokit.IOSkywalkFamily` 1.0, `com.apple.driver.corecapture` 1.0.0, `com.apple.iokit.IONetworkingFamily` 3.2, `com.apple.iokit.IOPCIFamily` 2.9, `com.apple.kpi.mach` 16.7, `com.apple.kpi.libkern` 16.7, `com.apple.kpi.iokit` 16.7, `com.apple.kpi.bsd` 16.7. ✓ Sequoia-native (Skywalk/WCL + corecapture linkage present; IO80211Family at Apple's Sequoia 1.5.0 ABI).
- **IOPCIMatch: 19 PCI IDs** (`itlwm` personality, IOProviderClass `IOPCIDevice`): `0x02F08086, 0x06F08086, 0x34F08086, 0x3DF08086, 0x4DF08086, 0x43F08086, 0xA0F08086, 0x27208086, 0x27238086, 0x27258086, 0x27268086, 0x27298086, 0x7A708086, 0x7AF08086, 0x51F08086, 0x51F18086, 0x54F08086, 0x7E408086, 0x7F708086`. Includes all AX211-family IDs checked by CI (0x51F0, 0x51F1, 0x54F0, 0x7E40, 0x7F70) **plus the Alder-Lake CNVi AX211 device `0x27258086`** (the MSI Modern 14 C12MO path: `IWL_DEV_INFO(0x2725, 0x0090, iwlax211_2ax_cfg_so_gf_a0)` → firmware `iwlwifi-so-a0-gf-a0-68.ucode`, embedded). Second personality `NetworkController` (IOClass `AirportItlwm`, IOProviderClass `IOPCIEDeviceWrapper`, IOProbeScore 70000).
- **Other metadata:** `OSBundleRequired = Network-Root`; `LSMinimumSystemVersion = 15.2`; DTSDKName `macosx15.5`; copyright "© 2026 laobamac. Based on AirportItlwm by OpenIntelWireless."
- **Codesigning:** **unsigned** — no `Contents/_CodeSignature/`, zero `0xFADE0CC0` (CMS) blob magics in the Mach-O, `CODE_SIGNING_ALLOWED=NO` in the build log. Not even ad-hoc signed.
- **Size:** binary **7,622,312 B** (7.62 MB decimal / 7.27 MiB); zip 6,823,999 B (6.82 MB). README build record states exactly 7,622,312 B (7.27 MB) — **exact match**. The "~under 7 MB" phrasing holds only for the *compressed zip* (6.82 MB); the binary itself exceeds 7 MB decimal (7.62) and 7 MiB (7.27). Baseline comparison verified from run 22 artifact: baseline binary 16,262,720 B → reduced 7,622,312 B = **−53.13%** (README claims −53.1% ✓).

## Firmware presence

- `strings` on the binary finds **27 `iwlwifi-` occurrences, 26 unique names**; **15 of them exactly match the 15 files in `itlwm/firmware/`** (16,700,476 B ≈ 16.7 MB raw across 15 blobs — matches the "16.7 MB / 15 blobs" claim). All 15 are `FwDesc` entries in the generated `fwList` (zlib-compressed by `fw_gen` into the Mach-O; ~2.2:1 payload compression: 16.7 MB raw → ≈7 MB of the 7.62 MB binary).
- Embedded set: `iwlwifi-Qu-b0-hr-b0/jf-b0-68`, `Qu-c0-hr-b0/jf-b0-68`, `QuZ-a0-hr-b0/jf-b0-68`, `cc-a0-68`, `so-a0-gf-a0-68 (+.pnvm)`, `so-a0-gf4-a0-68 (+.pnvm)`, `so-a0-hr-b0-68`, `so-a0-jf-b0-68`, `ty-a0-gf-a0-68 (+.pnvm)`.
- **AX211-required firmware confirmed embedded:** `iwlwifi-so-a0-gf-a0-68.ucode` (AX211 `0x2725 sub 0x0090`) and `iwlwifi-so-a0-gf4-a0-68.ucode` (AX411 `0x51F0/0x51F1 sub 0x1691`).
- The other 11 names in the binary (`QuQnj-*-48`, `SoSnj-*-63`, `ma-a0-*-63`) are **device-table `.fwname` references** in `ItlIwx.cpp` for hardware whose blobs were never in this repo's firmware set — not embedded; `getFWDescByName()` would return NULL for them.
- **Zero `iwm-*` / `iwn-*` firmware strings remain** (grep count 0) — the legacy-HAL firmware removal is verified at binary level.
- The firmware strings check *does* work despite zlib compression because `fwList[].name` C-strings are stored uncompressed; the workflow's `strings`-based check is therefore valid, not a false positive.

## Releases

3 releases, all published 2026-11-17, all marked **prerelease**, 0 drafts:

| Tag | Published (UTC) | Assets |
|---|---|---|
| `v2.5.0-alpha` | 16:16:08Z | 6 zips + sha256s: Sequoia / Sonoma14.0 / Sonoma14.4 × DEBUG/RELEASE, each ≈15.07–15.13 MB (commit `812ea1c`) |
| `v2.4.0-baseline-ax211` | 17:24:17Z | `AirportItlwm-v2.4.0-AX211-Sequoia-Debug-aa19316.zip` 15,130,646 B + sha256 |
| `v2.4.0-ax211-reduced` | 18:16:46Z | `AirportItlwm-v2.4.0-AX211-Sequoia-Debug-f588ecd.zip` **6,823,999 B** + sha256 (2 downloads) |

The reduced-build release exists and is downloadable: the release asset is **byte-identical** to run 26's CI artifact (sha256 `da628dc5…e0f4fa`). Release title marks it "awaiting hardware validation". Note the tag `v2.4.0-ax211-reduced` points at `e4857ff` while the shipped asset was built from parent commit `f588ecd` (docs-only difference).

## Findings

| ID | Finding | Classification |
|---|---|---|
| CI-001 | Latest successful reduced build verified end-to-end: run 26 (`f588ecd`) all steps green; artifact → kext sha256 chain (`da628dc5…` / `30a3ce59…`) matches CI sidecars, README build record, and the published release byte-for-byte. | **VALIDATED CORRECT BEHAVIOR** |
| CI-002 | Kext binary is x86_64-only Mach-O kext bundle, bundle id `com.zxystd.AirportItlwm`, version 2.4.0, 9 OSBundleLibraries incl. Sequoia-required IOSkywalkFamily 1.0 + corecapture 1.0.0 + IO80211Family 1.5.0. | **VALIDATED CORRECT BEHAVIOR** |
| CI-003 | All 15 iwlwifi-* firmware blobs embedded (16.7 MB raw → 7.62 MB binary, −53.13% vs baseline 16,262,720 B verified from run-22 artifact); zero iwm/iwn firmware remains; AX211 path (`0x2725 sub 0x0090` → `so-a0-gf-a0-68.ucode`) fully covered. | **VALIDATED CORRECT BEHAVIOR** |
| CI-004 | **No CI run for tagged commit `e4857ff`** (dispatch-only workflow + docs-only commit ⇒ never built). Release tag `v2.4.0-ax211-reduced` ships a binary built from parent `f588ecd` (embedded `_f588ecd`, artifact filename `-f588ecd`). Mitigated: `git diff f588ecd e4857ff` touches README.md only, so the shipped bits match the tag's code. | **CONFIRMED DEFECT** (release/CI provenance mismatch — cosmetic, no functional impact) |
| CI-005 | **Kext is completely unsigned** (no `_CodeSignature`, no embedded CMS blob, `CODE_SIGNING_ALLOWED=NO`). On stock Sequoia 15.8.2 with SIP enabled, `kmutil` will refuse to load it; the user must ad-hoc sign (`codesign -fs - AirportItlwm.kext`, then `kmutil install --update-all` + recovery-approval of the new cert) or inject via OpenCore. CI ships no signed variant and the release notes don't surface this step. | **CONFIRMED DEFECT** (installation blocker as-shipped; standard for dev builds but undocumented for handoff) |
| CI-006 | `IOPCIMatch` still advertises **19 Intel PCI IDs** spanning 3 generations (7265/8265/9560-era `0x24F3-class` IDs like `0x02F0/0x34F0/0x3DF0/0x02F08086…`, AX-era, BE-era) while the iwm/iwn HALs and their firmware are removed — legacy devices will match `IOPCIEDeviceWrapper`, fail `ItlIwx` probe, and get no driver. Deliberate per reduction commit (subdevice unknowable remotely), but over-broad matching is misleading and the 10MB→4MB floor change (run 25→26) shows the verify gate was retuned rather than the payload shrunk further. | **UNSUPPORTED OR INCOMPLETE CAPABILITY** (accepted risk, documented in commit eb815e4) |
| CI-007 | `CFBundleGetInfoString` absent — git SHA is not in Info.plist metadata (only artifact filename + `_f588ecd` string in binary). Version strings say "2.4.0" with no SHA, so `kextstat`/Finder can't distinguish reduced vs baseline builds. | **UNVERIFIED IMPLEMENTATION RISK** (traceability relies on non-standard channels) |
| CI-008 | Size claim nuance: "under ~7 MB" is true only for the compressed zip (6.82 MB); the actual Debug binary is 7,622,312 B (7.27 MiB / 7.62 MB decimal). README's exact figure (7,622,312 B) is accurate. | **VALIDATED CORRECT BEHAVIOR** (with phrasing caveat) |
| CI-009 | Release exists (`v2.4.0-ax211-reduced`, prerelease) with a downloadable, hash-verified kext — a testable artifact is available. However the release title itself says "awaiting hardware validation": **no on-target load test has been performed** (not CI-verifiable). | **UNRESOLVED** (hardware validation pending, out of CI scope) |
| CI-010 | Artifact retention: both run-26 artifacts and all release assets are live (expire 2027-02-15); baseline run 22 artifacts also retained. No missing artifacts. | **VALIDATED CORRECT BEHAVIOR** |

**Bottom line:** the reduced build is real, reproducible, hash-verified, and downloadable from the `v2.4.0-ax211-reduced` prerelease; its only actionable gaps for the hardware test handoff are (a) ad-hoc signing before `kmutil` load on Sequoia (CI-005), (b) tag-vs-build SHA provenance mismatch (CI-004, cosmetic), and (c) pending on-target validation (CI-009).
