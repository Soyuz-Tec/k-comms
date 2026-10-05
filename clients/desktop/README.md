# K-Comms Desktop evaluation

This package uses the existing `clients/web` UC interface with Electron. Its
committed default is disconnected, unsigned and has automatic updates disabled.
No native build, OS media, signing or distribution qualification is implied.

Use the [Desktop build and qualification runbook](../../docs/12-development-guides/desktop-client.md)
and [ADR-0105](../../docs/02-architecture/adr/0105-packaged-electron-uc-client.md).

Source checks: `npm run check:source` and `npm test`. Build the current web UI
first, set explicit public origin configuration for an authorized evaluation,
then `npm run prepare:ui` and `npm run package:unsigned` on the target OS.
Do not supply signing credentials to this evaluation package.
