# Folder server

Sushitrain can serve a (sub)directory in a Syncthing folder as localhost web application.

## HTTPS

The folder server uses a self-signed certificate at `https://localhost` (so that secure context-only APIs are available).
The self-signed certificate is generated each time a folder server is instantiated.

The web view that shows this URL inside the app is configured to accept the fingerprint of the self-signed certificate.

## Authentication

To prevent other apps on the same machine from accessing the served web site, the server requires a cookie to be sent.
The cookie name and value are determined by `FolderServer` (on the Go side). The web view inside the app is configured to
send the cookie with its requests. The cookie value is a random string that is generated each time a FolderServer is
instantiated.
