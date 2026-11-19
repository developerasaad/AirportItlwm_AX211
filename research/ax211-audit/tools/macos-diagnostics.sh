#!/usr/bin/env bash
#
# macos-diagnostics.sh - v1 - READ-ONLY AX211 wireless evidence collector
# Target: macOS Sequoia 15.8.2 (OpenCore) on MSI Modern 14 C12MO (Intel AX211).
# Context: AirportItlwm / itlwm driver audit.
#
# COMPATIBILITY: runs under bash or zsh (use: bash macos-diagnostics.sh).
#
# SAFETY CONTRACT
#   - Read-only: no configuration, network, kext, or NVRAM changes
#     (nvram is only queried, never written; no kext load/unload).
#   - No elevated rights needed for the base run.
#   - No downloads, no installs, no remote connections.
#   - Output is sanitized before packing (see REDACTION-LOG.txt in the bundle):
#       MAC  xx:xx:xx:xx:xx:xx -> BSSIDn
#       SSID text             -> APn
#       IPv4 addresses        -> 10.240.0.n
#       serial-number values  -> REDACTED-SERIAL
#       hostname/local names  -> HOSTn (kernel log and power log only)
#
# OUTPUT
#   AX211-MACOS-EVIDENCE-<UTC>/          numbered probe files + redaction log
#   AX211-MACOS-EVIDENCE-<UTC>.tar.gz    bundle to share back
#
# USAGE
#   bash macos-diagnostics.sh
#   Optional: ITLWM_KEXT=/path/to/AirportItlwm.kext bash macos-diagnostics.sh
#   (if the kext lives somewhere unusual and probe 05 cannot find it)
#   Optional: put tricky secrets (one per line) into extra-redact-list.txt
#   next to this script and they will be pseudonymized too.

set -euo pipefail

UTC="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="AX211-MACOS-EVIDENCE-${UTC}"
BUNDLE="${OUT}.tar.gz"
MAP="$(mktemp 2>/dev/null || echo "./.ax211-map-$$.tsv")"    # MAC + IPv4 entries
SMAP="${MAP}.ssid"                                           # SSID entries
HMAP="${MAP}.host"                                           # hostname entries

cleanup() { rm -f "$MAP" "${MAP}.macs" "${MAP}.ips" "${MAP}.stats" "$SMAP" "$HMAP"; }
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$OUT"

# ------------------------------------------------------------------
# Wi-Fi interface discovery (default en0)
# ------------------------------------------------------------------
WIFI_IF="en0"
if have networksetup; then
  DETECTED="$(networksetup -listallhardwareports 2>/dev/null | awk '
    /Wi-?Fi|AirPort/ {f = 1; next}
    f && /^Device:/ {sub(/^Device:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); print; exit}
  ' || true)"
  if [ -n "$DETECTED" ]; then
    WIFI_IF="$DETECTED"
  fi
fi

echo "[*] evidence folder : $OUT"
echo "[*] wifi interface  : $WIFI_IF (auto-detected, en0 assumed if blank)"

# ==================================================================
# 01 identity: time, OS version, kernel, hardware model
# ==================================================================
echo "[*] 01 identity"
{
  echo "### 01 identity"
  date -u
  if have sw_vers; then
    sw_vers
  else
    echo "TOOL-ABSENT: sw_vers"
  fi
  echo "--- uname (nodename field replaced by placeholder) ---"
  uname -a | awk 'NR==1 {$2="HOSTNAME-REDACTED"} {print}'
  if have sysctl; then
    sysctl hw.model hw.machine 2>/dev/null || echo "sysctl query failed"
  else
    echo "TOOL-ABSENT: sysctl"
  fi
} > "$OUT/01-identity.txt" 2>&1 || true

# ==================================================================
# 02 platform: board-id / product properties
# ==================================================================
echo "[*] 02 platform"
{
  echo "### 02 platform"
  echo "NOTE: on OpenCore systems these values are SMBIOS-derived from the"
  echo "      boot config and may not describe the physical hardware."
  if have ioreg; then
    ioreg -l 2>/dev/null | grep -E '"(board-id|product)"' | head -5 \
      || echo "no board-id/product properties found"
  else
    echo "TOOL-ABSENT: ioreg"
  fi
} > "$OUT/02-platform.txt" 2>&1 || true

