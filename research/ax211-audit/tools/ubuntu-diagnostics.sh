#!/usr/bin/env bash
#
# ubuntu-diagnostics.sh - v1 - READ-ONLY AX211 wireless evidence collector
# Target: Ubuntu 24.x on MSI Modern 14 C12MO (Intel AX211).
# Context: AirportItlwm / itlwm driver audit.
#
# SAFETY CONTRACT
#   - Read-only: no configuration, network, module, or system changes.
#   - No elevated rights required (no sudo anywhere in this script).
#   - No downloads, no installs, no remote connections, no module ops.
#   - Output is sanitized before packing (see REDACTION-LOG.txt in the bundle):
#       MAC  xx:xx:xx:xx:xx:xx -> BSSIDn
#       SSID text             -> APn
#       IPv4 addresses        -> 10.240.0.n
#       hostname in log lines -> HOST1
#
# OUTPUT
#   AX211-UBUNTU-EVIDENCE-<UTC>/          numbered probe files + redaction log
#   AX211-UBUNTU-EVIDENCE-<UTC>.tar.gz    bundle to share back
#
# USAGE
#   bash ubuntu-diagnostics.sh            (run from any writable directory)
#
# Optional: put tricky secrets (one per line) into extra-redact-list.txt next
# to this script and they will be pseudonymized too.

set -euo pipefail

UTC="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="AX211-UBUNTU-EVIDENCE-${UTC}"
BUNDLE="${OUT}.tar.gz"
MAP="$(mktemp 2>/dev/null || echo "./.ax211-map-$$.tsv")"    # MAC + IPv4 entries
SMAP="${MAP}.ssid"                                           # SSID entries
HMAP="${MAP}.host"                                           # hostname entries

cleanup() { rm -f "$MAP" "${MAP}.macs" "${MAP}.ips" "${MAP}.stats" "$SMAP" "$HMAP"; }
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$OUT"

# ------------------------------------------------------------------
# Interface discovery: first /sys/class/net/wlan* (fallback: iw dev)
# ------------------------------------------------------------------
WLAN=""
for d in /sys/class/net/wlan*; do
  [ -e "$d" ] || continue
  WLAN="${d##*/}"
  break
done
if [ -z "$WLAN" ] && have iw; then
  WLAN="$(iw dev 2>/dev/null | awk '/Interface/ {print $2; exit}' || true)"
fi

echo "[*] evidence folder : $OUT"
if [ -n "$WLAN" ]; then
  echo "[*] wlan interface  : $WLAN"
else
  echo "[!] no wlan interface found (radio blocked, driver dead, or renamed)"
fi

# ==================================================================
# 01 identity: time, pseudonymous host digest, kernel, distro
# ==================================================================
echo "[*] 01 identity"
{
  echo "### 01 identity"
  date -u
  echo "--- hostname digest (one-way; raw hostname is never stored) ---"
  hostname | sha256sum || echo "hostname-digest-unavailable"
  echo "--- uname (nodename field replaced by placeholder) ---"
  uname -a | awk 'NR==1 {$2="HOSTNAME-REDACTED"} {print}'
  echo "--- /etc/os-release ---"
  cat /etc/os-release 2>/dev/null || echo "os-release-unreadable"
} > "$OUT/01-identity.txt" 2>&1 || true

# ==================================================================
# 02 platform: CPU summary and DMI product identity
# ==================================================================
echo "[*] 02 platform"
{
  echo "### 02 platform"
  if have lscpu; then
    lscpu | head -25
  else
    echo "TOOL-ABSENT: lscpu"
  fi
  echo "--- DMI product ---"
  for f in /sys/class/dmi/id/product_name /sys/class/dmi/id/product_family; do
    if [ -r "$f" ]; then
      printf '%s: ' "${f##*/}"
      cat "$f"
    else
      echo "UNREADABLE: $f (needs elevated rights; see OPTIONAL-privileged.md)"
    fi
  done
} > "$OUT/02-platform.txt" 2>&1 || true

# ==================================================================
# 03 pci: full bus view plus the wifi controller slot detail
# ==================================================================
echo "[*] 03 pci"
WIFI_BUS=""
{
  echo "### 03 pci"
  if have lspci; then
    echo "--- lspci -nn (full) ---"
    lspci -nn
    echo "--- wifi bus slot ---"
    WIFI_BUS="$(lspci 2>/dev/null | grep -iE 'network|wireless' | awk '{print $1; exit}' || true)"
    if [ -n "$WIFI_BUS" ]; then
      echo "WIFI_BUS=${WIFI_BUS}"
      lspci -nn -s "$WIFI_BUS"
    else
      echo "no network/wireless PCI device line found"
    fi
  else
    echo "TOOL-ABSENT: lspci (package pciutils)"
  fi
} > "$OUT/03-pci.txt" 2>&1 || true

