#!/usr/bin/env bash
#
# flyakeed-vpn.sh — connect to the Flyakeed FortiGate VPN via openfortivpn + SAML.
#
# The gateway delegates auth to Microsoft (Azure AD), which is an *interactive*
# login (password + MFA). That can't be done with a headless curl, so the SAML
# step has to go through a real browser. This script:
#   1. installs openfortivpn if it's missing
#   2. starts `openfortivpn <gw> --saml-login` (it listens on 127.0.0.1:8020
#      for the SAML callback that carries the session cookie)
#   3. asks the gateway for the Microsoft login URL
#   4. opens that URL in your browser — you log in, the browser is redirected
#      back to 127.0.0.1:8020, and openfortivpn brings the tunnel up.
#
# The VPN stays up for as long as this script runs. Press Ctrl-C to disconnect.

set -euo pipefail

# ---------------------------------------------------------------------------
# Connection parameters
# ---------------------------------------------------------------------------
GATEWAY="54.195.80.74:10443"
TRUSTED_CERT="2ad8f6b2a643a2482fa0b817a1105fec22a4f1d78b9fe5feb21cf139f0642204"
USER_AGENT="Mozilla/5.0 FortiClient/7.0.0.0"
BASE_URL="https://${GATEWAY}"

COOKIE_JAR="$(mktemp)"
OFV_LOG="$(mktemp)"
OFV_PID=""

# ---------------------------------------------------------------------------
# Cleanup: drop temp files always; tear the tunnel down on interrupt.
# ---------------------------------------------------------------------------
cleanup() {
  if [[ -n "${OFV_PID}" ]] && kill -0 "${OFV_PID}" 2>/dev/null; then
    echo ">> Disconnecting VPN..."
    sudo kill "${OFV_PID}" 2>/dev/null || true
  fi
  rm -f "${COOKIE_JAR}" "${OFV_LOG}"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Open a URL in the user's browser, across Linux / macOS / WSL.
# ---------------------------------------------------------------------------
open_url() {
  local url="$1"
  if   command -v xdg-open >/dev/null 2>&1; then xdg-open "${url}" >/dev/null 2>&1 &
  elif command -v open     >/dev/null 2>&1; then open "${url}" >/dev/null 2>&1 &
  elif command -v wslview  >/dev/null 2>&1; then wslview "${url}" >/dev/null 2>&1 &
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 1. Install openfortivpn if not present
# ---------------------------------------------------------------------------
if ! command -v openfortivpn >/dev/null 2>&1; then
  echo ">> openfortivpn not found — installing..."
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get update -y && sudo apt-get install -y openfortivpn
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y openfortivpn
  elif command -v yum     >/dev/null 2>&1; then sudo yum install -y openfortivpn
  elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm openfortivpn
  elif command -v zypper  >/dev/null 2>&1; then sudo zypper install -y openfortivpn
  elif command -v brew    >/dev/null 2>&1; then brew install openfortivpn
  else
    echo "!! No supported package manager found. Install openfortivpn manually." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 2. Start openfortivpn in the background (it waits on the SAML callback)
# ---------------------------------------------------------------------------
echo ">> Starting openfortivpn (SAML login)..."
# Prime sudo up front so the background job doesn't block on a password prompt.
sudo -v
sudo openfortivpn "${GATEWAY}" \
  --saml-login \
  --trusted-cert="${TRUSTED_CERT}" >"${OFV_LOG}" 2>&1 &
OFV_PID=$!

# Wait until openfortivpn says its SAML listener is up. We watch its log instead
# of poking port 8020 directly — a raw probe is parsed as a bad SAML request.
echo ">> Waiting for the SAML listener..."
for _ in $(seq 1 60); do
  if ! kill -0 "${OFV_PID}" 2>/dev/null; then
    echo "!! openfortivpn exited before the SAML listener came up:" >&2
    cat "${OFV_LOG}" >&2
    exit 1
  fi
  if grep -q "Listening for SAML login" "${OFV_LOG}" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

# ---------------------------------------------------------------------------
# 3. Fetch the Microsoft (Azure AD) login URL from the gateway
# ---------------------------------------------------------------------------
echo ">> Requesting SAML login URL..."
LOGIN_URL="$(
  curl -k -s -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" \
    "${BASE_URL}/remote/saml/start?redirect=1" \
    -H "User-Agent: ${USER_AGENT}" \
  | grep -o "window.location='[^']*'" \
  | sed "s/window.location='//;s/'$//"
)"

if [[ -z "${LOGIN_URL}" ]]; then
  echo "!! Could not extract the SAML login URL from the gateway." >&2
  exit 1
fi

# The gateway may hand back a relative path; make it absolute.
case "${LOGIN_URL}" in
  http*) ;;
  /*)    LOGIN_URL="${BASE_URL}${LOGIN_URL}" ;;
  *)     LOGIN_URL="${BASE_URL}/${LOGIN_URL}" ;;
esac

# ---------------------------------------------------------------------------
# 4. Open the login URL in a browser. After you sign in, the browser is
#    redirected to 127.0.0.1:8020 and openfortivpn finishes the connection.
# ---------------------------------------------------------------------------
echo ">> Opening the Microsoft login page in your browser..."
if ! open_url "${LOGIN_URL}"; then
  echo ">> Couldn't auto-open a browser. Open this URL manually to sign in:"
fi
echo
echo "    ${LOGIN_URL}"
echo
echo ">> After signing in, the VPN connects automatically."
echo ">> Press Ctrl-C to disconnect."
echo

# Stream openfortivpn's ongoing output and keep the tunnel alive in the
# foreground. tail --pid exits when openfortivpn does.
tail -n +1 -f --pid="${OFV_PID}" "${OFV_LOG}" &
wait "${OFV_PID}"
