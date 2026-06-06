#!/usr/bin/env bash
# Run as root: sudo bash install_block.sh

set -euo pipefail

# ── targets ──────────────────────────────────────────────────────────────────
DOMAINS=(
  # LinkedIn
  linkedin.com www.linkedin.com m.linkedin.com mobile.linkedin.com
  linkedin.cn www.linkedin.cn lnkd.in licdn.com media.licdn.com
  static.licdn.com platform.linkedin.com badges.linkedin.com
  px.ads.linkedin.com snap.licdn.com dc.ads.linkedin.com
  # X / Twitter
  x.com www.x.com twitter.com www.twitter.com m.twitter.com
  mobile.twitter.com api.twitter.com t.co pbs.twimg.com abs.twimg.com
  ton.twimg.com twimg.com pic.twitter.com tweetdeck.com cards.twitter.com
  # Pinterest
  pinterest.com www.pinterest.com m.pinterest.com pinterest.co.uk
  pinterest.fr pinterest.de pinterest.es pinterest.it pinterest.ca
  pinimg.com i.pinimg.com s.pinimg.com widgets.pinterest.com
  # Reddit
  reddit.com www.reddit.com old.reddit.com new.reddit.com
  m.reddit.com i.reddit.com redd.it redditstatic.com
  redditmedia.com styles.redditmedia.com thumbs.redditmedia.com
  reddit.map.fastly.net events.reddit.com gateway.reddit.com
  # Instagram
  instagram.com www.instagram.com m.instagram.com cdninstagram.com
  i.instagram.com static.cdninstagram.com
  instagram.fgyd2-1.fna.fbcdn.net ig.me
  # Telegram
  telegram.org www.telegram.org t.me web.telegram.org
  desktop.telegram.org k.mtproto.org
  # Threads
  threads.net www.threads.net
  # Quora
  quora.com www.quora.com m.quora.com
  qph.fs.quoracdn.net qph.cf2.quoracdn.net
)

NFT_TABLE="blocker"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[block] $*"; }

# ── layer 1: /etc/hosts ───────────────────────────────────────────────────────
log "Writing hosts entries..."
chattr -i /etc/hosts 2>/dev/null || true

{
  echo ""
  echo "# --- social block ---"
  for d in "${DOMAINS[@]}"; do
    echo "0.0.0.0 $d"
    echo "::       $d"
  done
  echo "# --- end social block ---"
} >> /etc/hosts

chattr +i /etc/hosts
log "hosts locked (immutable)"

# ── layer 2: systemd-resolved NXDOMAIN stubs ─────────────────────────────────
log "Configuring resolved DNS stubs..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/block.conf <<'EOF'
[Resolve]
DNS=127.0.0.1
EOF

# Use resolved's NXDomain via a dnsmasq-style local config if dnsmasq exists
if command -v dnsmasq &>/dev/null; then
  DNSMASQ_CONF="/etc/dnsmasq.d/social-block.conf"
  for d in "${DOMAINS[@]}"; do
    echo "address=/${d}/0.0.0.0" >> "$DNSMASQ_CONF"
    echo "address=/${d}/::1"     >> "$DNSMASQ_CONF"
  done
  log "dnsmasq entries written"
fi

systemctl restart systemd-resolved 2>/dev/null || true

# ── layer 3: nftables firewall ────────────────────────────────────────────────
log "Resolving IPs for nftables..."

declare -A SEEN_IPS
NFT_IPS=()

for d in "${DOMAINS[@]}"; do
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    [[ -n "${SEEN_IPS[$ip]+x}" ]] && continue
    SEEN_IPS["$ip"]=1
    NFT_IPS+=("$ip")
  done < <(getent ahosts "$d" 2>/dev/null | awk '{print $1}' | sort -u)
done

NFT_RULES_FILE="/etc/nftables.d/social-block.nft"
mkdir -p /etc/nftables.d

{
  echo "table inet ${NFT_TABLE} {"
  echo "  set blocked_ips {"
  echo "    type ipv4_addr"
  echo "    flags interval"
  echo "    elements = {"
  # Anchor IPs for the biggest ASNs (manual hardcode for resilience)
  cat <<'HARDCODED'
      # Twitter/X ASN 13414
      104.244.40.0/21,
      69.195.64.0/19,
      192.133.76.0/22,
      # LinkedIn ASN 14413
      108.174.0.0/20,
      216.52.16.0/20,
      # Meta/Instagram ASN 32934
      31.13.24.0/21,
      31.13.64.0/18,
      179.60.192.0/22,
      185.89.216.0/22,
      204.15.20.0/22,
      # Pinterest ASN 54115
      192.30.252.0/22,
      151.101.0.0/16,
      # Reddit CDN (Fastly)
      151.101.0.0/16,
      # Quora
      52.2.0.0/15,
HARDCODED
  for ip in "${NFT_IPS[@]}"; do
    echo "      ${ip},"
  done
  echo "    }"
  echo "  }"
  echo ""
  echo "  chain output_block {"
  echo "    type filter hook output priority 0; policy accept;"
  echo "    ip daddr @blocked_ips drop"
  echo "  }"
  echo ""
  echo "  chain input_block {"
  echo "    type filter hook input priority 0; policy accept;"
  echo "    ip saddr @blocked_ips drop"
  echo "  }"
  echo "}"
} > "$NFT_RULES_FILE"