# ==================================================================
# 04 wifi capabilities: full wiphy dump (bands, channels, cipher suites)
# ==================================================================
echo "[*] 04 wifi caps"
{
  echo "### 04 wifi capabilities"
  if have iw; then
    iw --version
    echo "--- iw list (full wiphy dump; check 6GHz band for DRV-11D-001) ---"
    iw list
  else
    echo "TOOL-ABSENT: iw (package iw)"
  fi
} > "$OUT/04-wifi-caps.txt" 2>&1 || true

# ==================================================================
# 05 wifi state: interfaces, link, station, power save, regulatory
# ==================================================================
echo "[*] 05 wifi state"
{
  echo "### 05 wifi state"
  if have iw; then
    echo "--- iw dev ---"
    iw dev
    if [ -n "$WLAN" ]; then
      echo "--- iw dev $WLAN link ---"
      iw dev "$WLAN" link || echo "link query returned nonzero (often: not connected)"
      echo "--- iw dev $WLAN station dump ---"
      iw dev "$WLAN" station dump || echo "no station (not connected)"
      echo "--- power save state ---"
      iw dev "$WLAN" get power_save || echo "power_save query failed"
    else
      echo "SKIP: no wlan interface detected"
    fi
    echo "--- regulatory domain ---"
    iw reg get || echo "iw reg get failed"
  else
    echo "TOOL-ABSENT: iw"
  fi
} > "$OUT/05-wifi-state.txt" 2>&1 || true

# ==================================================================
# 06 driver + firmware (KEY PROBE): driver version and firmware files
# ==================================================================
echo "[*] 06 driver/fw"
{
  echo "### 06 driver and firmware (KEY PROBE)"
  if [ -n "$WLAN" ] && have ethtool; then
    echo "--- ethtool -i $WLAN ---"
    ethtool -i "$WLAN"
  else
    echo "SKIP: ethtool missing or no wlan interface"
  fi
  echo "--- modinfo iwlwifi (first 30 lines) ---"
  if have modinfo; then
    modinfo iwlwifi 2>/dev/null | head -30
    if ! modinfo iwlwifi >/dev/null 2>&1; then
      echo "(modinfo iwlwifi returned no metadata; module may not be installed on disk)"
    fi
  else
    echo "TOOL-ABSENT: modinfo"
  fi
  echo "--- iwlwifi So-family firmware files on disk ---"
  ls -la /lib/firmware/iwlwifi-so* /lib/firmware/updates/iwlwifi-so* 2>/dev/null \
    || echo "no iwlwifi-so* files matched in /lib/firmware or /lib/firmware/updates"
} > "$OUT/06-driver-fw.txt" 2>&1 || true

# ==================================================================
# 07 kernel log (KEY PROBE): iwlwifi/iwlmvm/firmware/cfg80211 lines, this boot
# ==================================================================
echo "[*] 07 kernel log"
{
  echo "### 07 kernel log, current boot (KEY PROBE)"
  if have journalctl; then
    KL="$(journalctl -k --no-pager -b 0 2>/dev/null | grep -iE 'iwlwifi|iwlmvm|firmware|cfg80211' | tail -250 || true)"
    if [ -n "$KL" ]; then
      printf '%s\n' "$KL"
    else
      echo "no matching kernel lines (journal empty, unreadable without root,"
      echo "or nothing matched; see OPTIONAL-privileged.md for the dmesg fallback)"
    fi
  else
    echo "TOOL-ABSENT: journalctl; see OPTIONAL-privileged.md for the dmesg fallback"
  fi
} > "$OUT/07-kernel-log.txt" 2>&1 || true

# ==================================================================
# 08 modules: loaded iwl / 80211 / bluetooth modules
# ==================================================================
echo "[*] 08 modules"
{
  echo "### 08 loaded modules (iwl / 80211 / bluetooth)"
  if have lsmod; then
    lsmod | grep -E 'iwl|80211|bluetooth' || echo "no matching modules loaded"
  else
    echo "TOOL-ABSENT: lsmod"
  fi
} > "$OUT/08-modules.txt" 2>&1 || true

# ==================================================================
# 09 NetworkManager: radio state, active connections, version
# ==================================================================
echo "[*] 09 NetworkManager"
{
  echo "### 09 NetworkManager"
  if have nmcli; then
    echo "--- radio ---"
    nmcli -f WIFI radio || echo "nmcli radio query failed"
    echo "--- active connections (column format) ---"
    nmcli -f NAME,TYPE,DEVICE,STATE connection show --active || echo "nmcli show failed"
    echo "--- active connections (terse, machine-readable) ---"
    nmcli -t -f NAME,TYPE,DEVICE,STATE connection show --active || true
  else
    echo "TOOL-ABSENT: nmcli"
  fi
  if have NetworkManager; then
    NetworkManager --version
  else
    echo "TOOL-ABSENT: NetworkManager binary"
  fi
} > "$OUT/09-networkmanager.txt" 2>&1 || true

