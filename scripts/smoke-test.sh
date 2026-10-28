#!/usr/bin/env bash
set -euo pipefail

HEALTH_ONLY=false
if [ "${1:-}" = "--health-only" ]; then
	HEALTH_ONLY=true
	shift
fi

BASE_URL="${1:-http://localhost}"
ATTEMPTS="${2:-30}"
BASE_URL="${BASE_URL%/}"

for tool in curl jq; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "ERROR: $tool is required" >&2
		exit 1
	}
done

echo "================================================================"
echo " Smoke test: ${BASE_URL} (${ATTEMPTS} attempts)"
echo "================================================================"

ready=false
for attempt in $(seq 1 "$ATTEMPTS"); do
	echo "Waiting for ${BASE_URL}/api/health (attempt ${attempt}/${ATTEMPTS})..."
	if response=$(curl -fsS "${BASE_URL}/api/health" 2>/dev/null); then
		echo "Health response: ${response}"
		if [ "$(printf '%s' "$response" | jq -r '.status // empty')" = "ok" ]; then
			ready=true
			break
		fi
	fi
	sleep 5
done

if [ "$ready" != "true" ]; then
	echo "ERROR: application did not become healthy" >&2
	exit 1
fi

if [ "$HEALTH_ONLY" = "true" ]; then
	if ! curl -fsS "${BASE_URL}/healthz" >/dev/null; then
		echo "ERROR: frontend health endpoint did not respond" >&2
		exit 1
	fi
	echo "Health-only check passed"
	exit 0
fi

echo "Checking frontend..."
html=$(curl -fsS "${BASE_URL}/")
printf '%s' "$html" | grep -qi '<div id="root"' || {
	echo "ERROR: frontend root element was not found" >&2
	exit 1
}
echo "Frontend responded with the expected HTML shell"

product_id=""
cleanup() {
	if [ -n "$product_id" ]; then
		echo "Cleaning up product ${product_id}..."
		curl -sS -X DELETE "${BASE_URL}/api/products/${product_id}" >/dev/null || true
	fi
}
trap cleanup EXIT

echo "Creating a product through the API..."
payload=$(printf '{"name":"smoke-%s","price":1.23,"image":"https://example.com/smoke.png"}' "$(date +%s)")
created=$(curl -fsS -X POST "${BASE_URL}/api/products" \
	-H "Content-Type: application/json" \
	--data "$payload")
echo "Create response: ${created}"
product_id=$(printf '%s' "$created" | jq -r '.data._id // empty')
[ -n "$product_id" ] || {
	echo "ERROR: create product did not return an id" >&2
	exit 1
}

echo "Reading products..."
listed=$(curl -fsS "${BASE_URL}/api/products")
printf '%s' "$listed" | jq -e --arg id "$product_id" '.data[] | select(._id == $id)' >/dev/null || {
	echo "ERROR: created product was not returned by the list endpoint" >&2
	exit 1
}
echo "Product ${product_id} is present in the list"

echo "Deleting the product..."
deleted=$(curl -fsS -X DELETE "${BASE_URL}/api/products/${product_id}")
echo "Delete response: ${deleted}"
printf '%s' "$deleted" | jq -e '.success == true' >/dev/null || {
	echo "ERROR: delete product failed" >&2
	exit 1
}
product_id=""

echo "Smoke test passed"
