# Automatic local-to-AI handoff

User requested automatic AI after local-rule failure, then explicitly chose to allow confident AI results to export without a manual confirmation click.

- Centralize per-field eligibility. Local OCR completion, enabling/saving AI settings, and opening a draft dispatch eligible unresolved records once per event. No completion-triggered retry loop.
- A manually chosen category must not suppress missing amount/date analysis. Protect manually edited fields and saved values, skip duplicates, in-progress rows, completed rows and empty OCR text.
- Confident source-validated AI outputs fill fields and clear only resolved warnings. Do not set the human-confirmation flag. Persist an optional AI marker and show AI-recognized status; missing optional fields remain backward-compatible.
- Uncertain fields retain candidates and export blockers. User edits invalidate late requests. Existing provider/privacy settings remain in effect.
- Add isolated eligibility, exportability and legacy JSON compatibility checks, compile/sign/package Mac 1.17. User handles live API and UI acceptance.