# ==================================================================
# 10 bluetooth coexistence: bt controllers on PCI and USB
# ==================================================================
echo "[*] 10 bt coex"
{
  echo "### 10 bluetooth coexistence"
  if have lspci; then
    lspci | grep -i blue || echo "no bluetooth PCI device"
  else
    echo "TOOL-ABSENT: lspci"
  fi
  if have lsusb; then
    lsusb 2>/dev/null | grep -i blue || echo "no bluetooth USB device listed"
  else
    echo "TOOL-ABSENT: lsusb"
  fi
} > "$OUT/10-bt-coex.txt" 2>&1 || true

# ==================================================================
# 11 power: PCIe ASPM policy
# ==================================================================
echo "[*] 11 power"
{
  echo "### 11 PCIe ASPM policy"
  if [ -r /sys/module/pcie_aspm/parameters/policy ]; then
    cat /sys/module/pcie_aspm/parameters/policy
  else
    echo "UNREADABLE: /sys/module/pcie_aspm/parameters/policy"
  fi
} > "$OUT/11-power-aspm.txt" 2>&1 || true

# ==================================================================
# SANITIZATION
#   Build one-run maps, then rewrite the evidence files with stable
#   pseudonyms via plain-string replacement (awk, longest original first,
#   so overlapping entries behave sanely). Map files are temporary and
#   deleted on exit; original values never enter the bundle. The SSID map
#   is applied only to wifi-state/log files, the host map only to the
#   kernel log, to limit collateral replacement.
# ==================================================================
echo "[*] sanitizing evidence"

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
  # SSID of the current association (iw link output)
  if [ -f "$OUT/05-wifi-state.txt" ]; then
    sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p' "$OUT/05-wifi-state.txt" || true
  fi
  # active wifi connection names (NetworkManager terse output)
  if [ -f "$OUT/09-networkmanager.txt" ]; then
    grep -h ':802-11-wireless:' "$OUT/09-networkmanager.txt" 2>/dev/null \
      | sed 's/:802-11-wireless:.*//' || true
  fi
  # SSID-like tokens in the state/log files. Two passes to stay precise:
  #   A) quoted values: SSID: "My Net" / SSIDString = "x" (spaces allowed)
  #   B) bare single tokens at end of line: SSID: MyWifi
  # Mid-line bare words are deliberately NOT captured, to avoid swallowing
  # the words that follow them.
  grep -ohE '(^|[^A-Za-z])[Ss][Ss][Ii][Dd]([[:space:]]*[Ss]tring)?([[:space:]]*[:="]+[[:space:]]*)*"[^"]{1,32}"' \
    "$OUT/05-wifi-state.txt" "$OUT/07-kernel-log.txt" "$OUT/09-networkmanager.txt" 2>/dev/null \
    | sed -E -e 's/^[^A-Za-z]?([Ss][Ss][Ii][Dd])([[:space:]]*[Ss]tring)?([[:space:]]*[:="]+[[:space:]]*)*//' \
             -e 's/"$//' || true
  grep -ohE '(^|[^A-Za-z])[Ss][Ss][Ii][Dd]([[:space:]]*[Ss]tring)?([[:space:]]*[:="]+[[:space:]]*)*[A-Za-z0-9_.-]{1,32}$' \
    "$OUT/05-wifi-state.txt" "$OUT/07-kernel-log.txt" "$OUT/09-networkmanager.txt" 2>/dev/null \
    | sed -E 's/^[^A-Za-z]?([Ss][Ss][Ii][Dd])([[:space:]]*[Ss]tring)?([[:space:]]*[:="]+[[:space:]]*)*//' || true
  # owner-supplied manual additions (one secret per line, '#' = comment)
  if [ -f "extra-redact-list.txt" ]; then
    grep -vE '^[[:space:]]*(#|$)' "extra-redact-list.txt" || true
  fi
} | awk 'index($0, "\t") == 0 && length($0) >= 2 && $0 !~ /^[[:space:]]+$/ && !seen[$0]++ {
           n++; printf "%s\tAP%d\tssid\n", $0, n
         }' >> "$SMAP" || true

# ---- collect hostname (applied to the kernel log only) ---------------
HN="$(hostname 2>/dev/null || true)"
if [ -n "$HN" ]; then
  printf '%s\tHOST1\thost\n' "$HN" >> "$HMAP"
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
    05-wifi-state.txt|07-kernel-log.txt|09-networkmanager.txt)
      apply_map "$pz_f" "$SMAP" ;;
  esac
  case "${pz_f##*/}" in
    07-kernel-log.txt) apply_map "$pz_f" "$HMAP" ;;
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
  echo "                  SSID text -> APn (wifi-state / kernel-log / NetworkManager files)"
  echo "                  IPv4 address -> 10.240.0.n"
  echo "                  hostname in kernel log -> HOST1 (01 file stores a digest only)"
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
  echo "- IPv6 addresses are NOT rewritten (link-local ones are usually"
  echo "  random on both OSes, but check)."
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
