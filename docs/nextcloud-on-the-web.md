# Using your own Nextcloud from the web version

The web version talks to your Nextcloud straight from the browser (WebDAV for the cloud-folder sync, CalDAV for the calendar). A browser
only lets a page do that when the server says so with **CORS headers**. Dropbox and OneDrive send them; a Nextcloud does not by default, so
if you want to sign in to your profile or sync through your Nextcloud from the browser, set them once on the server or the reverse proxy in
front of it. Native apps (Android, iOS, desktop) are not affected.

> These snippets were written from the requests the app makes (below) and have **not been tried against a real Nextcloud**. Test them with
> the check at the end.

## What the app sends

* Methods: `GET`, `POST`, `PUT`, `DELETE`, `PROPFIND`, `MKCOL` (the folder sync); `REPORT`, `PROPPATCH`, `MKCALENDAR` (the calendar of the same account).
* Request headers: `Authorization` (basic, with an app password), `Content-Type`, `Depth`, `If-Match`, `If-None-Match`, `OCS-APIRequest` (the sharing calls under `/ocs/`: shared folders, sharing with people; it is not a header a browser sends on its own, so it is preflighted and **must** be in the list below).
* `User-Agent` is **not** sent from the browser (a page may not set it; the app leaves it out on the web). An older web build did send it, and Firefox then asks for it
  in the preflight (`Access-Control-Request-Headers: user-agent`), which fails with "header 'user-agent' is not allowed ..." unless the server lists it. Adding `User-Agent` to
  `Access-Control-Allow-Headers` is harmless and makes those builds work too.
