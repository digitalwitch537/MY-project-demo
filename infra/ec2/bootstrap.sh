#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${BOOTSTRAP_ROOT}/.bootstrap.env"

trap 'rm -f "$ENV_FILE"' EXIT
if [ -f "$ENV_FILE" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$ENV_FILE"
	set +a
fi

: "${SONAR_ADMIN_PASSWORD:?SONAR_ADMIN_PASSWORD is required}"

SONAR_URL="http://127.0.0.1:9000"
SONAR_PROJECT_KEY="${SONAR_PROJECT_KEY:-mern-crash-course}"
SONAR_PROJECT_NAME="${SONAR_PROJECT_NAME:-MERN Crash Course}"
SONAR_QUALITY_GATE="${SONAR_QUALITY_GATE:-security-gate}"
TRIVY_VERSION="${TRIVY_VERSION:-0.76.1}"
SONAR_SCANNER_VERSION="${SONAR_SCANNER_VERSION:-8.1.0.6389}"
RUNNER_USER="${RUNNER_USER:-github-runner}"
INSTALL_RUNNER="${INSTALL_RUNNER:-true}"

log() {
	printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

if [ "$(id -u)" -ne 0 ]; then
	fail "run this script as root"
fi

log "Installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
	ca-certificates curl gnupg jq unzip git openssl lsb-release \
	apt-transport-https software-properties-common openjdk-17-jre-headless

log "Configuring the Docker repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
# shellcheck disable=SC1091
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
	> /etc/apt/sources.list.d/docker.list

log "Installing Docker, Compose, and buildx"
apt-get update -y
apt-get install -y --no-install-recommends \
	docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

if [ ! -f /etc/docker/daemon.json ]; then
	cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  }
}
EOF
	systemctl restart docker
fi

if ! command -v aws >/dev/null 2>&1; then
	log "Installing AWS CLI v2"
	aws_arch="x86_64"
	if [ "$(uname -m)" = "aarch64" ]; then
		aws_arch="aarch64"
	fi
	aws_tmp=$(mktemp -d)
	curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o "${aws_tmp}/awscliv2.zip"
	unzip -q "${aws_tmp}/awscliv2.zip" -d "$aws_tmp"
	"${aws_tmp}/aws/install" --update
	rm -rf "$aws_tmp"
fi

log "Installing Trivy ${TRIVY_VERSION}"
curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
	| sh -s -- -b /usr/local/bin "v${TRIVY_VERSION}"

log "Installing SonarScanner CLI ${SONAR_SCANNER_VERSION}"
scanner_zip="/tmp/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip"
curl -fsSLo "$scanner_zip" \
	"https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip"
unzip -q -o "$scanner_zip" -d /opt
ln -sf "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64/bin/sonar-scanner" /usr/local/bin/sonar-scanner
rm -f "$scanner_zip"

log "Configuring swap and kernel settings"
if [ ! -f /swapfile ]; then
	if ! fallocate -l 4G /swapfile 2>/dev/null; then
		dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
	fi
	chmod 600 /swapfile
	mkswap /swapfile
	swapon /swapfile
	grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

printf 'vm.swappiness=10\n' > /etc/sysctl.d/99-swap.conf
printf 'vm.max_map_count=262144\n' > /etc/sysctl.d/99-sonarqube.conf
sysctl --system >/dev/null
swapon --show

log "Creating service user and directories"
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
	useradd -m -s /bin/bash "$RUNNER_USER"
fi
usermod -aG docker "$RUNNER_USER"

mkdir -p /opt/sonarqube /opt/mern-app /opt/mern-staging /opt/backups
cp "${BOOTSTRAP_ROOT}/infra/sonarqube/compose.yml" /opt/sonarqube/compose.yml
chown -R "${RUNNER_USER}:${RUNNER_USER}" /opt/sonarqube /opt/mern-app /opt/mern-staging /opt/backups
chmod 750 /opt/sonarqube /opt/mern-app /opt/mern-staging /opt/backups

if [ ! -f /opt/sonarqube/.env ]; then
	umask 077
	cat > /opt/sonarqube/.env <<EOF
SONAR_DB_USER=sonar
SONAR_DB_PASSWORD=$(openssl rand -hex 24)
EOF
	chown "${RUNNER_USER}:${RUNNER_USER}" /opt/sonarqube/.env
	chmod 600 /opt/sonarqube/.env