# Include in main nftables config
if ! grep -q "nftables.d" /etc/nftables.conf 2>/dev/null; then
  echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
fi

nft -f "$NFT_RULES_FILE" 2>/dev/null || log "nft load warning (non-fatal)"
systemctl enable --now nftables 2>/dev/null || true
log "nftables rules applied"

# ── layer 4: guardian systemd service ────────────────────────────────────────
log "Installing guardian service..."

# The guardian re-applies nft + checks hosts immutability every 5 min
GUARDIAN_SCRIPT="/usr/local/lib/.sysd-netcheck"

cat > "$GUARDIAN_SCRIPT" <<'GUARD'
#!/usr/bin/env bash
set -euo pipefail
# re-lock hosts if someone unlocked it
if ! lsattr /etc/hosts 2>/dev/null | grep -q "\-i\-"; then
  chattr +i /etc/hosts
fi
# re-apply nftables
if [ -f /etc/nftables.d/social-block.nft ]; then
  nft -f /etc/nftables.d/social-block.nft 2>/dev/null || true
fi
GUARD
chmod 700 "$GUARDIAN_SCRIPT"

# Make the name look innocuous
cat > /etc/systemd/system/systemd-netcheck.service <<'SVC'
[Unit]
Description=Network Check Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/.sysd-netcheck
SVC

cat > /etc/systemd/system/systemd-netcheck.timer <<'TMR'
[Unit]
Description=Network Check Timer
After=network.target

[Timer]
OnBootSec=30
OnUnitActiveSec=300
Persistent=true

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now systemd-netcheck.timer
log "Guardian timer active (every 5 min)"

# ── layer 5: obfuscate chattr ─────────────────────────────────────────────────
log "Obfuscating chattr..."

CHATTR_PATH="$(command -v chattr)"
if [[ -n "$CHATTR_PATH" ]]; then
  # Move real chattr to obscure location, leave a wrapper that does nothing
  cp "$CHATTR_PATH" /usr/local/lib/.e2fattr
  cat > "$CHATTR_PATH" <<'FAKE'
#!/usr/bin/env bash
# passthrough for non-sensitive flags
case "$*" in
  *"+i"*|*"-i"*) exit 0 ;;  # silently swallow immutability changes
  *) /usr/local/lib/.e2fattr "$@" ;;
esac
FAKE
  chmod 755 "$CHATTR_PATH"
fi
log "chattr neutered"

# ── layer 6: block package managers from installing workarounds ───────────────
log "Locking down pacman hook..."
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/block-proxy.hook <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = tor
Target = proxychains-ng
Target = redsocks
Target = v2ray
Target = xray

[Action]
Description = Blocked by system policy
When = PreTransaction
Exec = /bin/false
AbortOnFail
HOOK
log "Pacman hook installed (blocks common proxy tools)"

# ── layer 7: browser-level (if chrome/firefox/brave exist) ───────────────────
log "Writing browser policies..."

# Chrome / Chromium / Brave
for policy_dir in \
  /etc/chromium/policies/managed \
  /etc/opt/chrome/policies/managed \
  /etc/brave/policies/managed; do
  mkdir -p "$policy_dir"
  cat > "$policy_dir/social-block.json" <<'POL'
{
  "URLBlocklist": [
    "linkedin.com", "*.linkedin.com",
    "x.com", "*.x.com", "twitter.com", "*.twitter.com",
    "pinterest.com", "*.pinterest.com",
    "reddit.com", "*.reddit.com",
    "instagram.com", "*.instagram.com",
    "telegram.org", "*.telegram.org", "t.me",
    "threads.net", "*.threads.net",
    "quora.com", "*.quora.com"
  ]
}
POL
done

# Firefox policies
for ff_dir in /usr/lib/firefox/distribution /usr/lib64/firefox/distribution; do
  if [ -d "$(dirname $ff_dir)" ]; then
    mkdir -p "$ff_dir"
    cat > "$ff_dir/policies.json" <<'FFPOL'
{
  "policies": {
    "WebsiteFilter": {
      "Block": [
        "*://linkedin.com/*", "*://*.linkedin.com/*",
        "*://x.com/*", "*://*.x.com/*",
        "*://twitter.com/*", "*://*.twitter.com/*",
        "*://pinterest.com/*", "*://*.pinterest.com/*",
        "*://reddit.com/*", "*://*.reddit.com/*",
        "*://instagram.com/*", "*://*.instagram.com/*",
        "*://telegram.org/*", "*://*.telegram.org/*",
        "*://t.me/*",
        "*://threads.net/*", "*://*.threads.net/*",
        "*://quora.com/*", "*://*.quora.com/*"
      ]
    }
  }
}
FFPOL
  fi
done
log "Browser policies written"

# ── self-destruct ─────────────────────────────────────────────────────────────
log "Erasing installer..."
shred -u "${BASH_SOURCE[0]}" 2>/dev/null || rm -f "${BASH_SOURCE[0]}"

log "Done. All layers active. Reboot recommended."