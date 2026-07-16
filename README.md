# Outlook Buddy

macOS menu-bar watcher that signs in Microsoft Outlook and Teams with one
Microsoft 365 account. MFA and other verification prompts remain manual.

When both sessions expire, Outlook is handled first. Teams is handled only if
Microsoft's shared sign-in does not authenticate it automatically.

## Setup

1. Create `.env`:

   ```bash
   cp .env.example .env
   ```

2. Add your credentials:

   ```dotenv
   MICROSOFT_EMAIL=you@example.com
   MICROSOFT_PASSWORD=your-password
   ```

3. Grant Accessibility to your terminal:

   System Settings → Privacy & Security → Accessibility

4. Start the watcher:

   ```bash
   ./scripts/microsoft-login-buddy.swift
   ```

The moon menu-bar icon means idle; the yellow bolt means signing in. The watcher
sleeps between the roughly six-hour login sessions.

## Commands

```bash
./scripts/microsoft-login-buddy.swift          # watch continuously
./scripts/microsoft-login-buddy.swift once     # handle visible login windows
./scripts/microsoft-login-buddy.swift inspect  # show detected login pages
./scripts/microsoft-login-buddy.swift dump     # redacted Accessibility dump
```
