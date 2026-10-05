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

The desktop shell has native File/Edit/View/Help menus and operating-system
window controls. Windows/Linux use a 44px native controls overlay; macOS keeps
its native traffic lights and system menu. The shared web header opens real
native popup menus, reserves the native control area, and synchronizes the
selected light/dark/system theme. Close and Quit use the existing native
window/media lifecycle; reload and developer-tool commands are absent.
Custom UI intents have no native accelerators, so renderer shortcuts retain
their editor, modal and consent guards.

The frozen preload adds only shell state, one finite menu category, one finite
theme choice, and a subscription to bounded UI intents. Every request still
requires the current packaged main frame; menu display additionally requires
the foreground window. Explicit user Edit menu operations use native roles;
no renderer clipboard, window-control, filesystem, network or generic IPC API
is exposed. Public entry menus reuse existing guarded UI actions without
granting protected workspace access.

`npm test` covers native menu construction, ownership/argument rejection,
theme and close-role behavior, and actual preload subscription cleanup with
fake Electron providers. Native controls, menu placement/keyboard use and
platform accessibility still require target-OS evaluation receipts.
