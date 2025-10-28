#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_TOKEN:?Defina GITHUB_TOKEN}"
: "${GITHUB_REPO:?Ex: C14-2025/API-BolaMarcada}"
: "${TAG:?Ex: ci-<commit>}"
: "${ASSET_PATH:?Caminho do arquivo .tar/.zip/etc}"

API="https://api.github.com"
UA="jenkins-ci-upload"
AUTH_HEADER=("Authorization: Bearer ${GITHUB_TOKEN}")
ACCEPT_JSON=("Accept: application/vnd.github+json")
CONTENT_BIN=("Content-Type: application/octet-stream")

# --- helpers ---------------------------------------------------------------

# remove CR (\r) de ambientes Windows
trim_cr() { tr -d '\r'; }

# URL-encode (RFC3986) – puro bash
urlencode() {
  local LC_ALL=C
  local s="${1-}" out="" c hex
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      ' ') out+='%20' ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

curl_json() {
  # GET que falha se status >=400
  curl -fsS -H "${AUTH_HEADER[@]}" -H "${ACCEPT_JSON[@]}" -A "$UA" "$@"
}

curl_post_json() {
  local url="$1"; shift
  local body="$1"; shift
  curl -fsS -X POST -H "${AUTH_HEADER[@]}" -H "${ACCEPT_JSON[@]}" -H "Content-Type: application/json" -A "$UA" \
    --data "$body" "$url"
}

# --- checagens -------------------------------------------------------------

if [ ! -f "$ASSET_PATH" ]; then
  echo "ERRO: arquivo não encontrado: $ASSET_PATH" >&2
  exit 1
fi

fname="$(basename -- "$ASSET_PATH")"
fname_enc="$(urlencode "$fname")"

# --- obter/ criar release por TAG -----------------------------------------

set +e
release_resp="$(curl_json "${API}/repos/${GITHUB_REPO}/releases/tags/${TAG}" 2>/dev/null)"
status=$?
set -e

if [ $status -ne 0 ] || ! echo "$release_resp" | jq -e '.id' >/dev/null 2>&1; then
  echo "Release com tag '${TAG}' não existe. Criando (prerelease=true)..."
  create_body="$(jq -n --arg tag "$TAG" '{tag_name:$tag, name:$tag, draft:false, prerelease:true}')"
  release_resp="$(curl_post_json "${API}/repos/${GITHUB_REPO}/releases" "$create_body")"
fi

release_id="$(echo "$release_resp" | jq -r '.id')"
if [ -z "$release_id" ] || [ "$release_id" = "null" ]; then
  echo "ERRO: não foi possível obter/ criar a release (TAG=${TAG})." >&2
  echo "$release_resp" >&2
  exit 1
fi

# --- upload_url base (sem {?name,label}) -----------------------------------

upload_url_raw="$(echo "$release_resp" | jq -r '.upload_url' | trim_cr)"
# remove template do fim e espaços residuais
upload_base="${upload_url_raw%\{*}"
upload_base="${upload_base%"${upload_base##*[![:space:]]}"}" # strip trailing spaces

# sanity check
case "$upload_base" in
  https://uploads.github.com/*) ;;
  *)
    echo "ERRO: upload_base inválido: '$upload_base'" >&2
    exit 1
    ;;
esac

echo "Upload base: $upload_base"
assets_url="${API}/repos/${GITHUB_REPO}/releases/${release_id}/assets"

# --- deletar asset existente com mesmo nome --------------------------------

assets_json="$(curl_json "$assets_url")"
asset_id="$(echo "$assets_json" | jq -r --arg n "$fname" '.[] | select(.name==$n) | .id' || true)"
if [ -n "${asset_id:-}" ] && [ "$asset_id" != "null" ]; then
  echo "Removendo asset existente '${fname}' (id=${asset_id})..."
  curl -fsS -X DELETE -H "${AUTH_HEADER[@]}" -H "${ACCEPT_JSON[@]}" -A "$UA" \
    "${API}/repos/${GITHUB_REPO}/releases/assets/${asset_id}" >/dev/null
fi

# --- montar URL final e validar --------------------------------------------

upload_uri="${upload_base}?name=${fname_enc}"

# validação simples de URL (host + path)
if ! printf '%s' "$upload_uri" | grep -qiE '^https://uploads\.github\.com/'; then
  echo "ERRO: URI de upload inválida: $upload_uri" >&2
  exit 1
fi

# --- upload ----------------------------------------------------------------

echo "Enviando '${fname}'..."
curl -fsS -X POST -H "${AUTH_HEADER[@]}" -H "${CONTENT_BIN[@]}" -H "${ACCEPT_JSON[@]}" -A "$UA" \
  --data-binary @"${ASSET_PATH}" \
  "$upload_uri" >/dev/null

echo "OK: Asset '${fname}' enviado para a release '${TAG}' (id=${release_id})."
