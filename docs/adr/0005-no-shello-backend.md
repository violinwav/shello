# No Shello backend; sync only through the user's iCloud

Shello runs no server of its own and needs no account: sync goes through the user's own iCloud (CloudKit's private database, and iCloud Keychain for secrets the user opts in). This keeps Shello local-first and its App Store privacy label at "Data Not Collected", and with no running costs a one-time Pro purchase is enough to pay for it.

## Consequences

- There is no sync with non-Apple clients unless one ever exists and brings its own answer.
