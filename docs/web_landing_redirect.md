# Sending signed-in visitors from the landing page to the app

The web app keeps everything in the browser, so the server (PHP or not) cannot tell who is signed in. The app therefore sets a
flag in `localStorage` (`notation_signed_in` = `1`) while a profile is set up in the browser, and removes it on sign-out.
`localStorage` is shared by every page of the same address (scheme, host, port), so the landing page can read it.

Put this at the top of the landing page's `<head>` (before anything is drawn, so a signed-in visitor never sees the page):

```html
<script>
  try {
    if (localStorage.getItem('notation_signed_in') === '1' && !/[?&]stay\b/.test(location.search)) location.replace('live/');
  } catch (e) {}
</script>
```

Needs: the landing page and the app on the same host and port (e.g. `example.org/` and `example.org/live/`). A different
subdomain or port has its own `localStorage` and does not see the flag. To let a signed-in visitor still reach the landing page,
link to it as `/?stay` (the snippet in the site's index.html skips the redirect then: it also tests `location.search`).
