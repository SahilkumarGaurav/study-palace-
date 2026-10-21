#!/usr/bin/env bash
# ============================================================================
#  StudyPalace — fully automatic server installer
# ============================================================================
#  Downloads the project from GitHub, restores the 5 component files that the
#  GitHub web uploader silently dropped, repairs apt/Caddy, creates
#  .env.example, installs everything, builds, starts the site and opens the
#  firewall. Idempotent: safe to run as many times as you like.
#
#  Usage:   sudo bash /tmp/sp-install.sh
# ============================================================================

REPO="https://github.com/SahilkumarGaurav/studypalace-.git"
APP="/opt/studypalace"
STAGE="/tmp/sp-code"
FIX="/tmp/sp-fixpack"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[1;31m✗ %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run with sudo:  sudo bash /tmp/sp-install.sh"
[ -d "$FIX" ] || die "The fixpack did not extract. Re-run the whole paste block."

# --------------------------------------------------------------------------
say "1/9  Repairing apt (removes any malformed source list)"
# --------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
for f in /etc/apt/sources.list.d/*.list; do
  [ -e "$f" ] || continue
  # A valid line is:  deb [opts] uri suite component
  if grep -qE '^\s*deb\s+\[.*\]\s+\[' "$f" 2>/dev/null; then
    bad "malformed: $f  -> deleting"
    rm -f "$f"
  fi
done
apt-get update -y >/dev/null 2>&1 || apt-get update -y || die "apt-get update still failing"
apt-get install -y ca-certificates curl gnupg git rsync sqlite3 build-essential python3 ufw >/dev/null
ok "apt healthy, base tools installed"

# --------------------------------------------------------------------------
say "2/9  Downloading the project from GitHub"
# --------------------------------------------------------------------------
rm -rf "$STAGE"
git clone --depth 1 "$REPO" "$STAGE" >/dev/null 2>&1 || die "Could not clone $REPO — is the repo public and the URL right?"
COUNT=$(find "$STAGE" -type f -not -path '*/.git/*' | wc -l)
ok "cloned $COUNT files"

# --------------------------------------------------------------------------
say "3/9  Restoring the files the web uploader dropped"
# --------------------------------------------------------------------------
RESTORED=0
for f in components/Header.tsx components/Footer.tsx components/ProductGrid.tsx \
         components/GuideBody.tsx components/Newsletter.tsx; do
  if [ ! -f "$STAGE/$f" ]; then
    mkdir -p "$(dirname "$STAGE/$f")"
    cp "$FIX/$f" "$STAGE/$f"
    ok "restored $f"
    RESTORED=$((RESTORED + 1))
  fi
done
[ "$RESTORED" -eq 0 ] && ok "all 5 component files were already in the repo"

# the fixed deploy scripts + templates always win
mkdir -p "$STAGE/deploy"
cp -f "$FIX"/deploy/* "$STAGE/deploy/" 2>/dev/null || true
chmod +x "$STAGE"/deploy/*.sh 2>/dev/null || true
ok "deploy/ scripts are the fixed versions"

[ -f "$STAGE/.env.example" ] || { cp "$FIX/env.example.txt" "$STAGE/.env.example"; ok "created .env.example"; }
[ -f "$STAGE/.gitignore" ]   || { cp "$FIX/gitignore.txt"   "$STAGE/.gitignore";   ok "created .gitignore"; }

# --------------------------------------------------------------------------
say "4/9  Installing into $APP (your data and config are preserved)"
# --------------------------------------------------------------------------
mkdir -p "$APP" "$APP/data" "$APP/uploads" /var/log/studypalace
rsync -a \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude '.next' \
  --exclude 'data' \
  --exclude 'uploads' \
  --exclude '.env.local' \
  --exclude '.env*.local' \
  "$STAGE"/ "$APP"/
ok "code in place"

if [ ! -f "$APP/.env.local" ]; then
  cp "$APP/.env.example" "$APP/.env.local"
  bad ".env.local did not exist — created a blank template. YOU MUST FILL IT IN (step 9)."
else
  ok ".env.local preserved"
fi

# --------------------------------------------------------------------------
say "5/9  Node.js 20"
# --------------------------------------------------------------------------
if node -v 2>/dev/null | grep -q '^v20\.'; then
  ok "Node $(node -v) already installed"
else
  curl -fsSL "https://deb.nodesource.com/setup_20.x" | bash - >/dev/null
  apt-get install -y nodejs >/dev/null
  ok "Node $(node -v) installed"
fi

# --------------------------------------------------------------------------
say "6/9  Swap (so the build is not killed on a 1 GB instance)"
# --------------------------------------------------------------------------
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile 2>/dev/null || true
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "2 GB swap enabled"
else
  ok "swap already present ($(free -h | awk '/^Swap:/{print $2}'))"
fi

# --------------------------------------------------------------------------
say "7/9  Caddy (automatic HTTPS)"
# --------------------------------------------------------------------------
if command -v caddy >/dev/null 2>&1; then
  ok "Caddy already installed"
else
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https >/dev/null
  mkdir -p /usr/share/keyrings
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y >/dev/null
  apt-get install -y caddy >/dev/null
  ok "Caddy installed"
fi
mkdir -p /var/log/caddy

if ! command -v pm2 >/dev/null 2>&1; then
  npm install -g pm2 >/dev/null 2>&1
  ok "PM2 installed"
else
  ok "PM2 already installed"
fi

# --------------------------------------------------------------------------
say "8/9  Installing dependencies and building (5-10 minutes)"
# --------------------------------------------------------------------------
id -u sp >/dev/null 2>&1 || useradd --system --home /home/sp --create-home --shell /usr/sbin/nologin sp
mkdir -p /home/sp/.pm2
chown -R sp:sp /home/sp "$APP" /var/log/studypalace

cd "$APP"
sudo -u sp npm install --no-audit --no-fund || die "npm install failed"
ok "dependencies installed"

sudo -u sp npm run build || die "The build failed — scroll up and paste me the error."
ok "production build complete"

# --------------------------------------------------------------------------
say "9/9  Firewall, web server, starting the app"
# --------------------------------------------------------------------------
ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
ok "firewall: SSH + HTTP + HTTPS open"

if [ -n "${DOMAIN:-}" ]; then
  sed "s/studypalace\.in, www\.studypalace\.in/${DOMAIN}, www.${DOMAIN}/" \
      "$APP/deploy/Caddyfile" > /etc/caddy/Caddyfile
  ok "Caddy configured for ${DOMAIN}"
else
  printf ':80 {\n\treverse_proxy 127.0.0.1:3000\n\tencode gzip\n}\n' > /etc/caddy/Caddyfile
  ok "Caddy serving plain HTTP on port 80 (add DOMAIN= later for HTTPS)"
fi

systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy
ok "Caddy running"

cd "$APP"
sudo -u sp pm2 delete studypalace >/dev/null 2>&1 || true
sudo -u sp pm2 start deploy/ecosystem.config.cjs >/dev/null
sudo -u sp pm2 save >/dev/null
pm2 startup systemd -u sp --hp /home/sp > /tmp/pm2su.sh 2>/dev/null || true
[ -s /tmp/pm2su.sh ] && { bash /tmp/pm2su.sh >/dev/null 2>&1 || true; sudo -u sp pm2 save >/dev/null; }
ok "app running under PM2 (auto-restarts on crash and on reboot)"

sleep 5
IP=$(curl -fsS --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "YOUR_SERVER_IP")
if curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:3000/"; then
  ok "the site is answering on this server"
else
  bad "the site did not answer — run:  sudo -u sp pm2 logs studypalace --lines 50"
fi

cat <<EOF


$(printf '=%.0s' $(seq 1 62))
  StudyPalace is installed and running.
$(printf '=%.0s' $(seq 1 62))

  Your store        http://${IP}/
  Admin panel       http://${IP}/admin/login

  Config file       ${APP}/.env.local     <-- FILL THIS IN NEXT
  Database          ${APP}/data/
  Your PDFs         ${APP}/uploads/
  Logs              sudo -u sp pm2 logs studypalace

  DO THIS NOW
    1.  sudo nano ${APP}/.env.local
        Set ADMIN_EMAIL, ADMIN_PASSWORD, APP_SECRET, RAZORPAY keys,
        and NEXT_PUBLIC_SITE_URL=http://${IP}
        (generate secrets with:  cd ${APP} && npm run secret)
    2.  cd ${APP} && sudo -u sp npm run build && sudo -u sp pm2 restart studypalace
    3.  Log in at http://${IP}/admin/login  ->  Settings  must be all green
    4.  Also open ports 80 + 443 in the LIGHTSAIL CONSOLE:
           Instance -> Networking -> Firewall
    5.  When your domain points here, enable HTTPS with:
           cd ${APP} && sudo DOMAIN=yourdomain.com bash deploy/setup-lightsail.sh

$(printf '=%.0s' $(seq 1 62))

EOF
