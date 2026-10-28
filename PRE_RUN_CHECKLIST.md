# Pre-Run Checklist: EC2 → GitHub → Pipeline

Follow this in order. Do **not** run the CI/CD pipeline until steps 1-6 are done.

## 1) Create and connect to EC2
- [ ] **Launch EC2**: Ubuntu 22.04/24.04, t3.medium or larger (min 4GB RAM recommended). Enable swap (bootstrap will create 4GB swap).
- [ ] **Security Group**: Allow SSH (22) from your IP. Allow HTTP (80) from anywhere if you want public access. **Do NOT** open 9000 publicly (SonarQube stays on 127.0.0.1). 
- [ ] **Get key pair**: Download `.pem` file (e.g. `mern-key.pem`). Keep it safe.
- [ ] **Connect via SSH**:
```bash
chmod 400 mern-key.pem
ssh -i mern-key.pem ubuntu@<EC2_PUBLIC_IP>
```
- [ ] **Update packages** (optional): `sudo apt update && sudo apt upgrade -y`

## 2) Push this repo to GitHub
- [ ] **Create repo**: Create a new repo on GitHub (e.g. `mern-crash-course`)
- [ ] **Initialize git locally** (from repo root):
```bash
git init
git add .
git commit -m "Initial commit with secure CI/CD pipeline"
git branch -M main
git remote add origin https://github.com/<YOUR_GITHUB_USERNAME>/<YOUR_REPO_NAME>.git
git push -u origin main
```
- [ ] **Verify**: Check GitHub shows all files including `.github/workflows/`, `infra/`, `scripts/`

## 3) Create all GitHub Secrets
Go to `GitHub Repo → Settings → Secrets and variables → Actions → Secrets → New repository secret`

| Secret | Value | Notes |
| --- | --- | --- |
| `EC2_HOST` | `<EC2_PUBLIC_IP>` or `<EC2_PRIVATE_IP>` | Host used by `infra-bootstrap.yml` to SSH in |
| `EC2_USER` | `ubuntu` | SSH user for Ubuntu EC2 |
| `EC2_SSH_KEY` | Contents of `mern-key.pem` | Copy the **entire** PEM file including `-----BEGIN RSA PRIVATE KEY-----` and `-----END RSA PRIVATE KEY-----` |
| `SONAR_ADMIN_PASSWORD` | `<strong-password>` | **You choose this**. Bootstrap will change SonarQube admin password from `admin` to this. Use a strong unique password. |
| `GH_PAT` | `<github-pat>` | GitHub PAT with `repo`, `workflow` (classic) OR fine-grained with Actions/Secrets/Variables/Administration write. Needed for runner registration and syncing `SONAR_TOKEN`. |
| `SONAR_TOKEN` | *(leave empty for now OR add later)* | Bootstrap will create this and sync it. If bootstrap sync fails, you'll add it manually. |
| `NVD_API_KEY` | `<nvd-api-key>` | Get from https://nvd.nist.gov/developers/request-an-api-key (free). Speeds up Dependency-Check. |
| `DOCKERHUB_USERNAME` | `<dockerhub-username>` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | `<dockerhub-token>` | Docker Hub Access Token (Settings → Security → New Access Token). **Not** your password. |
| `MONGO_ROOT_USERNAME` | `<mongo-user>` | **URL-safe**: 3-32 chars, letters/digits/./_/- only |
| `MONGO_ROOT_PASSWORD` | `<mongo-pass>` | **URL-safe**: 24-128 chars, letters/digits/./_/-/~ only. Must not contain `@`, `:`, `/`, `?`, `#`, `[`, `]` etc. |

## 4) Create GitHub Variable (optional but recommended)
Go to `GitHub Repo → Settings → Secrets and variables → Actions → Variables → New repository variable`

| Variable | Value | Notes |
| --- | --- | --- |
| `SONAR_HOST_URL` | `http://127.0.0.1:9000` | Bootstrap will try to sync this, but safe to add now. |

## 5) Bootstrap the EC2 (Infrastructure Setup)
1. Go to `GitHub Repo → Actions → Infrastructure Bootstrap → Run workflow`
2. Set `install_runner` to `true` (default)
3. Click `Run workflow`
4. Watch the logs. This takes **15-30 minutes** (installs packages, starts SonarQube, configures everything)

**What bootstrap does:**
- Installs Docker, Docker Compose, Trivy 0.76.1, SonarScanner CLI
- Creates 4GB swap, sets `vm.max_map_count=262144`
- Starts SonarQube + Postgres on `127.0.0.1:9000`
- Changes admin password using `SONAR_ADMIN_PASSWORD`
- Creates project `mern-crash-course`
- Creates quality gate `security-gate` with: `new_security_rating GT 1`, `new_vulnerabilities GT 0`, `new_bugs GT 0`, `new_security_hotspots_reviewed LT 100`
- Generates CI token (`ci-<timestamp>`) and saves to `/opt/sonarqube/.sonar-token`
- Registers self-hosted runner with label `mern-prod`
- Syncs `SONAR_TOKEN` secret and `SONAR_HOST_URL` variable to GitHub (using `GH_PAT`)

## 6) Verify runner is ready
1. Go to `GitHub Repo → Settings → Actions → Runners`
2. You should see a runner like `mern-prod-<hostname>` with status **Idle** and labels `self-hosted`, `linux`, `x64`, `mern-prod`
3. If it's offline, SSH to EC2 and check:
```bash
sudo systemctl status actions.runner.*.service
sudo journalctl -u actions.runner.* -n 20 --no-pager
```

## 7) Run the CI/CD Pipeline
1. Go to `GitHub Repo → Actions → Build, Scan, and Deploy → Run workflow`
2. Leave `run_dast` as `true` (default)
3. Click `Run workflow`
4. Monitor all 7 stages

## 8) After pipeline succeeds
- **App URL**: `http://<EC2_PUBLIC_IP>` (port 80)
- **SonarQube**: `http://127.0.0.1:9000` on EC2 (only accessible locally on runner). SonarQube will **remain running** after SAST stage now.
- **Reports**: Check GitHub Actions artifacts (`sast-reports`, `dependency-reports`, `image-reports`, `dast-reports`)

## Troubleshooting tips
- **Runner offline**: SSH to EC2, restart runner service or rerun bootstrap with `install_runner=true`
- **SonarQube won't start**: Check `vm.max_map_count` and memory. Bootstrap sets these. SSH: `sysctl vm.max_map_count`
- **Mongo URI issues**: Double check `MONGO_ROOT_USERNAME` and `MONGO_ROOT_PASSWORD` are URL-safe
- **Dependency-Check slow**: Add/update `NVD_API_KEY` if missing
- **WSL bash broken locally**: Use Git Bash `C:\Program Files\Git\bin\bash.exe`
- **ZAP fails**: Only runs on throwaway staging stack on 127.0.0.1:8080 - never touches production
- **If SONAR_TOKEN sync failed**: SSH to EC2 `sudo cat /opt/sonarqube/.sonar-token` and manually add to GitHub Secrets as `SONAR_TOKEN`

## Quick check before running pipeline
- [ ] All secrets added
- [ ] Runner online with `mern-prod` label
- [ ] Bootstrap completed successfully
- [ ] Repo pushed to GitHub
- [ ] EC2 connected and accessible
