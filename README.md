
> Guilty of trusting claude here, I didn't read the whole script, nor documentation because I didn't want to understand it that so I don't disable it, so read it before you run it obviously. **

# Social Block — Documentation

> **Arch Linux / Omarchy** · multi-layer, self-obfuscating blocker for LinkedIn, X, Pinterest, Reddit, Instagram, Telegram, Threads, and Quora.

---

⚠️ **This is intentionally hard to undo.** By design, normal attempts to reverse these changes will fail silently. The only reliable recovery path is booting a live USB and manually undoing each layer from outside the running system. Keep this document somewhere offline if you think you'll ever need to reverse it.

---

## Installation

Run once as root. The script self-destructs after execution.

```bash
sudo bash install_block.sh
sudo reboot
```

The script deletes itself with `shred -u` on exit. No log file is written. No history is kept.

---

## Architecture — seven layers

Each layer alone can be bypassed; all seven together make casual circumvention practically impossible.

### L1 · `/etc/hosts` poisoning — *fs-level*

All known domains + CDN variants redirected to `0.0.0.0` and `::`. Covers ~70 hostnames per platform including image/asset CDNs (`twimg.com`, `licdn.com`, `cdninstagram.com`, etc). File immediately locked with `chattr +i`.

### L2 · `chattr` neutered — *obfuscation*

The real `chattr` binary is moved to `/usr/local/lib/.e2fattr`. A decoy wrapper replaces it at the original path. The wrapper silently ignores `+i` and `-i` flags — so attempts to unlock the hosts file appear to succeed but do nothing.

### L3 · nftables kernel firewall — *kernel*

Packet-level `DROP` rules for all resolved IPs at install time, plus hardcoded CIDR ranges for the major ASNs:

| Platform | ASN |
|---|---|
| Twitter / X | AS13414 |
| LinkedIn | AS14413 |
| Meta / Instagram | AS32934 |
| Pinterest | AS54115 |
| Reddit (Fastly CDN) | AS54113 |

Applied at both `output` and `input` hooks. Persisted via `nftables.service` on boot.

### L4 · systemd-resolved / dnsmasq — *dns*

A drop-in config under `/etc/systemd/resolved.conf.d/` forces DNS through localhost. If `dnsmasq` is installed, per-domain `address=/domain/0.0.0.0` entries ensure NXDOMAIN-equivalent responses even for subdomains not in the hosts file.

### L5 · Guardian timer — *persistence*

A systemd oneshot service named `systemd-netcheck` (intentionally named to blend in with stock systemd units) re-locks the hosts file and re-applies nft rules every 300 seconds. The script lives at `/usr/local/lib/.sysd-netcheck` (hidden by dot prefix).

### L6 · Browser managed policies — *browser*

Managed policy JSON written for Chromium, Chrome, Brave, and Firefox. These policies are enforced at the browser engine level, below extensions. Users cannot override them from within the browser UI. The policy blocks by wildcard domain pattern.

### L7 · Pacman hook — *pkg mgr*

A pacman hook aborts installation of known circumvention packages before the transaction starts:

- `tor`
- `proxychains-ng`
- `redsocks`
- `v2ray`
- `xray`

---

## Files written to disk

| Path | Purpose |
|---|---|
| `/etc/hosts` | Appended with ~70 blocked domains × 2 (IPv4 + IPv6). Marked immutable. |
| `/etc/nftables.d/social-block.nft` | nft ruleset. Included by main `nftables.conf` on every boot. |
| `/etc/systemd/resolved.conf.d/block.conf` | Forces resolved to use local DNS. |
| `/etc/dnsmasq.d/social-block.conf` | Per-domain address overrides (if dnsmasq present). |
| `/usr/local/lib/.sysd-netcheck` | Guardian script. Dot-prefixed, hidden in a non-obvious lib path. |
| `/usr/local/lib/.e2fattr` | Real `chattr` binary, relocated here. |
| `/usr/bin/chattr` | Replaced with decoy wrapper that no-ops immutability flags. |
| `/etc/systemd/system/systemd-netcheck.service` | Guardian service unit (innocuous name). |
| `/etc/systemd/system/systemd-netcheck.timer` | Fires guardian every 5 minutes + on boot. |
| `/etc/pacman.d/hooks/block-proxy.hook` | Aborts install of known proxy/circumvention packages. |
| `/etc/chromium/policies/managed/social-block.json` | Chromium managed policy — URLBlocklist. |
| `/etc/opt/chrome/policies/managed/social-block.json` | Chrome managed policy. |
| `/etc/brave/policies/managed/social-block.json` | Brave managed policy. |
| `/usr/lib/firefox/distribution/policies.json` | Firefox WebsiteFilter policy (if Firefox installed). |

