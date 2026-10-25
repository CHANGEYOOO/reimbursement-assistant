# AI assistance for amount and transaction date

User approved automatically filling clear amounts, retaining candidates when uncertain; user then added date assistance.

- Keep local OCR first. Extend the current compatible API call with optional independent payment and transaction_date results, reusing existing provider settings.
- Trigger for missing or locally uncertain amounts and missing/invalid dates; retain definite local fields and manual input. Batch unresolved fields into one request.
- Validate money against complete OCR monetary tokens. Normalize negative debit magnitude; reject fabricated values, arithmetic, identifier/date fragments, and refund/incoming auto-selection.
- Validate complete dates from OCR; require payment/transaction evidence for automatic date fill. Do not infer missing years or current/file dates. Otherwise show verified date candidates.
- Model uncertainty or malformed optional results do not invalidate the category or other valid fields. Keep original local candidates and merge verified AI candidates.
- Guard late responses with per-record tokens, config revision and manual-field revisions. No automatic manual confirmation. Refresh displayed amount drafts after an accepted AI fill.
- Preserve schema and previous baseline/package. Package Mac 1.15 after isolated source-validation/store checks and compilation. User performs live API and UI acceptance.
