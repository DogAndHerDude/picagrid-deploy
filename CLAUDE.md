# Picagrid deployment

Production, on one Hetzner server. See `README.md`.

- `compose.yaml` is production. Settings and secrets are in `.env` on the server, never here.
- `scripts/deploy.sh` is what the server's timer runs. It has to stay quiet and do nothing when nothing changed, and must never leave the app down when a build is bad.
- These run unattended, and over a real database. Test a change with `test/up.sh`, against the local registry it starts: that's how the bugs here were found. Run `shellcheck` too.
- The app and API are on different addresses here, unlike development. Anything that fetches a file needs `credentials: "include"` and `fileUrl`, and layouts must store paths, not addresses.
