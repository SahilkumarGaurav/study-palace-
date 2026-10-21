#!/usr/bin/env bash
# ============================================================================
#  STUDYPALACE ONE-SHOT INSTALLER  —  self-extracting, fully automatic
# ============================================================================
#  This single file contains every file that the GitHub web uploader dropped,
#  plus a complete installer. Nothing else to download, nothing to edit.
#
#  HOW TO USE
#    1. Get this file onto your Lightsail server (any way you like):
#         scp -i YOUR_KEY.pem studypalace-install.sh ubuntu@YOUR_SERVER_IP:/tmp/
#       ...or paste its contents into:  nano /tmp/studypalace-install.sh
#    2. Run it:
#         sudo bash /tmp/studypalace-install.sh
#    3. Optional, to get free HTTPS in the same run:
#         sudo DOMAIN=yourdomain.com bash /tmp/studypalace-install.sh
#
#  It is safe to run repeatedly. It never deletes your database, your uploaded
#  PDFs, or your .env.local.
# ============================================================================
set -uo pipefail

PAYLOAD_START=$(grep -n '^__PAYLOAD_BELOW__$' "$0" | cut -d: -f1)
mkdir -p /tmp/sp-fixpack
tail -n +$((PAYLOAD_START + 1)) "$0" | base64 -d | tar -xzf - -C /tmp/sp-fixpack
[ -f /tmp/sp-fixpack/components/Header.tsx ] || {
  echo "PAYLOAD EXTRACTION FAILED — the file was truncated during transfer."
  echo "Re-copy it and check:  wc -c /tmp/studypalace-install.sh   (should be ~38591)"
  exit 1
}
echo "✓ payload extracted: $(find /tmp/sp-fixpack -type f | wc -l) files"

# ---- now write and run the real installer -----------------------------------
cat > /tmp/sp-install.sh <<'__INSTALLER_EOF__'
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

__INSTALLER_EOF__

bash /tmp/sp-install.sh
EXIT=$?
exit $EXIT

