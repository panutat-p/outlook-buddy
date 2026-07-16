# Outlook Buddy

Native macOS menu-bar watcher that fills Microsoft sign-in pages shown by:

- Microsoft Outlook (`com.microsoft.Outlook`)
- Microsoft Teams (`com.microsoft.teams2`)

It fills the Microsoft 365 email and password, then stops. MFA, number matching,
CAPTCHA, consent, and device-management prompts always remain manual.

When both apps expire together, Outlook is handled first. The watcher waits for
its login/MFA flow to finish and gives Microsoft shared SSO a short propagation
window. If that closes Teams' login, Teams is skipped; if Teams' dedicated login
window remains, the same credentials are submitted there next.

## Setup

1. Create `.env` in this project:

   ```bash
   cp .env.example .env
   ```

   Set:

   ```dotenv
   MICROSOFT_EMAIL=you@example.com
   MICROSOFT_PASSWORD=your-password
   ```

   To load credentials from a different file:

   ```bash
   OUTLOOK_BUDDY_ENV=~/.config/outlook-buddy.env \
     ./scripts/microsoft-login-buddy.swift
   ```

2. Grant Accessibility to the terminal that launches the script:

   System Settings → Privacy & Security → Accessibility

3. Start the watcher:

   ```bash
   ./scripts/microsoft-login-buddy.swift
   ```

The menu-bar moon means idle; the yellow bolt means an active sign-in sequence.
The observed Microsoft session is typically about six hours. The watcher sleeps
between prompts and wakes on Outlook/Teams window events, with a low-frequency
safety check; it does not continuously scan the UI.

## Inspect the open login window

Run this from a terminal that already has Accessibility permission:

```bash
./scripts/microsoft-login-buddy.swift inspect
./scripts/microsoft-login-buddy.swift dump
```

`inspect` reports only which app and page type were recognized. `dump` prints
only dedicated Microsoft login surfaces. Both are read-only; email addresses and
editable values are redacted, and secure-field values are never read.
