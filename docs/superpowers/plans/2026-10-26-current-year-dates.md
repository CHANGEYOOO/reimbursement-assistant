# Current-year completion for month/day dates

User amended the date requirement while GitHub publication was in progress. Finish this update, then publish the latest source and Mac DMG to the existing repository.

- Accept OCR month/day dates using the current Gregorian year at request time. Use a single reference date for request and response validation so crossing New Year does not change interpretation.
- Preserve explicit years. Never reinterpret a full date, invalid full date, price, phone number or order identifier as a month/day date.
- Payment/transaction evidence is still required for automatic fill. Show verified candidates otherwise, and annotate when a year was completed.
- Validate real calendar dates, including leap years. Keep manual values and previous packages/baseline intact.
- Verify deterministic date cases and compatibility, package Mac 1.16, push source plus baseline tag, create GitHub release and upload the new DMG. No real model-key calls in testing.
