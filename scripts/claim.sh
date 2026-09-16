#!/usr/bin/env bash
# Claim an Oracle Cloud Always Free compute instance (Ampere A1 / AMD micro)
# the moment capacity appears. Dependencies: openssl, curl, jq — all present on
# the GitHub ubuntu runners.
#
# One scheduled run makes MAX_ROUNDS attempts (ARM first, optional micro second)
# so a single billed CI minute covers several tries.
set -euo pipefail

# ---------------------------------------------------------------- self test
self_test() {
  local tmp; tmp="$(mktemp -d)"
  openssl genrsa -out "$tmp/k.pem" 2048 >/dev/null 2>&1
  openssl rsa -in "$tmp/k.pem" -pubout -out "$tmp/k.pub" >/dev/null 2>&1
  printf 'oci-test' | openssl dgst -sha256 -sign "$tmp/k.pem" -out "$tmp/sig" -binary
  printf 'oci-test' | openssl dgst -sha256 -verify "$tmp/k.pub" -signature "$tmp/sig" >/dev/null
  local empty
  empty="$(printf '' | openssl dgst -sha256 -binary | openssl base64 -A)"
  [[ "$empty" == "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=" ]]

  # a pinned image short-circuits the API lookup (and keeps this test offline)
  OCI_IMAGE_OCID="ocid1.image.oc1..pinned"
  [[ "$(resolve_image VM.Standard.A1.Flex)" == "$OCI_IMAGE_OCID" ]]

  # a hard error on the fallback shape must not end the run before the last round
  local rounds="$tmp/rounds" mrc
  OCI_TENANCY=t OCI_USER=u OCI_FINGERPRINT=f OCI_KEY=x
  OCI_REGION=r OCI_COMPARTMENT=c OCI_AD=a OCI_SUBNET=s
  setup
  resolve_image() { printf 'img'; }
  try_launch() { echo "$1" >> "$rounds"; [[ "$1" == VM.Standard.A1.Flex ]] && return 3; return 1; }
  ALLOW_MICRO=true MAX_ROUNDS=2 RETRY_SLEEP=0
  set +e
  main >/dev/null 2>&1
  mrc=$?
  set -e
  [[ $mrc -eq 0 && "$(grep -c . "$rounds")" == 4 ]] || {
    echo "self-test: fallback error cut the run short (rc=${mrc}, attempts=$(grep -c . "$rounds" 2>/dev/null))" >&2
    exit 1
  }

  rm -rf "$tmp"
  echo "self-test ok"
}
# ---------------------------------------------------------------- config
need() { [[ -n "${!1:-}" ]] || { echo "missing env: $1" >&2; exit 2; }; }

setup() {
  for v in OCI_TENANCY OCI_USER OCI_FINGERPRINT OCI_KEY OCI_REGION OCI_COMPARTMENT OCI_AD OCI_SUBNET; do need "$v"; done

  HOST="iaas.${OCI_REGION}.oraclecloud.com"
  NAME="${INSTANCE_NAME:-server-1}"
  ARM_OCPUS="${ARM_OCPUS:-2}"
  ARM_MEMORY_GB="${ARM_MEMORY_GB:-12}"
  ALLOW_MICRO="${ALLOW_MICRO:-true}"
  MAX_ROUNDS="${MAX_ROUNDS:-2}"
  RETRY_SLEEP="${RETRY_SLEEP:-20}"
  LAUNCHED_ID=""

  KEY="$(mktemp)"
  trap 'rm -f "$KEY"' EXIT
  printf '%s\n' "$OCI_KEY" > "$KEY"
  chmod 600 "$KEY"
}