* No cookies: the app never asks the browser to send credentials, so `Access-Control-Allow-Credentials` is **not** needed.
* **The login** ("Log in with the browser", Nextcloud's Login Flow v2) is two plain `POST` requests, to `/index.php/login/v2` and `/index.php/login/v2/poll`
  (no custom headers, so no preflight, but the answers need `Access-Control-Allow-Origin` or the page cannot read them). The login page itself opens in a
  tab of its own and needs nothing.
* The rest is under `/remote.php/dav/` (and `/ocs/` for sharing). A request with `Authorization` and a method like `PROPFIND` is **preflighted**: the browser first sends
  an `OPTIONS` request *without* credentials and only goes on if the answer carries the headers below. That `OPTIONS` must get a `2xx`
  answer, not Nextcloud's `401`; this is the part that usually goes wrong, so answer it in the web server before it reaches Nextcloud.

## The headers

For the address the web version is served from, e.g. `https://notation.example.org` (the origin only: no path, no trailing slash; use the
one you open the app at):

| Header | Value |
|---|---|
| `Access-Control-Allow-Origin` | `https://notation.example.org` (the exact origin; not `*`, because the request carries a password) |
| `Access-Control-Allow-Methods` | `GET, POST, PUT, DELETE, PROPFIND, PROPPATCH, REPORT, MKCOL, MKCALENDAR, OPTIONS` |
| `Access-Control-Allow-Headers` | `Authorization, Content-Type, Depth, If-Match, If-None-Match, OCS-APIRequest, Prefer, X-Requested-With` |
| `Access-Control-Expose-Headers` | `ETag, DAV, Content-Type` |
| `Access-Control-Max-Age` | `86400` |
| `Vary` | `Origin` |

## Where to set it

Either on the whole Nextcloud site (simplest: nothing else in the app needs the headers, and they only ever name the one origin you list) or only on
the two paths the app uses, `/remote.php/dav` and `/index.php/login/v2`. The snippets below work for both.

**Answer only browser preflights.** Native clients (the Nextcloud desktop client, DAVx5, Thunderbird, ...) also send `OPTIONS` to `/remote.php/dav` and
rely on Nextcloud's own answer. A rule that answers *every* `OPTIONS` with an empty `204` breaks them. A browser preflight is recognisable: `OPTIONS`,
with an `Origin` header that is your Notation site, and an `Access-Control-Request-Method` header. Only those are answered here; everything else goes on
to Nextcloud untouched.

**Behind more than one proxy, set it on exactly one of them** (preferably the one closest to Nextcloud, which is a plain config file you control). `add_header`
does not replace a header that comes from further back, so with two proxies the browser gets every `Access-Control-*` header twice, and it refuses an answer
with a repeated `Access-Control-Allow-Origin`. Check through the public address that it appears once:
`curl -si -X POST https://cloud.example.org/index.php/login/v2 -H 'Origin: https://notation.example.org' | grep -ci '^access-control-allow-origin'` prints `1`.

## nginx

In the `location` that serves Nextcloud (or in the locations for the paths; on OPNsense see below), replacing `notation.example.org` with the origin:

```nginx
# a preflight: OPTIONS + the Notation origin + Access-Control-Request-Method (nginx has no "and", so a flag is built up)
set $notation_preflight "";
if ($request_method = OPTIONS)                     { set $notation_preflight "O"; }
if ($http_origin = "https://notation.example.org") { set $notation_preflight "${notation_preflight}I"; }
if ($http_access_control_request_method != "")     { set $notation_preflight "${notation_preflight}M"; }
if ($notation_preflight = "OIM") {
    add_header Access-Control-Allow-Origin  "https://notation.example.org" always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, PROPFIND, PROPPATCH, REPORT, MKCOL, MKCALENDAR, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Authorization, Content-Type, Depth, If-Match, If-None-Match, OCS-APIRequest, Prefer, X-Requested-With" always;
    add_header Access-Control-Max-Age 86400 always;
    add_header Vary Origin always;
    return 204;
}

# every other answer: the header names the one origin, so it is the same for everybody
add_header Access-Control-Allow-Origin   "https://notation.example.org" always;
add_header Access-Control-Expose-Headers "ETag, DAV, Content-Type" always;
```

(`add_header` lines of an outer block are dropped as soon as an inner block has any of its own: put these where the location's other `add_header` lines are, not
in a second block that also matches.)

**OPNsense nginx plugin:** it has no field for this. It includes `/usr/local/etc/nginx/<location-id>_post/*.conf` at the end of each location block
(`grep -n _post /usr/local/etc/nginx/nginx.conf` shows the ids): make that folder and put the block above in a file `cors.conf` there, then check with
`nginx -t -c /usr/local/etc/nginx/nginx.conf` and press Apply. These folders are not part of the OPNsense configuration backup; keep a copy.

## Apache

With `mod_headers` and `mod_rewrite` (in the Nextcloud virtual host or its `.htaccess`):

```apache
<IfModule mod_headers.c>
    Header always set Access-Control-Allow-Origin   "https://notation.example.org"
    Header always set Access-Control-Expose-Headers "ETag, DAV, Content-Type"
</IfModule>
<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteCond %{REQUEST_METHOD} =OPTIONS
    RewriteCond %{HTTP:Origin} ^https://notation\.example\.org$
    RewriteCond %{HTTP:Access-Control-Request-Method} .+
    RewriteRule ^ - [R=204,L,E=NOTATION_PREFLIGHT:1]
</IfModule>
<IfModule mod_headers.c>
    Header always set Access-Control-Allow-Methods "GET, POST, PUT, DELETE, PROPFIND, PROPPATCH, REPORT, MKCOL, MKCALENDAR, OPTIONS" env=NOTATION_PREFLIGHT
    Header always set Access-Control-Allow-Headers "Authorization, Content-Type, Depth, If-Match, If-None-Match, OCS-APIRequest, Prefer, X-Requested-With" env=NOTATION_PREFLIGHT
    Header always set Access-Control-Max-Age "86400" env=NOTATION_PREFLIGHT
    Header always merge Vary Origin
</IfModule>
```

## Caddy

```caddy
@preflight {
    method OPTIONS
    header Origin https://notation.example.org
    header Access-Control-Request-Method *
}
header Access-Control-Allow-Origin   "https://notation.example.org"
header Access-Control-Expose-Headers "ETag, DAV, Content-Type"
handle @preflight {
    header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, PROPFIND, PROPPATCH, REPORT, MKCOL, MKCALENDAR, OPTIONS"
    header Access-Control-Allow-Headers "Authorization, Content-Type, Depth, If-Match, If-None-Match, OCS-APIRequest, Prefer, X-Requested-With"
    header Access-Control-Max-Age 86400
    respond 204
}
```

(Put these above the `reverse_proxy` / `php_fpm` line of the Nextcloud site. The Apache and Caddy versions were written from the documentation and not tried.)

## Is the whole site a risk?

* The header names one origin and there is no `Access-Control-Allow-Credentials`, so a page on that origin can read an answer only when it sends the credentials itself in
  `Authorization` (the app password). It cannot ride on a login cookie of the browser. Pages on any other origin get nothing.
* So what it adds over the two paths is that a script on the Notation origin that already has the app password could reach the rest of the Nextcloud API too. That
  password already opens all of your files over WebDAV; the difference is small, but it is the reason to prefer the three paths if you do not mind three locations.
* If the Notation site is served by something you do not control, do not name it here.

## Checking it

From any shell (replace the origin, host and user):

```sh
# the preflight: must be 2xx and show the allow headers
curl -i -X OPTIONS https://cloud.example.org/remote.php/dav/files/USER/ \
  -H 'Origin: https://notation.example.org' \
  -H 'Access-Control-Request-Method: PROPFIND' \
  -H 'Access-Control-Request-Headers: authorization,depth,content-type'

# the real request: the answer must carry Access-Control-Allow-Origin
curl -i -X PROPFIND https://cloud.example.org/remote.php/dav/files/USER/ -u USER:APP-PASSWORD \
  -H 'Origin: https://notation.example.org' -H 'Depth: 0'
```

The login flow can be checked the same way: `curl -i -X POST https://cloud.example.org/index.php/login/v2 -H 'Origin: https://notation.example.org'` must
answer with the `Access-Control-Allow-Origin` header (and a JSON body with `poll` and `login`).

Then in the web version: *Sign in with your cloud folder → Nextcloud*, and press "Log in with the browser". If a header is missing, the connection fails
with a network error: a browser does not tell the page whether the address was wrong or CORS refused it, only its developer console does
("blocked by CORS policy ...", with the header it missed).

The app password is made by the login flow and shows up in Nextcloud under *Settings → Security → Devices & sessions*, where it can be revoked. Typing
an app password by hand still works; never use the account password.

If only the sharing calls fail in the browser console ("header 'ocs-apirequest' is not allowed ..."), `OCS-APIRequest` is missing from `Access-Control-Allow-Headers`, or the
`/ocs/` path is outside the location that carries the headers.
