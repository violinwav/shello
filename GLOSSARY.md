# Shello

Shello is an iOS and iPadOS app for working on remote servers over SSH, Mosh and VNC. This glossary fixes the words the spec, the code and the agents use for its concepts.

## Hosts and servers

**Host**:
A saved entry in Shello that holds everything needed to reach one server as one user. Two hosts can point at the same server.
_Avoid_: Profile, connection profile, machine, bookmark

**Server**:
The remote computer a host points at, identified by its address and port.
_Avoid_: Machine, box, remote

**Host key**:
The key a server proves its identity with. Trust in a host key belongs to the server, so it covers every host that points at that server.
_Avoid_: Server key, fingerprint (the fingerprint is how a host key is shown)

**Group**:
The one group a host belongs to, if any. New hosts in a group inherit its defaults. Groups do not nest.
_Avoid_: Folder, category

**Tag**:
A label on a host. A host can have any number of tags.
_Avoid_: Label, category

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

## Keyboard

**Key**:
A key the user presses: on the Shello keyboard, the extra keys row, a pad or a hardware keyboard. Never an SSH key or a host key.
_Avoid_: Button

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
The key in the extra keys row that sends arrow keys while the user drags across it.
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

**Unlock window**:
The time after the user passes app lock during which Shello and its SSH keys work without another prompt. It ends when app lock re-engages.
_Avoid_: Grace period, session, unlock (for buying Pro)

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

## Buying Shello

**Pro**:
The one-time purchase that keeps Shello's advanced features after the trial.
_Avoid_: Pro unlock, full unlock, premium

**Trial**:
The free period at the start in which every Pro feature works without buying Pro.
_Avoid_: Demo, free tier
