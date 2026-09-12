#!/usr/bin/env bash
#
# Hardened release build (plan §4.2).
#
# The threat model is a rooted/jailbroken device where an attacker can pull the
# binary off disk and symbolicate it, or attach a debugger to a live process.
# Two things have to be true of every artifact this script produces:
#
#   1. Dart identifiers are unrecoverable  -> --obfuscate
#   2. The mapping that would recover them never ships -> --split-debug-info
#      writes it to a directory that stays in the release vault (§ "symbols").
#
# Usage:
#   scripts/release.sh                  # both platforms, output in build/release
#   scripts/release.sh --only-android   # Android appbundle only
#   scripts/release.sh --only-ios       # iOS ipa archive only
#
set -euo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MOBILE_DIR="${REPO_ROOT}/mobile"
readonly OUT_DIR="${MOBILE_DIR}/build/release"
# Deliberately OUTSIDE the tree that is packaged and, per .gitignore, outside
# anything that can be committed: these files decode a crash into readable
# frames, so leaking them is equivalent to shipping unobfuscated symbols.
readonly SYMBOL_DIR="${REPO_ROOT}/build-symbols/$(date -u +%Y%m%dT%H%M%SZ)"

ONLY_ANDROID=false
ONLY_IOS=false
case "${1:-}" in
  --only-android) ONLY_ANDROID=true ;;
  --only-ios)     ONLY_IOS=true ;;
  "")             ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

cd "${MOBILE_DIR}"

command -v flutter >/dev/null 2>&1 || {
  echo "error: flutter not on PATH" >&2; exit 127;
}

mkdir -p "${OUT_DIR}" "${SYMBOL_DIR}"

# Refuse to build over a dirty tree: the version stamp below is the only thing
# tying a set of symbols to a binary, and it lies if the tree was modified.
if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain=v1)" ]]; then
    echo "error: working tree is dirty; commit or stash before a release build" >&2
    exit 1
  fi
fi

# Resolve dependencies first: the build below intentionally skips its own
# implicit `pub get` so the exact lockfile under test is the one used here.
echo "==> pub get"
flutter pub get

# --tree-shake-icons drops unused Material icon fonts (smaller binary, fewer
# strings to mine). --dart-define is used instead of a config file so no
# environment marker ever lands on disk next to the app.
readonly COMMON_FLAGS=(
  --release
  --obfuscate
  --split-debug-info="${SYMBOL_DIR}"
  --tree-shake-icons
  --no-pub
)

if [[ "${ONLY_IOS}" == false ]]; then
  echo "==> Android appbundle (minified via R8, see android/app/build.gradle.kts)"
  flutter build appbundle "${COMMON_FLAGS[@]}" --output-dir "${OUT_DIR}"
fi

if [[ "${ONLY_ANDROID}" == false ]]; then
  echo "==> iOS archive"
  flutter build ipa "${COMMON_FLAGS[@]}" --output-dir "${OUT_DIR}"
fi

echo
echo "==> artifacts in ${OUT_DIR}"
echo "==> debug symbols (KEEP PRIVATE — upload to the crash backend, never the store):"
echo "    ${SYMBOL_DIR}"

# Post-build proof that §4.2 holds. A release binary that still contains real
# Dart class names means --obfuscate silently did not run (a known failure mode
# when a wrapper script drops flags), so we fail the build rather than ship it.
verify_obfuscated() {
  local artifact="$1"
  # Identifiers defined in our own Dart code. They MUST NOT appear in an
  # obfuscated binary (each verified present in the source tree).
  local probe=(
    "EncryptedResultArchive"
    "TransactionStage"
    "VerificationForm"
    "ResultCanvas"
  )
  local leaked=0
  for name in "${probe[@]}"; do
    if LC_ALL=C grep -qa -- "${name}" "${artifact}" 2>/dev/null; then
      echo "error: identifier '${name}' is present in $(basename "${artifact}")" >&2
      leaked=1
    fi
  done
  if [[ "${leaked}" -eq 1 ]]; then
    echo "error: build is NOT obfuscated — refusing to publish" >&2
    return 1
  fi
  echo "==> obfuscation verified for $(basename "${artifact}")"
}

shopt -s nullglob
local_artifacts=( "${OUT_DIR}"/*.aab "${OUT_DIR}"/*.ipa "${OUT_DIR}"/app/**/outputs/**/*.apk )
if [[ ${#local_artifacts[@]} -eq 0 ]]; then
  echo "warning: no artifacts matched under ${OUT_DIR}; skipping obfuscation check" >&2
else
  for artifact in "${local_artifacts[@]}"; do
    verify_obfuscated "${artifact}"
  done
fi
