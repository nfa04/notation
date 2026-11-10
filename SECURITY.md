# Security policy

Notation encrypts locked notes, live sessions and device sync end to end, and runs a public signalling server. If you find a way around
any of that, please tell us privately first so it can be fixed before it is used against people.

## Reporting a vulnerability

**Please do not open a public issue.** Instead, either:

* use GitHub's private reporting: the **Security** tab of https://github.com/nfa04/notation → **Report a vulnerability**; or
* write to **mail@noelaeby.me** with "Security" in the subject.

Please include what is affected (app version and platform, the web version, or the signalling server), the steps to reproduce it,
and what an attacker could do with it. A proof of concept helps but is not required.

## What happens next

Notation is maintained by one person in their spare time, so these are aims, not promises:

* an answer that the report arrived within **7 days**;
* an assessment, and a plan for a fix, within **30 days**;
* a fix released, then the problem disclosed together with the fix. You are credited unless you would rather not be.

Please give us **90 days** (or until a fix is out, if that is sooner) before you disclose a problem publicly.

## Supported versions

Only the latest release gets security fixes. Notation is an early beta (0.0.x); please update before you report.

## In scope

* The app on every platform, and the web version (`/live/` on the website).
* The cryptography of locked notes, invitation links, live sessions, device sync and the cloud copies.
* The signalling server and its relay credentials: `tool/signaling/` here and https://github.com/nfa04/note-signaling-cf-worker.
* Extensions escaping their sandbox or their granted permissions.
* The MCP server for desktop assistants exposing more than the permissions allow.

## Out of scope

* Problems in services you connect yourself (Dropbox, OneDrive, Nextcloud, S3, AI providers); report those to the service.
* Attacks that need an already unlocked device, or root/administrator access to it.
* Using up the relay's daily budget or the free plan's request limit by flooding: the server is built to fail closed (no relay) when
  that happens. Ways to get past the limits *without* many addresses are in scope.
* Missing security headers or best practices on the website without a concrete attack.

## Safe harbour

If you act in good faith, only test against your own data and devices (or a signalling server you run yourself), do not degrade the
public signalling server for others, and report what you find privately, we will not take legal action against you.
