# kc — secrets in the macOS Keychain

A small command-line wrapper around the macOS login Keychain for storing
API keys, tokens and passwords, and handing them to other programs without
writing them to `.env` files or shell history.

Secrets are stored as ordinary generic-password items (service `kc`, account =
secret name), so you can also see, edit or delete them in **Keychain Access**.

## Install

```bash
swift build -c release
```

```bash
cp .build/release/kc /usr/local/bin/kc
```

## Usage

```bash
kc set GITHUB_TOKEN            # prompts for the value (hidden input)
echo -n "$VALUE" | kc set X    # or pipe it in
kc set X some-value            # or pass it inline (lands in shell history!)

kc get GITHUB_TOKEN            # print it
kc get GITHUB_TOKEN | pbcopy   # copy it (no trailing newline when piped)
kc list                        # names only, never values
kc delete GITHUB_TOKEN

# Run a command with secrets exported as environment variables.
# NAME exports as $NAME; NAME=VAR exports as $VAR.
kc run GITHUB_TOKEN DB_PASS=PGPASSWORD -- psql -h db.example.com
```

### Deploying: push secrets to your host

A deployed app needs its secrets on the host, but the Keychain can stay the
one place you edit them. `kc sync` pushes them into a host's secret store
through its own CLI, passing each value on stdin (never in arguments or
output):

```bash
kc sync wrangler RESEND_API_KEY CRON_SECRET          # Cloudflare Workers
kc sync vercel RESEND_API_KEY                        # Vercel, production env
kc sync vercel RESEND_API_KEY -- preview             # another Vercel env
kc sync gh RESEND_API_KEY -- --repo you/your-repo    # GitHub Actions secrets
kc sync fly RESEND_API_KEY -- -a your-app            # Fly.io (one restart)
kc sync --dry-run vercel RESEND_API_KEY              # show the commands only
```

`NAME=VAR` renames on the way out, and anything after `--` goes to the host's
CLI (e.g. `--env production` for wrangler). The CLI is found in
`./node_modules/.bin` first, then `$PATH`. Every secret is read before
anything is pushed, so a missing one fails cleanly.

Put it in front of your deploy so the host is overwritten from the Keychain
every time, and rotating a key is `kc set NAME` followed by a deploy:

```json
"deploy": "kc sync wrangler RESEND_API_KEY CRON_SECRET && wrangler deploy"
```

### Namespaces

Use `--service` (or `$KC_SERVICE`) to keep separate groups of secrets, e.g.
per project:

```bash
kc --service work set AWS_SECRET_ACCESS_KEY
KC_SERVICE=work kc list
```

## Notes

- Items go in your login Keychain, which is unlocked when you log in and
  syncs nowhere unless you've turned on iCloud Keychain for it.
- macOS ties each item's access list to the binary that created it. After you
  rebuild `kc`, the first read of an existing secret may show a
  "kc wants to use your confidential information" prompt — choose
  **Always Allow** to stop it recurring.
- `KeychainKit` is a separate library target if you want to use the same
  wrapper from other Swift code:

  ```swift
  import KeychainKit
  let keychain = Keychain(service: "my-app")
  try keychain.set("token", value: "abc")
  let token = try keychain.get("token")
  ```
