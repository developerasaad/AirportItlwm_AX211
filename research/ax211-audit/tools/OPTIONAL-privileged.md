# Optional privileged probes - exact list

The two diagnostic scripts produce a complete, useful evidence bundle with
**no root access at all**. The commands below are the *only* ones that add
value with elevated rights. They are all **pure reads**. Nothing privileged
runs by default, and the scripts never invoke sudo themselves.

Run these manually in a terminal only if you are comfortable doing so, save
each result to a file, **hand-check for private values (AP names, hardware
addresses, IP addresses, serial numbers) before sharing**, and include the
checked files alongside the regular bundle.

| Command | OS | What it adds | Why it is optional |
|---------|----|--------------|-------------------|
| `sudo dmesg \| grep -iE 'iwlwifi\|iwlmvm\|firmware\|cfg80211' \| tail -100 > dmesg-iwl.txt` | Ubuntu | Kernel ring-buffer copy of driver/firmware messages, including early boot | Only needed if `07-kernel-log.txt` came back empty (journal unreadable as a normal user) |
| `sudo lspci -vv -s <bus> > lspci-vv-wifi.txt` (bus id is in `03-pci.txt`, e.g. `00:14.3`) | Ubuntu | LTR, link speed/width, ASPM capabilities and current link state of the AX211 | Adds power-management detail for findings DRV-AP-006/007; verbose register dump, elevated read only |
| `sudo wdutil info > wdutil.txt` | macOS | Full association state: AP hardware address, channel, band, security mode, roaming status | Richest link-state snapshot, but it prints the real AP identity and network name, so it must be hand-redacted before sharing |
| `sudo log show --last boot --style compact --predicate 'sender == "kernel"' \| grep -iE 'itlwm\|iwx\|wcl\|skywalk\|80211' \| tail -400 > boot-kernel.txt` | macOS | Kernel log for the whole boot session instead of only the last 2 hours | Large output; useful after sleep/wake or roaming tests when the standard `08-kernel-log.txt` window is too short |

Safety notes:

- Every command above only reads state; none changes configuration,
  networks, kexts, or NVRAM.
- Outputs of these commands are **not** auto-sanitized by the kit. Review
  them (or paste them into `extra-redact-list.txt` handling by rerunning the
  relevant checks) before sharing anything.
- If in doubt, skip these; the unprivileged bundle alone already covers
  most findings in README.md.
