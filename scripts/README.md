# scripts

## microsoft-login-buddy.swift

A dependency-free Swift menu-bar watcher using AppKit, macOS Accessibility, and
process-targeted Core Graphics keyboard events.

Commands:

```bash
./scripts/microsoft-login-buddy.swift        # standing watcher
./scripts/microsoft-login-buddy.swift once   # handle one visible login page
./scripts/microsoft-login-buddy.swift inspect # report recognized pages, no input
./scripts/microsoft-login-buddy.swift dump   # redacted Accessibility dump
```

The watcher recognizes:

- account chooser → presses **Use another account**
- email page → fills email and presses **Next** / **Continue**
- password page → fills password and presses **Sign in** / **Next**

After password submission it enters a cooldown and performs no MFA actions.
The known Microsoft “sign-in timed out” response is retried once within the
active sequence; a second timeout fails closed.

If Outlook and Teams both have expired sessions, Outlook is handled first. The
script waits for that login window to close, allows shared SSO to propagate, and
then handles Teams only if its dedicated login window is still present.