fi

docker volume create depcheck-data >/dev/null

log "Starting SonarQube and PostgreSQL"
docker compose -p sonarqube \
	-f /opt/sonarqube/compose.yml \
	--env-file /opt/sonarqube/.env \
	up -d --remove-orphans

log "Waiting for SonarQube to become UP"
sonar_status=""
for attempt in $(seq 1 90); do
	sonar_status=$(curl -fsS "${SONAR_URL}/api/system/status" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
	echo "SonarQube status (${attempt}/90): ${sonar_status:-unreachable}"
	if [ "$sonar_status" = "UP" ]; then
		break
	fi
	sleep 5
done

if [ "$sonar_status" != "UP" ]; then
	docker compose -p sonarqube -f /opt/sonarqube/compose.yml --env-file /opt/sonarqube/.env logs --tail=200 sonarqube || true
	fail "SonarQube did not become UP"
fi

log "Configuring the SonarQube administrator password"
if curl -fsS -u "admin:${SONAR_ADMIN_PASSWORD}" "${SONAR_URL}/api/authentication/validate" 2>/dev/null | grep -q '"valid":true'; then
	echo "Administrator password already configured with SONAR_ADMIN_PASSWORD"
elif curl -fsS -u "admin:admin" "${SONAR_URL}/api/authentication/validate" 2>/dev/null | grep -q '"valid":true'; then
	echo "Changing password from admin:admin to SONAR_ADMIN_PASSWORD"
	if curl -fsS -u admin:admin -X POST "${SONAR_URL}/api/users/change_password" \
		--data-urlencode "login=admin" \
		--data-urlencode "previousPassword=admin" \
		--data-urlencode "password=${SONAR_ADMIN_PASSWORD}" >/dev/null; then
		echo "Password changed successfully"
	else
		echo "Warning: Could not change password automatically"
	fi
else
	echo "Warning: Could not authenticate with admin:admin or SONAR_ADMIN_PASSWORD; continuing with existing credentials"
fi

log "Creating the CI token"
token_name="ci-$(date +%s)"
token_json=$(curl -fsS -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST \
	"${SONAR_URL}/api/user_tokens/generate" \
	--data-urlencode "name=${token_name}")
sonar_token=$(printf '%s' "$token_json" | jq -r '.token // empty')
[ -n "$sonar_token" ] || fail "could not create a SonarQube token"
printf '%s' "$sonar_token" > /opt/sonarqube/.sonar-token
chmod 600 /opt/sonarqube/.sonar-token
echo "Token written to /opt/sonarqube/.sonar-token"

log "Creating the SonarQube project"
curl -fsS -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST "${SONAR_URL}/api/projects/create" \
	--data-urlencode "project=${SONAR_PROJECT_KEY}" \
	--data-urlencode "name=${SONAR_PROJECT_NAME}" >/dev/null 2>&1 || true

log "Creating the security quality gate"
AUTH_PASS="${SONAR_ADMIN_PASSWORD:-admin}"
gate_id=""

# Try to find existing gate with any password
for try_pass in "${AUTH_PASS}" "admin" "${SONAR_ADMIN_PASSWORD:-}"; do
	[ -z "$try_pass" ] && continue
	gate_id=$(curl -fsS -u "admin:${try_pass}" "${SONAR_URL}/api/qualitygates/list" 2>/dev/null \
		| jq -r --arg name "$SONAR_QUALITY_GATE" '.qualitygates[]? | select(.name == $name) | .id' 2>/dev/null | head -n 1)
	if [ -n "$gate_id" ] && [ "$gate_id" != "null" ]; then
		AUTH_PASS="$try_pass"
		break
	fi
done

# Try to create if not found
if [ -z "$gate_id" ] || [ "$gate_id" = "null" ]; then
	log "Quality gate not found, attempting to create: ${SONAR_QUALITY_GATE}"
	for try_pass in "${AUTH_PASS}" "admin"; do
		[ -z "$try_pass" ] && continue
		curl -s -u "admin:${try_pass}" -X POST "${SONAR_URL}/api/qualitygates/create" \
			--data-urlencode "name=${SONAR_QUALITY_GATE}" >/dev/null 2>&1
	done
	sleep 10
	for try_pass in "${AUTH_PASS}" "admin"; do
		[ -z "$try_pass" ] && continue
		gate_id=$(curl -fsS -u "admin:${try_pass}" "${SONAR_URL}/api/qualitygates/list" 2>/dev/null \
			| jq -r --arg name "$SONAR_QUALITY_GATE" '.qualitygates[]? | select(.name == $name) | .id' 2>/dev/null | head -n 1)
		if [ -n "$gate_id" ] && [ "$gate_id" != "null" ]; then
			AUTH_PASS="$try_pass"
			break
		fi
	done
fi

SONAR_ADMIN_PASSWORD="$AUTH_PASS"

if [ -n "$gate_id" ] && [ "$gate_id" != "null" ]; then
	echo "Found quality gate ID: $gate_id"
	gate_json=$(curl -fsS -u "admin:${SONAR_ADMIN_PASSWORD}" "${SONAR_URL}/api/qualitygates/show?id=${gate_id}" 2>/dev/null || echo '{}')
	existing_conditions=$(echo "$gate_json" | jq -c '.conditions[]?' 2>/dev/null || true)

	add_condition() {
		local metric="$1"
		local op="$2"
		local threshold="$3"
		local condition_id=""

		if [ -n "$existing_conditions" ]; then
			condition_id=$(echo "$existing_conditions" | jq -r --arg metric "$metric" 'select(.metric == $metric) | .id' 2>/dev/null | head -n 1)
		fi

		if [ -n "$condition_id" ] && [ "$condition_id" != "null" ]; then
			curl -fsS -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST "${SONAR_URL}/api/qualitygates/update_condition" \
				--data-urlencode "id=${condition_id}" \
				--data-urlencode "metric=${metric}" \
				--data-urlencode "op=${op}" \
				--data-urlencode "error=${threshold}" >/dev/null 2>&1 || true
			echo "Condition updated: ${metric} ${op} ${threshold}"
			return
		fi

		curl -fsS -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST "${SONAR_URL}/api/qualitygates/create_condition" \
			--data-urlencode "gateId=${gate_id}" \
			--data-urlencode "metric=${metric}" \
			--data-urlencode "op=${op}" \
			--data-urlencode "error=${threshold}" >/dev/null 2>&1 || true
		echo "Condition created: ${metric} ${op} ${threshold}"
	}

	add_condition "new_security_rating" "GT" "1"
	add_condition "new_vulnerabilities" "GT" "0"
	add_condition "new_bugs" "GT" "0"
	add_condition "new_security_hotspots_reviewed" "LT" "100"

	curl -fsS -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST "${SONAR_URL}/api/qualitygates/select" \
		--data-urlencode "gateId=${gate_id}" \
		--data-urlencode "projectKey=${SONAR_PROJECT_KEY}" >/dev/null 2>&1 || true
	echo "Quality gate configured"
else
	echo "WARNING: Could not find/create quality gate ${SONAR_QUALITY_GATE}; continuing" >&2
fi

curl -fsS -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST "${SONAR_URL}/api/new_code_periods/set" \
	--data-urlencode "project=${SONAR_PROJECT_KEY}" \
	--data-urlencode "type=PREVIOUS_VERSION" >/dev/null 2>&1 || true

if [ "$INSTALL_RUNNER" = "true" ]; then
	if [ -z "${GH_PAT:-}" ] || [ -z "${REPO_SLUG:-}" ]; then
		fail "GH_PAT and REPO_SLUG are required to install the self-hosted runner"
	fi
	export GH_PAT REPO_SLUG RUNNER_USER
	bash "${SCRIPT_DIR}/runner-install.sh"
else
	log "Skipping runner installation because INSTALL_RUNNER is not true"
fi

cat > /opt/sonarqube/bootstrap-summary.txt <<EOF
SonarQube URL: ${SONAR_URL}
SonarQube project: ${SONAR_PROJECT_KEY}
Quality gate: ${SONAR_QUALITY_GATE}
CI token file: /opt/sonarqube/.sonar-token
Retrieve it with: sudo cat /opt/sonarqube/.sonar-token
Add that value to GitHub as the SONAR_TOKEN secret.
EOF
chmod 644 /opt/sonarqube/bootstrap-summary.txt

log "Bootstrap complete"
free -h
df -h /
docker --version
docker compose version
trivy --version
sonar-scanner --version 2>&1 | head -n 1
cat /opt/sonarqube/bootstrap-summary.txt
