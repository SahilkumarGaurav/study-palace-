# GitHub setup for StudyPalace

Do this **once** on your laptop. After this, updating your live site is two commands
(`git push` on your laptop, `git pull` on the server) instead of dragging files into a browser.

**Why bother:** the GitHub website's uploader silently drops files when you drag large
folders — that's exactly how `Header.tsx`, `Footer.tsx`, `ProductGrid.tsx`, `GuideBody.tsx`
and `Newsletter.tsx` went missing and broke your build. Git never does that.

---

## Part 0 — Get the project onto your laptop

Download the `studypalace` folder from your workspace to somewhere sensible,
e.g. `Desktop/studypalace`.

Then **check the 5 files that went missing last time are actually there**:

- Windows: open File Explorer → paste this in the address bar → Enter
  ```
  %USERPROFILE%\Desktop\studypalace\components
  ```
- Mac: Finder → **Cmd+Shift+G** → `~/Desktop/studypalace/components`

You must see these 20 files plus an `admin` folder:

```
AddToCartButton.tsx   AnnouncementBar.tsx   BuyBox.tsx
CheckoutWidget.tsx    ContactForm.tsx       CoverImage.tsx
DownloadsLookup.tsx   DownloadButtons.tsx   Footer.tsx
GuideBody.tsx         Header.tsx            Newsletter.tsx
ProductCard.tsx       ProductGrid.tsx       SearchForm.tsx
ShopFilters.tsx
```

If `Header.tsx` / `Footer.tsx` / `ProductGrid.tsx` / `GuideBody.tsx` / `Newsletter.tsx`
are missing, re-download the folder — don't continue without them.

---

## Part 1 — Install git

| | |
|---|---|
| **Windows** | https://git-scm.com/download/win — run it, click Next through everything, defaults are fine |
| **Mac** | In Terminal type `git --version`. If it offers to install Command Line Tools, click Install |

Check it worked:

```bash
git --version
```

---

## Part 2 — Tell git who you are (one time only)

```bash
git config --global user.name "Sahil Kumar Gaurav"
git config --global user.email "the-email-you-use-on-github@example.com"
git config --global init.defaultBranch main
git config --global core.autocrlf input
```

> Use the **same email as your GitHub account**, otherwise GitHub won't link your commits
> to your profile. `core.autocrlf input` stops Windows from rewriting line endings, which
> is a classic source of "why did every file change" diffs.

---

## Part 3 — Let git talk to GitHub

Git can no longer use your account password. Pick **one** of these.

### Option A — GitHub CLI (easiest, recommended)

1. Install: https://cli.github.com  (Windows: `winget install --id GitHub.cli`)
2. Then:

```bash
gh auth login
```

Answer: **GitHub.com** → **HTTPS** → **Login with a web browser** → copy the one-time
code it shows → paste it in the browser tab that opens → **Authorize**.

Done. Test it:

```bash
gh auth status
```

### Option B — Personal Access Token

1. Go to https://github.com/settings/tokens?type=beta → **Generate new token** (Fine-grained)
2. Name: `studypalace-laptop` · Expiration: 90 days (or longer)
3. **Repository access** → *Only select repositories* → `studypalace-`
4. **Permissions → Repository permissions → Contents** → **Read and write**
5. Generate → **copy the token immediately** (you cannot see it again)
6. The first time you `git push`, a login window appears:
   - Username: `SahilkumarGaurav`
   - Password: **paste the token** (not your GitHub password)

---

## Part 4 — ⚠️ Create `.gitignore` BEFORE anything else

This is the step that protects you. Without it, `git add -A` will try to upload
**40,000 `node_modules` files**, your **customer database**, and potentially your
**Razorpay keys**.

In your `studypalace` folder, create a file named exactly **`.gitignore`**
(leading dot, no `.txt` at the end) containing:

```gitignore
# dependencies
/node_modules
/.pnp
.pnp.js

# next
/.next/
/out/
next-env.d.ts

# production
/build

# secrets — NEVER commit these
.env
.env*.local

# misc
.DS_Store
Thumbs.db
*.pem
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# vercel
.vercel

# typescript
*.tsbuildinfo

# ---- StudyPalace runtime data: your customers and your products ----
/data
/uploads
/backup

# the self-extracting installer bundle
studypalace-install.sh
github-fix.zip
```

**How to create it:**

- **VS Code** (best): `code .` inside the folder → right-click → New File → `.gitignore` → paste → save
- **Windows Notepad**: Save As → *Save as type* = **All Files (\*.\*)** → filename `.gitignore`
  (if it becomes `.gitignore.txt`, rename it in a terminal: `mv .gitignore.txt .gitignore`)
- **Mac**: `nano .gitignore` → paste → Ctrl+O, Enter, Ctrl+X

> `.gitignore` already exists in the folder you downloaded — just open it and confirm
> the `/data` and `/uploads` lines are there.

---

## Part 5 — Push (overwrites the broken repo)

Open a terminal **inside** your `studypalace` folder:

- Windows: open the folder in Explorer → click the address bar → type `cmd` → Enter
- Mac: right-click the folder → *New Terminal at Folder*

```bash
cd ~/Desktop/studypalace        # adjust to wherever you put it
```

### 🛑 Step 5a — DRY RUN FIRST. Do not skip this.

```bash
git init
git add -A
git status --short | wc -l
git status --short | grep -E 'node_modules|\.next/|^A  data/|^A  uploads/|\.env\.local|\.pem' || echo "✓ clean — no junk, no secrets staged"
```

