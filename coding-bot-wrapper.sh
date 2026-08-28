#!/usr/bin/env bash
set -euo pipefail

# coding-bot-wrapper.sh
#
# Authenticate as a GitHub App, obtain a short-lived, repository-scoped
# installation token, and run a `gh` command with that token.
#
# This is a thin wrapper: it only negotiates the token and then hands off to
# `gh` (or any command you pass). It does not clone, branch, commit, or push.
#
# Requirements:
#   bash, curl, jq, openssl, gh
#
# Required environment variables:
#   GITHUB_APP_ID
#   GITHUB_PRIVATE_KEY_FILE
#
# When GITHUB_APP_ID is not already set, configuration is loaded from an env
# file (default: ~/.coding-bot.env, overridable via CODING_BOT_ENV). The file is
# a plain shell snippet, e.g.:
#   GITHUB_APP_ID=123456
#   GITHUB_PRIVATE_KEY_FILE=/home/me/my-app.private-key.pem
#
# The target repository (used to scope the installation token) is read from the
# `-R`/`--repo` flag in the gh command. If that flag is absent, it falls back to
# the GH_REPO or GITHUB_REPOSITORY environment variable.
#
# Optional environment variables:
#   GH_REPO / GITHUB_REPOSITORY  target repository in OWNER/REPO form, used when
#                                the gh command does not pass -R/--repo.
#   GITHUB_API_URL               default: https://api.github.com
#   GITHUB_API_VERSION           default: 2026-03-10
#
# Usage:
#   ./coding-bot-wrapper.sh gh <args...>
#
# Example:
#   GITHUB_APP_ID=123456 \
#   GITHUB_PRIVATE_KEY_FILE=./my-app.private-key.pem \
#   ./coding-bot-wrapper.sh gh pr comment 123 --body 'msg'

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for cmd in curl jq openssl base64; do
  require_cmd "$cmd"
done

# Load configuration from an env file when GITHUB_APP_ID is not already set in
# the environment. The path is overridable via CODING_BOT_ENV.
CODING_BOT_ENV="${CODING_BOT_ENV:-$HOME/.coding-bot.env}"
if [[ -z "${GITHUB_APP_ID:-}" && -f "$CODING_BOT_ENV" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CODING_BOT_ENV"
  set +a
fi

[[ $# -ge 1 ]] || die "usage: $0 gh <args...>"

# Determine the repository the installation token should be scoped to. It is
# taken from the -R/--repo flag in the gh command, falling back to the
# GH_REPO / GITHUB_REPOSITORY environment variables.
detect_repo() {
  local prev=""
  for arg in "$@"; do
    case "$prev" in
      -R|--repo)
        printf '%s\n' "$arg"
        return 0
        ;;
    esac
    case "$arg" in
      --repo=*)
        printf '%s\n' "${arg#--repo=}"
        return 0
        ;;
      -R?*)
        printf '%s\n' "${arg#-R}"
        return 0
        ;;
    esac
    prev="$arg"
  done

  if [[ -n "${GH_REPO:-}" ]]; then
    printf '%s\n' "$GH_REPO"
    return 0
  fi
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf '%s\n' "$GITHUB_REPOSITORY"
    return 0
  fi
  return 1
}

REPO_SLUG="$(detect_repo "$@")" \
  || die "could not determine repository; pass -R OWNER/REPO to gh or set GH_REPO"

[[ "$REPO_SLUG" == */* ]] || die "repository must be in OWNER/REPO form (got: ${REPO_SLUG})"

OWNER="${REPO_SLUG%%/*}"
REPO="${REPO_SLUG#*/}"

: "${GITHUB_APP_ID:?Set GITHUB_APP_ID}"
: "${GITHUB_PRIVATE_KEY_FILE:?Set GITHUB_PRIVATE_KEY_FILE}"

[[ -f "$GITHUB_PRIVATE_KEY_FILE" ]] || die "private key not found: $GITHUB_PRIVATE_KEY_FILE"

GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_API_VERSION="${GITHUB_API_VERSION:-2026-03-10}"

api_headers=(
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}"
)

base64url() {
  # Works with both GNU and BSD/macOS base64.
  base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

json_base64url() {
  printf '%s' "$1" | base64url
}

create_app_jwt() {
  local now iat exp header payload unsigned signature

  now="$(date +%s)"
  # Backdate slightly to avoid clock-skew problems.
  iat=$((now - 60))
  # GitHub App JWTs should be short lived. 9 minutes stays below the
  # documented 10-minute maximum.
  exp=$((now + 540))

  header='{"alg":"RS256","typ":"JWT"}'
  payload="$(jq -cn \
    --argjson iat "$iat" \
    --argjson exp "$exp" \
    --arg iss "$GITHUB_APP_ID" \
    '{iat:$iat,exp:$exp,iss:$iss}')"

  unsigned="$(json_base64url "$header").$(json_base64url "$payload")"

  signature="$(
    printf '%s' "$unsigned" \
      | openssl dgst -sha256 -sign "$GITHUB_PRIVATE_KEY_FILE" \
      | base64url
  )"

  printf '%s.%s\n' "$unsigned" "$signature"
}

github_api() {
  local token="$1"
  shift

  curl --fail-with-body --silent --show-error \
    "${api_headers[@]}" \
    -H "Authorization: Bearer ${token}" \
    "$@"
}

APP_JWT="$(create_app_jwt)"

echo "Finding GitHub App installation for ${REPO_SLUG}..." >&2

INSTALLATION_JSON="$(
  github_api "$APP_JWT" \
    "${GITHUB_API_URL}/repos/${OWNER}/${REPO}/installation"
)"

INSTALLATION_ID="$(jq -r '.id // empty' <<<"$INSTALLATION_JSON")"
[[ -n "$INSTALLATION_ID" ]] || die "could not determine installation ID"

# Scope the installation token to this repository only. It still cannot exceed
# the permissions granted to the GitHub App installation.
TOKEN_JSON="$(
  github_api "$APP_JWT" \
    -X POST \
    "${GITHUB_API_URL}/app/installations/${INSTALLATION_ID}/access_tokens" \
    -d "$(jq -cn --arg repo "$REPO" '{repositories:[$repo]}')"
)"

INSTALLATION_TOKEN="$(jq -r '.token // empty' <<<"$TOKEN_JSON")"
TOKEN_EXPIRES_AT="$(jq -r '.expires_at // empty' <<<"$TOKEN_JSON")"

[[ -n "$INSTALLATION_TOKEN" ]] || {
  jq . <<<"$TOKEN_JSON" >&2 || true
  die "GitHub did not return an installation access token"
}

echo "Installation token acquired; expires at ${TOKEN_EXPIRES_AT}." >&2

# Hand off to the requested command (typically `gh`) with the token in the
# environment. GH_TOKEN authenticates gh; GH_REPO scopes it to the same repo.
export GH_TOKEN="$INSTALLATION_TOKEN"
export GH_REPO="$REPO_SLUG"

exec "$@"