# ---------------------------------------------------------------- signer
# oci_request METHOD PATH [BODY]  -> prints the response body
oci_request() {
  local method="$1" path="$2" body="${3:-}" host="$HOST" args=()
  # HTTP method stays canonical (GET/POST) on the wire; the signing string uses lowercase.
  local lmethod; lmethod="$(printf '%s' "$method" | tr '[:upper:]' '[:lower:]')"
  local when; when="$(LC_ALL=C date -u +'%a, %d %b %Y %H:%M:%S GMT')"
  local sstring hook

  if [[ -n "$body" ]]; then
    local sha clen
    sha="$(printf '%s' "$body" | openssl dgst -sha256 -binary | openssl base64 -A)"
    clen="$(printf '%s' "$body" | wc -c | tr -d '[:space:]')"
    sstring="(request-target): ${lmethod} ${path}
host: ${host}
date: ${when}
content-length: ${clen}
content-type: application/json
x-content-sha256: ${sha}"
    hook='headers="(request-target) host date content-length content-type x-content-sha256"'
    args=( -H "date: ${when}" -H "content-type: application/json" -H "content-length: ${clen}" -H "x-content-sha256: ${sha}" --data-binary "$body" )
  else
    sstring="(request-target): ${lmethod} ${path}
host: ${host}
date: ${when}"
    hook='headers="(request-target) host date"'
    args=( -H "date: ${when}" )
  fi

  local sig
  sig="$(printf '%s' "$sstring" | openssl dgst -sha256 -sign "$KEY" -binary | openssl base64 -A)"
  local authz="Signature version=\"1\",keyId=\"${OCI_TENANCY}/${OCI_USER}/${OCI_FINGERPRINT}\",algorithm=\"rsa-sha256\",${hook},signature=\"${sig}\""

  # only GETs are auto-retried: a POST whose response times out may already have
  # created the instance, and re-sending it would hide the launch behind a duplicate.
  local retry=()
  [[ "$method" == "GET" ]] && retry=( --retry 2 --retry-delay 1 )

  curl -sS ${retry[@]+"${retry[@]}"} -X "$method" "https://${host}${path}" "${args[@]}" -H "Authorization: ${authz}"
}

resolve_image() {
  local shape="$1"
  # OCI_IMAGE_OCID pins a known-good image and skips the per-run lookup
  [[ -z "${OCI_IMAGE_OCID:-}" ]] || { printf '%s' "$OCI_IMAGE_OCID"; return 0; }
  local path="/20160918/images?compartmentId=${OCI_COMPARTMENT}&operatingSystem=Canonical%20Ubuntu&shape=${shape}&sortBy=TIMECREATED&sortOrder=DESC&limit=25"
  # list endpoints return a bare JSON array; prefer Ubuntu LTS 24.04 (Python 3.12)
  oci_request GET "$path" | jq -r '[.[] | select(.displayName | test("24\\.04"))][0].id // .[0].id // empty' 2>/dev/null || true
}

# try_launch -> 0 launched, 3 capacity miss, 4 already exists, 1 other error
try_launch() {
  local shape="$1" cfg="$2" image="$3"
  [[ -n "$image" ]] || { echo "no image found for ${shape}" >&2; return 1; }
  local body sshkey
  # secrets may carry CRLF from Windows tooling; JSON strings must not contain control chars
  sshkey="$(printf '%s' "${OCI_SSH_PUBLIC_KEY:-}" | tr -d '\r\n')"
  body="{\"availabilityDomain\":\"${OCI_AD}\",\"compartmentId\":\"${OCI_COMPARTMENT}\",\"displayName\":\"${NAME}\",\"shape\":\"${shape}\"${cfg},\"sourceDetails\":{\"sourceType\":\"image\",\"imageId\":\"${image}\",\"bootVolumeSizeInGBs\":50},\"createVnicDetails\":{\"subnetId\":\"${OCI_SUBNET}\",\"assignPublicIp\":true},\"metadata\":{\"ssh_authorized_keys\":\"${sshkey}\"}}"
  local resp id code msg
  resp="$(oci_request POST /20160918/instances "$body")"
  id="$(jq -r '.id // empty' <<<"$resp" 2>/dev/null || true)"
  code="$(jq -r '.code // empty' <<<"$resp" 2>/dev/null || true)"
  msg="$(jq -r '.message // empty' <<<"$resp" 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    LAUNCHED_ID="$id"
    echo "launched ${shape}"; return 0
  fi
  if [[ "$code" == "LimitExceeded" ]]; then
    echo "${shape}: instance already exists"; return 4
  fi
  if grep -qiE 'TooManyRequests|Too Many Requests' <<<"${code} ${msg}"; then
    echo "${shape}: rate limited"; return 5
  fi
  if grep -qiE 'capacity|InternalError' <<<"${code} ${msg}"; then
    echo "${shape}: no capacity"; return 3
  fi
  echo "error ${shape}: ${code} ${msg}" >&2
  return 1
}

