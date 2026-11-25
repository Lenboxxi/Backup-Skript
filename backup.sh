#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/backup.env"

# --- Konfiguration ---------------------------------------------------------
PAPERLESS_EXPORT_DIR="$HOME/paperless/export"
PAPERLESS_CONTAINER="paperless-webserver-1"

IMMICH_DIR="$HOME/immich"
IMMICH_EXCLUDES=(
    "$IMMICH_DIR/library/thumbs"
    "$IMMICH_DIR/library/encoded-video"
)

KEEP_DAILY=5
KEEP_WEEKLY=4
KEEP_MONTHLY=6
# ---------------------------------------------------------------------------

DATE=$(date +%Y-%m-%d)

export SSHPASS="$STORAGEBOX_PASSWORD"
export BORG_PASSPHRASE
export BORG_RSH="sshpass -e ssh -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no -o PreferredAuthentications=password"
export BORG_REPO="ssh://$STORAGEBOX_USER@$STORAGEBOX_HOST:23/./$BORG_REPO_NAME"

send_discord () {
    curl -fsS -H "Content-Type: application/json" \
         -d "{\"content\": \"$1\"}" \
         "$DISCORD_WEBHOOK" >/dev/null || true
}

borg_run () {
    local rc=0
    borg "$@" || rc=$?
    if (( rc == 1 )); then
        APP_WARNINGS=1
        send_discord "⚠️ $APP Backup Warnung (Borg): $STEP ($DATE)"
    elif (( rc > 1 )); then
        return "$rc"
    fi
}

borg_prune () {
    borg_run prune --list --glob-archives "$1-*" \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY"
}

# --- Apps ------------------------------------------------------------------
backup_paperless () {
    STEP="Export"
    docker exec "$PAPERLESS_CONTAINER" document_exporter ../export

    STEP="Export prüfen"
    if [ -z "$(ls -A "$PAPERLESS_EXPORT_DIR")" ]; then
        echo "Export-Verzeichnis ist leer, Abbruch." >&2
        false
    fi

    STEP="Borg-Backup"
    borg_run create --stats --compression zstd \
        "::paperless-{now:%Y-%m-%d_%H-%M}" "$PAPERLESS_EXPORT_DIR"

    STEP="Aufräumen"
    borg_prune paperless
}

backup_immich () {
    STEP="Ordner prüfen"
    if [ -z "$(ls -A "$IMMICH_DIR/library")" ]; then
        echo "$IMMICH_DIR/library fehlt oder ist leer, Abbruch." >&2
        false
    fi

    STEP="DB-Dumps prüfen"
    if [ -z "$(find "$IMMICH_DIR/library/backups" -name '*.sql.gz' -mtime -2 2>/dev/null)" ]; then
        echo "Kein Immich-DB-Dump jünger als 2 Tage in library/backups, Abbruch." >&2
        false
    fi

    STEP="Borg-Backup"
    local excludes=() e
    for e in "${IMMICH_EXCLUDES[@]}"; do
        excludes+=(--exclude "pp:$e")
    done
    borg_run create --stats --compression zstd "${excludes[@]}" \
        "::immich-{now:%Y-%m-%d_%H-%M}" \
        "$IMMICH_DIR/library"

    STEP="Aufräumen"
    borg_prune immich
}
# ---------------------------------------------------------------------------

# Führt eine App isoliert in einer Subshell aus: ein Fehler bricht nur diese App ab.
RESULTS=()
FAILED=0
run_app () {
    local app=$1 func=$2 rc
    echo "=== $app ==="
    (
        set -Eeuo pipefail
        APP=$app
        APP_WARNINGS=0
        STEP="Start"
        trap 'send_discord "❌ $APP Backup fehlgeschlagen (Borg): $STEP ($DATE)"; exit 1' ERR
        "$func"
        (( APP_WARNINGS )) && exit 100
        exit 0
    )
    rc=$?

    case $rc in
        0)   RESULTS+=("✅ $app") ;;
        100) RESULTS+=("⚠️ $app") ;;
        *)   RESULTS+=("❌ $app"); FAILED=1 ;;
    esac
}

echo "=== Backup gestartet ==="

run_app "Paperless" backup_paperless
run_app "Immich"    backup_immich

echo "=== Compact ==="
rc=0
borg compact || rc=$?
if (( rc > 1 )); then
    RESULTS+=("❌ Compact")
    FAILED=1
fi

SUMMARY=$(IFS='|'; echo "${RESULTS[*]}" | sed 's/|/ · /g')
echo "=== Fertig: $SUMMARY ==="
send_discord "📦 Heimserver Backup (Borg) $DATE: $SUMMARY"

exit "$FAILED"