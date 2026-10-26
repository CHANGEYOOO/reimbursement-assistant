# Invoice Inbox Implementation Plan

> **For agentic workers:** Use subagent-driven-development. Keep existing project drafts compatible.

**Goal:** Add a global invoice inbox, QQ mail metadata collection and explicit on-demand attachment download, with manual assignment to projects.

**Architecture:** Sidebar selects global inbox or existing project. Inbox owns copied files, remote references and assignment metadata. QQ read-only IMAP collects headers/BODYSTRUCTURE/INTERNALDATE only; attachment bytes are fetched only by explicit download, preview or assignment.

**Tech Stack:** SwiftUI/Combine, Foundation JSON atomic files, PDFKit/Vision, Network TLS, Security Keychain.

**Spec:** User-approved conversation and reference image; latest override: do not automatically download attachments.

## Global Constraints
- Mac Chinese UI, no Windows changes, no GitHub publication without request.
- Group by mail receipt date (INTERNALDATE): this month, last month, earlier yyyy-MM; newest first. Manual import uses import date.
- Global inbox filters by buyer title/date/assignment; one invoice belongs to at most one project.
- Project removal releases assignment; keep inbox original. Old project files remain usable.
- Keys in Keychain only. Read-only mail, no read-state changes, no server message deletion. Only TLS QQ IMAP.
- Explicit attachment download before local OCR; show unknown amount/title before downloading. Link-only messages require manual download.
- Delete files only via /usr/bin/trash; leave test temp data.

## Review Focus
- UIDVALIDITY changes must not download a different email attachment.
- Failed sync/download must remain retryable without duplicate cards/files.
- Cross-project assignment cannot duplicate an invoice; failed writes cannot silently lose source.
- Malicious MIME filenames/ZIP paths cannot escape local storage.
- Opening existing drafts must preserve invoices and order workflow.

## Tasks
- [x] Storage: InboxInvoice/InvoiceInboxStore, reuse InvoiceStore OCR, atomic metadata and explicit download, assignment/reconciliation; offline checks.
- [x] Mail: Keychain config, read-only TLS IMAP metadata and on-demand fetch, MIME/bodystructure parsing; offline protocol checks.
- [x] UI: receipt-month cards, filters/selection/preview/edit/assignment; sidebar integration with existing projects.
- [x] Integrate mailbox settings and 5-minute metadata sync while running; retain errors/link-only notices and explicit sync button.
- [x] Verify offline checks/full build, inspect changes, produce Mac 1.20 DMG. Real QQ login and UI acceptance are left to user.
