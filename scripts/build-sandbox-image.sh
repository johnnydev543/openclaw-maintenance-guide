#!/usr/bin/env bash
# Build, validate, activate, and recreate the OpenClaw sandbox image.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="${SCRIPT_DIR}/../sandbox"
VERSION=""
INSTALL_PLAYWRIGHT_CHROMIUM=0
IMAGE_CONFIG_PATH="agents.defaults.sandbox.docker.image"
BUILD_DIR=""
BASE_APT_PACKAGES=(
  ca-certificates curl file git jq procps python3 python3-pip ripgrep unzip zip
)
BASE_PIP_PACKAGES=(
  beautifulsoup4==4.13.4 httpx==0.28.1 requests==2.32.5
)

cleanup() {
  [[ -z "$BUILD_DIR" ]] || rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: build-sandbox-image.sh [version] [--playwright-chromium]

Builds, activates, and recreates OpenClaw sandboxes.
Use --playwright-chromium only when the local pip package list contains playwright.
USAGE
}

for argument in "$@"; do
  case "$argument" in
    --playwright-chromium) INSTALL_PLAYWRIGHT_CHROMIUM=1 ;;
    --help|-h) usage; exit 0 ;;
    -*) echo "Unknown option: $argument" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "Only one image version may be supplied." >&2
        usage >&2
        exit 2
      fi
      VERSION="$argument"
      ;;
  esac
done

VERSION="${VERSION:-$(date +%F)}"
IMAGE_TAG="openclaw-sandbox:tools-${VERSION}"

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

BUILD_DIR="$(mktemp -d)"
cp "${SANDBOX_DIR}/Dockerfile" "${BUILD_DIR}/Dockerfile"
printf '%s\n' "${BASE_APT_PACKAGES[@]}" > "${BUILD_DIR}/apt-packages.txt"
printf '%s\n' "${BASE_PIP_PACKAGES[@]}" > "${BUILD_DIR}/pip-packages.txt"

for packages_file in apt-packages.txt pip-packages.txt; do
  local_file="${SANDBOX_DIR}/${packages_file}"
  if [[ -f "$local_file" ]]; then
    printf '\n# Local packages (not tracked by Git)\n' >> "${BUILD_DIR}/${packages_file}"
    cat "$local_file" >> "${BUILD_DIR}/${packages_file}"
  fi
done

if grep -Eq '^[[:space:]]*[^#[:space:]]' "${BUILD_DIR}/pip-packages.txt" \
  && ! grep -Eq '^[[:space:]]*python3-pip([[:space:]]|$)' "${BUILD_DIR}/apt-packages.txt"; then
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
  --file "${BUILD_DIR}/Dockerfile" \
  --build-arg "INSTALL_PLAYWRIGHT_CHROMIUM=${INSTALL_PLAYWRIGHT_CHROMIUM}" \
  --tag "$IMAGE_TAG" \
  "$BUILD_DIR"

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