notify() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0
  curl -sS --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

# public IP of a just-launched instance (the VNIC can take a few seconds to appear)
public_ip() {
  local id="$1" i att vnic
  for i in 1 2 3 4 5; do
    att="$(oci_request GET "/20160918/vnic-attachments?compartmentId=${OCI_COMPARTMENT}&instanceId=${id}" | jq -r '.[0].vnicId // empty' 2>/dev/null || true)"
    if [[ -n "$att" ]]; then
      vnic="$(oci_request GET "/20160918/vnics/${att}" | jq -r '.publicIp // empty' 2>/dev/null || true)"
      if [[ -n "$vnic" ]]; then printf '%s' "$vnic"; return 0; fi
    fi
    sleep 3
  done
  return 0
}

# Stop this workflow so it does not ping every 5 minutes once the instance exists.
disable_self() {
  [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || return 0
  curl -sS -X PUT -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/claim.yml/disable" >/dev/null 2>&1 || true
}

handle_success() {
  local shape="$1" ip
  ip="$(public_ip "$LAUNCHED_ID")"
  echo "created ${shape} (details sent to Telegram)"
  notify "✅ OCI instance created
shape: ${shape}
name: ${NAME}
ip: ${ip:-pending}
poller disabled"
  disable_self
  exit 0
}

main() {
  local arm_img micro_img round rc
  arm_img="$(resolve_image VM.Standard.A1.Flex)"
  [[ -n "$arm_img" ]] || echo "warning: no ARM image found"
  if [[ "$ALLOW_MICRO" == "true" ]]; then
    micro_img="$(resolve_image VM.Standard.E2.1.Micro)"
    [[ -n "$micro_img" ]] || echo "warning: no micro image found"
  fi

  for (( round=1; round<=MAX_ROUNDS; round++ )); do
    echo "--- round ${round}/${MAX_ROUNDS} ---"
    set +e
    try_launch VM.Standard.A1.Flex ",\"shapeConfig\":{\"ocpus\":${ARM_OCPUS},\"memoryInGBs\":${ARM_MEMORY_GB}}" "$arm_img"; rc=$?
    if [[ $rc -eq 0 ]]; then set -e; handle_success VM.Standard.A1.Flex; fi
    if [[ $rc -eq 4 ]]; then set -e; echo "instance already exists"; exit 0; fi
    if [[ $rc -eq 5 ]]; then set -e; echo "rate limited, stopping this run"; exit 0; fi
    if [[ $rc -eq 1 ]]; then set -e; exit 1; fi
    if [[ "$ALLOW_MICRO" == "true" ]]; then
      try_launch VM.Standard.E2.1.Micro "" "$micro_img"; rc=$?
      if [[ $rc -eq 0 ]]; then set -e; handle_success VM.Standard.E2.1.Micro; fi
      if [[ $rc -eq 4 ]]; then set -e; echo "instance already exists"; exit 0; fi
      if [[ $rc -eq 5 ]]; then set -e; echo "rate limited, stopping this run"; exit 0; fi
      # micro is only a fallback (it can be absent from this region altogether), so a
      # hard error must not cut the run short and lose the remaining ARM rounds.
      if [[ $rc -eq 1 ]]; then echo "warning: micro attempt failed, staying on ARM"; fi
    fi
    set -e
    if [[ $round -lt $MAX_ROUNDS ]]; then sleep "$RETRY_SLEEP"; fi
  done

  echo "no capacity this run"
}

if [[ "${1:-}" == "--self-test" ]]; then self_test; exit 0; fi
setup
main
