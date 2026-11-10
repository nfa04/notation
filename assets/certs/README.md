# ca-bundle.pem

Mozilla's list of trusted root certificates (the `cacert.pem` of the conda-forge `ca-certificates` 2026.2.25 package, which is curl's
extract of Mozilla's list), comments removed. Used only on Windows, as an addition to the roots Windows hands over: see
lib/net/extra_roots.dart. Refresh it from https://curl.se/ca/cacert.pem now and then.
