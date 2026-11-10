# Notation signalling server

Live sessions connect devices directly (WebRTC). A *signalling server* is the meeting point where
they find each other first. It relays small messages between the devices of one session and
**keeps nothing**: no log, no storage, no accounts. The messages are sealed with the session key
before they get here, so all it can see is the (meaningless) room name, who connects when, and how
much they send.

There are three interchangeable implementations of the same protocol. Pick whichever you can host:

| | where | needs |
|---|---|---|
| [note-signaling-cf-worker](https://github.com/nfa04/note-signaling-cf-worker) (its own repository) | Cloudflare Workers (a Durable Object per room) | a Cloudflare account; the free plan is enough |
| [`node/`](node) | any machine or container with Node 18+ | `npm install`, a TLS proxy for `wss://` |
| `../signaling_server.dart` | any machine with Dart | `dart run tool/signaling_server.dart` |

In the app: **Settings → Live collaboration → My own server**, enter the address, press *Test*.
Invite links contain the server address, so everyone in a session uses the same one.

## The protocol (version 1)

- A device opens a **WebSocket** to `/live/<room>` where `<room>` is **32 lowercase hex digits**
  (derived from the session secret). Use `wss://` on the internet.
- The server sends every **text** frame it receives to **every other** device connected to the same
  room, unchanged. It never sends a frame to its sender, and it does not interpret them. (The app
  sends one JSON object per frame, `{"p": "<base64 of a sealed message>"}`.)
- **Limits** (all implementations must apply these; clients rely on them):
  - at most **8** devices per room: the 9th connection attempt gets **HTTP 429** and no WebSocket;
  - a frame larger than **65 536 bytes** (UTF-8), or a **binary** frame, closes that connection with code **1008**;
  - more than **60 frames in one second** from one device closes that connection with code **1008**.
- A text frame that is exactly `ping` is answered with `pong` to its sender and not relayed (the keep-alive, as in `/sync` rooms:
  a client that hears no `pong` takes the connection for dead, after a network change say, and makes a new one).
- Anything that is not a WebSocket upgrade to `/live/<32 hex>` gets **HTTP 404**.
- A room exists while a device is in it; when the last one leaves, nothing is left.
- Nothing is logged about the content; operators should not log more than they must (addresses are
  personal data).

Run the conformance tests against any server (from the repository root):

    SIGNALING_URL=ws://127.0.0.1:8787 flutter test test/collab/signaling_test.dart

Without `SIGNALING_URL` the tests start the Dart server themselves.

## Profile sync rooms (version 2 addition)

Devices of one profile (see "Sync profile" in the app) meet in `/sync/<room>`, where `<room>` is **32 hex digits: the first 16
bytes of the SHA-256 of an Ed25519 public key**. That key pair is made from the secret of the profile, so the server can check
that a device knows the secret without ever seeing it:

1. On a WebSocket upgrade to `/sync/<room>` the server sends `{"s":"challenge","n":"<32 hex random>"}`.
2. Within **8 seconds** the device answers `{"s":"auth","k":"<base64 public key, 32 bytes>","g":"<base64 signature, 64 bytes>"}`.
   The signature is Ed25519 over the UTF-8 text `uninotes-sync-v1|<room>|<n>`.
3. The server accepts if `SHA-256(k)[0..16]` is `<room>` and the signature is valid, and answers `{"s":"ready"}`. Otherwise it
   closes with code **1008** ("no proof"). A fresh nonce for each connection means an old proof is worthless.
4. From then on the room works like a `/live` room, for devices that have proven themselves only: text frames go to every
   other proven device, and a device that has not proven itself neither hears nor is heard. At most **8** proven devices
   (the 9th is closed with **1013**); at most **16** devices that are still proving themselves (more: **HTTP 429**).
5. A text frame that is exactly `ping` is answered with `pong` to its sender and not relayed (the keep-alive; the Cloudflare
   Worker answers it without waking the room, so an idle room costs nothing). The app pings every 20 seconds and makes a new
   connection when it has heard nothing for 45 (a connection that died without closing, after a change of network).
6. When a proven device's connection closes, the server sends `{"s":"left"}` to the other proven devices of the room - not
   *which* device left; the devices ask each other who is still there, and one that does not answer within a few seconds is
   taken for gone. A proven device that sent nothing (not even a ping) for **70 seconds** is closed (its network vanished and
   no close will ever come), and the others are told the same way. A server without this still works; the devices then notice
   a device that went without a word only when it misses its signs of life (about two minutes).

The room name changes every day (the key is made from the secret and the UTC date), and the devices pad every message to a multiple of 4096 bytes before sealing it, so that the server can neither follow a profile from day to day nor tell the kinds of messages apart by their length.

The server learns that *some* device with the secret is online (a connection to the room), and when; that is the presence the
app's opt-in "keep my devices in sync automatically" setting gives away. Messages stay sealed with a key from the secret.

## Relay servers (version 3 addition, optional)

Two devices that cannot reach each other directly (both on mobile networks, say) need a relay (TURN server). A server that has one
hands out its credentials to the devices that are in a room:

1. A device in a `/live` room, or a *proven* device in a `/sync` room, sends the text frame `{"s":"ice"}`.
2. The server answers **to that device only** (the frame is never passed on) with one text frame:
   - `{"s":"ice","servers":[{"urls":["turn:...","turns:..."],"username":"...","credential":"..."}],"ttl":7200}`, the servers in the
     form WebRTC takes, and the seconds they work for; or
   - `{"s":"ice","none":"<reason>"}`: `unconfigured` (this server has no relay), `limit` (its budget is used up), `unavailable` or `busy`.
3. A server that does not know the question may answer nothing; the app gives up after 3 seconds and does not ask that server again
   for half an hour. The Node and Dart servers answer `unconfigured` at once.

The app adds what it is given to its STUN servers (and to the relay that the person may have entered in the settings) for the
connections it makes through that server, and asks again shortly before the credentials end.
The Cloudflare implementation (its own repository, linked above) is the one that has a relay, with a budget: see its README.

## Which one for what

- **Public, always on, no machine to look after:** Cloudflare Workers. See the README of the Cloudflare repository.
- **Your own network, a VPS, a Raspberry Pi, a container:** Node (or Dart).
- Moving from one to another changes nothing in the app but the address.
