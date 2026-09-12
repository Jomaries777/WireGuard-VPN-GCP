#!/usr/bin/env bash
# Every check that can run without a GCP project. Run it before you push:
#
#   ./scripts/check.sh
#
# CI runs exactly this, so a green run here means a green run there.
#
# The reason this exists rather than just `terraform validate`: validate does
# NOT render templatefile(). The startup script is a template, and Terraform
# claims dollar-brace and percent-brace sequences inside it, so an unescaped one
# passes validate cleanly and blows up at apply time — after you have waited for
# a VM to build. Rendering it here catches that in seconds.
set -euo pipefail

cd "$(dirname "$0")/.."

pass() { printf '  ok    %s\n' "$1"; }

fail() {
  printf '  FAIL  %s\n' "$1"
  if [ $# -gt 1 ] && [ -n "$2" ]; then
    printf '%s\n' "$2" | sed 's/^/        /'
  fi
  exit 1
}

# Run a command, report it by label, and show its output only if it fails.
run() {
  local label="$1"
  shift
  local out
  if out="$("$@" 2>&1)"; then
    pass "$label"
  else
    fail "$label" "$out"
  fi
}

# Linting is optional locally (brew install shellcheck) but required in CI, so a
# missing binary can't quietly turn a real gate into a skipped one.
#
# This comment does not start with the tool's name on purpose: a comment opening
# with that word is read as a shellcheck directive and fails to parse.
have_shellcheck() {
  if command -v shellcheck > /dev/null; then
    return 0
  fi
  if [ "${REQUIRE_SHELLCHECK:-0}" = "1" ]; then
    fail "shellcheck is not installed" "CI sets REQUIRE_SHELLCHECK=1, so this is an error rather than a skip"
  fi
  return 1
}

# ---------------------------------------------------------------------------
echo "Formatting"
# ---------------------------------------------------------------------------
run "terraform fmt (fix with: terraform fmt -recursive)" \
  terraform fmt -check -recursive -diff

if have_shellcheck; then
  run "shellcheck (scripts/check.sh)" shellcheck scripts/check.sh
fi

# ---------------------------------------------------------------------------
echo "Configuration is valid"
# ---------------------------------------------------------------------------
validate_dir() (
  cd "$1"
  terraform init -backend=false -input=false > /dev/null
  terraform validate > /dev/null
)

for dir in . bootstrap; do
  run "terraform validate ($dir)" validate_dir "$dir"
done

# ---------------------------------------------------------------------------
echo "Startup script renders and parses"
# ---------------------------------------------------------------------------
# Ask Terraform itself to render the template, so this tests the real thing
# rather than an imitation of it.
render() {
  terraform console "$@" 2> /dev/null <<'EXPR' |
jsonencode(templatefile("${path.module}/startup-script.sh", { hub_address = var.hub_address, project_id = var.project_id, key_secret_id = var.hub_key_secret_id, peer_blocks = local.peer_blocks }))
EXPR
    python3 -c 'import json,sys; sys.stdout.write(json.loads(json.loads(sys.stdin.read().strip())))'
}

GOOD_KEY_A='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
GOOD_KEY_B='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='

# Both paths matter: the opt-in one, and the one someone following Stages 1-7
# gets with no optional variables set at all.
render_opted_in() {
  render \
    -var 'project_id=ci-project' \
    -var 'hub_key_secret_id=ci-hub-key' \
    -var 'vm_service_account_email=ci@ci-project.iam.gserviceaccount.com' \
    -var 'dns_zone_name=ci-zone' \
    -var 'dns_hostname=vpn.example.com.' \
    -var "peers={laptop={public_key=\"$GOOD_KEY_A\",tunnel_ip=\"10.20.0.2\"},phone={public_key=\"$GOOD_KEY_B\",tunnel_ip=\"10.20.0.3\"}}"
}

render_defaults() {
  render -var 'project_id=ci-project'
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for variant in opted-in defaults; do
  case "$variant" in
    opted-in) render_opted_in > "$tmp/$variant.sh" ;;
    defaults) render_defaults > "$tmp/$variant.sh" ;;
  esac

  if [ ! -s "$tmp/$variant.sh" ]; then
    fail "render produced nothing ($variant)" "templatefile() probably errored — check for an unescaped dollar-brace"
  fi

  run "bash -n ($variant)" bash -n "$tmp/$variant.sh"

  # Rendered output SHOULD still contain dollar-brace and percent-brace text:
  # $${#candidate} and %%{http_code} exist precisely so bash and curl receive
  # ${#candidate} and %{http_code}. What must never survive is one of the four
  # names Terraform fills in, which would mean somebody double-escaped it and
  # shipped a literal placeholder into wg0.conf. Nothing else catches this —
  # bash parses ${hub_address} quite happily as an unset variable.
  if leaked="$(grep -nE '\$\{(hub_address|project_id|key_secret_id|peer_blocks)\}' "$tmp/$variant.sh")"; then
    fail "a template variable was escaped instead of substituted ($variant)" "$leaked"
  fi
  pass "template variables all substituted ($variant)"

  if have_shellcheck; then
    run "shellcheck ($variant)" shellcheck "$tmp/$variant.sh"
  fi
done

# ---------------------------------------------------------------------------
echo "Bad input is rejected at plan time, not at boot"
# ---------------------------------------------------------------------------
# A mistyped peer key produces a tunnel that starts cleanly and never completes
# a handshake, with nothing in any log to say why. These guards are the only
# thing standing between a typo and a lost evening, so they are worth testing.
#
# Note `terraform console` reports a variable validation failure and then keeps
# going, exiting 0 — so the exit code proves nothing here. Match the error text
# instead, and match the SPECIFIC message so a test cannot pass on some
# unrelated error. Whitespace is collapsed on both sides because Terraform wraps
# its messages to the terminal width.
rejects() {
  local what="$1" expected="$2"
  shift 2
  local out
  out="$(echo 'var.project_id' | terraform console -no-color "$@" 2>&1 | tr -s '[:space:]' ' ')"
  if [[ "$out" == *"$expected"* ]]; then
    pass "rejects $what"
  else
    fail "did not reject $what" "expected the error to mention: $expected"
  fi
}

rejects "a truncated peer public key" "44-character base64" \
  -var 'project_id=ci' \
  -var 'peers={x={public_key="tooshort=",tunnel_ip="10.20.0.2"}}'

rejects "a tunnel_ip carrying a prefix length" "bare IPv4 address" \
  -var 'project_id=ci' \
  -var "peers={x={public_key=\"$GOOD_KEY_A\",tunnel_ip=\"10.20.0.2/32\"}}"

rejects "two peers on one address" "Two peers share a tunnel_ip" \
  -var 'project_id=ci' \
  -var "peers={a={public_key=\"$GOOD_KEY_A\",tunnel_ip=\"10.20.0.2\"},b={public_key=\"$GOOD_KEY_B\",tunnel_ip=\"10.20.0.2\"}}"

rejects "a hostname missing its trailing dot" "must be fully qualified" \
  -var 'project_id=ci' \
  -var 'dns_hostname=vpn.example.com'

echo
echo "All checks passed."
