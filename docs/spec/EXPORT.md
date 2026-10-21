# Shello — Export File Format

Oct 21, 2026

Shello exports all of its non-secret data as one JSON file, and imports such a file (README section 15). During TestFlight the export is the safety net against data loss when the database schema changes, so the format is stable: every later version of Shello imports a file that an earlier one wrote. Terms follow `GLOSSARY.md`.

`ExportFormat` in `Packages/ShelloKit/Sources/ShelloStorage/ExportFormat.swift` defines the format, and `Packages/ShelloKit/Tests/ShelloStorageTests/Fixtures/export-v1.json` is a file that schema version 1 wrote.

## The file

- One JSON object in UTF-8, at most 16 MiB. Shello suggests the name `Shello Export 2026-10-21 14.05.09.json`, and writes the file with sorted keys and indentation, so that the same data always gives the same file.
- It never holds a secret. Passwords, passphrases and SSH keys live in the Keychain or the Secure Enclave only (README section 13); a host refers to its SSH key by identifier, and the key may not exist on the device that imports the file.
- Deleted records are left out, and so are a host's references to deleted groups and tags: the file holds what the user sees. Modification times are left out too; they belong to sync (v1).
- Settings are not in it yet: Shello stores none so far.

## Schema version 1

The top-level object:

| Key | Value |
| --- | --- |
| `format` | `"ch.shello.export"`, in every schema version |
| `schemaVersion` | `1` |
| `groups` | The groups, by name: `id`, `name` |
| `tags` | The tags, by name: `id`, `name`, `color` |
| `hosts` | The hosts, by name, with the keys below |

A host:

| Key | Value |
| --- | --- |
| `id`, `name`, `address`, `port`, `username` | As in README section 3 |
| `protocol` | `ssh`, `mosh` or `vnc` |
| `authMethod` | `sshKey`, `password` or `keyboardInteractive` |
| `sshKeyID` | The identifier of the host's SSH key; optional |
| `groupID` | The identifier of the host's group; optional |
| `tagIDs` | The identifiers of the host's tags |
| `notes`, `startupCommand`, `terminalType` | Text; the first two may be empty |
| `keepaliveIntervalMilliseconds`, `connectTimeoutMilliseconds` | Whole milliseconds |
| `isFavorite` | `true` or `false` |
| `lastConnectedAt` | When Shello last connected to the host; optional |

Values:

- Identifiers are UUIDs in their usual text form, such as `E621E1F8-C36C-495A-93FC-0C247A3E6E5F`.
- A tag's `color` is one of the tag palette's: `red`, `orange`, `yellow`, `green`, `blue`, `purple` or `gray`.
- Times are seconds since 2001-01-01T00:00:00Z, as a number, as the database stores them, so that they read back exactly.
- An optional key without a value is left out.

## Importing

An import is checked completely before it touches the database (STACK section 7.10):

1. The file is at most 16 MiB, is JSON, and has the `format` above.
2. Its `schemaVersion` is one this Shello knows. A file from a newer schema version is refused with the reason, and the advice to update Shello.
3. Every key is there, with a value of the right type.
4. Every record follows the rules the host editor and the database follow:
   - A host, group or tag has a name that is not blank.
   - A host's address is a hostname, an IPv4 address or an IPv6 address, and its port is from 1 to 65535.
   - A host's protocol, sign-in method and a tag's colour are values Shello knows.
   - A host's terminal type is not empty and has no spaces; its keepalive interval and connect timeout are longer than zero; its last connection, if any, is a date between the years 1 and 4000.
   - Each group and tag a host refers to is in the file.
   - No two hosts, no two groups and no two tags have the same identifier.
   - No text holds a null character, which the database stores but reads back cut off.

A file that fails a check is refused as a whole, and nothing is stored. Every record is checked; the user is told the first problem and how many more there are. Otherwise the user sees how many hosts, groups and tags the file holds, and how many of them are already in Shello, and confirms. The records are then written in one transaction:

- A record whose identifier is already in the database replaces it. A deleted one comes back.
- Every other record stays as it is: importing never deletes.
- As with every write, only the fields that change get a new modification time, so that sync can merge per field later.

## Changing the format

- Any change to what the file holds, or to how it holds it, is a new schema version: raise `ExportFile.currentSchemaVersion`. An older Shello then refuses the file instead of leaving out what it does not know.
- A newer Shello imports every older schema version. Keep the fixture of each version in `Fixtures/`, with a test that imports it, as `ImportTests` does for version 1.
- Snippets, presets and settings (README section 15) join as new top-level keys, such as `snippets`, `presets` and `settings`. A file of an earlier version, which does not have them, imports as having none.