__PAYLOAD_BELOW__
H4sIAAAAAAAAA+xbfXfTxprnX/wpHgQXOzSSbCeBS7hhaxIXcpvEru2UskCNbI1tNbIkNFISQ7nnfofuOXvOnvvHfrZ+kv09M5ItO1Da24Te3UU9JXqZeeZ5
f5uxZV+78quK697WlvqLa/Wvuq9t1e9u3atv3N2o4/29e/XNa7R19ahdu5bKxImJrsVhmPzSuI99/196WfbYS7xxEMbCSs6vhkIW8N3NzQ/Kf/NebVn+tfrm
1t1rVL0SbFau/+fyv0muiETgimDoCVmyg9AV/Wnopj4/WVEQlfgf6wdZKt2kQJwneMt/7JIdpviX700RnFqulagxUYzZw8QLg5I9SD3f5ZdTTw5L1l63302g
aaU7ViSmpSCamq4YpGPLD8d3SjMnDi48izgOY/1sYZU7uB06vrpnuKciHgo8Zn/xJplFQg5jL0qwSiIVBl4wCvmbiYu6SerO2o7vDAXFaZB4U0GukzhU+brZ
bFPruEetr+jxfm9NjS/Z/LFkp5EfOi54MnCGJ2lU+qMFd0mXZbPsxLkzjfyr8gAfsX9Y/uaq/d+rfbb/T3LdpJ3ffcGylqzq57//B0GrvDgMpiJI6NSJPWfA
DgUDd8NoRsnEkzTyfEFJSK/YmLVdvyIncPmDT15AszCNKRaODwh+KqTF84+a3zY7NAynUy9ZngpQiGVUwf+A7viY6c74lanjm7vGAC6B3MyT6ItqFnX3e83C
K3w/hFrRAORNhKYgSge+N6TjzoFFx1KAyDCmbrNFQycIAw8EyHWSXiKmTmSdT/11AGnBMdPj2Ikm5E2dsZCKOx3nTRhHzgwzfZ+dEfhy1Pyu128fPzrY3+0z
Mn2sszNJkmjbthV3JqFMtjdgbBeHHjUOmzsF8a2QV7eosXe4f0QHrcf4txIG/oyetY4ZcXKGQyEl2Y479YK1ZRbsTpxgrDggxQ3aH2kw/Xaj233a6uyxjHwx
Apd8JzhRjHKiiEYgShKTBXkCijFUYKaiVt8wFP1qJK9HkRMIn+QkPJOsK+SQH6Yu+O3SGWKHF4whcMD4+b/+m/YP261Or3HUU9rp+GfOTNIZeKvgRY6UZ2Hs
stbttcCcJn1z3Oo1u6wxR4hwiH+UQJAJy4DS4HUaJljGuAmcpALBbiShcAQsWDmh95AnU0ArhO8czm62sR4IwjcJIwgSsHQgMA0iNg5nBilCmSQwOQgT0DUG
aozMN7wwa7cMOdImYpiQjCA2rRwhUInxQgw9KB14FzvDRMRQEY1E87Cxf7BjKP59KVnokRK65QVGaQVPQ0uwB1vthV0gB6sNxgdhMO7Xq/V7BitKVwxjkVDK
Gg37k7C0goAklAN5ABgSnniCviA3PAs4jJLvBSfKnh+LQMROIigMBJ15yWSbiHMQMgVkHwYyRFgC+ZVYvE69WFTKw3gWJWF5zYpBcDh9NAM/Khv1NSsJu0kM
DCvliTgvr62BoHa7323udpq9HQMiToTJLsW8u2nOOWNqKKZUU01wTxgrFrBhUafx761Ou/FsWcP3HDkZhA7UxnwITiQJIEi+b7T36WsxU/dzAnsCLgFviSps
+8Cax6/9ZjgH3qkowFHeZQruzdZKOZr9r5vP+vt7O/GbqM/r9M+XruVxGYPOP3ApP8TZHJYZpAnW0+rtCnd7GfOnYjCBoBW2jusq1WcfJOGEmO9gswMlxnTb
iTw7zvyYfabnYbQ4hS1swxpnbD/W0ImSFNa8wPdp89GTVuvrHGcW1G4ax0heZ9AuOAKapsMJuxYXCWeI7E64Nst6LFxr4Tlh6kDTU6oKEHIKp8PSSQOOH5Hj
SaH88/5RZ42tmGr37/MD7fBdtWqVdo87nebR7rMdvF1Rl03Eg16r03i8EhKesm6RTiNhLe29r+AAIUsLwhQRYWWknt39vab2SCpe2EDDd9miQxUuOYKy31VO
eKBCy3DCpjeJw3Q8ge9BIuyNPOGug4ueu2xwVum4fdBq7PX39js71jyjRbRyzjPEYMFvBHPm8FHpsPFdP5tw+GjnbrVUUIVt8kbKQflQyRj6d6pC+bcqDbe7
G+Aa3IIK83i9IAieXTLLEZ/YV6oIP0iHJxicRX44sjOO/6BOiviUI2UcThlEzIjBiB2XHUcWwuCsmr3+o0ZXx7wVWWxZtNfoNfjzsjC63xwg1lLFFSMn9RMV
FN6IOGS00wjME/GIXStrgUPftrtkkwqkNAXHvUCsbbPhZrDV0oz7tqWqBbvoWd0BY4v4O45Bm46fgRBulgMoImOfwygHadaJE5Ex8uIiUQYHJgWfG29z4PpS
BfetzY26jbWWGXDXola7t986ahysMADGEmQmADxCluIXcNRBArcI3RmLUve4zTEzixkyjaIwTlaCxnzQ0yeNXhf+dse4DxPJL4M9fBiOkeg1oDWzxBsiW6C2
76TSQ0ZIU+FImLhKEz0orbDGFj02v5tfS/nK4wZ7tf8rpde/xAWFFbD82VW2AX9z/69Wq9ern/t/n+Kay1//seTk8tf4iPw3ayj2l+W/UcXwz/X/J7hu3kAg
ie2BF3AjiMPz5FKK5EK5/J7ugJx4kSqkIpdT2ixFOPDGk0Q6np8FxStApJMGOiv5qtM65DK2QweNdq/VXufcwnN1xY7C6gcd/Tn52lZFpLqYPbRqMJQOkGim
X9asurVhbZLp0d/sOS17OsNAwq56ngrUfoJIG3lC6gRoyPVOJUD2G+sXi67GumpNctJEyBWyjG2NmwMqF1LFcrGBu46UULU8dTmITIHLUjkvr7nC0onO1AlS
pDPIpyLdWNlDQqCaoeBOKvENeUqt+vPff9qoQh7IDFx5Of2TgkQ4STSbIkUt60VglOeXSr1G5zEXbLfe1rbNd0ap233SRw7T5Td19YbLOk5h8SK73TbtMEqK
aVc27LjbnI/j+21TRvhUQvb6nMw3ZNzSyxn08gEzKSgREuyE/vKXcrP1Vbl0LJEJbZc+InnWI9QknW+bnf5+m55DA+zISSZ2EtonWvAvS6WmbrLKj4LbsGrV
+1atbm1+WJnMVJrInRKzptTqIxBXkjaQhhniHDVHrTTySszjHUNi/K23Obvf4V7zhvklhpOQjJ2dh7Q7EcMTFKi66aHslDVGVSLc5DNKtwCCymoGtCaAIXGp
eKvCaWrgTMVauQivO4PiApw2AnniRRE/rpqAvZ5rP+6KmxTrpLYjUO3HEqDIdN4g03WFL+BYXoBMbiSskGboD6Y4H/opli0XAZZXPyr4F9+OvYsvGdMLLzO8
L0KYk/jeT3eK3ywbqprLY3uu9+/sJdnsa5fA/Cs6hcwVZFsh40xChkxdSEjVAWaHFjaSw1f3tFgrnzd0Cy/p9m1SgMy0CIKCaJp7KBAWhKaTulA3dTtKA/c3
A4vhuRUFSxR3tIMrUPWrAEbTeu4bqWAbQE9HJN7QwjrS58p8o7DeE+H48KBDNoL5imkMGkeyS2ZIsL1TO0iZ6jMqT8KpUMXUNj3p9dr0p7fcEOmzrr97EZQp
a9HW6vesKv6rqRatbdCPPyqp63W5fdnL/LeLmp4bgk4gz0RscTzbJtLqnWkHlZk6PxzLFdKgF9CFrWo542BG1s//+In2lMMQrmVkL4m+9STkpcIRt6WVDimy
s26vjRW4xZdwsa4aKpj8R2czn6/fes3z/13HdWfcw7j8NT6y/1e/d2/jQv6/Wf2c/3+K6y3czO9L6hQAmquP3l9Jk3DqJN5Qub2u3uwq1ABhsEj2LxMBGosk
D3eBOJN0IJKypGagNg1oKBAqRh4SPDhCxgnuzdLTO7ACxmw5U9L5sioTdPeaKoMQb9RYSQPhh2drCoKGMt9l2taeU08CBg3VN49dmvLGYL43GYVegCfdKNUQ
dEZVZt+t+Id0ciCAqsgI5O6vJ2UqeJ9pQY71+7lYur5M+zqdnZ1ZK/x4W7p+fbEj5nsoHwLJ4lwOYVSZ7zrqXjUrBcct3QVeA5SYyx0p+qi1zmcr04HLdaQu
nBGO36BSfCMTt6RW7gpEWy+Z0QQMxHy81HcKs+u8ATRMzF6M+MjdSnM+3pg65yYC8c5GbWvjLtZ4gPREZVvddLCnxCQfoPATnKsZDOs7czcMQB7AzSJh6s63
JCMIZeCNRmoM4KtC9fr1d6WMM5wP+9zOpmHsnPl4Ui3kQRyeQbaQH4JoVmR6p1z8OtAFpuPL/AVXDlmQzWPtHVJbJksPeWufn6FZIuYbFaHDNCF7OjPzEQUu
zRfZZTwUhXHoM1Gm5JM565TzqWpoip6xHqvNCiBKA2+cbaBC82FtAUrJVOabB4UNPq4kmags+c2JmhORnRKSxXdT4XqOUo3XKe9aDUIo/ByCEjCw66stinq1
evgo5ztvj6rPoDwC8coP2adOzEmKPWTDWWrJz8dfB/G+BlirTgeLVyec+G3x8zu1iFonO0B0FObOYCaSf+PdfN1SGEDnT/ItCt5aUCUIi5r3Np1BeCqyI0WA
tJ9oU5fsSwBKpYdhUKiq4ANg/DLM94HVjmHuDPaOuhaD2f5zlSm5Sb9sTzygYFD8/E4na/P4rzY+kCNmXvkyG4G/3P+rb9Y3V8//bd6rfo7/n+T6Y/p/janz
ppgDsIWYvK/MoTtrKiiFvMoWYOuIek+apPs263yOg2VMFfhrFfa5cFxb19uPF5uDha6gqjCL/ZeLtjTv+827dkcwRo6h9ep6FtorK1kT1m4f1oEY1enxI5Jn
TqQ8G0OqwC+84r6ErolfwSMJGZQTToDoBCWZcNmbOFTjqWrRYCgAcciHWMS8IciwXA+5CZz/bP1DPcWso5g3EZWQdF/RS6wFaUhanJHq5sbC5HqdRY0ikps6
nJXN1AGSefbjQuhWNpfRp6NWD5N5A/9CF1RnU4VWqHqxtJn+SZqTv7/1eNTaa/YPG39tdXbq1dJe67Cxf8TD9B33N2l+3aRwvt+ejVzJx3Rzo/kx7SvxCZo1
orecdQTJiMovghfVjY3ntQcbW1NubPxJqufqlNsSxq2a8QARIjzhSYVZRPms+vTnf/yUTeHJhVl89grz3jdrY3rj/XNcT3wIvxpW+s8ifvk8eni7/iDrYjKM
0nO8rngumemaQaZ4TVV6ya0UACdjbvaZnW//KrtdOQv0uy8WBBk1+z7RMXea2B4iZ3iCjEtl09K45PXEOefBtNd8tN846n/VaR31mkd7O3zmEMktn4HyToU+
yeWPTGSJUDUHSaCPNAP5GCH/jWd8TgDmi2QkjVH3WIyppU9rYOgJTJcPZT6Dc0j4gErmx9liLBRW6nDISYDM0Bw4GqKniieVybih8gm5cxC+hFPwRnSDoZns
zrJNInNGDxfdtfrD27V5x541joyV8bw8CGAf5PP5MwDXpzkWxGl6FOMNgFkBwEvQjzSOkQqaYZPKtkiGSFdh7JoPLxQjXliu/fx7evmFfixjimSWmynuzibM
I/Z3ZMb0qLH3AASX2LY1zjFzh1FDfXAighwjdZaEbmG8oQbHUzJH0O7sBXvOi/iCQbmy44tyx6o5p0GrXiGVlc4vTyxnBbOjz1bqE/cG7wuEJ2QsaWc2AwVS
DmLe4+XS1FwqsFVfdByk0Vidy1VBxBRSQgH4cGIEiYfBBqWjM9Kte/na9xKBNwHnqLy48vYZBjJfi5e/Cquss1U2XG6R64gbjnTQrUSxOpmmI6CiA9rLwxaR
VsXZTuNw7bINWO1U3WDx24yMsrnFXhUflw2HSvqwiceFMawKLnmjHWUzassvxMP8+0Du1A5JnZFDINr8M298TaahSyiOF2DwdnqimLCYubBCfOW3IL84QRvM
ayp/P39bJmU7I8hvwJipJnN5ATLgCkktI8/gtatleviwMEU1N9QpOZ0EwYzFVMTjbHuDOwyqdh+J7DwkBKEPV0VCuFbeSS+fTi0GEHEjHOTzMnoVOZPDxIch
379v8ghrGAYjpk69hzxxk4jpMumsoAofEfDGl9rjGsUCopjA8p2zE1D4fRcDtu23KqzRrfq7MhSEfVxx/rwdFAupDkD+Sji8c3cFdrDBdlDYSsoz1VtvF7nL
O+v8shVdH6ns9XkRJEQVfQr4FG544fVz1WF9AQPYNjjoF6caSALpdBnXO/RyYTLMdiYJ9BTnvZuLoeBmMknNd3gOyMhPtLpiYDGK2mOrU60qfeivsgkyVDmG
WfDYBa/JMH6QS3jlpCNd550vPONfPF6ZxDdXJP6BeuQKXFueK0DOqk3zwRDP3NFoXRATVW5V9GTugPB58x9Ve5DM2trC2t7DeojQcwLzRMxivWWqHp14OEFO
NH/NE5N5Q1GJn3w5MGPhCz7Mqlwkaigy4SS5lpYTJxZ2Nl0uq095rj6+NeRfK8gpSk3LC+3swG/erGKPYo+jsQU4eguYOBdBLOXNbSeewruZ5gzejzcdLy6r
AZka0CpNFuAs/P3m5j8HQHnlp7GX5D9ziUI+ZozyLI2l8Lm3FTvq9wjJhNtXcapOvKvBeZ9Q6CxSt68rjYBAmu9hSi5KxGCVteuf9KlKzKXdOefK+c+IsgPQ
+ncICpoXqDM8/JME4ZqD2c66Or8OXLIGYeOg02zsPdOHXqEWS0N1fxLoKlgGdIOeL75blvXywjP+MTjhQ/3K+VcseH2pegkayOFKVo0JVDnu7CPDAcPW9M9b
BtDuE8lH4TFCn65maJmhWGvzYLaC0j8jwpf0m9QRK9raSDhfN3MRqS2OTEWzeFpIkrNiYQkX9a70vgz2/Yaq5i45gYKPhk9c2N9Sz/dKfOXWiq9sH9apwu3i
Qn+Ej/XTF4seCSeIA9ScV+xBed//l/wno/rhILd0YmPMwArTlvl9FXy9y3zd5e5U7iOYlXzIXZlF3qRCvncFTLxBqm2AVCLv1hgf5ORNtZmHJFMd7pg3z/Qh
KPUbJWSCzDO1ocLil+xN1A/lWO+5mP6bbbGwQJgC+IoflLak0Sv14wDJP+WAHgErcxLp3RPVV1NAF5o2Uv6BD/dAvdiLMsOg+4uUFfMZT8PmP3aBPtPUvUD9
HeMnAqRqN8Lt4CDUJzwKPFmyNf1+bx+g5rfq1w/F52zzxlhYZvFMyipSiitGaX4mqbD0dlE0F4hRxaLSlfL8ZRkWmOOhqtvZ1ZSN95TihtEs19v89Cgy9XCO
wWUrbXe3s9/uZb3IytDl1hcEw+fr+KTYo0b3Sb/bOu7sNp9XX74zEFxu36bozIULandaf23uzucuZi1gYnx2RtK4VRhu0I3/ae/bmuM4svT2uX9FTosadDdR
1RfcSIighqRICru8IAhIWg1JqQvdBaDF7q52V4MABoRiYsPe8L7Y4Rk7wo7YiImYh43wL7D3xQ/7U/gHvD/B5zsnMyuzqhoAKYoa22iJALoq73ny5LmfDXff
XzqHgv16+dbSgpzjXjyZ8YLwg1RuXtZ/QxO8S3QClT4i+mEWjwG6xn7PN9+7wE5vnqXeHFu9OdZ68+31zrXYU7nlaTqL09TY09oSs2sTm/32PRbQYOTp4XjM
QiroGzKwEXS7BdZw+hpmWJB4CiGVDUdFvWmSAgGJJDN1xAbZYczKe+auk3wRHQ2gWl7VytsEffRVSSHrs6UIBU1AxbAcDm7Dj7/a3lH3v9jcUfR/DebH6oY2
pJDJXnz6MwAswyo/yyG/kbv1C+aVmXHlh+2dT7YFBmPL6C4H7u3egDpNiHbboDtrYy8i6Cq1umSoJSZ6XjvnWWwyjvXm7crj5rVozTYr+jDo2CBajEbUywRH
/edBzTexaw/oRj6iYRo1G0Q7g/1MieWQGx968z5RXz34Zl0bS8BW9Lo6Iqod8iqi/O/AhzuBj/+NVnN5ecl442VaUe3//Kt6BUJSaQZBAdBUnj7BtmalOp3m
rDdxqlEX9EC51Zy31Lu8zr0NAmJY6KIWCZf7li/cvaN1TGuR5QOL2tYLM7IW9iAfRHPlohxwadXUPbQvjMHRizD3tGlUY2dikGS/NqsWB1vqI2fKWDX8iLAx
9rnHSgg8wM+YRYa2fYukP3EsPuAFSfxpH6Yf66KpzhlwwCKjYLRxoja3Qu1aUD4k63GgLTrON+dwbTnOtDm/IOVxojWFap+YEFHBapYp5fGyxskbMSuIqFfH
Kz3MsPwzUeVq13ythfTduS+phdToXSQ1oG2Z5Qv0eSxdlBIYZ/1GVmIANMStEXZkihcCWw2vpSIlNDKbHsZOcWMKLlxjBhr6SiZovhgNg4TXZItL4s7tfE4T
MhC9hnEvkUGGskhh74d0fs3otXdC2a/7VSwMqg6cMRWdGxsZHSSTOvBvLNE2rLCPHX/yjIXDoCgZUoFfYkalyGYQuM9GkyY1EOgG4JeSE+rykgjGSEvLZ7iD
YaysyLyVVqW3XcmK2Rpa8wUGi9tHPBEYhNiVZAd1AzQZb6/9BZaZLS93Cig3+Pdl09q4kvnJdJKMWSFVMLG06EmOqanlOwgATTEKYLtAOr9lrgFyLje3mJHI
hh3AEpAdwlbssFdvhp2V5VD/boKwS2fNUTyLAnbSEalRMJi8Xi6V2y/4nlJQYlTE3Qo4rFL5SfYavpnRwKFPwp/WMLXMwTsG4FyOjHGGXpNrp5tbZyD27zgx
acqKOF4TaPEOe3MY4QF/Mr+VCjhKRouM5FT+vUtq8+dWEAhRvfPl5raCzzw18YWxl8k+ThO8YVQqM/AsK2WcrqjgI8CN/ykDJ0wOA1DbO/e3tulLO1T3QUkC
6wgeWzdGU+OI7qvSafHNjmAoyglcs5gLpUPfbYQXEzJnmoX5eBWfpKE0ZKOnpBywJjX3WcFbyNCsUo4qd0LjZLTuTPyneBlRo0uh2mLb7zlW4nQkGGio6DKt
ntxmTF7pQVziHna3er5hEAGiJUNBCKSgBLCU5xGk67Kom9qsDAFfnsQzOAEBVdE3Q3P/xHMHpPBLG0j+P/6x9r8S1vCX8P9fW22vFPx/lq78/z/K55ex/xVg
EwHRUWIEhE7As2hvD3hwltD1wgGDPvSI6MMXIP9FGMs3MK0Z94RFxa4V9LtHgEKk7TSt6+rmZuTqmAnfoRyHbop7hgVFumx2r5mucDepGm4heGuIp6WZvHbV
FTIdolkW+tfF0BZWXOK7PzzRl0HBjtGeZbau1TKdCDqFPmHxE7VEFKSKRqo3JbLyh2R3fa4ls22J6EFNTgWoJWO5y2/FM0QLcrFlLJWTmh6Tb8P3DSOiptrL
XO9VPJmxFfC9p1vfwiD7sXr64IFjmU0tJqqWxsK27B8O+nFdfFAMGBm3iYj1MekrNmqGQTEWk4l8LO5gj0sZW2gwkn9RNsN379z7m69syewbFZ6znlQJIWs3
2stWWC8xE9SGqvr75Upf5pnJnmp/42ea3WdoqLoWtnSQWUXwjiqH5rUaTtX8giB3nz198v2jzSf3N6oEm0uqwf+xQX4BQSmtqWAjsRIJcKChFjJAsIJV60p9
zXaTiYZodcJ+SXXfQOKioo4vNR+xFp8xDaCZqUpwUa/ZWIXgXr9ohlUTyaHFbNw7bW6ZDbQ98d7OE2Pe9zQ/bps+K2N1bjh9ewl8/T0rbUeBmAF5tbK9c+cx
s6AsFrr+6befjj7tB59++enjT2F59PQrQF1WwVuNa1w5pIs83P8di5LvWgSqzR7YhBns/L4YApuoekexuFSKL6B47aUHEEql7NwIg2Z7LaTjaJIeJDPr5JVA
/y6av4iD+alv7jzSFi07Mp3RK6hAaPloEjPEG12AMe8UehkqUV1Q9/92cwezfwirN3rUJNZFnBCdleL3PDPipsx4tMSkr/L61+ys55uQAvTCtxwwlrd5GQod
4Oe+DqkkvJ3bn7JNXVClGuqzseAMLFdqQYyfzXH4l/9hZ76usg3KduX1ILLdh85xEjkJa7qCKD+wsOqtTfOcPpkXx36rmlGUmO4gOxXIYRcYM6SUcRudS9Hi
ES/pEQogEko20SrNPSWdN3RbxIzdPKh4Y9dP2aJ0MO4XSqsA4dLVHizVeyoY1nmOtdSaGhKjquWz8DiKrAHC7lSrdPW1y+QMlrxeeX6O0hEAVdQ36rdmcI6q
kUZA/G/WrbYCc7yx9PGuiGTdNPHsPkJw3kc88yok6/r7QmUns6FwaVKtrhykGmOvV0RuYWgna2+xT6z25TxHRHSwPUsQ2tMVHWSEVkAQMNFS32RSFBHcP57B
QUO7rchE0RIYluD4d3tujUBQo8aBKrgnMlI9WZEj6NDbsdZFY6qak9cDEihzK+ozghJ5ksUKkM6tb7x3S+qb+KO5FlDUbSGTdBVayIuLTCNGg5xO1mmB89Wo
7Ap2BmKZ4tYUdiYvvdGwVKnwNvR+B2Cn26mKNTeIWoWVzJheXlcq25u/ZcPm/iEsu3WlN8RYEMm4165XnXgsQlhrZz0YliMrQe0aWqjzqWD/ZPasx36O4yPI
J6+BGqwMUxW0Z/7t6t2WDQMknoSWoGowhMLu+rWaZEK4rtr1Or04jqYIRzwVL5SKg14wCqM+ZZqeR6DPEAfY9a74ihtZi3YBgW2eJEeCUhH/luh+MfZkD9BQ
PcCxZHYJGzqMJnRM+GhinwBs50Ra08pBMGplQbrW5xHV5UtlG/uxhAxLmxjT06lVn2M97nyzre492vR9ukXrDDMXYpOI7Nhe0tFvw19K1mXlP2W6pg/UxwXx
X9qra/n4nyud1vKV/OdjfJqNRoUYLai2jJGijeIiVq25fClQiC5mgQXFuJVJn0U0JCbMTBzA52u+ZlEfCGu5yMMwSNmI5y+nEVWNZkWMwkJxd0yJAT5lU+IJ
0T7P+eye6hMMLnRdLTineGFRv2o2tU81d9k1ARq0TZ9vuEK4TafB0dcGUybrvolak0v0iU5l/pWt00xnQKo8DsyOCHQOmxJ8mWn5bMneEd0AC/lbzL42Ag1q
rW2excdxD4PATIk0fZX1eshGqaLOgLLTvDiKZj1acTYdMs8QbGMUj4ip+97WWaAb7bFtju7fdbuySrHjy/0nX1OxbMFsYaUQHGedZ5o9o0W/71gNwnKpBmpy
0SZ5kNQMTiRMWMPWddBBCQ/utnYOlcBQbYPXMF1CsObBp9YXqTM7RbhDfi8OmQtlvHjTpiiyM00OZ+fWoPdeefZl+37I7L67KdC+uk94UC8XK2effbCrwuL/
R5sPv9zZvrP5KHj41eYX98NR/0N1cQH+X1pZaxXif611ruT/H+XziY79h8OXi9BVCNLBkXthsLl7wr8rlW+00Jd9LZNRDDdOceiWDD+wKGJ+Y0rEIaBZmJCA
k3FohTALIdKQWDOinTTINxrRLuTiyy1FOOBwFqeNxqIacTipPb4fogHbKVUqjcbT8X4iEUTT2XqjoX68tvL2939st5qjZDw7sIOwgt/rVKIVrrS0O7gNtBUS
Meo4oZuIYoPXEqdXsU+m2Lh5fs45/FGB5V/lEyR8iESsD4N+4+7ObD9QaaXyRu1wb290agjkL4r59ntTeUON8D8qdWfMxGTUY2dddglNw4g3h7W+bN+BHBzG
/UAcnbJ9A1srjsppPImgBsc9LPEcown9zb0YEzcW06LXE2pwn+6uKZ2P2sPkCyzHonpCr7neovoyYWOxeLqo7g72nyXE/YcSwb/rh6nocg/fFpTz1I39nqUS
efv3f8iyoOBLo2ESodDuvuF1y6zs2RAu0cmihEVQUsIdRLNrZH4Zq89BK5E6h9qs3M6HdfpWG/CJDz3xhBwpWbUJtFZFkRFzcDPxfYuOEKyJVoguyjSEF7l2
c+MGtRvXTE7PmgMj23jQFis9ZvZyCncDtJVKO1QPE8BIo2GctjJxgw8RRNJ1QrWTTIIpSqyryQBkGG8nDbjR6EGphrYkvCctE7zbaXGx2t3Hh6PdaKBq0SRI
6RAeBO16N6ws0YEYop1GQ4/UjK3RCCuQLhwk1CoLFAIqtEWThrcbTuQjOsPHza/Gg2Pz9u7wMGZfZrx+uq2ecpA43uuvmF1TnU7YWlaPdrapAELydJbpe93U
hwUsQRCSnEzRRBZ3DKuuk3qgAOjTvT3W4AlklsVSzmYKzrEbUgfsbZ6lKYNUD+vDAW0WUk41w+lPdGImPSxrETEZRuN1kNZKv7m2QuhI1UyYgEWgNvpze/uL
um53D66TyKEE7BAyBLNUyQi9CLhSPy5BmjgBCY4ShP/hmBtOr4wFVa1johPovsYJoas42qVF3wMqnuoQP6HawhbzvHWCFzoDxekxEU1tuUesW1k5D0TUN4Sy
1Y8dg9AVUi8OTeqs2SGCBxFGaDSeCY8BqFp1ZFaNhs4gs7lFHacs4tGnz2J2xoI12WcniHa3HuKwfaLau6HYRKIWnddJPKXLBzLk2mAExiEaz+qVyk6WroYK
SQIy45HJBnFep4YVWtS+n0fJ4VC7cbrmPZl9UuEKCfl0P0IytFE8PtTnILOo0QfTrqq9sbBGyM82m0XIejSzR9rbl2yobiuou+Ss7zg+cq/CRmOHgSA1awVY
YLvHw1TLS2ELRwiHoJyw5x0nYGWP89jgkm21VpoHGFDtx2tL4SqAsc6X0wA7zReqREiJeAqSRCyyrjAZ+AjtkUCJPUygbUnlHJp6HCEKiaMA2tr/iC4us++9
UJLpaWJEbJOw6AKvvGa5VfKWnxgPXumvxrhCGg1j38RUCQAKSWwk1R1ckWNwyhCxsqsOYVK6DhA/hz2goPQeDdIUyb/WQQXcgUk5wYF4rm9Nk1nSSyCR24Jh
tkMLaHoAuI9uuHtb9LPT4QuRTbnNsxst+2zbPoQ5F19zGr3uGgScBfu3OjCWYGES2jUJ0LC5Z7wUnPE74aEZNBBnR1WBi6ucy0vBumH/QLZKbyrDi3f9dXhz
HzEmZZ8wzBCE3eOop5pyeWgIYDO1HTq1A8TEqlS63S5brGTC1h+bX5iol6Vh831UX0HkbJYivkstX6K4c2dn8973m1sYDEb9zWBMK5DqEeO0bCVH8XSb3Str
+q0ixNxuqwOCY2wnsC/UGnWZ0wQV2B/TDPDe+ouvUnr2gvp8Ycf64qeN9elU/QB3vJ5B2hKtn8bM3MD2lzSHeSaAJrYbdiR14pvO9OYgSD9fwJLqCvdZBCjg
CENROgDxNKVhilGI4zfIrmA6Q9tM08UJneOnOJqiNCPSTs9qMAnaa52gsxocB8frP17rosQCJwrLE1lLPOKHsbFDZapRJx7R6UYqW7IOxMXQzDnyQIxoVIxD
JP4r4Tk0w4Lph4PZl4e7quZkxFvU4bDEnz3FTE/oQtk6pF2c5UhSS5EyyqPrTSKzUs+6YQ6oIKxTzSdw6y7o9z3tBCItDZDG7te/5qhL7At8x3zTaVODkao6
zF6Va+1OCfsRsD1mh35+hOhU2CFqIyFSkmDBkJ709uBwl6OeMGTB4BWJRD0NLhXiZiaYfnBo2uDmGQBvQwXwv//nf8wuZZ6zsxZ0kYc2QXnXeq9rj8zUSwC7
qLqskpIksl1jn9UVdsgEvrVhsbg7gDX0RYNebNlBpEJnImDsC++dRWclURZ1IK9gcrRQAqjr8qtYkjdlCLb5XVe22BZBQuEZL7MDvncZfL+ScL17Vr2i+SY2
DOmmvQlVsvHycB7cUrjzYNrhaDVq1t1Tg3RDx9TA7ekDvQu6VoXzTshXe+VOPTebUiy3znrEwnLwzvKssik0Gu+6u5mq05M1FsWPFV8neQFAzN3E2+oLpvB1
qOWuK2fuCjYWgv0ABm8EUYvGHWkw01gE8E1HuZt5NPuN1HBZddkNu+uauDBE1PMIdZk7FTDJsSo1tr7LkHrdQ1flC3pxEEu9eYOU4ykb65X5AVV1+FRtS5kk
Q/HU1SYbnxUZqs9sdFRkEu69ivscQpvmP+lqryeOr/BZeZzUz9w4qY7CIJqgZeNlmHpE6GduMFVexwHzA0Rw0Qnju0SEWZkcTNUgByN6ret47Gqc50SErbO8
gInTCDzMIFRv/+t/qVS+AfQzSIwHRGKwaGsBliyg94iOpVUlNmc3ORZswAefs1YbFxiTmFvf+HJuKtrVxT+ATdkziFKIYQNbZMw4XVGjTZISIks0QLgPSF8k
4mQ0EYnHDpEKSCB+kCQzocgjQUC7yWyWjPKguSICFbPkjsUtVskme/7XP/3n/6QhamCSODPXDyq9NxOqWC50mncDrTTs/QCkuhKFjmfJbArORDuYnA/xOS8T
XqXNmdIEOUyiOVlLxp6NTI+7BWcaiQnsIy/2qznPXIJ7fKDzrDcaNGEEs5qB1WEmppZJaDGafT3JvoxLbo6VSCNzgiRxnDbyJFohIvU0C62FYqpGQyKWbMD+
8+mQxsrR0M/NXe6Dk1HyfKJ5csBGeYJhgAdDwpr2K9fKJPa+WldPnzz6lgEN/XuJsenhb/ymimmxfxtPDk6mAbIIBON493AYOSF79QCFQfZ3WY8EIZt04rcL
8mPL8Jwc1iu7cW85utGKo+XVG73e7sreSqt1sxUtdeLW7grHn7qodyNvXb9M1mnqPp9SulqeU7pamlO6Wp5Sujo3oXM1v5LukooIG5IUvbk37JJKblrCxjBi
SX3pELOnmIqfz7Z0q0uz2d5YW0Vy3XbLBCnINJHXxZRqHafntREARGnAd5TDNKH7yyYLLs3R7JPLjcYdJ4H964h4eba26TOWVP9GcsSLwfuJiW+mup+ARCYe
iQNjIoEJ8eLnZbenCuI1oBPay11lEtbPCLh6NpY4D4LR7szBp5+0oaNN4WQeJxMaGhQc1cG4l0xhLmxRcVWCle8RojAUACG87UjsdoHNoBO6N5sOrz8F/dlo
3Ef0Yvw5E2qO3/0thFqCJ3vWbQ9YggXg2uFEsOZlKBJrBHZRqjCzPV0XlzW6Zmc4cQZdIwZ4Gw2+ooFsWSWmbz2N1LplCLFrEzuuEzmSjc4LseH6Ic4fedcs
ETHlInQxUsMo82A971J3HVl54tuE0ZRJlsMM/ghAfz27aTE9FjUQWcei7fG6p9Ew6EcLTTySZH8ax+MmwjOwEzOHk1MPBsdaIIsXAxiEQD5n2tsy2UUgy7vO
6pjIkGQAGk1ERzDFlVTleE1M4CL7i7Bk1AoMdT0mUSQWmTDsHATs7d/9c1tUQZPDKe1gCgY+o5yseouLMAkySwQEpyOL7kUXladiVnkttjk8npNRyVjX/euf
/vC/mLZy/JasjNlmlxcsqGlmOMeEbFzINAW1G+YIB/GuL1h6XuAMpCnzyElvkHc1sp4QNP3uXNs7AvOCTWF7melhdlNlS0GzAMnensPBAZc9yDG0izRruB2p
ozh+9YEYzzmc5ntYE84xJdRixDtQMR5Ox95FQlQVbjZrXg5uwMW32GQmXwHFqev2dHQAoZ3n/FSXM7jpy723Tdvq12alRQCO86U9kWl0FhzdsaAF3nbZRqK+
WMOQztZFG7DSfHhXtPJ0glnaQnCqTEg7mQadujF7ZvmHYY0PQ8FpWq4kOm+9AyyUyLyJrv+D4Li1KNPFfvFkW7tXVyp3/EYcPTeNiqOL7g0jZEMSlQ60gISF
RFyPbFDqDevBVZN14PTta77+6OXOo7zEXkvtu3e69L77G/7pQw8eLbVEaq+LHR0dnVuwwto0SKxE60M4itCTibMleRrZhi4D+j6xCtdpp6Yy94zsseyH5tEk
xrQm5a1CiNkkjmgDlnLFqvFYerkXHynoeVJ9t6wRm7KjgZf3RMtvsQec9Cw1DJwc3kWTMaQgSshQqQx4/RIXd7lz/GWkC2LywbqMvRgwFc3PIMer3/U76YKX
GuNmxw6GuZeLWWY6JbsX89zzBiQsoDKpsQ0FS0SAm8c1L666kOODh2cpq1UtZ6GqlXlkxiWoI30j4M7LzBX89rOrPi8bmER9SF9CfY5v61M9EH/OLCOKuVsX
9E0He8dFIgGSfaRciMbQ3aWL2iJVayemkn5vaGxlOIGNj2luSIYijTXsBX4U7x5AvVXrs79yWqczaL13F1lwzGYUwLSKDSwEJSPi/WjQD6gNpqFxhHbpaoO2
l4GbvrOPMRqgU0snpno4nkSDvq9DY1Iej0VbPMduptH4RsaZWqUxZvKEIE6/EOMQ2ngiJMt3hjOyTXX7TT3vLlD5NrOS61ZhZGQfDbH71Xb8MAa5z/kS1onA
5YJ68mGPrmVE2hIa3jyVTB3yjJcixDxpoHDToIsMdgBbhwZfYAjnC+YvdRbmsqBHB9RHnrt9L4ZgLZRs2Vr/yZdMPNU5SbAxILddaycxbMBZgG4dXKxqVPW+
uXHK3v7jH6vgdLRIzsWJiN/zDttKS3FaTV5V19nINAzDM4VgMmoUR2OtrBv3JU0lfJBwzmRu3pG5Kbq1xFKcBjpFx65j/GUw22j8zbf32K4HGr6jQRpLTaaP
xZCFMPQM2WWIojmxZg27dKjrTOifYy1mxRcC/lY+9wg90Att+GASfkqQSkOcg012VEoZS6NnBsJk2YkI031HwGAjmTlbz6FRedO7jza/vs/4rMvcIXJosXFM
9VsbXkAiubFuFoW1Eh74JFvnnfvbO5hXtcH2EQtAkoPjuJ9R/6vaIAaEI/MzhouBTDwSA0HDAGleexpzJMkTifK+l4X6tN327eY4vI5sKKNAyRadN4JrCbtz
uDsSkkYQeanhWxrDGy7c5xI69QKeBFo5LTgOiA90EV3ZxrZMEn0aQ7f83V0jXDLYOzHLCGJl5293NNFYB9AQeQxeM5oY9BpDDEFQIE/D4xHBDG8rTwOggvSQ
jQZubyK0JzGrBKBdJkADu9NtIhCbiO9jWPFwgAPhNWXMzyQbJoFmPz5m4bfm+nSnVtk8mPF+YCtGCS80B6NweV9t/AVqK8UIRfyoVfTZhtjUVJb6YAtGoe20
tOIQQRyNCtwoxy9Q9IgyGFYNPmlxbtjRn0yGuIM2CePEBZ7YQDP0uzT0jH1sNIyu08GtLgGpZVT0oJQffHfuMiPCT8a9NLNRqI05oyynxcOOlCu8QYlafXfd
yopMKmTRLxHWpAGxAdsABihvf/9H4s3pskvY/truPrtj9KMTa5vNaACoKYYc2SzHJ9puL78P5U/n5qNvI93vJ3b3muIL29RG0pfY44tcaS906KTeEZVVG4Fw
8Sw0pLZNlMiQuXd+2EhR875DdEt0DImMCGNVTZLs0nE9nNQr/T04iTYrcBYtE8kYv9pSr1y0LDFijNxFDB2IqngXMQ+vDPyC5PYjBnmPWB9pQbxF9y7IsuvT
CjktHqQc23xt8Y0vEjmhzmuGYE8nSMzRVFXGQkQ7L3Dk8GnMVn/VOiFDYMktHbnMGKihGCyTwjLDJSp/nq0fHhn7Pv6CLWEDOxwm5kU0N5wJuXvRYSpq2+5K
q6Pu0kwe0v4fRSddPUIbg5U2Y1fTsvAoHyBrp+Rmy9MSc4/MSquLe0X0k4iC0/eJFpHFS647bajH6IAHWN200ncR01I5Twzvynf14Pm66fp6MBjjsEMGWGK6
QodW0VBQImiVpY+6WHWRaQ7y2gtNbLwzfcVzlOgfe6wLYkxf/evodbQtEgUmacC2EYUj3m1VrAFnjpd8bnrWSLmFeJomrar2xubNWvc5jvlp2IxIviS3mn1X
yLBmXhSSq5m0YFYpZlhnUI0/Usc0Jwybz92OUGvZ1gsfjbKpnz1enNz0tEH2MFSKpAbQw2Z4J/FskYEFEiSODpgKn9s3bE53roipS+OAMDPNiZW8Xf6BXhFj
zwnXDjUmZTIAxNDUeqgvtWSTtzRDnR72epwxA8dqnGQ6VPo+SwwIw6bbsPAyO4ef0h5ChoOXWRnuPVQZtf6Ug4Hxn4lRDwjzLojkcTR9BZWZ8K8w27Mer5oO
FrPmufTygRaLCd9zFOHmEZa5LlLwAuOg97Nqg31y4NNAQ7aefddVPnZR5IiNFUA3lN4gXb1IiOrFGXugcckB/VwLKbmDLhOKgUvOjwzhQLH2igAJj3FFQtuL
ksd4EghKZn2R8dUwC8EqEkI12uYlyZrEqn6lL1NgDHP4Id6Ff4CmkfcGx6wLRRb3RTUZHqZaytrVN3VX2w/uIZoCK1rYikcbEqnRCRPnGu+4hmfcXfk1VWaX
XmakW7vA+rauQymIPa0JTY6UEjObedUhACGxN5ZAkHhvwvDpjTz2XdOyYXt5pqmw+Luwubr1C6hZK/9fG2twxJdoNK61tGPXF54L2o9v/+6fb7RazRNi7hyT
dhdx1XzxLCIA8U2ba7dEXYH2r7VCcZDRpp8jDunD6gjUsgd0wqLDaJxGPW2l/2PnUy7SaGi3xQQzQm/06O0//HuZ/3h2wAOwK7tFjNcwOoSdrVVm0lv1XL2c
J43rakdlzZRq4aip417WXW01DTIF5o3DE08V2UNyEE69muraGTLxNLD6ghiDEgv4NDmDlZp2ZbTPjpVXEDhLiRKplXGai/umf211xNIHw6EyqaknyxIJqIgM
4OiK7JunpUp9U85TwtpQg6idJZuzyyZCjGCSDAe9k66eMi8T3TdyVyl5aap41iOMQjlsGAzlmM029mIwUNZ1JBLcronlkoydQHBGT5DBo84iqutqOYNiNn02
E88YLdveZmEH7NuAKX6aK3jYxEImcIJKmx/Ipzj/uSD+K//t+3932u32X6mVn2k83uf/c/9vb/+fxEcpnSm6RcJZevzB+rgg/stKu9XJx39ptZau/P8/xmcB
Nt+94YD2f+GzSkXcINUpxHu4uGN1JgLeBbDcXERnlDdOtoRH5VLMgKd2ytgZocs2JKKIOltX9uHn60iYQJh/rM7qHD0ENM9MPWd+lM1x7uOvl1TbDKO2sFD/
LCsJBiLmkvzWLXlrYdBHwuk3agE4n+40/hsp0/kPZnUWbtekmNvoKE5T4jS42cfyd3EIiCrDAZzsvAVD1+J19QxLFD5IpiNWf9V1ZJQ41PnDtfCvxp1yCMYa
TwQhaLPR1jWvJIXMFGvZe/tCD9KsjVJIKmqiscikYG++oaIjthaARru2wHogGjQU7LvxwqITv2UUzw4SBJvZerq948RtQTZd4nuwhwt06yDqYgAziAUqGmXe
i80fUiLOs9Apiva5f7Ku/nr76ZMwnSEq0GDvhKDDbDRnCOUQNcTyT6lm3VQ90zMy82Dy3UyEJhWiq1o97EE8VavV1cZtVTs9q9tqWNxfoWDyqu7MMFtOgQNb
3ltQ9PZ5yCUQ53RhO8HKgN4+Yv0FeKdQbXH+X150jgsYuq25e6g4dK7fPcOjLV/o2zg6fa4WjMrHPNKqT7GD+9c//Yd/WFC0hMQWxb9S37C0TrMNIE1sBA4I
DlJO6waSKPS65tOWQZEi8gtOimE62ZkS8fJ5WFsY28P9PeyXDyeAmwxesg2UJs4Ub4xd+LnL7kKxlsKJMOKc5cVinlUqhQMkS6r71DRcTfdzqz94TWguSlPY
7WycdqcITBv3g6XjIUEps/DyKyCaeBZ0Wi21uy9/r7TUJFgh+vJ4FvRE4XPt1CA42iBe/3S0PgnWFs66Z7ctDNyaOF1W9+jgBMQYToZsDkiNDRGIlh6yq/Ju
Ai8VPOZOie+p3qatf/v7/zaN3T1Xb//x391qTub1MpoFbWkmHTnNraG5U43hzpz6t5q0MvKFl5cX1lu8W4jiQCMQldbGqeC7M3c184sxOg5g04IAUsFRcDxc
sIuS24fq3jAmIKUfAVye96NJ0AlXiBFb52fE1VadiQ6j3Rja7dGQcOxGdTwMGJFU3QbTaQDOx6mmFMO38UPImmtye077g/HkcObUG/SdTpzniJm6US08NuFX
nEcs29w45aJnzvNkfI+NfTdOazHjLnsKY9gI7sezkKvW3Uqsrz5gBzu2Xp/+htsVY52smLMYPCFZ3rZbBJtjtPIlE+Fqj4mbK7xrOqsl4jW9GAIUVQg+mIsh
MCnebC7MVHdn42A/YdklXQyvgpa3ZWXVAV7bMadDevv7f2JAgztvDrUtnDk7LGMsgXW/B0FKELvqE0Jd1eYfsI49YHx803g0yE4vAUCwSqdNTYnE2ahGw3g6
86dmTqEzTnsc6zSri3s+TuU31m2l5a/cAyzHwzs7ZklYeUyXc6quKyT2NOpiRDuC5mm0qA7HlhxgcRCM0ksHJ0O+1QRGwEPCGGdXCVr+r/54/N9D2B7cJZrt
g7J/F/B/7RUEe/P5v+WVpdUr/u9jfDTD94hQiWb0OGYl/M/A7OnwoB5g6OQbs8H4ZJEDI9E9P30FIRuMSiBTnsIndopgW5r83L7/VAxbUhPp84t4SOhGxyJ7
8nQHjh5sqTW0rRG5szuNpsRAwGwkmsKiEgrQYPeEFaEs48Nlj/YIB0N/N0a9WOyM0pCnJf43ekgQCk7ZntJOE8HciaYbR8M660zR2kFEpOCYSt+KboswchoP
iRhIoPWJISScxnt0a8TTqqpRQ1IdtvQ8MODHiOWpaoDwpDRsGp7I8BoN3BXaYvI50PjL2uF0KClN4lwkzEGq4rQXTRA/7kT4S46yKpGfprEYxaovdx4/olv7
B7Eu4viYIUdFrXB497uQGCskyEPOBjyiq/Ogs/AZ3yLrSlgzpqvdAksXFJhc8P5wSAUgxkxNiecv82WSS5RhhfAFfbGSisqAU81a+kxBL5J9L7aNMD3EthCk
W36eIa02ss3U12UBqXImqxBF/IYa9cOpGBLWmi+mL8bN/UW18GK8UCfmaTiY1fjvTMawi4bSrMENRYOkt0PE/aNvLRYwSEik2kDd0m7Aw3i8j5Cnwtpozj46
ogr8/vng5WfOGwbBDRQIaQKjmkgtNEuMlxlDPLh+3eGzCWAPY8Nj2SrN74IguH6tGULAXpP6xBQ3v3vRwH/+m6xpmWqI2B+1/HJnXPol+ke7oVgwweC6tgB7
roWLeiLoXdQQIw0MB7RHy3W9JJcbwzlDuMQIOmUjWPpQI3jfAXTebQDzR3DbG4GA3gSvnZNs4BufOVANqttAsR6Z343bi5IeZKL5WvYgfnf7Rfp5kw7iQt2R
yDiTPDtv2QTdmJWT/n5IBuPaAk3YF0xdcqXeUD2a5QAR9UtmTyfpzfMX6fqb4OX1F28+d88TTQ+VzBQL681I5lkCTFAjVGdRFrGUmSQqOXLYA92S+yRbtxdv
ZNVK3754c634VmO5N/7TUTSp1XrM2PbM0H15HvA0DdqMX5CHBUd1fUN1/AoFRP4BQOuND1roQmDBG5ZT+33ASW6mRZ7xIvdxGRhqfvc8aLz9/Z9fvkivl+NX
WZb81XnJVZnTvDdVZ2W4l4sOndPi+x49ohgWpbPLrdGL/vXnYf1nW6PS5n/SGjktvu8aJZdeI4uSo9LJX0BlWGrCoTIsPaGHvOfIKn6FLM/229C/rBbq81/e
9l+WgWauQHFfzmk+Q03ubnF4zvx6Y6n0Dhavxuwu5mJmsUr3aOJeH1Hh9nBlrFIfchTwWmobmIedyaZiKUYcA5P9HKopJcZk3OcAKmVsxAExJcSEEN1vidkB
MyQ1l3SuG0UV/0TUJI+y5X7KihjIMYoletCsgQJ8/l2DLi76o/6m9uL58+9evKSvL1/Unn9Xpz/q9ea+IXHZn5upXPk+kqQDz+L9+8eT+8dx7850Gp0QfY6U
NKYQzJhylHGNK4LGRcaHuMfzo9P4q40Nrmp2GrvFRUN2nlC3eQR1maPsGWpqygjvFpVT3hxPmfEseRWPQfKjwPPWy0yJx288oGs03KvF6e6WjhJEk9o47e5e
O6U/rl+H1uBUtyJE2qIKOvWzW00pftuqVZgr9A/oCBvx3YvnNVn5OpZe1r7+ok7EhCwQGvcO7sg9DloDuqhYJE6XFUESdnzk4Ceqg8fePJt8dlXh+Sf+zeot
gfNUqVsseJDVGGarwS1unOLn2W2vglKnPMYzv5km2rm96Dx0UGtu2c4dT3T+YJRI5zeq3+8Oo/Gr6ly5AP25lwyHngLjvPFHcwdvkFR+Ei4Qe7t75uArfeLc
Q3BdIFljMMFHmnBF4VuMuSx+m39U5HRoNMbFGIvNMw+wIiRCk1bCw2YB5lvG27tWAYIgaQ6aL9eF3c61niqnWppMkzQO2JrP7sGpRtdMoO7SPdo/ZirVURBL
LIHabghc7gNxD/pIsFXr3ublVI12Tw86AkvUyRl0SacgAWl+m320DozlKUTS3pQAJoCUf7kANDR0jcpN1XxvzYOOX8mBITv0pcsOfenjDn3pwqFPykd+a5IN
9Ha+H6guii0RkXm5RTgcOm0XJ7UbCsnHsAQX8B/ECqFQEprLgTT1QzbIAQ9wOCi2XC9ZocPhhSuUXHZeyV/QvJKL5yX8ePnu83HmAueCQVasBB5YJlXe/MHU
OQauJu4kuGHMBaCDa0Pf1yxpW5i/y20L0Fd5b7vBCsfF3qPrJNCqdWO/UDBfMOMprv8tHk3xOd7gfJe9wbtp+QsGFdQTSDk4D1BsNwZcVNpLoDfuJcOSkTpd
6L08KMCO02xzdjCvjSLM2Tql00Jbc5bi1gzWTOUd0Uqw9IBXYnrRStCS2mMzd1anUy1GWVSvLlhXtNiXFl9l4N8D5M/m7Co+89Zm/urMq0Ply9eGXpTBnKeI
1w27h0cTD6XnxrAG8rHUkdVN65ZZNa15Kh6DQnRrxMvpa2t/faVpit94O7OWCnHKuQ7nd2Z7t9Tnq7L7MMdaaRLmNKNOUIDHFs6SRwjsfo9Qg5bAZaKB543u
S1YeLBTefBcFv2sFN19e5/dBocB3wfU3ENBL7XdUyXv63wdsxvVhlb9/dbH+t1Ow/11ut9au9L8f43O+/teaA4sbx6KKdlNrEfwbKrXblDdu2Xt3du4/fPps
8/52rqioRaFWFtKeE81tQ7BAEH3KbBYy5o0He7NgP5oF6cmQeKXDNJj09xY0b0oFnmw+2GELl239XhEArYENnwx6AaKJ1LURaq7NHrXZn0ZHdECDCTIrEytT
1jZNQH0h5dSWLqe2iN8rbzYdzA7Z/jWAMCoYIVTCIBo6rW6bEhxEeZ09ZYhcjuBxrDFOacuw1wkmEcwuxwE4nzQ4iuFyFe3H+UHfh23PlpRVv1bf2HL5lkUP
71S/g2hXsBrSb1Dhpd2kR/cf3nlU2CPPf8YdShI8E7TXVM8kUMiWlMkPA65q7iiQ1QMx/RAwo1CYg/d7HW3Jk3mtsytyb+ZUuCdPaGm2JVqsnec8jlWwYc1l
RtkTbYNz5XwBc9Z6uB/PHtCN9C29qJXwpGIYm7fiahlibZaj2mBzenRA9LclivJcrfaxpirHan9KlxlsJtstNTkJ2sswnMRDGFOmQUcN952vLmeWb5XqUZkg
nURjqWa/tT3yTMQ1LA+pNqsFQ05mHIyNLBtz5oi7W2izUO0guKmO6J9XHeFCB3sn5quhdzsgePeD/SndvzBDnyXBriR1C5DAgm3vFD3Egt7En7CT85c0G8zr
ffV6EB/dTY43qi3VUp1l+t+b1gGR3kfBSpWjD9PqH06n1Ou9ZJhMqyqiYx4cDPr9eLxRRQClMqIbxhiqv1F93O6oJdVRN4a0WyvqRrD8evWg8/WNR3j+26pr
Wlmsu6ra7XDl6/Zqr6Xa4Zrq0L8ltaqW0tWgHdJfwdLrYDlcGQb0LKBv1GAyiXqD2clGNVxbKWn+VpOmn9udJrbnoh27jBkzzMaBZWccdsLaKt5cKfIlHAm+
0AtXsRtavS2h4ksHWHimhYHuk7wd5bIxTU6tKedQKDpaQDvc1QIbZSK6MHHIaHcylZSKQBgSwAOBfO4iApsExaK7xJhgcvyqdJHvF30PKXMPLXr9+BdGyX1B
rWhYVNHeXjSYsqN4ykmnOMb9NH49SOhqZIw1iSYxYjO6XWzBezOmRmKE67RO8+LCO8sS4cqKTi5YznMMYrGSNworeSvyjhnY23Vn02GvruWuXZggz5J12Nxz
ymdOkaBDfrPRtGd0L5/5ZQty1/nzLGsEST1TBO74XOUlx7kh5C13hS0L5iDK81bQWPArZ5msk0CuV71mxpf4KApHcbN06cxMaPVybeRk3Lm3cy3hvHLvh2yX
CdkufyBk24kI0bbRE/0X3AgJh66E7Uf0ojNcAda8Y9638Y+e/3a0Qri0vRy2e0HYCYFaO4RuOwFQLn6H1EDQVvgRrgX0K1zmnzeDcIkerQb0P6Fm1AM2Dpbp
5yr963AptIOaK/y7E95IqSh1QH92eiizRK/oB7W8dBCu0CMaV7iMH6uE2sObhPbbvZAap3/yeEgjQLcrVBxD5kYwpnCNvi2FNxRuB7kx2oqno/+ixad/NBgq
hZ8yoSHG1+7ZdjrytIMMelKuo2t0dA00WnZ7lVwvijPipncmExOw/7yzCEt48PqumTzz9h4R453eg6XCFfK83Z4cv5RDxQeKOo6nPXEs0pfUEfCpc0stA1lt
HySS51hsKvMyagiH8ziQwzgFJ/BgycHmacYSubYxBRGgEaf2wnR4uF8iHHLor9Nus4eDLUW7Z4WpG/8fTCmHPDIcWybloTYRgKEo6ClerPI0L+zNC4luFaXB
HiGJCHjVsvGX4EI79OJ8ipcMPnc5NAZHleL7+e3f/6EwgeK08pPyJfAfFRLZoYNpDbn5VW37/tP6TwRIYb0FGPfPB8b9sFQN6wOjLvQBgXA/LNGTztuui6Hw
F9zAL+PhhNhO5pUHcfoTd475cdm44fkbN7zMxg0/+MYNP+zGXYw+RieBTaRQikbeZyLPYtuoGp0w6ngPtHHx4Bl0AhYCfLCxs9cuRs3Nvje2cx/k5AUEpKs+
S16mgwKjLi5qzVX40OZ1wz4f8dMOmY4GluZI+Hf13rPMiolwc0F7xh3PcI8rOe7xq61NYgP/rO5F037Kfz2JZ7sSm5y/foNwMIVh5xQk3lcfd+V3Zo5g6RzZ
jytRKnHHhWRp1XN+LnNBdF128bfH4NB3I83ZjWdHCChEj0R2EO/53pG3csv9L/9dnYKHPfO5MSZQQgXRJYe2TDma1fQ1gtF9MdgfICaTjQ9GfPjpglrIYRX3
FHrizGpB3FGEEZxGQP+UnS36iBAsImC87Fz2qHIkXo6Ltyh/YxRp7mjycS2OnzObSCrBIfsBZVGOLs26+0fIa/5JwpKFwXDAad/YBwpESMg/3/7bP3MEJBzK
fgzJtIlq9iSS8PycVmQwQ4JfevMgSg9EmtE7GBM/tz9fvHAOrJ82ocyb0p5yPClESljn8MSSLU1iQCPqwXUdu0k1mmbRbkk+CduNuC27wSuG/esIKuE4OzdV
nA4HIu6CxCcYM8gOJFZ2b9YcJ0EfbtwZjpWvyWE6PNmOZ5tjOlZwzto4de2Ivv8ePuzFuBjeBiz8hjWPxzME2bCBr3sHtNphMt1fWMyVnul4HN/Eu1usHvDe
H06pv2g3ZZM9/9Ug3Yqms6d7HN3DbQYhqBYWORjbusofvkW/STfoh3LieNDfZgc0iwjvYcjEr/yH/yI+nv5Xp816OB30P6QS+IL4T53VlaV8/Kd2a+VK//sx
Plpry36ip0oDQE5vi6TcmYJXlwFFo0uFTedZVnCeT/E8fZsDfYwLzf0NXBKPJrOTnQFSQmxAyyi8vIlLu5AVQQJclIiPJEawMupY3Fe7McguEwTehK1FgD7O
zJelMeJAtxJUU+5YBPWEmCLkrkA1oBeWXNgnjzg8CT2+m1XUBWDn6sxo3cxVLOqzyX1uDEg+cyfkPUVPhQfctfNUW9Cyx6fpNOffcX6AnGoxPg6RgvoPxKuF
R3JGYXYc1WVzDbR+u+XSjOeQnyZWjNYEtiECph/voAsU+mql5QqI8qqby4mf16jvtfcTP7u6us7BjeGyWn7dXv1y9evOb0cQHq98vXawFK48ai8p+pWXmOak
pXny35dGsITg0tGErN7tNAOzM18GkWORTPCeGWTVWlE26qsCR8prfGqh9Mwn4xwZQ0HCwLFfDhBOFn9Rm9SXL+g4tVB95knsfO71EsGLctAmKnNHRQ4eZ4n1
5hGCPI36jsZ8aZ4C/dSeKZbDTBbVICeKueViSZbGTMJB/8xgAPqKvwfJFBraU/hgLZ9lIFEvtWb7WfC/d/9/yXHePrb91+paOx//c7m1fBX/46N8yuM/XmQO
RpW2CN9xnOYzt+A4ej3YZ34qV/z+3l6MFEJz40pmpmbEjdwjDE+FbViineQeov7nLM/o0XvZnT2583XBoEkuas8mCiRGuV3WOcZpD+/svLfx2b15dd/Vwuxi
my+JEuXbe82jywQreHZQz6H95UCZyJLrRcnkeJ9uWM2e3stYdtUr3HIKTgxAbbjgpaNXWAjSsR5zkFETn1sTSo07qnlerfVF9fwl91ZoSiahB07FzEDKiwv1
1E96h5y7DnbPxMOfDOPQmOjTBDg5wOfEtzPBwKHKFj7zyC7P7eiC1kzdM77jFmX1X8rC+LedBOr0LLuQgQ8Z1CZBS/0OVJIm23bnmZ41b6wwSdyfUp3d4eE0
OB5eyhzNUHCrRfOGpWopZVBmQ2bCwZUZkwkVxjC8UWXDIbELIqJ9FOcM1ZL9JEdjXWzJ9Lx900qfMzLKyHbHnF330qZNP82wKf/EED7ZA0K1Htk2JKpQ4K24
dG1QMlhefwkf09b5ZBehRuP4E49yrnH4yFEF9nods0+eObMbG5KFm1mjN2/sG9cttHvt1JY5a3Y9k//5fjGYd0HFIY4ytrHCeyE8zylQFguUubzJcUAEOqTe
HQMUyxYoMkEwsgEMGD1eOy00rswKEQqYw6CstVqMFkr0O1Zr4gqRNYwtFPoqmu+UOeBhIUrVcmXqIG9jzuquBQYBXU5tmoPBjJe7wBi0uK+uNYAPdA6PNgfA
O8rbxKI6yuVQy/Z4qWSPHUbH3XC9SxqN8m4uzZH4g5/gY+fNx8NiEssftIZbKMdcSqnNHpIBXWCfqVeIzrsYnFVv6y7YhAD9vP39P803mrzMDnE2iORwNneX
pvEwYvh3bd4OIBM4wo/L8PaX2UZXY/eeGzR3Y067oCsWOdIvERNnPGj9hbFdOwv9u+CfwdwGoZ2yndNt3VYtRBspoL38vka7aTKEOiVghReh9ACXettcu5yR
mzj1lXdY3n3HZprORNschpwO9hwbajONIlopWurm7DHK4a0AY3m5AXHNyEtjJAca3KFyzGAtN8y7hyec+u783iVWrFdRlETywoeUZHwPOZA3Tn0asvaav/7q
dc6EwYvJ+9GOBOEAWZ4SKCdiP0KrG6cgJs/mHgNDyd5DTixFROohwzxmK9/mQ76pe4vr6iNAlW89pnr6qw8SfrjeC3WBo2QXuk9wVbQkma5POvYOVSHuNKfB
HYxp44LjoMX0MRGuuwkNYMSU8nIr87k9kWvNrnK2sB4KPYc2NgY9q6xOz8sOC96QBZncbnZTva9BoycNL5g1XFJUlnfo4OW+nHUj91FKzOHj2j2WFig1eiwt
WSLFvoyJCod5XyrSA0XjkJJe57gF00CRDa/cZ7bMGqrcS74AH3n7NX6WYwgMyLVzND8fmmJUkiLlX9zAedt3ETV+CXpcFRjBUpRo7EfcjaWbaxnHCiSd3r2V
c6i5Gy6hbUjz4p6W2rbNp6N5ee4dxK+nxZue35Vud8lmly5xmaXbOSzNX8ACFlfg8Yk1Ucmb0p23dOX2aj4fws/OU2B5hI4x0prjFfauSRuqt3fYXwKqRaax
4Y36eRmCvSBRg5G+lKDYbU56apPRw6noOrsR9ZLRbkLMdu8VextxysqjxFitp5JQsh/3kFOc04LQMrwKC0tcHGvePvvzlPDYxiSZHA6jaYEo40D+mS4HOjxQ
K/PNsXfpgkrj4TCeXs6sMm+fe459nNWdiDDMqk8y533IhrQ40xef5Wluy8d8RDdFlR5EdE4CWupM6vZzeiq+j4fiz+KZ6ChBM/ZBtk7ETg4XvKElqNi493At
giivCm158irOr5U8/WbQnx1sVDthZ/7q3eoNpj0iQHvUbZuu2d6J/J5uVNfsvOxSjTo0sBaQLP6ZfgjY41400fhK19IrQXOXiVsW8t2n7QHF5ad9zqSdrV89
aNPGQkt8k1iZzqMVtfRlZ97MsqeIh+hP2F/Lm7KUnRYvZTtcLQdqMw+ZVUk77Rvv3VB+ByzL8tF24FzAs3uwrNYO2qv0q93Rv/H93YDLcmd/YXMj+BoS6ml3
HrdvEEYhTHPj3SamSYr3xBUZwbMEZ9R3nuPyJeY4uskTWyXkOHfTzjs32ZR/aT3y1efqc/W5+lx9rj5Xn6vP1efqc/W5+lx9rj5Xn6vP1efqc/W5+lx9rj5X
n6vP1efqc/W5+lx9rj5Xn1/u838AsPkACgBAAQA=
