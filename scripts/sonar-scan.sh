#!/usr/bin/env bash
set -euo pipefail

: "${SONAR_TOKEN:?SONAR_TOKEN is required}"
: "${SONAR_HOST_URL:?SONAR_HOST_URL is required}"
: "${SONAR_PROJECT_KEY:=mern-crash-course}"

echo "================================================================"
echo " SonarQube scan"
echo " Host:    ${SONAR_HOST_URL}"
echo " Project: ${SONAR_PROJECT_KEY}"
echo " Time:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================"

ARGS=(
	"-Dsonar.host.url=${SONAR_HOST_URL}"
	"-Dsonar.token=${SONAR_TOKEN}"
	"-Dsonar.projectKey=${SONAR_PROJECT_KEY}"
	"-Dsonar.qualitygate.wait=true"
	"-Dsonar.qualitygate.timeout=300"
)

for arg in "$@"; do
	ARGS+=("$arg")
done

if command -v sonar-scanner >/dev/null 2>&1; then
	echo "Using local sonar-scanner: $(sonar-scanner --version 2>&1 | head -n 1)"
	exec sonar-scanner "${ARGS[@]}"
fi

echo "sonar-scanner is not installed; falling back to the official Docker image"
exec docker run --rm --network host \
	-v "${PWD}:/usr/src" \
	-w /usr/src \
	-e SONAR_HOST_URL \
	-e SONAR_TOKEN \
	sonarsource/sonar-scanner-cli:12.3.0.4285_8.1.0 \
	"${ARGS[@]}"
