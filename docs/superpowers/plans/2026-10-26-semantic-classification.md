# Configurable semantic classification

User approved semantic-model assistance and requested custom API settings for DeepSeek and Alibaba. The earlier keyword expansion was paused and is not shipped.

- Preserve the local OCR, amount/date parsing and existing local category rules.
- Add separate DeepSeek, Alibaba Model Studio and custom compatible endpoint/model profiles. Keys use native Keychain only; AI is off by default.
- Automatic AI is limited to newly recognized orders whose category is unresolved; existing/incorrect orders can be rejudged manually using recognized text.
- Send OCR text only, with a task prompt describing the five categories and mixed/unknown cases. Treat OCR as untrusted data. Validate response category, certainty, finish status and size. No executable output.
- Use URLSession, HTTPS, Bearer authorization, 45-second timeout, no redirects, no retry or provider fallback. Keep service error bodies and keys out of user-facing errors.
- Apply only a confident category and default purpose; preserve custom purposes, amount/date and concurrent manual edits. AI suggestions require manual confirmation. Ignore late results after deletion or draft switching.
- Test request/response validation and store application using fabricated data, without user keys or external calls. User tests live provider connection through the settings window and manually accepts UI.

Official protocol references checked 2026-10-26:
- https://api-docs.deepseek.com/
- https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope

Deliverable: Mac 1.14. Baseline Mac 1.10 and existing installation packages remain available.
