#!/usr/bin/env bash
set -euo pipefail

: "${GH_PAT:?GH_PAT is required to register the runner}"
: "${REPO_SLUG:?REPO_SLUG is required, for example owner/repo}"

RUNNER_USER="${RUNNER_USER:-github-runner}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_VERSION="${RUNNER_VERSION:-2.328.0}"

log() {
	printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
	log "Creating runner user ${RUNNER_USER}"
	useradd -m -s /bin/bash "$RUNNER_USER"
fi

usermod -aG docker "$RUNNER_USER"

if command -v curl >/dev/null 2>&1; then
	latest_version=$(curl -fsSL \
		-H "Authorization: Bearer ${GH_PAT}" \
		-H "Accept: application/vnd.github+json" \
		"https://api.github.com/repos/actions/runner/releases/latest" 2>/dev/null \
		| jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//' || true)
	if [ -n "${latest_version:-}" ]; then
		RUNNER_VERSION="$latest_version"
	fi
fi

log "Installing GitHub Actions runner ${RUNNER_VERSION}"

if [ -x "${RUNNER_DIR}/svc.sh" ]; then
	"${RUNNER_DIR}/svc.sh" stop >/dev/null 2>&1 || true
	"${RUNNER_DIR}/svc.sh" uninstall >/dev/null 2>&1 || true
fi

rm -rf "$RUNNER_DIR"
mkdir -p "$RUNNER_DIR"

archive="/tmp/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
curl -fsSL \
	-H "Authorization: Bearer ${GH_PAT}" \
	-o "$archive" \
	"https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

tar -xzf "$archive" -C "$RUNNER_DIR"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"
rm -f "$archive"

registration_token=$(curl -fsSL \
	-X POST \
	-H "Authorization: Bearer ${GH_PAT}" \
	-H "Accept: application/vnd.github+json" \
	"https://api.github.com/repos/${REPO_SLUG}/actions/runners/registration-token" \
	| jq -r '.token // empty')

if [ -z "$registration_token" ]; then
	echo "ERROR: could not obtain a runner registration token" >&2
	exit 1
fi

log "Registering runner with ${REPO_SLUG}"
runuser -u "$RUNNER_USER" -- "${RUNNER_DIR}/config.sh" \
	--url "https://github.com/${REPO_SLUG}" \
	--token "$registration_token" \
	--name "mern-prod-$(hostname -s)" \
	--labels "mern-prod" \
	--work "_work" \
	--unattended \
	--replace

log "Installing and starting the runner service"
cd "$RUNNER_DIR"
./svc.sh install "$RUNNER_USER"
./svc.sh start
systemctl --no-pager --full status "actions.runner.$(printf '%s' "$REPO_SLUG" | tr '/' '-').mern-prod-$(hostname -s).service" 2>/dev/null || true

log "Runner installation complete"
