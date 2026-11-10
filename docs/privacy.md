# Notation privacy policy

*Last updated: 2026-11-10*

Notation is a free, open-source app (AGPL-3.0-or-later). It has no accounts, no advertising, no analytics tools and no tracking. The author keeps no database of users and stores none of your notes. This page says what data reaches the author's services, what reaches other parties, and what you decide yourself.

**Short version:** the author runs two things on the internet: the **website** (with the web version of the app), which only delivers files, and a *signalling server*, a meeting point that lets your devices find each other when you use live collaboration or device sync. The web host keeps access logs with IP addresses for up to 90 days; the signalling server stores nothing permanent. Everything else stays on your device, or goes to a service **you** choose, under that service's own rules.

## Who is responsible

Noel Aeby (the "author"), the controller under the GDPR. Contact: mail@noelaeby.me, or an issue at https://github.com/nfa04/notation.

## What stays on your device

Your notes, drawings, PDFs, images, flashcards, tasks, reminders and settings are stored in the app's own folder on your device. Notes you lock with a passcode or biometrics are encrypted with a key kept in the system keystore. Handwriting, maths, text and speech recognition, and the built-in AI models, run on the device; recorded sound and your writing are not uploaded by the app. Deleting the app deletes this data. None of this reaches the author.

## The website and the web version