# ==================================================================
# 03 opencore: version and boot-args (read-only nvram queries)
# ==================================================================
echo "[*] 03 opencore"
{
  echo "### 03 OpenCore version and boot-args (read-only nvram queries)"
  if have nvram; then
    nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version 2>/dev/null \
      || echo "opencore-version: not-set"
    nvram boot-args 2>/dev/null || echo "boot-args: none"
  else
    echo "TOOL-ABSENT: nvram"
  fi
} > "$OUT/03-opencore.txt" 2>&1 || true

# ==================================================================
# 04 kexts (KEY PROBE): loaded itlwm / 80211 / skywalk / corecapture
# ==================================================================
echo "[*] 04 kexts"
{
  echo "### 04 loaded kexts (KEY PROBE)"
  found=0
  if have kmutil; then
    if kmutil show 2>/dev/null | grep -iE 'itlwm|80211|skywalk|corecapture'; then
      found=1
    fi
  fi
  if [ "$found" -eq 0 ] && have kextstat; then
    if kextstat 2>/dev/null | grep -iE 'itlwm|80211|skywalk'; then
      found=1
    fi
  fi
  if [ "$found" -eq 0 ]; then
    echo "no itlwm/80211/skywalk lines found (kext not loaded, or tools unavailable)"
  fi
} > "$OUT/04-kexts.txt" 2>&1 || true

