# MERN Crash Course — Secure CI/CD

This repo ships a MERN app with a security-focused CI/CD pipeline designed to run on a self-hosted EC2 runner (`[self-hosted, linux, x64, mern-prod]`).

## Architecture
- `backend/` Express API on port `5000` with `/api/health` and MongoDB
- `frontend/` React (Vite) built and served by nginx (unprivileged, port `8080`)
- `docker-compose.yml` production stack (Mongo, backend, frontend on port `80`)
- `docker-compose.staging.yml` throwaway staging stack for DAST (binds `127.0.0.1:${STAGING_PORT:-8080}:8080`)
- `infra/sonarqube/compose.yml` SonarQube + Postgres (localhost only)

## Required GitHub Secrets
| Secret | Purpose |
| --- | --- |
| `EC2_HOST` | EC2 public/private host for bootstrap |
| `EC2_USER` | SSH user (Ubuntu) |
| `EC2_SSH_KEY` | PEM private key for SSH |
| `SONAR_ADMIN_PASSWORD` | SonarQube admin password set by bootstrap |
| `GH_PAT` | GitHub PAT with repo/admin scope for runner registration and secret sync |
| `SONAR_TOKEN` | SonarQube CI token (synced by bootstrap or set manually) |
| `NVD_API_KEY` | NVD API key for OWASP Dependency-Check |
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token |
| `MONGO_ROOT_USERNAME` | Production Mongo root username (3-32 chars, URL-safe) |
| `MONGO_ROOT_PASSWORD` | Production Mongo root password (24-128 URL-safe chars: letters/digits/./_/-/~) |

> `MONGO_ROOT_USERNAME`/`MONGO_ROOT_PASSWORD` must be URL-safe because the Mongo URI is interpolated in docker-compose. SonarQube is accessed only via `127.0.0.1:9000` on the runner.

## Required GitHub Variables
| Variable | Purpose | Default |
| --- | --- | --- |
| `SONAR_HOST_URL` | SonarQube URL | `http://127.0.0.1:9000` (synced by bootstrap) |

## Bootstrap (one-time)
1. Provision Ubuntu EC2 (4 GB RAM recommended; 4 GB swap is configured by bootstrap). Open required SG rules (SSH, HTTP 80 as needed).
2. Run **Infrastructure Bootstrap** workflow (`infra-bootstrap.yml`):
   - Copies `infra/`, `scripts/`, compose files to `/opt/mern-bootstrap/`
   - Uploads `.bootstrap.env` with `SONAR_ADMIN_PASSWORD`, `GH_PAT`, `REPO_SLUG`, `INSTALL_RUNNER`
   - Runs `infra/ec2/bootstrap.sh` as root (installs Docker/Compose, Trivy, SonarScanner, configures swap/kernel, starts SonarQube, creates project/quality gate, optionally installs self-hosted runner)
   - Retrieves Sonar token and syncs `SONAR_TOKEN` secret + `SONAR_HOST_URL` variable via `gh`
3. After bootstrap, retrieve token if needed: `sudo cat /opt/sonarqube/.sonar-token` on EC2. `.bootstrap.env` is removed after use.

Runner is registered with labels `[mern-prod]` (see `infra/ec2/runner-install.sh`).

## Pipeline (`.github/workflows/ci-cd.yml`)
Runs on push to `main`, PRs (with repo check), or manual dispatch with `run_dast` (default true).

Order:
1. **Preflight** - checks secrets, AWS identity (optional), ensures SonarQube UP, Docker Hub login
2. **SAST + quality gate** - `npm ci` (root + frontend), SonarQube scan via `scripts/sonar-scan.sh` (local scanner or Docker fallback), waits for quality gate, stops SonarQube
3. **Dependency and file scans** - npm audit, Trivy FS/config (HIGH/CRITICAL, ignores unfixed), OWASP Dependency-Check (13.0.0, NVD API key), converts Dependency-Check to Sonar external issues (`scripts/depcheck-to-sonar.mjs` -> `reports/sonar-external-issues.json`, `dast/dependency-findings.js`), uploads artifacts/SARIF
4. **Build, scan, push** (non-PR) - build backend/frontend images, Trivy image scan (HIGH/CRITICAL, ignores unfixed), generate SBOMs, push to Docker Hub only if scans pass
5. **Deploy production** (non-PR, `environment: production`) - write `/opt/mern-app/.env` with prod creds, `docker compose up -d`, smoke test via `scripts/smoke-test.sh` (full API test) with rollback on failure, prune images
6. **DAST + Sonar import** (non-PR, non-dispatch-disabled) - download dependency DAST source, start staging (`docker-compose.staging.yml`, throwaway creds on `127.0.0.1:8080`), run ZAP full scan (`zap-full-scan.py`, `-P 8090`, `-m 2`, `-T 10`, `-j`, `-I`, config `scripts/zap-rules.tsv`), tear down staging, merge ZAP findings into `reports/sonar-external-issues.json` via `scripts/zap-to-sonar.mjs`, start SonarQube, import external issues + quality gate, enforce gate (fail if ZAP exit !=0, high-risk alerts >0, or Sonar gate fails), stop SonarQube
7. **Final report** - summarize all stages

Quality gate `security-gate` includes: `new_security_rating GT 1`, `new_vulnerabilities GT 0`, `new_bugs GT 0`, `new_security_hotspots_reviewed LT 100`.

## Local validation
Use the temp binaries on this machine:
- actionlint: `C:\Users\SANDRA\AppData\Local\Temp\opencode\actionlint\actionlint.exe`
- shellcheck: `C:\Users\SANDRA\AppData\Local\Temp\opencode\shellcheck\shellcheck.exe`
- Trivy: `C:\Users\SANDRA\AppData\Local\Temp\opencode\trivy\trivy.exe`
- Git Bash: `C:\Program Files\Git\bin\bash.exe` (WSL bash is broken)

Commands:
```bash
actionlint -config-file .github/actionlint.yaml .github/workflows/ci-cd.yml .github/workflows/infra-bootstrap.yml
shellcheck scripts/*.sh infra/ec2/*.sh
bash -n scripts/*.sh infra/ec2/*.sh
node --check backend/server.js scripts/depcheck-to-sonar.mjs scripts/zap-to-sonar.mjs
docker compose config --quiet -f docker-compose.yml --env-file .env.example
docker compose config --quiet -p mern-staging -f docker-compose.staging.yml --env-file .env.example
docker compose config --quiet -p sonarqube -f infra/sonarqube/compose.yml --env-file .env.example
trivy config --quiet --skip-dirs reports .
trivy fs --quiet --scanners secret --skip-dirs reports --skip-dirs node_modules --skip-dirs frontend/node_modules .
```

## Manual EC2 caveats
- Ensure security groups allow SSH, HTTP 80 (and restrict SonarQube/ZAP to localhost)
- Bootstrap installs Docker, configures 4 GB swap, sets `vm.max_map_count=262144` for SonarQube
- SonarQube runs on `127.0.0.1:9000` only; pipeline stops it after SAST and after DAST to save memory
- Mongo credentials must be URL-safe; staging uses throwaway credentials
- Trivy pinned to `0.76.1` on EC2; use native binary locally if Docker scan hangs
- ZAP full scan targets staging only (`http://127.0.0.1:8080`), runs active scans
- External Sonar issues require `rules` + `issues` format; converters write to `dast/` and merge in DAST stage
- Frontend runs as non-root (`USER 101`), backend runs as `node`
- `dast/dependency-findings.js` and `reports/` are ignored by git
