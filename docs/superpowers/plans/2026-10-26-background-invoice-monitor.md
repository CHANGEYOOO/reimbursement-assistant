# Background Invoice Monitoring Plan

> Implementation follows the user-approved background/menu/notification design with opt-in login launch.

**Goal:** Retain app-level mail metadata polling after closing the main window, with optional notifications and login launch.

**Architecture:** AppRuntime owns a single inbox, mailbox and polling task. A single retained main window hides on close; synchronous draft flush guards hiding and quitting. MenuBarExtra shares the same state. UserNotifications delivers aggregate count-only reminders. SMAppService.mainApp registers only after explicit toggle.

## Scope and checks
- [x] Move mailbox ownership out of View.task; one app-level loop.
- [x] Close hides window; true quit stops polling; save failures prevent close/quit.
- [x] Menu restores window, reports sync/count, syncs manually and quits.
- [x] Opt-in notifications, privacy-safe text, click opens invoice inbox.
- [x] First sync/backfill aggregated; duplicates don't count; pending counts survive incomplete batches.
- [x] Opt-in login launch with system approval/errors reflected honestly.
- [x] Offline policy check, full compile, DMG integrity check; actual OS permission/login/QQ acceptance stays with user.

No Windows update, no GitHub publication. No actual login-item registration, notification permission request or live mailbox connection during development checks.