# ==================================================================
# 05 kext binary strings (KEY PROBE): embedded iwlwifi firmware names
# ==================================================================
echo "[*] 05 kext strings"
KEXT_PATH=""
{
  echo "### 05 itlwm/AirportItlwm kext binary strings (KEY PROBE)"
  # (a) explicit override from the environment
  if [ -n "${ITLWM_KEXT:-}" ] && [ -d "${ITLWM_KEXT}" ]; then
    KEXT_PATH="${ITLWM_KEXT}"
  fi
  # (b) path printed by probe 04 (kmutil show includes Path: lines)
  if [ -z "$KEXT_PATH" ] && [ -f "$OUT/04-kexts.txt" ]; then
    cand="$(grep -oE '/[^[:space:]]*[Ii]tlwm[^[:space:]]*\.kext' "$OUT/04-kexts.txt" 2>/dev/null | sed -n '1p' || true)"
    if [ -n "$cand" ] && [ -d "$cand" ]; then
      KEXT_PATH="$cand"
    fi
  fi
  # (c) standard install locations and common EFI mount points
  if [ -z "$KEXT_PATH" ]; then
    for cand in \
      "/Library/Extensions/AirportItlwm.kext" \
      "/Library/Extensions/itlwm.kext" \
      "/EFI/OC/Kexts/AirportItlwm.kext" \
      "/Volumes/EFI/EFI/OC/Kexts/AirportItlwm.kext"; do
      if [ -d "$cand" ]; then
        KEXT_PATH="$cand"
        break
      fi
    done
  fi
  # (d) any mounted volume with an OC Kexts folder
  if [ -z "$KEXT_PATH" ]; then
    for v in /Volumes/*; do
      [ -d "$v" ] || continue
      for cand in "$v/EFI/OC/Kexts/AirportItlwm.kext" "$v/EFI/OC/Kexts/itlwm.kext"; do
        if [ -d "$cand" ]; then
          KEXT_PATH="$cand"
          break
        fi
      done
      if [ -n "$KEXT_PATH" ]; then
        break
      fi
    done
  fi

  if [ -n "$KEXT_PATH" ]; then
    echo "kext path: $KEXT_PATH"
    BIN="$(ls "$KEXT_PATH/Contents/MacOS/" 2>/dev/null | sed -n '1p' || true)"
    if [ -n "$BIN" ]; then
      BINF="$KEXT_PATH/Contents/MacOS/$BIN"
      echo "binary: $BINF"
      echo "--- bundle version ---"
      if have defaults; then
        defaults read "$KEXT_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null \
          || echo "version read failed"
      elif have plutil; then
        plutil -p "$KEXT_PATH/Contents/Info.plist" 2>/dev/null | grep -i version \
          || echo "version read failed"
      else
        echo "TOOL-ABSENT: defaults / plutil"
      fi
      echo "--- firmware names embedded in the binary ---"
      if have strings; then
        strings "$BINF" 2>/dev/null | grep -iE 'iwlwifi|\.ucode|fw-' | sort -u | head -80 \
          || echo "no firmware-name strings matched"
      else
        echo "TOOL-ABSENT: strings"
      fi
    else
      echo "REASON-SKIPPED: kext found but no executable under Contents/MacOS"
    fi
  else
    echo "REASON-SKIPPED: no itlwm/AirportItlwm kext found via the loaded-kext"
    echo "output, standard /Library/Extensions paths, or mounted EFI volumes."
    echo "If you know its location, rerun with:"
    echo "  ITLWM_KEXT=/path/to/AirportItlwm.kext bash macos-diagnostics.sh"
  fi
} > "$OUT/05-kext-strings.txt" 2>&1 || true

# ==================================================================
# 06 wifi state: system_profiler, current association, interface stats
# ==================================================================
echo "[*] 06 wifi state"
{
  echo "### 06 Wi-Fi state (interface: $WIFI_IF)"
  if have system_profiler; then
    echo "--- system_profiler SPAirPortDataType (full detail, first 150 lines) ---"
    system_profiler SPAirPortDataType -detailLevel full 2>/dev/null | head -150 \
      || echo "system_profiler failed"
  else
    echo "TOOL-ABSENT: system_profiler"
  fi
  if have networksetup; then
    echo "--- networksetup -getairportnetwork $WIFI_IF ---"
    networksetup -getairportnetwork "$WIFI_IF" 2>/dev/null \
      || echo "getairportnetwork failed"
  else
    echo "TOOL-ABSENT: networksetup"
  fi
  echo "--- ifconfig $WIFI_IF (first 20 lines) ---"
  if have ifconfig; then
    ifconfig "$WIFI_IF" 2>/dev/null | head -20 || echo "ifconfig failed"
  else
    echo "TOOL-ABSENT: ifconfig"
  fi
} > "$OUT/06-wifi-state.txt" 2>&1 || true

# ==================================================================
# 07 ioreg wireless: IO80211Controller subtree
# ==================================================================
echo "[*] 07 ioreg wireless"
{
  echo "### 07 IO80211Controller registry (first 250 lines)"
  if have ioreg; then
    IO="$(ioreg -r -c IO80211Controller -w 0 2>/dev/null || true)"
    if [ -n "$IO" ]; then
      printf '%s\n' "$IO" | head -250
    else
      echo "no IO80211Controller entries returned"
    fi
  else
    echo "TOOL-ABSENT: ioreg"
  fi
} > "$OUT/07-ioreg-wireless.txt" 2>&1 || true

# ==================================================================
# 08 kernel log (KEY PROBE): wireless-relevant lines, last 2 hours
# ==================================================================
echo "[*] 08 kernel log (this query can take a minute)"
{
  echo "### 08 kernel log, last 2h, wireless lines (KEY PROBE)"
  echo "NOTE: empty output may mean the unprivileged log stream omits kernel"
  echo "      messages; see OPTIONAL-privileged.md for the elevated variant."
  if have log; then
    KL="$(log show --last 2h --style compact --predicate 'sender == "kernel"' 2>/dev/null \
      | grep -iE 'itlwm|iwx|wcl|skywalk|80211' | tail -400 || true)"
    if [ -n "$KL" ]; then
      printf '%s\n' "$KL"
    else
      echo "no matching kernel log lines in the last 2h"
    fi
    echo "--- supplementary: itlwm-tagged lines from any sender (last 2h) ---"
    KL2="$(log show --last 2h --style compact --predicate 'eventMessage CONTAINS[c] "itlwm"' 2>/dev/null | tail -300 || true)"
    if [ -n "$KL2" ]; then
      printf '%s\n' "$KL2"
    else
      echo "no itlwm-tagged lines in the last 2h"
    fi
  else
    echo "TOOL-ABSENT: log"
  fi
} > "$OUT/08-kernel-log.txt" 2>&1 || true

# ==================================================================
# 09 power: pmset settings, assertions, recent log tail
# ==================================================================
echo "[*] 09 power"
{
  echo "### 09 power management"
  if have pmset; then
    echo "--- pmset -g ---"
    pmset -g || true
    echo "--- pmset -g assertions ---"
    pmset -g assertions || true
    echo "--- pmset -g log (last 80 lines) ---"
    pmset -g log 2>/dev/null | tail -80 || echo "pmset log unavailable"
  else
    echo "TOOL-ABSENT: pmset"
  fi
} > "$OUT/09-power.txt" 2>&1 || true

# ==================================================================
# 10 airport CLI: legacy private snapshot (absent on newer releases)
# ==================================================================
echo "[*] 10 airport cli"
{
  echo "### 10 airport CLI snapshot"
  AIRPORT="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
  if [ -x "$AIRPORT" ]; then
    "$AIRPORT" -I 2>/dev/null || echo "airport -I failed"
  else
    echo "airport-cli-absent (normal on newer macOS releases)"
  fi
} > "$OUT/10-airport-cli.txt" 2>&1 || true

# ==================================================================
# SANITIZATION
#   Serial-number values are scrubbed first, then MAC/IPv4 everywhere,
#   then SSIDs in the wifi-state/log files, then host names in the log
#   files. Replacement is plain-string (awk, longest original first).
#   Map files are temporary and deleted on exit; original values never
#   enter the bundle.
# ==================================================================
echo "[*] sanitizing evidence"

# ---- scrub serial-number values and ioreg hex address blobs -------------
# (keys stay, values are replaced; read-only rewrite of our own files)
for sf in "$OUT"/*.txt; do
  [ -f "$sf" ] || continue
  if sed -E \
      -e 's/("[^"]*[Ss]erial[Nn]umber[^"]*"[[:space:]]*=[[:space:]]*")[^"]*(")/\1REDACTED-SERIAL\2/g' \
      -e 's/([Ss]erial[[:space:]]*[Nn]umber[^:]*:[[:space:]]*).+/\1REDACTED-SERIAL/g' \
      -e 's/("[^"]*([Aa]ddress|[Bb][Ss][Ss][Ii][Dd]|[Mm][Aa][Cc]|addr)[^"]*"[[:space:]]*=[[:space:]]*)<[0-9A-Fa-f]+>/\1<HEX-REDACTED>/g' \
      "$sf" > "${sf}.s"; then
    mv "${sf}.s" "$sf"
  else
    echo "REDACTION-FAILED: this file was withheld from the bundle." > "$sf"
    rm -f "${sf}.s"
    echo "[!] serial scrub failed for ${sf##*/}; file replaced with a notice"
  fi
