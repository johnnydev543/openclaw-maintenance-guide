#!/usr/bin/env bash
# Build, validate, activate, and recreate the OpenClaw sandbox image.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="${SCRIPT_DIR}/../sandbox"
VERSION="${1:-$(date +%F)}"
IMAGE_TAG="openclaw-sandbox:tools-${VERSION}"
IMAGE_CONFIG_PATH="agents.defaults.sandbox.docker.image"

if [[ ! "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Version must contain only letters, digits, dots, underscores, or hyphens." >&2
  exit 2
fi

for command in docker openclaw; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

[[ -f "${SANDBOX_DIR}/Dockerfile" ]] || {
  echo "Sandbox Dockerfile not found: ${SANDBOX_DIR}/Dockerfile" >&2
  exit 1
}

if grep -Eq '^[[:space:]]*[^#[:space:]]' "${SANDBOX_DIR}/pip-packages.txt" \
  && ! grep -Eq '^[[:space:]]*python3-pip([[:space:]]|$)' "${SANDBOX_DIR}/apt-packages.txt"; then
  echo "pip-packages.txt contains packages, so apt-packages.txt must include python3-pip." >&2
  exit 1
fi

if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "Refusing to overwrite existing image: $IMAGE_TAG" >&2
  echo "Choose a new version, for example: $0 ${VERSION}-r2" >&2
  exit 1
fi

echo "Building ${IMAGE_TAG}"
docker build \
  --file "${SANDBOX_DIR}/Dockerfile" \
  --tag "$IMAGE_TAG" \
  "$SANDBOX_DIR"

echo "Applying image setting"
openclaw config set "$IMAGE_CONFIG_PATH" "\"${IMAGE_TAG}\"" --strict-json

echo "Validating configuration"
openclaw config validate

echo "Restarting Gateway and recreating managed sandboxes"
openclaw gateway restart
openclaw sandbox recreate --all
openclaw sandbox list

echo
echo "Complete: ${IMAGE_TAG} is now the configured sandbox image."
