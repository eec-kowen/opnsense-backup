# OPNsense Backup

Backs up OPNsense firewall configurations through the REST API, keeps them in git, and alerts Teams/Discord when something breaks.

Replaces the old SSH/SCP-based `pfsense-backup`.

## How it works

For every firewall in the list file, `opnsense_backup.sh`:

1. Calls `GET /api/core/backup/download/this` with that firewall's API key (HTTP basic auth; credentials are handed to curl on stdin, never on the command line).
2. Checks the TLS certificate against a pinned public key (or a CA file / system store).
3. Validates the download: HTTP 200, at least 1 KB, well-formed XML, root element `<opnsense>`, and not less than `MIN_SIZE_PERCENT` (default 50%) of the previous copy. A download that fails any check is kept as `config_<name>.xml.failed` and the last good copy stays.
4. Replaces `config_<name>.xml` (mode 600) only if it changed.
5. Commits changed files and pushes. If a push fails, the commit stays local and is pushed on the next run.
6. Alerts on the first failure, repeats at most every `WEBHOOK_REPEAT_HOURS` (default 24) while it keeps failing, and sends one "recovered" message when it works again.

Firewalls are backed up in parallel. A lock stops runs from overlapping. Exit code is 0 only if every firewall and the git step succeeded.

## Requirements

`bash` 4.4+, `curl`, `xmllint` (libxml2-utils), `git`, `flock` (util-linux), `jq` (for webhooks), and `openssl` (to get a pin).

## OPNsense side: a least-privilege API user

1. **System → Access → Users → Add**: e.g. `backup-api`. Set a long random password you don't keep, and leave the login shell as `/sbin/nologin`.
2. Under **Effective Privileges**, give it only **Diagnostics: Configuration History**. That privilege covers `/api/core/backup/*`.
3. Save, then click the API key **+** button for the user. The browser downloads `<hostname>_backup-api_apikey.txt`.
4. Put that file on the backup host as `$API_KEY_DIR/<name>.txt` with mode 600:

   ```bash
   install -d -m 700 ~/.config/opnsense-backup/keys
   install -m 600 ~/Downloads/OPNsense.internal_backup-api_apikey.txt ~/.config/opnsense-backup/keys/<name>.txt
   shred -u ~/Downloads/OPNsense.internal_backup-api_apikey.txt
   ```

## Setup

```bash
cp .env.example .env                 # edit paths and webhooks
cp opnsense_list.txt.example /path/to/opnsense_list.txt   # add firewalls + TLS pins
./opnsense_backup.sh --dry-run       # fetch + validate only; writes nothing, sends nothing
./opnsense_backup.sh
```

`BACKUP_DIR` must already be a git repository. Add an `origin` remote with an upstream branch if you want pushes.

### TLS pin

The default OPNsense GUI certificate is self-signed for `OPNsense.internal`, so normal verification fails when you connect by IP. Pin its public key instead:

```bash
echo | openssl s_client -connect 10.60.99.254:443 2>/dev/null | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
```

If the GUI certificate is replaced, runs fail with "TLS public key does not match the pinned key" until you update the pin. That is deliberate.

## Scheduling

Hourly from the user's crontab (`crontab -e`):

```cron
0 * * * * /home/kowen/Documents/Projects/opnsense-backup/opnsense_backup.sh >/dev/null 2>&1
```

Everything goes to `LOG_FILE`. Failures are reported through the webhooks, not cron mail.

## Webhooks

`send_webhook.sh` builds JSON with `jq`, so quotes and newlines in messages are safe.

- Teams URLs on `*.webhook.office.com` (legacy Office 365 connectors) get a MessageCard. Microsoft is retiring these connectors, so plan to move to a Teams Workflows webhook.
- Any other Teams URL (Workflows / Power Automate "post to a channel when a webhook request is received") gets an Adaptive Card.
- Discord gets a plain message.

## Security notes

- `config.xml` contains secrets: password hashes, certificate private keys, WireGuard/OpenVPN keys, SNMP communities and so on. Keep the backup repository private. The script writes the files mode 600.
- API keys live outside both repositories (`API_KEY_DIR`). This repo's `.gitignore` also excludes `.env`, `keys/` and `*apikey*.txt`.
- Give the API user only the Configuration History privilege. A full-admin key on a backup box would be a much bigger target.

## Troubleshooting

| Message | Meaning |
|---|---|
| `HTTP 401` | Key or secret is wrong, or the key was deleted |
| `HTTP 403` | The API user is missing the "Diagnostics: Configuration History" privilege |
| `curl error 90` | The GUI certificate's key changed. Check that it was intentional, then update the pin |
| `curl error 7` / `28` | Can't reach the firewall: routing, the GUI listen interface, or a firewall rule |
| `XML root is <…>` / `not well-formed` | The download wasn't a config file. Look at the `.failed` file |
| `new config is N bytes vs M` | The download shrank sharply. Look at the `.failed` file; if the shrink is genuine, delete the old file and rerun |
