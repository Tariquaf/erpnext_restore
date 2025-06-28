#!/usr/bin/env bash
set -euo pipefail

# ─── CONFIG ────────────────────────────────────────────────────────────────
BENCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
SITES_DIR="$BENCH_ROOT/sites"

# ─── DEPENDENCY CHECK ──────────────────────────────────────────────────────
for cmd in bench jq find stdbuf; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $cmd" >&2
    exit 1
  fi
done

# ─── MODE SELECTION ────────────────────────────────────────────────────────
echo
echo "Select environment:"
echo " 1) Production (emails & scheduler enabled after restore)"
echo " 2) Staging    (emails & scheduler disabled after restore)"
read -rp "Enter choice [1]: " mode
mode=${mode:-1}
if [[ "$mode" == "2" ]]; then
  IS_STAGING=true
  echo "➡️  Staging mode selected: will disable emails & scheduler."
else
  IS_STAGING=false
  echo "➡️  Production mode selected: will enable emails & scheduler."
fi

# ─── SELECT SITE ───────────────────────────────────────────────────────────
echo
echo "Available ERPNext sites:"
mapfile -t SITES < <(
  find "$SITES_DIR" -mindepth 1 -maxdepth 1 -type d \
    -exec test -f "{}/site_config.json" ';' \
    -printf '%f\n' | sort
)
if [[ ${#SITES[@]} -eq 0 ]]; then
  echo "ERROR: No sites found in $SITES_DIR" >&2
  exit 1
fi
for i in "${!SITES[@]}"; do
  idx=$((i+1))
  echo " $idx) ${SITES[i]}"
done
read -rp "Select site [1]: " sidx
sidx=${sidx:-1}
if (( sidx < 1 || sidx > ${#SITES[@]} )); then
  echo "ERROR: Invalid site selection" >&2
  exit 1
fi
SITE="${SITES[$((sidx-1))]}"
BACKUP_DIR="$SITES_DIR/$SITE/private/backups"
echo "Selected site: $SITE"
echo "Backup directory: $BACKUP_DIR"

# ─── SELECT BACKUP ─────────────────────────────────────────────────────────
echo
echo "Available SQL backups:"
mapfile -t DUMPS < <(
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.sql.gz' \
    -printf '%T@ %f\n' | sort -nr | cut -d' ' -f2-
)
if [[ ${#DUMPS[@]} -eq 0 ]]; then
  echo "ERROR: No SQL backups found in $BACKUP_DIR" >&2
  exit 1
fi
for i in "${!DUMPS[@]}"; do
  idx=$((i+1))
  echo " $idx) ${DUMPS[i]}"
done
read -rp "Select backup [1]: " didx
didx=${didx:-1}
if (( didx < 1 || didx > ${#DUMPS[@]} )); then
  echo "ERROR: Invalid backup selection" >&2
  exit 1
fi
SQL_GZ="${DUMPS[$((didx-1))]}"
BASE="${SQL_GZ%-database.sql.gz}"
PUB_TAR="$BACKUP_DIR/${BASE}-files.tar"
PRIV_TAR="$BACKUP_DIR/${BASE}-private-files.tar"

echo
echo "Chosen backup:"
echo " SQL:     $SQL_GZ"
echo " Public:  $(basename "$PUB_TAR")"
echo " Private: $(basename "$PRIV_TAR")"
read -rp "Proceed with restore? [Y/n]: " ok
ok=${ok:-Y}
if [[ ! $ok =~ ^[Yy]$ ]]; then
  echo "Aborting."
  exit 0
fi

# ─── MYSQL ROOT CREDENTIALS ────────────────────────────────────────────────
echo
read -rp "MySQL admin user [root]: " DB_USER
DB_USER=${DB_USER:-root}
read -rsp "MySQL admin password: " DB_PASS
echo

# ─── RESTORE PROCESS ───────────────────────────────────────────────────────
cd "$BENCH_ROOT"
echo
echo "🔧 Enabling maintenance mode…"
bench --site "$SITE" set-maintenance-mode on

ROOT_FLAGS=(--db-root-username "$DB_USER")
if [[ -n "$DB_PASS" ]]; then
  ROOT_FLAGS+=(--db-root-password "$DB_PASS")
fi

echo
echo "📥 Running bench restore (live progress)…"
stdbuf -oL -eL bench --site "$SITE" restore \
  "$BACKUP_DIR/$SQL_GZ" \
  --with-public-files "$PUB_TAR" \
  --with-private-files "$PRIV_TAR" \
  "${ROOT_FLAGS[@]}" \
  --force

# ─── POST-RESTORE ACTIONS ──────────────────────────────────────────────────
echo
if [[ "$IS_STAGING" == true ]]; then
  echo "📪 Disabling emails & pausing scheduler…"
  bench --site "$SITE" set-config disable_emails 1
  bench --site "$SITE" set-config pause_scheduler 1
else
  echo "📬 Enabling emails & resuming scheduler…"
  bench --site "$SITE" set-config disable_emails 0
  bench --site "$SITE" set-config pause_scheduler 0
fi

echo
echo "🟢 Disabling maintenance mode…"
bench --site "$SITE" set-maintenance-mode off

echo
echo "🔄 Restarting supervisor services…"
sudo supervisorctl restart all

echo
MODE_TEXT="production"
if [[ "$IS_STAGING" == true ]]; then
  MODE_TEXT="staging"
fi
echo "✅ Restore complete for $SITE — $MODE_TEXT mode."