- The **count should be roughly 110–130**.
- The second command must print **`✓ clean`**.

**If it prints anything else, STOP.** Run `git rm -r --cached . -q`, fix `.gitignore`,
and redo step 5a. Do not commit until it says clean.

Also eyeball the list:

```bash
git status --short | head -40
```

You should see `app/`, `components/`, `lib/`, `deploy/`, `scripts/`, `public/`,
`middleware.ts`, `package.json`, etc.

### Step 5b — Commit and force-push

```bash
git commit -m "StudyPalace: complete storefront, admin panel and deploy scripts"
git branch -M main
git remote add origin https://github.com/SahilkumarGaurav/studypalace-.git
git push -f origin main
```

> `-f` (force) is intentional and safe **here**: your existing repo only holds a
> half-uploaded copy with no real data. This replaces it wholesale.

### Step 5c — Verify on GitHub

Open https://github.com/SahilkumarGaurav/studypalace-/tree/main/components

You should see **20 `.tsx` files** including `Header.tsx`, `Footer.tsx`,
`ProductGrid.tsx`, `GuideBody.tsx`, `Newsletter.tsx`, and an `admin/` folder.

Also confirm these are **NOT** in the repo: `node_modules`, `.next`, `data`,
`uploads`, `.env.local`.

### Step 5d — Make the repo private (do this)

https://github.com/SahilkumarGaurav/studypalace-/settings → scroll to
**Danger Zone** → **Change repository visibility** → **Private**.

> Note: after this, the server needs authentication to pull. See Part 7.

---

## Part 6 — Get it onto the server

SSH into your Lightsail instance, then:

```bash
sudo rm -rf /opt/studypalace-new
sudo -u ubuntu git clone https://github.com/SahilkumarGaurav/studypalace-.git /opt/studypalace-new
```

If the repo is **private**, git will ask for credentials. Easiest fix on a server:

```bash
sudo -u ubuntu gh auth login          # if you installed gh on the server
```
or embed a read-only token in the URL once:
```bash
sudo -u ubuntu git clone https://YOUR_TOKEN@github.com/SahilkumarGaurav/studypalace-.git /opt/studypalace-new
```

Then swap it in, keeping your data:

```bash
sudo mv /opt/studypalace /opt/studypalace-old
sudo mv /opt/studypalace-new /opt/studypalace
sudo cp -a /opt/studypalace-old/.env.local /opt/studypalace/ 2>/dev/null || true
sudo mkdir -p /opt/studypalace/data /opt/studypalace/uploads
sudo cp -a /opt/studypalace-old/data/.    /opt/studypalace/data/    2>/dev/null || true
sudo cp -a /opt/studypalace-old/uploads/. /opt/studypalace/uploads/ 2>/dev/null || true
sudo chown -R sp:sp /opt/studypalace
ls /opt/studypalace/components/ | wc -l      # must print 20
```

Then build and start:

```bash
cd /opt/studypalace
sudo -u sp npm install --no-audit --no-fund
sudo -u sp npm run build
sudo -u sp pm2 restart studypalace || sudo -u sp pm2 start deploy/ecosystem.config.cjs
```

---

## Part 7 — Your everyday workflow from now on

**Made a change on your laptop?**

```bash
cd ~/Desktop/studypalace
git add -A
git commit -m "what you changed"
git push
```

**Ship it to the live site:**

```bash
ssh -i ~/LightsailDefaultKey.pem ubuntu@YOUR_SERVER_IP
cd /opt/studypalace
sudo -u ubuntu git pull
sudo -u sp npm install --no-audit --no-fund
sudo -u sp npm run build
sudo -u sp pm2 restart studypalace
```

Or from your laptop in one line, using the helper that's already in the repo:

```bash
bash deploy/deploy.sh ubuntu@YOUR_SERVER_IP -i ~/LightsailDefaultKey.pem
```

---

## Troubleshooting

**`fatal: not a git repository`**
You're not inside the project folder. `cd` into it first.

**`remote origin already exists`**
```bash
git remote set-url origin https://github.com/SahilkumarGaurav/studypalace-.git
```

**`Authentication failed` / `403` on push**
Your token expired or lacks **Contents: Read and write**. Make a new one (Part 3, Option B),
then clear the old credential:
- Windows: Control Panel → Credential Manager → Windows Credentials → delete the `github.com` entry
- Mac: Keychain Access → search `github` → delete

**`Updates were rejected because the remote contains work that you do not have`**
You're replacing a bad upload, so force it: `git push -f origin main`

**`warning: LF will be replaced by CRLF`**
Harmless on Windows. `git config --global core.autocrlf input` reduces it.

**git uploaded `node_modules` anyway**
`.gitignore` was created *after* `git add`. Fix:
```bash
git rm -r --cached node_modules .next data uploads
git add -A
git commit -m "remove files that should never have been tracked"
git push
```

**My `.env.local` got committed!**
Treat those keys as compromised. Rotate the Razorpay key in your dashboard, change
`ADMIN_PASSWORD` and `APP_SECRET`, then:
```bash
git rm --cached .env.local
git commit -m "stop tracking .env.local"
git push
```
(Also delete the repo and re-push if you want the secret gone from history entirely.)

**How do I know `.gitignore` is working?**
```bash
git check-ignore -v node_modules .next data uploads .env.local
```
Every line should be listed with `.gitignore:<line number>`. If any prints nothing,
that path is *not* ignored — fix it before committing.