---

## Recovery — from a live USB only

From within the running system you *cannot* cleanly undo this — that's the point.  
Boot into any Arch-compatible live USB, mount your root partition, then work through each layer:

```bash
# 1. Mount your root partition (adjust /dev/sda2 to your actual device)
mount /dev/sda2 /mnt

# 2. Unlock and clean hosts
# Use the REAL chattr, which was moved to .e2fattr
/mnt/usr/local/lib/.e2fattr -i /mnt/etc/hosts
# Then edit /mnt/etc/hosts and remove everything between:
# "# --- social block ---" and "# --- end social block ---"

# 3. Restore real chattr
cp /mnt/usr/local/lib/.e2fattr /mnt/usr/bin/chattr

# 4. Remove nft rules
rm /mnt/etc/nftables.d/social-block.nft

# 5. Remove guardian
rm /mnt/usr/local/lib/.sysd-netcheck
rm /mnt/etc/systemd/system/systemd-netcheck.service
rm /mnt/etc/systemd/system/systemd-netcheck.timer

# 6. Remove DNS config
rm /mnt/etc/systemd/resolved.conf.d/block.conf
rm /mnt/etc/dnsmasq.d/social-block.conf

# 7. Remove pacman hook
rm /mnt/etc/pacman.d/hooks/block-proxy.hook

# 8. Remove browser policies
rm /mnt/etc/chromium/policies/managed/social-block.json
rm /mnt/etc/opt/chrome/policies/managed/social-block.json
rm /mnt/etc/brave/policies/managed/social-block.json
rm /mnt/usr/lib/firefox/distribution/policies.json

# 9. Unmount and reboot into your system
umount /mnt && reboot
```

### Why normal approaches fail

| Attempt | Why it fails |
|---|---|
| `sudo chattr -i /etc/hosts` | The decoy wrapper intercepts it and silently no-ops the flag. |
| Rebooting | The guardian timer is persistent. All layers reapply within 30s of boot. |
| Editing hosts as root | `chattr -i` is neutered; the file stays immutable. |
| Uninstalling `nftables` | Guardian will reinstall the rules next time it fires; also breaks your firewall. |

### What partially works

- **VPN** — may tunnel around the nft IP block, but DNS and hosts layers still apply. Browser policies remain active regardless.
- **Live USB** — full recovery, all layers accessible from outside the running system. ✓

---

## Known gaps

- **Mobile hotspot tethering** — traffic from another device bypasses all layers on this machine.
- **DNS-over-HTTPS** — if a browser has DoH hardcoded (e.g. Firefox's Trusted Recursive Resolver), it can bypass the resolved/dnsmasq layer. The nft IP block still applies.
- **CDN IP rotation** — the nft IP set was resolved at install time. If platforms rotate to entirely new IPs, the IP block may miss them. Hosts and DNS layers remain effective regardless.
- **Curl / wget / CLI tools** — blocked by hosts and nft, but not by browser policies.
- **Tor browser** — not blocked at the browser policy level (doesn't read managed policies). Would need to be blocked separately or removed.
- **Flatpak / AppImage browsers** — managed policies don't apply unless policies are symlinked into the Flatpak's filesystem.

---

*social-block · arch / omarchy · keep this doc offline, not stored on system*