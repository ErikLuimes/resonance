# Security

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately
instead: on GitHub, open the repository's **Security** tab and click
**Report a vulnerability**. Only the maintainer sees it.

Say what you found, how to reproduce it (a file, a link or the steps), which
version of Resonance you used (About Resonance shows it) and what an attacker
could do with it. Resonance is maintained by one person in their spare time:
you'll get an answer within a week, usually sooner, and a fix ships as an
update that every copy installs by itself.

## Supported versions

Only the newest release gets fixes. Resonance updates itself (Check for
Updates… in the app menu), so that's the version to test against.

## What's in scope

- The Resonance app for the Mac, including its Quick Look extension
- The `resonance` command line tool and the assistant (MCP) server it runs
- The Raycast extension
- The share server behind `useresonance.app/t/` links
- The website and its update feed

Problems in the Phosphor engine Resonance is built on belong with
[Phosphor](https://github.com/sandlbn/Phosphor); problems in libsidplayfp,
Sparkle or other libraries belong with those projects. If you're not sure
where something belongs, report it here and it'll be passed on.

## How Resonance protects you

- **Signed and notarized.** Releases are signed with the Developer ID of team
  `R4D8QN85WK` and notarized by Apple. To check a download:
  `spctl --assess --type execute -v /Applications/Resonance.app` should say
  `source=Notarized Developer ID`.
- **Sandboxed.** The app runs in the App Sandbox: it reads only its own
  folder and the files and folders you give it. Its few exceptions are listed
  in [`design/sandbox/README.md`](../design/sandbox/README.md).
- **Signed updates.** Updates are checked against the app's EdDSA key before
  they're installed, as well as Apple's signature.
- **SID tunes are emulated.** A SID file is a small Commodore 64 program; it
  runs inside an emulated C64, never on your Mac. A tune that breaks out of
  the emulator, or crashes the app, is worth reporting.
- **Local control only.** The command line tool reaches the app through a
  Unix socket that only your user account can open; there's no network port.