done

# ---- collect MAC addresses (xx:xx:xx:xx:xx:xx; both cases -> one id) ----
grep -ohE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$OUT"/*.txt 2>/dev/null \
  | sort -u > "${MAP}.macs" || true
n=0
if [ -s "${MAP}.macs" ]; then
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    n=$((n + 1))
    printf '%s\tBSSID%d\tmac\n' "$m" "$n" >> "$MAP"
    up="$(printf '%s' "$m" | tr 'a-f' 'A-F')"
    if [ "$up" != "$m" ]; then
      printf '%s\tBSSID%d\tmac\n' "$up" "$n" >> "$MAP"
    fi
  done < "${MAP}.macs"
fi

# ---- collect IPv4 addresses -----------------------------------------
grep -ohE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$OUT"/*.txt 2>/dev/null \
  | sort -u > "${MAP}.ips" || true
n=0
if [ -s "${MAP}.ips" ]; then
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    n=$((n + 1))
    printf '%s\t10.240.0.%d\tipv4\n' "$ip" "$n" >> "$MAP"
  done < "${MAP}.ips"
fi

# ---- collect SSID strings (state/log files only) ---------------------
{
  # current association (networksetup output)
  if [ -f "$OUT/06-wifi-state.txt" ]; then
    sed -n 's/^Current Wi-Fi Network: //p' "$OUT/06-wifi-state.txt" || true
    # network entries in the system_profiler "Current Network Information" block
    awk '
      /Current Network Information:/ {f = 1; next}
      f && /^[^[:space:]]/ {f = 0}
      f && /^[[:space:]]+[^[:space:]].*:$/ {
        t = $0; gsub(/^[[:space:]]+/, "", t); sub(/:$/, "", t)
        if (t != "") print t
      }
    ' "$OUT/06-wifi-state.txt" || true
  fi
  # airport CLI style SSID line
  if [ -f "$OUT/10-airport-cli.txt" ]; then
    sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p' "$OUT/10-airport-cli.txt" || true
  fi
  # SSID-like tokens in the state/log files. Two passes to stay precise:
  #   A) quoted values: SSID: "My Net" / SSIDString = "x" (spaces allowed)
  #   B) bare single tokens at end of line: SSID: MyWifi
  # Mid-line bare words are deliberately NOT captured, to avoid swallowing
  # the words that follow them.
  grep -ohE '(^|[^A-Za-z])[Ss][Ss][Ii][Dd]([[:space:]]*[Ss]tring)?([[:space:]]*[:="]+[[:space:]]*)*"[^"]{1,32}"' \
    "$OUT/06-wifi-state.txt" "$OUT/07-ioreg-wireless.txt" "$OUT/08-kernel-log.txt" "$OUT/10-airport-cli.txt" 2>/dev/null \
    | sed -E -e 's/^[^A-Za-z]?([Ss][Ss][Ii][Dd])([[:space:]]*[Ss]tring)?([[:space:]]*[:="]+[[:space:]]*)*//' \
             -e 's/"$//' || true
  grep -ohE '(^|[^A-Za-z])[Ss][Ss][Ii][Dd]([[:space:]]*[Ss]tring)?([[:space:]]*[:="]+[[:space:]]*)*[A-Za-z0-9_.-]{1,32}$' \
    "$OUT/06-wifi-state.txt" "$OUT/07-ioreg-wireless.txt" "$OUT/08-kernel-log.txt" "$OUT/10-airport-cli.txt" 2>/dev/null \
    | sed -E 's/^[^A-Za-z]?([Ss][Ss][Ii][Dd])([[:space:]]*[Ss]tring)?([[:space:]]*[:="]+[[:space:]]*)*//' || true
  # owner-supplied manual additions (one secret per line, '#' = comment)
  if [ -f "extra-redact-list.txt" ]; then
    grep -vE '^[[:space:]]*(#|$)' "extra-redact-list.txt" || true
  fi
} | awk 'index($0, "\t") == 0 && length($0) >= 2 && $0 !~ /^[[:space:]]+$/ && !seen[$0]++ {
           n++; printf "%s\tAP%d\tssid\n", $0, n
         }' >> "$SMAP" || true

