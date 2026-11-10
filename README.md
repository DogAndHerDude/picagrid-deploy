# Picagrid deployment

How Picagrid runs in production, on one Hetzner server, behind Traefik.

| Address | What |
| --- | --- |
| `picagrid.com` | The homepage. `www.picagrid.com` redirects here |
| `app.picagrid.com` | The app, and Kratos at `/kratos` |
| `api.picagrid.com` | The API |
| `s3.picagrid.com` | Garage, for browsers sending uploads. It only accepts `PUT` and `OPTIONS` |

## How updates arrive

1. Pushing to `main` in `picagrid-api`, `picagrid-ui`, `picagrid-website` or `picagrid-ory` runs the tests and pushes an image to GitHub's registry.
2. The server checks the registry every minute, with `scripts/deploy.sh` on a timer.
3. If something changed, it backs up the database when the API or Kratos changed, runs migrations, and starts the new containers. Only what changed restarts.
4. If health checks fail, the old images go back and that build is skipped until a newer one arrives. `ALERT_WEBHOOK_URL` hears about it.

Changes to this repository, like `compose.yaml`, arrive the same way. The server asks, rather than being told, so it has no public webhook to secure and GitHub holds no way into it.

## First deployment

### Before the server

1. **Create this repository** on GitHub as `DogAndHerDude/picagrid-deploy`, and push it.
2. **Push the other four**, with their `.github/workflows/publish.yml`, and check the images appear under the account's Packages.
3. **DNS:** A records (and AAAA, if you use IPv6) for `picagrid.com`, `www`, `app`, `api` and `s3`, all to the server. Do this early, so they've spread by the time certificates are requested.
4. **Google sign-in:** create an OAuth client with the redirect address `https://app.picagrid.com/kratos/self-service/methods/oidc/callback/google`.
5. **Microsoft sign-in:** register an app with the redirect address `https://app.picagrid.com/kratos/self-service/methods/oidc/callback/microsoft`, and turn on the optional `xms_edov` claim under Token configuration. Without it nobody can sign up with Microsoft, on purpose: see `oidc.microsoft.jsonnet`. The sign-in screen shows its button either way, so set this up before people see it.
6. **Mail:** an SMTP login from a provider like Postmark, Brevo or Amazon SES, with SPF and DKIM set up for the domain. Without those, invites land in spam.
7. **A GitHub token** for the server to pull images: a classic personal access token with only `read:packages`.

### The server

An Ubuntu 24.04 server, with your SSH key added when creating it. In Hetzner's firewall, allow only 22, 80 and 443.

```sh
scp scripts/setup.sh root@SERVER:
ssh -t root@SERVER bash setup.sh
```

It installs Docker, a firewall, fail2ban and automatic security updates, adds swap, makes a `deploy` user, turns off SSH passwords, generates the secrets, asks for the rest, checks DNS, and starts everything. It'll show you a deploy key to add to this repository. Running it again is safe.

**Include your own address when it asks who can sign up without an invite**, as the app is invite-only and you'd otherwise be locked out.

### Check it

- `sudo -u deploy /opt/picagrid/scripts/status.sh`
- Sign in, create an organisation, place a photo and a PDF, and export.
- Send yourself an invite, and read it in a real inbox.

## Day to day

Run these on the server as the `deploy` user, from `/opt/picagrid`.

| To | Run |
| --- | --- |
| See how it's doing | `scripts/status.sh` |
| Watch deploys | `journalctl -fu picagrid-deploy` |
| Read a service's logs | `docker compose logs -f api` |
| Go back to a build | `scripts/rollback.sh api <commit sha>` |
| Follow `main` again | `scripts/rollback.sh api main` |
| Back up now | `scripts/backup.sh` |
| Restore a backup | `scripts/restore.sh backups/<when>` |
| Change a setting | Edit `.env`, then `docker compose up -d --wait` |

Allow someone to sign up without an invite by adding them to `SIGNUP_ALLOWED_EMAILS` in `.env`.

## Uploaded files

Files are in one bucket in Garage, on one node keeping one copy, which is meant for testing within the team. `scripts/deploy.sh` generates its settings in `.env`. Browsers upload straight to it, so restarting the API doesn't interrupt an upload, and everything is read through the API.

To use another S3 service, create a bucket and set `S3_ENDPOINT`, `S3_PUBLIC_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY` and `S3_SECRET_KEY` in `.env`. The API sets the bucket's CORS and expiry rules when it starts, and logs it if it can't.

## Backups

Every night at 03:00 UTC, and before any update to the API or Kratos: both databases, and nightly the uploaded files. They're kept for two weeks in `backups/`.

**Set `BACKUP_RSYNC_TARGET`.** Backups on the server don't survive losing the server. A Hetzner Storage Box works, using the `deploy` user's SSH key. Try a restore now and then, as a backup you've never restored is only a hope.

Going back to an older build doesn't undo migrations. If that build can't run on the newer database, restore the backup taken before the update.

## Things to keep in mind

- **`.env` holds every secret and is the one file you can't get back.** Keep a copy somewhere safe, like a password manager. Losing `KRATOS_CIPHER_SECRET` makes stored two-factor secrets unreadable, and changing the domain breaks every passkey.
- The Traefik dashboard isn't exposed, and neither are Postgres or Kratos' admin API.
- One server means updates cause a few seconds of downtime for what's restarting, and that server is a single point of failure.

## Trying it locally

`test/up.sh` runs all of this on your machine on `picagrid.localhost`, with HTTPS and subdomains. Use it after changing how the pieces connect, since development runs everything on one address and can't catch those problems. `test/down.sh` removes it.
