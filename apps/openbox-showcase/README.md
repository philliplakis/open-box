# OpenBox macOS showcase

Requires macOS 26 and Apple's `container` CLI.

```sh
./apps/openbox-showcase/run.sh
```

The command stays attached until the app window closes. The script reuses a
service already listening on `127.0.0.1:7070`, or starts one for the lifetime
of the app. The app uses the local `OpenBoxClient` package to show health,
workspace registration, workspace-backed box lifecycle, environment names,
and `git status`.

The workspace field starts with a tiny generated Git repository so the full
flow is quick to try. Replace it with any existing local folder when needed.

The service forwards the standard API-key environment variables when they are
set. Add more names with a space-separated allowlist:

```sh
MY_TOKEN=value OPENBOX_ALLOW_ENV=MY_TOKEN ./apps/openbox-showcase/run.sh
```