# ---- collect host names (kernel/power logs only) ---------------------
# add_host <command...>: record one host-name string if the command prints one
add_host() {
  hval="$("$@" 2>/dev/null || true)"
  if [ -n "$hval" ]; then
    hn=$((hn + 1))
    printf '%s\tHOST%d\thost\n' "$hval" "$hn" >> "$HMAP"
  fi
}
hn=0
add_host hostname
if have scutil; then
  add_host scutil --get LocalHostName
  add_host scutil --get ComputerName
fi

# ---- apply_map <file> <mapfile>: plain-string pseudonymization -------
apply_map() {
  am_f="$1"
  am_map="$2"
  [ -f "$am_f" ] || return 0
  [ -s "$am_map" ] || return 0
  if awk -v map="$am_map" -v statsf="${MAP}.stats" -v src="${am_f##*/}" '
    BEGIN {
      n = 0
      while ((getline line < map) > 0) {
        if (index(line, "\t") == 0) continue
        split(line, a, "\t")
        if (length(a[1]) < 1 || length(a[2]) < 1) continue
        n = n + 1
        o[n] = a[1]; r[n] = a[2]; c[n] = a[3]
        l[n] = length(a[1]); k[n] = 0
      }
      close(map)
      for (i = 2; i <= n; i++) {            # sort entries longest-first
        t1 = o[i]; t2 = r[i]; t3 = c[i]; t4 = l[i]
        j = i - 1
        while (j >= 1 && l[j] < t4) {
          o[j+1] = o[j]; r[j+1] = r[j]; c[j+1] = c[j]; l[j+1] = l[j]
          j = j - 1
        }
        o[j+1] = t1; r[j+1] = t2; c[j+1] = t3; l[j+1] = t4
      }
    }
    {
      s = $0
      for (i = 1; i <= n; i++) {
        while ((p = index(s, o[i])) > 0) {
          s = substr(s, 1, p - 1) r[i] substr(s, p + l[i])
          k[i] = k[i] + 1
        }
      }
      print s
    }
    END {
      for (i = 1; i <= n; i++)
        if (k[i] > 0)
          printf "%s: %s (%s) x%d\n", src, r[i], c[i], k[i] >> statsf
      close(statsf)
    }
  ' "$am_f" > "${am_f}.tmp"; then
    mv "${am_f}.tmp" "$am_f"
  else
    echo "REDACTION-FAILED: this file was withheld from the bundle." > "$am_f"
    rm -f "${am_f}.tmp"
    echo "[!] redaction pass failed for ${am_f##*/}; file replaced with a notice"
  fi
}

