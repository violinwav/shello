# Shello is open source under GPLv3

Shello ships upstream Mosh, which is GPLv3, and Mosh's authors [accept App Store distribution](https://codegraph.jelmer.uk/mosh/1.4.0-1/COPYING.iOS) only when the GPL is otherwise followed. A closed-source Shello would have to reimplement the Mosh protocol, which encrypts with AES-128 in OCB mode, a mode CryptoKit does not offer, so we license Shello itself under GPLv3. This also lets Shello use libssh (LGPL 2.1 or later) without relinking obligations.

## Consequences

- Every outside contribution needs a contributor licence agreement, so the App Store release stays possible. VLC was [pulled from the App Store](https://thenextweb.com/news/apple-officially-pulls-vlc-from-the-app-store) in 2011 after one of its own developers objected that App Store terms conflict with the GPL.
- Anyone can build Shello for free. The registered name, not the code, is what stops a free fork on the App Store.
- Every dependency must be compatible with GPLv3.
