# Windows Mac 1.27 parity implementation plan

Goal: ship a Chinese Windows EXE matching the frozen Mac 1.27 workflows and business rules, retaining icon and Excel column order.

Architecture: extend the existing .NET 10 WinForms app. ProjectStore owns projects and orders; InvoiceRepository owns inbox and project invoice membership; SettingsStore owns encrypted settings; MainForm composes the UI. MailKit handles IMAP without marking mail read, PdfPig/PDFium plus Tesseract extract invoice text/layout. No Mac runtime code changes.

## Scope and contracts
- ProjectRecord: Id, Title, Expenses; project data under AppPaths.Projects/<id>, owned screenshot copies.
- AppSettings.Current: AiEnabled, AiProvider, AiEndpoint, AiModel, ApiKey, MailEnabled, MailAddress, MailPassword, MailSince, NotificationsEnabled, StartupEnabled, CacheLimitMb (secrets encrypted on disk).
- InvoiceRepository: Root data under AppPaths.Invoices; list InvoiceRecord; import, download, assign/unassign, project export, cache maintenance; event Changed.
- Shared categories: 待分类、交通、餐食、住宿、道具采购、其他.
- Only ordinary electronic VAT invoices accepted; filename amount first, otherwise total tax inclusive. Every PDF page verified; no user type override.
- New mail auto-download after per-account activation; historic metadata manual; account isolation and persisted failures; no infinite cache redownload.
- Delete via Windows recycle bin. Development file deletion only /usr/bin/trash.

## Work
- [ ] Freeze Mac baseline and create branch; establish shared types and build tools.
- [ ] Port order recognition + AI prompts/output validation, same-text parity checks.
- [ ] Implement invoice parsing/repository, strict allowlist, cache, project export and invoice workspace.
- [ ] Implement encrypted settings, QQ IMAP, tray/background/notifications/startup settings.
- [ ] Implement autosaved projects, complete order editor/search/review/preview/undo and integrate all modules.
- [ ] Compile win-x64, run portable unit/fixture checks; Windows build/installer smoke checks where possible.
- [ ] Package self-contained EXE installer, verify artifact and document real-device manual checks.

Non-goals: no GitHub release without request; no claim real Windows UI/OCR/QQ acceptance from Mac cross-compilation alone. No user data deletion or live mailbox/API calls in automated checks.
