# Shello

Shello is an iOS and iPadOS app for working on remote servers over SSH, Mosh and VNC. This glossary fixes the words the spec, the code and the agents use for its concepts.

## Devices, hosts and servers

**Device**:
The iPhone or iPad running Shello.
_Avoid_: Phone (except for something only an iPhone has), handset

**Host**:
A saved entry in Shello that holds everything needed to reach one server as one user. Two hosts can point at the same server.
_Avoid_: Profile, connection profile, machine, bookmark

**Server**:
The remote computer a host points at, identified by its address and port.
_Avoid_: Machine, box, remote

**Host key**:
The key a server proves its identity with. Trust in a host key belongs to the server, so it covers every host that points at that server.
_Avoid_: Server key, fingerprint (the fingerprint is how a host key is shown)

**Trusted host key**:
The host key the user accepted for a server on the first connection to it, kept in Shello's own trust store. Every later connection to the server must present it: a different host key is a changed host key, which blocks the connection.
_Avoid_: Known host (OpenSSH's `known_hosts` file, which Shello does not use), saved fingerprint

**Group**:
The one group a host belongs to, if any. New hosts in a group inherit its defaults. Groups do not nest.
_Avoid_: Folder, category

**Tag**:
A label on a host, with a name and a colour. A host can have any number of tags.
_Avoid_: Label, category

**Favourite**:
A host the user marked to list before the others.
_Avoid_: Starred, pinned, bookmark

**Recents**:
The hosts Shello connected to last, newest first.
_Avoid_: History, last used

**Production host**:
A host with at least one tag marked production. Shello asks for extra confirmation before risky actions on it.
_Avoid_: Prod server, critical host

## Tabs and connections

**Tab**:
What the user works in on the device: an SSH tab, a Mosh tab or a VNC tab. A tab outlives the connections behind it.
_Avoid_: Session, window, terminal

**Connection**:
The live SSH or Mosh link behind a tab. Connections drop and are replaced while the tab stays.
_Avoid_: Session, link

**tmux session**:
A session of the tmux program on the server, which keeps running when connections drop. Always written in full.
_Avoid_: Session (on its own)

**Hidden channel**:
An SSH channel Shello opens for its own commands, which never appears in a tab.
_Avoid_: Side channel, exec channel, background channel

**Side connection**:
A separate SSH connection a Mosh tab opens when it needs hidden channels, file transfer or port forwards.
_Avoid_: Helper connection, SSH session

**Reconnect**:
Giving a tab a new connection after its old one dropped.
_Avoid_: Re-establish, recover

**Reattach**:
Rejoining the same tmux session after a reconnect.
_Avoid_: Rejoin

**Resume**:
A Mosh tab carrying on over its existing connection after sleep or a network change, with no reconnect.
_Avoid_: Recover, reconnect (for Mosh)

**Restore**:
Recreating the last open tabs after the app was terminated.
_Avoid_: Relaunch restore, recover

**Foreground command**:
The program in the foreground of a tab's terminal, or of the active tmux pane in it.
_Avoid_: Current process, running app

**Terminal**:
The screen inside a tab that draws what the server sends and sends what the user types, as xterm does. A tab keeps its terminal, and the terminal its scrollback, while connections come and go.
_Avoid_: Console, shell (the shell is the program on the server), tab

**Scrollback**:
The lines that have scrolled off the top of a terminal, which it keeps to scroll back to and to search: 10,000 by default.
_Avoid_: History (that is the shell's), buffer

**Terminal demo**:
A terminal attached to a stand-in for a server that runs on the device, under Settings, Diagnostics, to try the terminal without connecting. It is not a shell: Shello has no local shell.
_Avoid_: Local shell, sandbox, playground

## Keyboard

**Key**:
A key the user presses: on the Shello keyboard, the extra keys row, a pad or a hardware keyboard. Never an SSH key or a host key.
_Avoid_: Button

**Shello keyboard**:
The keyboard Shello shows in place of the system keyboard in a terminal, in three layers, under the extra keys row. One key on the row switches to the system keyboard and back.
_Avoid_: Custom keyboard, soft keyboard, on-screen keyboard (the system keyboard is one too)

**Layer**:
One of the Shello keyboard's sets of keys, shown one at a time: letters, symbols or function keys.
_Avoid_: Page, mode, plane

**Letters layout**:
The arrangement of the letters layer: QWERTY or QWERTZ, and AZERTY in v1. Unless the user chooses one, it is that of the first keyboard in the Settings app.
_Avoid_: Keyboard layout, locale

**Flick**:
Pulling a key down before letting go, which types the symbol in its corner.
_Avoid_: Swipe (that is the swipe key's), slide

**Alternates**:
The characters a long-press on a key offers, such as its accented letters.
_Avoid_: Accents, variants, popup

**Sticky modifier**:
Control or Alt on the extra keys row, which stays down for the user: one tap arms it for the next key, a double tap, or holding it on its own, locks it until it is tapped again. It applies to the next key of the system keyboard too.
_Avoid_: Latching key, toggle key

**Extra keys row**:
The scrollable row of terminal keys above whichever keyboard is active.
_Avoid_: Toolbar, accessory bar

**Custom key**:
A key whose output the user defines. It can point at a snippet.
_Avoid_: Macro key, shortcut

**Preset**:
A named set of keys for the extra keys row.
_Avoid_: Layout, key profile

**Swipe key**:
The key in the extra keys row that sends arrow keys while the user drags across it, or one arrow for a tap on that arrow.
_Avoid_: Swipe pad, trackpad, joystick

**Pad**:
A replacement for the letters keyboard, made for one full-screen program and shown while that program runs.
_Avoid_: Panel, overlay

**Vim pad**:
The pad for Vim.

## Keys and access

**SSH key**:
A private key the user signs in to servers with: either a generated key or an imported key.
_Avoid_: Key (on its own), identity, credential

**Generated key**:
An SSH key Shello created on this device. It never leaves the device.
_Avoid_: Device key, local key

**Imported key**:
An SSH key the user brought into Shello from elsewhere.
_Avoid_: External key

**Secure Enclave key**:
A generated key inside the device's Secure Enclave: ECDSA P-256, the only kind the Secure Enclave makes, and the default. Not even Shello can read its private key.
_Avoid_: Hardware key (a FIDO2 security key is one too), device key

**Public key**:
The half of an SSH key that a server holds in its `authorized_keys` to let the user in. Shello shows, copies and shares it; the private key of a generated key never leaves the device.
_Avoid_: Key (on its own), identity

**Fingerprint**:
The SHA-256 hash of a public key or a host key, written as `ssh-keygen` writes it (`SHA256:…`), to compare keys by eye.
_Avoid_: Hash, key ID

**Signing policy**:
When an SSH key may sign: while Shello is unlocked, inside the unlock window, or on every use, after Face ID, Touch ID or the passcode for that one signature.
_Avoid_: Unlock policy, key lock

**SSH agent**:
Shello holding the user's SSH keys and signing for servers on request, for agent forwarding and key-based sudo.
_Avoid_: Agent (on its own), key agent

**App lock**:
Face ID, Touch ID or the device passcode before Shello shows anything: when it opens, and when it returns after app lock's timeout in the background. Passing it opens the unlock window.
_Avoid_: Passcode lock, screen lock, PIN

**Unlock window**:
The time after the user passes app lock during which Shello and its SSH keys work without another prompt. It ends when app lock re-engages.
_Avoid_: Grace period, session, unlock (for buying Pro)

**Secret**:
A password or passphrase, which Shello keeps in the Keychain only, never in the database or an export. A secret belongs to a host or an SSH key and is found by its owner's identifier.
_Avoid_: Credential, key (for a password)

**Privacy cover**:
What the app switcher shows of Shello: its logo, over every screen and sheet, whenever Shello is not the active app.
_Avoid_: Splash screen, blur

**Auto sudo**:
Shello answering sudo password prompts on a host, in one of three modes: off, confirm or automatic.
_Avoid_: Sudo fill, sudo autofill

**Key-based sudo**:
Sudo approved by a signature from the user's SSH key instead of a password. A host uses either auto sudo or key-based sudo, never both.
_Avoid_: Passwordless sudo, auto sudo mode

## Snippets

**Snippet**:
A saved command with variables, inserted or run in a tab or run on several hosts.
_Avoid_: Macro, script, alias

**Multi-host run**:
Running one snippet on several hosts at once, with results per host.
_Avoid_: Multi-host snippets, fan-out

**Broadcast typing**:
Sending the user's keystrokes to several open tabs at once.
_Avoid_: Sync typing, synchronized panes

## Data

**Export**:
The JSON file with all of Shello's non-secret data: its hosts, groups and tags, and later its snippets, presets and settings. Importing an export adds its records and replaces those already in Shello with the same identifier.
_Avoid_: Backup (the encrypted full backup also holds passwords and imported keys), dump

## Buying Shello

**Pro**:
The one-time purchase that keeps Shello's advanced features after the trial.
_Avoid_: Pro unlock, full unlock, premium

**Trial**:
The free period at the start in which every Pro feature works without buying Pro.
_Avoid_: Demo, free tier
