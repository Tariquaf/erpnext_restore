# 🛠️ ERPNext Restore Script with Live Progress

An interactive shell script to restore **ERPNext 15** site backups with **real-time progress** using `pv`, `mysql`, and `tar`.  
Supports both **Production** and **Staging** environments — making it ideal for development and live restore workflows.

---

## 🎯 Features

- 🔍 Lists all available ERPNext sites (`frappe-bench/sites/*`)
- ✅ Lets you select a site interactively
- 📦 Lists available `.sql.gz` backups for the selected site
- ✅ Lets you choose the backup to restore
- 🔐 Prompts for MySQL root (or admin) credentials
- 🧠 Creates the database automatically if it doesn't exist
- 📊 Restores `.sql.gz` SQL database **with live percentage progress** using:
  ```bash
  gunzip -c backup.sql.gz | pv -s SIZE | mysql -u... dbname
  ```
- 📁 Extracts public and private files from `.tar` archives
- 📬 Enables/disables emails and scheduler based on selected environment
- 🔄 Restarts `supervisor`-managed services after restore

---

## 🧩 Environment Modes

When you run the script, you'll be asked to choose one of the following:

- **Production Mode**  
  ✅ Emails and scheduler are **enabled** after restore

- **Staging Mode**  
  🚫 Emails and scheduler are **disabled** after restore  
  ✅ Safe for test restores and staging environments

---

## 📁 Required Backup Files

Backups must follow standard ERPNext format and be placed in the default path:

```
~/frappe-bench/sites/{site}/private/backups/
```

Expected files:

- `{site}-database.sql.gz` — Compressed SQL database dump
- `{site}-files.tar` — Public files archive
- `{site}-private-files.tar` — Private files archive

> ⚠️ All three files must exist for a complete and successful restore.

---

## 🚀 Usage

1. **Place the script** in your bench root directory:

   ```bash
   ~/frappe-bench/restore.sh
   ```

2. **Make it executable**:

   ```bash
   chmod +x restore.sh
   ```

3. **Run the script**:

   ```bash
   ./restore.sh
   ```

4. **Follow the prompts**:

   - Select environment (Production or Staging)
   - Pick a site and backup file
   - Enter MySQL credentials
   - Watch progress and completion messages

---

## 📦 Dependencies

The script checks for the following tools:

- `bench`
- `mysql`
- `pv`
- `gunzip`, `gzip`
- `tar`
- `jq`
- `find`
- `supervisorctl`

If any are missing, the script will print an error and exit.

To install required tools on Debian/Ubuntu:

```bash
sudo apt install pv jq mysql-client gzip tar supervisor
```

---

## ❗ Why Not `bench restore`?

This script **does not use `bench restore`**, because:

- It allows **real-time progress display** via `pv` during SQL import
- Offers more control over the restoration process
- Supports fine-grained logging, customization, and visibility

## If you'd prefer to use restore_bench.sh, make it executable and let Bench manage the restore flow automatically. 

---

## ✅ Example Output

```bash
📥 Restoring SQL database with % progress…
27.3MiB 0:00:03 [ 8.2MiB/s] [========>                    ]  32%
```

---

## 🧠 Tips

- Consider backing up your existing database before restoring.
- This script is best used on **ERPNext 14 or 15** (Frappe v14+).
- You can rename it to `restore_production.sh` if you're only restoring live sites and don't want to deal with the staging mode prompt.

---

## 📬 Support

Found a bug or want to suggest an improvement?  
Open an issue or submit a pull request. Contributions are welcome!

---
