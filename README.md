# Erpnext Restore Script
Restore backup for staging for ERPNext 15

End-to-end restore script that uses the official bench restore command (so you don’t have to manually drop/create the database). It will:
- List your sites
- Let you pick one
- List that site’s .sql.gz dumps
- Let you pick one
- Prompt for your MySQL root (or admin) credentials
- Run bench restore … --with-public-files … --with-private-files …
- Disable emails & scheduler
- Restart services

Save as restore.sh in your bench root, chmod +x, then run ./restore.sh

*Please note that path of backup with its respective private and public files must be in default location i.e., ~/frappe-bench/sites/frappe.site/private/backup