# ---- pseudonymize <file>: MAC/IPv4 everywhere, SSID/host selectively -
pseudonymize() {
  pz_f="$1"
  apply_map "$pz_f" "$MAP"
  case "${pz_f##*/}" in
    06-wifi-state.txt|07-ioreg-wireless.txt|08-kernel-log.txt|10-airport-cli.txt)
      apply_map "$pz_f" "$SMAP" ;;
  esac
  case "${pz_f##*/}" in
    08-kernel-log.txt|09-power.txt) apply_map "$pz_f" "$HMAP" ;;
  esac
}

for pf in "$OUT"/*.txt; do
  pseudonymize "$pf"
done

# ---- redaction log (pseudonyms and counts only) ----------------------
{
  echo "### REDACTION-LOG"
  echo "generated (UTC) : ${UTC}"
  echo "scheme          : MAC xx:xx:xx:xx:xx:xx -> BSSIDn"
  echo "                  SSID text -> APn (wifi-state / ioreg / kernel-log / airport files)"
  echo "                  IPv4 address -> 10.240.0.n"
  echo "                  serial-number value -> REDACTED-SERIAL (all files)"
  echo "                  ioreg hex address blob -> HEX-REDACTED (all files)"
  echo "                  hostname / local names -> HOSTn (kernel and power logs;"
  echo "                  the 01 file stores only a placeholder in uname output)"
  echo "mapping lifetime: temporary, destroyed after use; original values are"
  echo "                  never written to this log or anywhere in the bundle"
  echo ""
  echo "--- per-file replacement counts (file: pseudonym (category) x count) ---"
  if [ -s "${MAP}.stats" ]; then
    cat "${MAP}.stats"
  else
    echo "(no replacements were needed)"
  fi
  echo ""
  echo "--- limitations ---"
  echo "- SSID discovery relies on common output formats; names in unusual"
  echo "  forms may survive. Inspect the bundle before sharing."
  echo "- IPv6 addresses are NOT rewritten (macOS normally uses random"
  echo "  interface identifiers, but check)."
  echo "- If anything private is still visible: delete the bundle, put the"
  echo "  offending text (one item per line) into extra-redact-list.txt next"
  echo "  to this script, and rerun."
} > "$OUT/REDACTION-LOG.txt"

# ---- final sweep: refuse to pack if hardware identifiers survived ----
LEFT="$(grep -lE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$OUT"/*.txt 2>/dev/null || true)"
if [ -n "$LEFT" ]; then
  echo "[!] WARNING: colon-hex hardware identifiers remain in:"
  printf '%s\n' "$LEFT" | sed 's/^/      /'
  echo "[!] the bundle was NOT created; add the leftovers to extra-redact-list.txt and rerun"
  exit 1
fi

# ---- pack -------------------------------------------------------------
if tar czf "$BUNDLE" "$OUT"; then
  echo "[*] bundle created : $BUNDLE"
  echo "[*] share $BUNDLE back with the audit contact (it contains the"
  echo "    folder $OUT with the numbered probe files and REDACTION-LOG.txt)"
else
  echo "[!] tar failed; the folder $OUT is still present and can be packed manually"
fi
