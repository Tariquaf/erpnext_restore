#!/usr/bin/env bash
set -euo pipefail

# ─── CONFIG ────────────────────────────────────────────────────────────────
BENCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
SITES_DIR="$BENCH_ROOT/sites"

# ─── DEPENDENCY CHECK ──────────────────────────────────────────────────────
for cmd in bench jq find pv mysql gunzip tar gzip; do
  command -v "$cmd" >/dev/null || { echo "❌ Missing: $cmd" >&2; missing=1; }
done
[[ ${missing:-0} -eq 1 ]] && exit 1

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
  echo " $((i+1))) ${SITES[i]}"
done
read -rp "Select site [1]: " sidx
sidx=${sidx:-1}
if (( sidx < 1 || sidx > ${#SITES[@]} )); then
  echo "ERROR: Invalid site selection" >&2
  exit 1
fi
SITE="${SITES[$((sidx-1))]}"
SITE_DIR="$SITES_DIR/$SITE"
BACKUP_DIR="$SITE_DIR/private/backups"
echo "Selected site: $SITE"

# ─── BACKUP EXISTING SITE ──────────────────────────────────────────────────
echo
read -rp "Backup current site before restore? [Y/n]: " backup_confirm
backup_confirm=${backup_confirm:-Y}
if [[ "$backup_confirm" =~ ^[Yy]$ ]]; then
  echo "📦 Backing up current site..."
  bench --site "$SITE" backup --with-files
fi

# ─── SELECT BACKUP ─────────────────────────────────────────────────────────
echo
echo "Available SQL backups in $BACKUP_DIR:"
mapfile -t DUMPS < <(
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*-database.sql.gz' \
    -printf '%T@ %f\n' | sort -nr | cut -d' ' -f2-
)
if [[ ${#DUMPS[@]} -eq 0 ]]; then
  echo "ERROR: No SQL backups found in $BACKUP_DIR" >&2
  exit 1
fi
for i in "${!DUMPS[@]}"; do
  echo " $((i+1))) ${DUMPS[i]}"
done
read -rp "Select backup [1]: " didx
didx=${didx:-1}
if (( didx < 1 || didx > ${#DUMPS[@]} )); then
  echo "ERROR: Invalid backup selection" >&2
  exit 1
fi

SQL_GZ="${DUMPS[$((didx-1))]}"
BASE="${SQL_GZ%-database.sql.gz}"
PUB_TAR="${BASE}-files.tar"
PRIV_TAR="${BASE}-private-files.tar"
SITE_CONFIG_JSON="${BASE}-site_config_backup.json"
echo "Chosen backup: $SQL_GZ"

read -rp "Proceed with restore? [Y/n]: " ok
ok=${ok:-Y}
[[ ! $ok =~ ^[Yy]$ ]] && echo "Aborting." && exit 0

# ─── MYSQL ROOT CREDENTIALS ────────────────────────────────────────────────
echo
read -rp "MySQL admin user [root]: " ROOT_USER
ROOT_USER=${ROOT_USER:-root}
read -rsp "MySQL admin password: " ROOT_PASS
echo

# ─── RESTORE ───────────────────────────────────────────────────────────────
cd "$BENCH_ROOT"
echo "🔧 Enabling maintenance mode…"
bench --site "$SITE" set-maintenance-mode on

# Extract db name and password from site_config_backup.json
DB_NAME=$(jq -r .db_name "$BACKUP_DIR/$SITE_CONFIG_JSON")
DB_USER="$DB_NAME"
DB_PASS=$(jq -r .db_password "$BACKUP_DIR/$SITE_CONFIG_JSON")

echo
echo "💣 Dropping database $DB_NAME (if exists)…"
mysql -u"$ROOT_USER" -p"$ROOT_PASS" -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;"

echo "📄 Creating database $DB_NAME…"
mysql -u"$ROOT_USER" -p"$ROOT_PASS" -e "CREATE DATABASE \`$DB_NAME\`;"

echo "👤 Creating MySQL user '$DB_USER' with restored password…"
mysql -u"$ROOT_USER" -p"$ROOT_PASS" -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -u"$ROOT_USER" -p"$ROOT_PASS" -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
mysql -u"$ROOT_USER" -p"$ROOT_PASS" -e "FLUSH PRIVILEGES;"

echo "🛠 Replacing live site_config.json with restored config…"
cp "$BACKUP_DIR/$SITE_CONFIG_JSON" "$SITE_DIR/site_config.json"

echo
echo "📥 Restoring SQL database with % progress…"
SQL_PATH="$BACKUP_DIR/$SQL_GZ"
SQL_SIZE=$(gzip -l "$SQL_PATH" | awk 'NR==2 {print $2}')
gunzip -c "$SQL_PATH" | pv -s "$SQL_SIZE" | mysql -u"$ROOT_USER" -p"$ROOT_PASS" "$DB_NAME"

echo
echo "📂 Extracting public files…"
tar -xf "$BACKUP_DIR/$PUB_TAR" -C "$SITE_DIR/public"

echo
echo "🔐 Extracting private files…"
tar -xf "$BACKUP_DIR/$PRIV_TAR" -C "$SITE_DIR/private"

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
echo "🧹 Clearing cache and running migrate…"
bench --site "$SITE" clear-cache
bench --site "$SITE" migrate

echo
echo "🟢 Disabling maintenance mode…"
bench --site "$SITE" set-maintenance-mode off

echo
echo "🔄 Restarting supervisor services…"
sudo supervisorctl restart all

echo
MODE_TEXT="production"
[[ "$IS_STAGING" == true ]] && MODE_TEXT="staging"
echo "✅ Restore complete for $SITE — $MODE_TEXT mode."