The website and the web version of the app (under `/live/`) are hosted by **lima-city** (TrafficPlex GmbH, https://www.lima-city.de), a web host in Germany, and delivered through **Cloudflare's** content delivery network. Both act **on the author's behalf** under data processing agreements (Art. 28 GDPR). When you open a page, your browser's request passes through Cloudflare to lima-city. Both receive what any web server receives: your IP address, the address of the page, the time, and what your browser says about itself (its user agent).

lima-city logs every request: the full IP address (not shortened), the date and time, the domain and address requested, the status of the answer, the amount of data sent and the user agent. It keeps these access logs for **up to 90 days**, and error logs (which can also contain IP addresses) for up to seven days (https://www.lima-city.de/hilfe/welche-daten-speichert-lima-city-von-webseitenbesuchern). Cloudflare keeps technical logs for the periods in its own documentation (https://www.cloudflare.com/privacypolicy/). The author may look at these logs to find and fix errors, to spot attacks, and to improve the quality of the service; the author does not use them to build profiles of visitors, does not combine them with other data, and does not pass them on.

**Statistics.** lima-city automatically makes basic statistics from these access logs (for example how many pages were requested and how many visitors came, over time), which the author can see in lima-city's administration. They are counts only: they use no cookies, follow no one across sites or visits, and show the author no IP addresses or individual visitors.

*Purpose and legal basis:* delivering the website, keeping it secure, finding errors, and seeing in aggregate how much the site is used in order to improve it. This is the author's legitimate interest (Art. 6(1)(f) GDPR); a website cannot be delivered without your IP address.

**Cookies and storage in your browser.** The website itself sets no cookies and uses no analytics tools, advertising or tracking (only the web host's statistics above, made from its logs). Cloudflare and lima-city may each set a cookie that is needed to keep out automated attacks. The web version stores your notes and settings in your browser (see below). All of this is strictly necessary to provide the service you asked for, so no consent is needed (§ 25(2) no. 2 TDDDG, and the corresponding rules elsewhere).

**The web version.** Everything it needs is delivered from the same website (no fonts or scripts from other services). Your notes and settings live **in your browser** (its IndexedDB and local storage), not on the server; the server only hands out the app's files and never receives your notes. If you set up a profile, its secret is kept in the browser's local storage, and a flag there ("a profile is set up") lets the start page send you straight to the app; neither leaves your browser. A temporary session is erased from the browser the next time the page is opened after its tab was closed. Clearing the site's data in your browser deletes everything the web version stored. In the web version, the features in the sections below work the same way: your browser connects directly to the signalling server, to the storage or AI provider you chose, and to the download sources of the models.

## What the author's signalling server receives

You only touch it if you start a live session, join one, or turn on device sync. The default server is a Cloudflare Worker run by the author (`uninotes-signaling.noel-aeby.workers.dev`), with Cloudflare acting on the author's behalf. You can instead enter your own server in Settings → Live collaboration, and then the author receives nothing at all.

What the server can see:

* **Your IP address**, as any server you connect to does, for as long as the connection is open.
* **That a connection exists**, to which *room*, and when it opens and closes. A room name is 32 random-looking hexadecimal characters derived from a secret that only your devices know. It does not reveal who you are, what the note is called, or what is in it. For device sync the room name changes every day, so the server cannot follow a profile from day to day.
* **How many devices are in a room, and how much data they send** (every message is padded to a multiple of 4 096 bytes, to hide what kind of message it is).
* If a relay is needed (two devices that cannot reach each other directly), **short-lived relay credentials** are handed out. The relay is **Cloudflare's TURN service**: it carries the encrypted traffic between your devices, and Cloudflare sees the IP addresses of both devices and how much data they send, but nothing of what the data says. You can instead enter a relay of your own in Settings → Live collaboration.

What the server cannot see: your notes, their titles, your name, or the contents of any message. Messages are encrypted on your device with a key that is part of the invitation link and never sent to the server.

What the server stores: **nothing permanent.** No log, no database, no accounts, and no IP address is ever written to storage. A room exists only while a device is in it. To limit how often relay credentials are handed out, the server holds a scrambled form (a hash) of your IP address **in memory only**, for the length of the connection and up to an hour after a relay request; it is lost when the server restarts. A hash of an IP address is not anonymous, because anyone who knows the address can compute it, so treat it as the address itself. The only thing the server writes to storage is a count of how much relay data was used and the names of the relay credentials it handed out, with no addresses and no room names. Cloudflare keeps technical logs for the periods in its own documentation (https://www.cloudflare.com/privacypolicy/). The source code of the signalling server is public (`tool/signaling/` in this repository and the Worker repository https://github.com/nfa04/note-signaling-cf-worker), so you can check this and run your own.

*Purpose and legal basis:* connecting your devices when you start or join a session or turn on device sync, and keeping the service secure and its costs bounded. This is the author's legitimate interest in providing the connection you asked for (Art. 6(1)(f) GDPR).

## The people in a live session

When you share a note in a live session, everyone you invite receives what you share (the note, its pages and PDFs, your changes) and the display name you chose. They receive it directly from your device, end-to-end encrypted; the author does not. What they do with it is up to them.

## Processing outside the EU

Cloudflare (the content delivery network, the signalling server, the relay and the address lookup below) is a US company and may process data such as your IP address outside the EU and Switzerland, including in the USA. These transfers rely on Cloudflare's certification under the EU–US Data Privacy Framework and the Swiss–US Data Privacy Framework, and on the standard contractual clauses in Cloudflare's data processing terms. lima-city processes data in Germany.

## Other parties the app can contact

Only when you use the feature in question. Each of these receives at least your IP address and acts on its own account, under its own privacy policy.

| Feature | What is sent, and to whom |
| --- | --- |
| Live collaboration and device sync (direct connection) | To find a route between devices, the app asks **Cloudflare's STUN server** (`stun.cloudflare.com`) for the address the internet sees. Cloudflare receives your IP address. The notes themselves travel end-to-end encrypted, directly from device to device. |
| Models, dictionaries | A download from Hugging Face, GitHub or LibreOffice's dictionary repository, when you switch the feature on. Nothing is sent but what any download sends (your IP address). |
| Cloud sync and sharing (Dropbox, OneDrive, Nextcloud, S3, CalDAV) | Your notes go to the storage account **you** sign in to, encrypted or not as you configure it. Access tokens are kept in the system keystore. The author never sees them. |
| Citation lookup | The DOI, ISBN or title you look up goes to Crossref, Open Library or doi.org. |
| Look-up panel | Opens Google Translate, DuckDuckGo, Wikipedia or a thesaurus with the word you chose, inside the app (Android, iOS, macOS) or in your browser. Those sites may set their own cookies there. |

## AI providers you add yourself

By default, the AI features run on your device and nothing is sent anywhere.

If you add an external AI provider (an OpenAI-compatible address such as OpenAI, or any other service or your own server), the text you ask about, **which can include the content of your notes, the page you are on, and what you type into the chat, is sent to that provider.** This is your decision, and the following applies:

* **You use the provider under its own terms and privacy policy**, which you accept with the provider. The author is not a party to that relationship and is not a controller of what you send there.
* **The author has no influence on, and no responsibility for, what the provider does with your data**: how long it keeps it, whether it uses it to train models, where it processes it, who can read it, or whether it is secure.
* **Read the provider's privacy policy before you add it,** and do not send anything you are not willing to share with that provider. A provider on your own computer or network (for example Ollama on `localhost`) sends nothing to a third party.
* Your API key is stored in the system keystore on your device and is sent only to the address you entered.
* You can remove the provider in settings at any time; this stops further sending but cannot recall what was already sent.

The same goes for every other service in this policy that you connect yourself (Dropbox, OneDrive, Nextcloud, S3, and so on): the author is not involved and cannot change their policies.

## Permissions

* **Camera / photos**: scan pages, add pictures, scan a pairing QR code. Pictures are processed on the device.
* **Microphone**: dictation and recording into a note, on the device.
* **Calendar**: shows your calendar events next to your tasks, and adds events to a calendar when you ask it to.
* **Notifications**: reminders you set; they are scheduled on the device, not sent through a server.
* **Biometrics**: unlock notes you locked. The app only learns whether the check succeeded.
* **Network**: the features above.

## Required data, automated decisions

Using the website and the app is voluntary. The website cannot be delivered, and devices cannot be connected, without your IP address; everything else is optional. There is no automated decision-making and no profiling.

## Your rights

Under the GDPR (and the Swiss FADP) you have the right to **access** the data about you (Art. 15), to have it **corrected** (Art. 16) or **erased** (Art. 17), to **restrict** its processing (Art. 18), and to receive it in a portable format (Art. 20). To use them, write to the contact above.

**Right to object (Art. 21 GDPR):** where data is processed on the basis of legitimate interest (Art. 6(1)(f)), as for the web server logs and the signalling server, you may object at any time for reasons arising from your particular situation. The author will then stop processing it unless there are compelling legitimate grounds or it is needed for legal claims.

In practice, the only data about you that the author controls are the web host's access and error logs (IP addresses, kept up to 90 and 7 days) and, while you are connected, what the signalling server holds in memory. The author cannot tell which log lines are yours unless you say which IP address and time to look for. Your notes are only on your devices and in the services you chose, so the author cannot access or erase them; deleting the app, or clearing the site's data in your browser, deletes them there.

You also have the right to complain to a data protection authority, in particular in the country where you live or work, or where you think the GDPR was broken.

## Children

The app does not knowingly collect personal data from anyone, including children. It has no accounts.

## Changes

Changes to this policy are shown here with a new date. For significant changes the app's release notes will say so.
