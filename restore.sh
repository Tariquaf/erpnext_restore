#!/usr/bin/env bash
set -euo pipefail

# ─── CONFIG ────────────────────────────────────────────────────────────────
BENCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
SITES_DIR="$BENCH_ROOT/sites"

# ─── DEPENDENCY CHECK ──────────────────────────────────────────────────────
for cmd in bench jq find read; do
  command -v "$cmd" >/dev/null 2>&1 \
    || { echo "❌ '$cmd' is required but not installed."; exit 1; }
done

# ─── 1) PICK A SITE ─────────────────────────────────────────────────────────
mapfile -t SITES < <(
  find "$SITES_DIR" -maxdepth 1 -mindepth 1 -type d \
    -exec test -f "{}/site_config.json" ';' \
    -printf '%f\n' | sort
)
[[ ${#SITES[@]} -gt 0 ]] || { echo "❌ No sites found in $SITES_DIR"; exit 1; }

echo "Available ERPNext sites:"
for i in "${!SITES[@]}"; do
  printf "  %2d) %s\n" $((i+1)) "${SITES[i]}"
done

read -rp $'\nSelect site [1]: ' sidx; sidx=${sidx:-1}
(( sidx>=1 && sidx<=${#SITES[@]} )) \
  || { echo "❌ Invalid choice"; exit 1; }
SITE="${SITES[$((sidx-1))]}"
DB_NAME="${SITE//./_}"
BACKUP_DIR="$SITES_DIR/$SITE/private/backups"

echo -e "\n👉 Selected site: $SITE (DB: $DB_NAME)"
echo "   Backups folder: $BACKUP_DIR"
echo

# ─── 2) PICK A BACKUP DUMP ─────────────────────────────────────────────────
mapfile -t DUMPS < <(
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.sql.gz' \
    -printf '%T@ %f\n' | sort -nr | cut -d' ' -f2-
)
[[ ${#DUMPS[@]} -gt 0 ]] \
  || { echo "❌ No .sql.gz dumps in $BACKUP_DIR"; exit 1; }

echo "Available SQL dumps for $SITE:"
for i in "${!DUMPS[@]}"; do
  printf "  %2d) %s\n" $((i+1)) "${DUMPS[i]}"
done

read -rp $'\nSelect dump [1]: ' didx; didx=${didx:-1}
(( didx>=1 && didx<=${#DUMPS[@]} )) \
  || { echo "❌ Invalid choice"; exit 1; }
SQL_GZ="${DUMPS[$((didx-1))]}"
BASE="${SQL_GZ%-database.sql.gz}"
PUB_TAR="$BACKUP_DIR/${BASE}-files.tar"
PRIV_TAR="$BACKUP_DIR/${BASE}-private-files.tar"

echo -e "\n👉 Will restore:\n   • SQL:     $SQL_GZ\n   • Public:  $(basename "$PUB_TAR")\n   • Private: $(basename "$PRIV_TAR")"
read -rp $'\nProceed? [Y/n]: ' ok; ok=${ok:-Y}
[[ $ok =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ─── 3) ASK FOR DB-ROOT CREDENTIALS ────────────────────────────────────────
read -rp "MySQL admin user [root]: " DB_USER; DB_USER=${DB_USER:-root}
read -rsp "MySQL admin password: " DB_PASS; echo

# ─── 4) PERFORM RESTORE ─────────────────────────────────────────────────────
cd "$BENCH_ROOT"

echo -e "\n🔧 Enabling maintenance mode…"
bench --site "$SITE" set-maintenance-mode on

echo "📥 Running bench restore…"
bench --site "$SITE" restore \
  "$BACKUP_DIR/$SQL_GZ" \
  --with-public-files "$PUB_TAR" \
  --with-private-files "$PRIV_TAR" \
  --db-root-username "$DB_USER" \
  --db-root-password "$DB_PASS" \
  --force

echo -e "\n📪 Disabling outgoing emails & pausing scheduler…"
bench --site "$SITE" set-config disable_emails 1
bench --site "$SITE" set-config pause_scheduler 1

echo "🟢 Disabling maintenance mode…"
bench --site "$SITE" set-maintenance-mode off

echo "🔄 Restarting supervisor-managed services…"
sudo supervisorctl restart all

echo -e "\n🎉 Restore complete for $SITE!"
