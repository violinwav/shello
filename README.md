# Shello — Functional Specification

Oct 12, 2026 · @violin

## 1. Purpose and scope

Shello is an iOS and iPadOS app for working on remote machines: SSH and Mosh shells, tmux, Vim, SFTP file transfer and simplified VNC remote desktop. This spec defines what the final app does. The canvas design defines how it looks and is not repeated here.

Product goals:

- From tap to a usable shell in under 2 seconds on a known host, and back into the same session after sleep or a network switch.
- A keyboard built for the terminal: modifiers, arrows and symbols without hunting through layers.
- tmux and Vim treated as first-class citizens, not just bytes in a stream.
- Secure by default: hardware-backed keys, verified host keys, post-quantum key exchange, no plaintext secrets.
- Local-first: no account required, no Shello server in the data path.

Baseline: everything the competitor Termigo lists (SSH, SFTP, key management, host groups, tabs, snippets) must be covered by v1. Shello's differentiators are the keyboard, tmux, Vim, Mosh, VNC, auto sudo and multi-host snippets.

Licence and business model: Shello is open source under GPLv3 and sold on the App Store as a free download with a 14-day trial and a one-time Pro unlock (section 17).

How to read it: every requirement carries a phase tag, MVP, v1 or Later, defined in section 17. Out of scope for now: Android, a native macOS app, and a local shell on the device.

## 2. Technical baseline

Shello is a native Swift app for iOS and iPadOS 26 and later. With iOS 27 current, iOS 26 is one release back, which keeps the test matrix small.

- App shell: SwiftUI. Terminal view and Shello keyboard: UIKit, using a custom input view and input accessory view, which iOS allows inside your own app.
- Terminal emulation: SwiftTerm (MIT licence), already used by commercial SSH clients.
- SSH and SFTP: libssh 0.12 (LGPL 2.1 or later), built as an xcframework with OpenSSL 3.x as its crypto backend; mbedTLS is the fallback, decided in the spike (section 18). libssh covers every algorithm in sections 4 and 14, including both post-quantum hybrids, plus keyboard-interactive, certificates and agent forwarding.
- Networking: Shello opens every connection with Network.framework (NWConnection, connecting by name) and hands libssh one end of a socketpair (SSH\_OPTIONS\_FD). libssh never opens sockets itself, because BSD sockets are incompatible with VPN On Demand and need a hand-written Happy Eyeballs ([TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)).
- Threading: each libssh session runs on its own serial queue, because a session must never be used from two threads at once.
- Mosh: the upstream Mosh client (GPLv3), built for iOS. This is possible because Shello itself is GPLv3 (section 18).
- VNC: RoyalVNCKit (MIT licence). Its iOS view is still a work in progress, so Shello builds its own UIKit view.
- Storage: a local database (SwiftData or SQLite) for hosts, snippets and settings. Secrets live only in the Keychain or the Secure Enclave, never in the database.
- Architecture: a UI-independent session core (connections, channels, transfers, tmux queries) so it can later back a File Provider extension, a Mac app or a shared library.
- Licence: every dependency must be compatible with GPLv3. Contributions require a contributor licence agreement, so the App Store release stays possible.
- No Shello backend. Sync is optional and goes through the user's own iCloud (section 15).

## 3. Hosts and connection profiles

A host is a saved profile that holds everything needed to connect in one tap; secrets are referenced, never stored in the profile.

- MVP: Profile fields: name, address (hostname, IPv4 or IPv6), port, protocol (SSH, Mosh, VNC), username, auth method (key, password, keyboard-interactive), key reference, group, tags, notes, startup command, terminal type (default xterm-256color), keepalive interval, connect timeout.
- MVP: Groups and tags. A tag has a colour.
- MVP: Search across name, address, user and tags. Favourites and recents ordering.
- MVP: Host key verification. First connect shows key type and SHA-256 fingerprint and asks the user to trust it. Keys are stored per host and port.
- MVP: A changed host key blocks the connection with a clear warning. Replacing the stored key requires an explicit action plus biometric confirmation.
- MVP: The first connection to a host on the local network triggers the iOS Local Network permission prompt ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)). Shello explains why just before it appears.
- v1: A tag can carry a "production" flag that switches on safety confirmations (sections 9 and 11).
- v1: Auto sudo mode per host (section 9).
- v1: Environment variables per host. OpenSSH only accepts variables the server lists in AcceptEnv, which accepts none by default, and the UI says so. The startup command (export NAME=value) works on every server.
- v1: Jump hosts: a chain of one or more saved hosts (ProxyJump), each with its own credentials.
- v1: Import from an OpenSSH config file and a known\_hosts file. Supported: Host, HostName, User, Port, IdentityFile, ProxyJump, LocalForward, RemoteForward. Unsupported directives are listed after import, never silently dropped.
- v1: Reachability and latency. While the host list is visible, each directly reachable host is probed with a TCP connect to its port, at most once per minute. Hosts behind a jump host show status only while connected. Probing can be turned off globally and per host. Probing never triggers the Local Network prompt: hosts on the local network are probed only after the user has granted access.
- v1: Duplicate a host, and per-group defaults (user, key, jump host) that new hosts inherit.

## 4. Sessions and protocols

Work must survive the app leaving the foreground. iOS will suspend the app and the SSH connection will drop, so the work keeps running on the server in tmux or Mosh, and Shello reconnects and reattaches when the user returns.

- MVP: Supported servers: OpenSSH 8.8 or later on Linux. Dropbear, older OpenSSH and network appliances come in v1 or Later (section 16).
- MVP: SSH-2 client with publickey (Ed25519, ECDSA P-256 and P-384, RSA with SHA-256/512), password and keyboard-interactive (including one-time-code prompts) authentication.
- MVP: Algorithm policy. Preferred key exchange: post-quantum hybrids first (section 14), then curve25519-sha256. Ciphers: chacha20-poly1305, AES-GCM, AES-CTR. MACs: HMAC-SHA2 encrypt-then-MAC. SHA-1, CBC ciphers and DSA keys are off.
- MVP: Several concurrent sessions, each in its own tab, several tabs per host, fast switching between them.
- MVP: Lifecycle: connect, verify host key, authenticate, run the startup command, active. On network loss the tab shows "reconnecting" and retries automatically with backoff before giving up.
- MVP: Background: Shello uses the short background time iOS grants, then closes connections cleanly. It does not use workarounds such as silent audio or location updates to stay alive, because they risk App Store rejection and drain the battery.
- MVP: Return to foreground: the visible tab reconnects at once; other tabs reconnect when selected, since nothing ran while the app was suspended. When the host uses tmux, Shello reattaches to the same tmux session. Local scrollback from before the drop is kept. Authentication uses the shared unlock window (section 13), so a return costs at most one Face ID prompt.
- MVP: Configurable keepalive. The latency shown in a session is the keepalive round-trip time.
- v1: A legacy algorithm can be enabled per host only, with a visible warning on that host.
- v1: Agent authentication, once Shello acts as an SSH agent (section 13).
- v1: Mosh sessions: bootstrapped over SSH, then UDP (ports 60000 to 61000 by default). They roam across networks, survive sleep and use local echo prediction. Requires mosh-server on the host. A Mosh tab is Mosh plus tmux plus an SSH side connection:
  - tmux auto-attach is always on, and the tab's scrollback and search come from tmux (tmux capture-pane), because Mosh only synchronises the visible screen.
  - An SSH side connection opens on demand for the tmux browser, Vim detection, SFTP and port forwards. It closes when idle and reconnects lazily after a return to the foreground, while the Mosh tab itself resumes at once.
  - Shell integration is not offered, because Mosh drops OSC 133 and OSC 7.
- v1: Relaunch restore: after the app was terminated, the last open sessions are listed for one-tap reconnect and reattach.
- v1: Port forwarding: local, remote and dynamic (SOCKS), saved per host and started with the session. Local listeners only work while Shello is running, which the UI must state. For Mosh hosts, forwards run over the SSH side connection.
- v1: Agent forwarding, off by default and enabled per host; every forwarded signature request needs confirmation (section 13).
- v1: Session transcript: off by default; per session the user can save the output to a file.

## 5. Terminal

The terminal must behave like xterm so that full-screen tools (tmux, Vim, htop, less) work without configuration.

- MVP: xterm-compatible emulation: 256 colours and 24-bit colour, text attributes, alternate screen, SGR mouse reporting. A tap is sent as a click when the remote app has mouse mode on.
- MVP: Unicode: wide characters, combining marks and emoji measured per xterm rules, so columns never drift.
- MVP: Resize: the new size is reported to the server on rotation, iPad split view and font size change.
- MVP: Scrollback of 10,000 lines per tab by default (configurable), with search.
- MVP: Selection and copy: long-press selects a word, handles extend it, a menu copies it as plain text.
- MVP: Paste uses bracketed paste when the remote supports it. Otherwise, pasting more than one line asks for confirmation and shows the line count.
- MVP: Hardware keyboards: Ctrl, Option as Meta (configurable), an assignable Esc for keyboards without one, and Cmd shortcuts for the app (new tab, next tab, font size).
- MVP: Bell: haptic tap plus a visual flash; a badge on the tab if it rings in the background.
- MVP: Pinch to change font size.
- v1: Per-host font and theme overrides.
- v1: Links: URLs, IP addresses and file paths are detected and can be opened or copied. SwiftTerm already detects OSC 8 and implicit links.
- v1: OSC 52: lets the server write to the iOS clipboard. Off by default, enabled per host. Reading the clipboard from the server is never allowed.
- v1: Optional shell integration script for bash, zsh and fish, installed on the server by the user. It marks prompts and commands (OSC 133) and the working directory (OSC 7). That enables jumping between commands, copying one command's output, exit status per command, and command detection for the Vim pad (section 7). Not offered in Mosh tabs (section 4).
- Later: Inline images (Sixel, Kitty or iTerm2 protocols). SwiftTerm already renders all three, so this can move up cheaply.

## 6. Shello keyboard

The Shello keyboard replaces the system keyboard inside terminal tabs and puts every terminal key within one tap or one gesture. Typed input goes only to the active session and is never logged or analysed.

- MVP: In-app keyboard with three layers: letters; symbols (digits plus ! @ # $ % ^ & \* ( ) \~ \` | \\ { } \[ \]); function (F1 to F12, Home, End, PgUp, PgDn, Ins, Del and common Ctrl shortcuts such as ^C ^D ^Z ^L ^R ^A ^E ^W).
- MVP: Letters layer in QWERTY and QWERTZ. The default follows the first enabled system keyboard (UITextInputMode.activeInputModes) and can be changed in settings. Umlauts and other accented letters come from the long-press alternates.
- MVP: One key switches to the system keyboard and back, for dictation, other languages and emoji.
- MVP: Extra keys row above whichever keyboard is active, scrollable sideways: esc, tab, ctrl, alt, swipe pad, frequent symbols.
- MVP: Flick down on a letter types the symbol shown in its corner. Long-press shows further alternates.
- MVP: Sticky modifiers: one tap arms Ctrl or Alt for the next key, a double tap locks it, and the armed state is always visible. Works with the system keyboard too.
- MVP: Swipe pad: dragging sends arrow keys in that direction; repeat speed grows with drag distance; sensitivity is adjustable.
- MVP: Key repeat on hold for delete, arrows and space. Haptic feedback per key, on by default.
- v1: Extra-row presets (Shell, Vim, tmux, Custom) with a default preset per host.
- v1: Custom keys: a label plus exactly what it sends (an escape sequence, a key combination such as Ctrl-b then %, a text, or a snippet). Keys are added from a library and reordered by dragging.
- v1: With a hardware keyboard attached, the Shello keyboard hides; the extra keys row can stay.
- v1: iPad layout with a number row, and a wider layout in landscape on iPhone.
- v1: AZERTY letters layout.
- Later: Terminal gestures such as a two-finger swipe to switch tabs.

## 7. Vim pad and context detection

Shello only receives a stream of text, so it can never be certain Vim is running. The Vim pad therefore switches on from layered signals, and the user can always toggle it by hand.

Detection signals, most reliable first:

1. Inside tmux: the current command of the active pane, queried over a hidden SSH channel whenever the pane or screen mode changes.
2. With shell integration installed: the command name reported when a command starts.
3. Fallback: the alternate screen is switched on and the window title names vim or nvim.

In Mosh tabs, signal 1 runs over the SSH side connection (section 4), signal 2 is unavailable because Mosh drops shell integration, and signal 3 reduces to the window title, because mosh-client keeps the alternate screen on for the whole session.

- v1: Auto-switch to the Vim pad when vim, nvim or vi is detected (the list is editable), and back to the keyboard when it exits. A manual toggle is always visible; a manual choice wins until the program exits.
- v1: Pad contents: motions (h j k l, w b e, 0 $, gg G, %), operators and actions (d c y p x u .), modes (i a o v V), esc, a count key, and command keys (:w :q :wq :%s / n N \*). Every key carries a short caption.
- v1: Mode indicator: Shello tracks the mode from the keys it sent itself (i means insert, esc means normal). It is a best guess, because mappings and system-keyboard input can desynchronise it; esc always resets it. It can be hidden.
- v1: Entering insert mode can switch to the letters keyboard automatically (setting); esc returns to the pad.
- Later: Pads for other full-screen tools (a pager pad for less and man, a pad for htop) and user-defined pads bound to a command name.

## 8. tmux integration

tmux is Shello's main answer to iOS suspending apps: the session lives on the server, and Shello makes finding and re-entering it a single tap.

- MVP: Auto-attach per host: on connect, attach to a named session or create it if missing (equivalent to tmux new -A -s main). Reconnects reattach to the same session.
- v1: Session browser fed by tmux list-sessions, list-windows and list-panes over a separate SSH exec channel, so nothing appears in the user's terminal. Shows sessions, attached clients, windows, creation time and activity or bell flags.
- v1: Pane map drawn from each pane's position and size. Tapping a pane attaches and selects it.
- v1: Actions: attach, new session, rename, kill (with confirmation), new window, split right, split down, select window or pane, detach.
- v1: Prefix awareness: Shello reads the configured prefix from the server (tmux show -gv prefix) instead of assuming Ctrl-b, and uses it for the tmux preset and prefix actions.
- v1: Works through jump hosts and inside Mosh sessions, where the queries use the SSH side connection (section 4). For Mosh hosts, auto-attach is always on. A minimum tmux version is set during testing; older versions fall back to plain attach.
- Later: tmux control mode (tmux -CC): tmux windows and panes shown as native Shello tabs and splits.
- Later: Attach helpers for GNU screen and Zellij.

## 9. Auto sudo

Auto sudo answers sudo password prompts for the user. The default is a one-tap confirmation, not a silent fill, because the main risk is sending a password to the wrong machine.

Modes, set per host:

1. Off.
2. Confirm (default once enabled): when a sudo prompt is detected, Shello shows which host and user are asking; Face ID or a tap sends the password.
3. Automatic: sends without asking. Turning it on for a host tagged production needs an extra confirmation.
4. Key-based sudo (recommended, no password at all): the server authenticates sudo against Shello's SSH agent using the PAM module [pam\_rssh](https://github.com/z4yx/pam_rssh) (MIT licence; supports ECDSA P-256, Shello's default key type, plus Ed25519 and RSA with SHA-256). Each sudo needs a tap that names the host, plus Face ID when app lock has re-engaged (section 13). It needs agent forwarding and ships with it in v1. Shello ships a setup guide and snippet for the server side. The older [pam\_ssh\_agent\_auth](https://github.com/jbeverly/pam_ssh_agent_auth) is not recommended: its last commit dates from February 2021.

Saving a sudo password never turns auto sudo on silently. Shello asks once, "Answer sudo prompts on this host?", with "Ask me each time" (Confirm) highlighted and "Not now". Automatic can only be switched on in the host's settings.

Detection:

- v1: A prompt counts as a sudo prompt when the last line matches the sudo pattern for the expected user (default "\[sudo\] password for \<user>:", plus a custom pattern per host) and the cursor sits at its end.
- v1: With shell integration or tmux available, Shello also checks that the foreground command is sudo.
- v1: In Mosh tabs, Automatic mode works only when the SSH side connection can confirm through tmux that the foreground command is sudo; otherwise the host falls back to Confirm.

Security rules:

- v1: The sudo password is stored in the Keychain, readable only on this device after biometric unlock. It is excluded from sync unless the user opts in (section 15).
- v1: A password is only sent into a session of the host it belongs to, and only when the user named in the prompt matches the stored sudo user.
- v1: Nested sessions: if tmux or shell integration reports that the foreground command is ssh, mosh or telnet, auto sudo pauses, because the prompt may come from another machine. Without those signals, Confirm mode shows the host so the user decides. This is why Automatic is not the default.
- v1: Fake prompts: any program on the host can print text that looks like a sudo prompt. The exposure is limited to that host's password, so the settings warn against reusing it elsewhere.
- v1: One fill per prompt. If sudo answers "Sorry, try again", Shello stops filling for that session and asks the user to update the stored password, to avoid account lockouts.
- v1: Every fill is recorded in a local security log (time, host, mode). The password never appears in logs, the clipboard or the scrollback.
- Later: The same mechanism for su, doas and other password prompts, each opted into separately.

## 10. File transfer (SFTP and SCP)

Shello transfers files over SFTP on the existing SSH connection. "SCP" is offered as a familiar name, but the engine is SFTP, the same choice OpenSSH made when its scp switched to the SFTP protocol by default in [version 9.0](https://lists.mindrot.org/pipermail/openssh-unix-dev/2022-April/040174.html).

- v1: File browser per host: list, sort, hidden-files toggle, path bar, bookmarks, go-to-path. It opens in the terminal's current directory when shell integration reports it.
- v1: Operations: upload, download, rename, move, delete (with confirmation), new folder, change permissions, and details (owner, group, size, modified time). Symlinks are shown and followed.
- v1: Transfer queue with progress, speed, pause, resume and retry. Interrupted transfers resume from the last byte instead of restarting.
- v1: Background: transfers continue only as long as iOS allows. An interrupted transfer resumes automatically when the app returns, and the queue says so.
- v1: Preview images and PDFs; open text files in a built-in editor with syntax highlighting. Saving checks whether the remote file changed in the meantime and asks before overwriting.
- v1: iOS integration: "Upload to host" in the share sheet, import and export through the Files app, drag and drop on iPad (Files to host, and host to host streamed through the phone).
- v1: Dropping a file on a terminal tab uploads it to the current directory and types its path at the prompt.
- v1: Works through jump hosts and for Mosh hosts (over the SSH side connection), and uses the same host key checks as the terminal.
- Later: File Provider extension: hosts appear as locations in the Files app, so other apps can open and save remote files directly.
- Later: Legacy SCP protocol fallback for small devices without an SFTP server (some routers and embedded systems). libssh includes an SCP API, so this is cheap when needed.
- Later: Edit root-owned files through sudo, using auto sudo for the password.

## 11. Snippets, command palette and multi-host run

Snippets turn repeated commands into one tap, and multi-host run applies them to several servers at once with results per host.

- v1: Snippet fields: name, command, description, tags, scope (all hosts, a group, or chosen hosts) and variables written as $name. A variable can have a default, a list of choices, or be asked every time.
- v1: Insert or run: insert types the command at the prompt without pressing return; run also presses return.
- v1: Command palette with fuzzy search across snippets, hosts (connect or switch), tmux sessions and app actions (new tab, split, keyboard preset). Opened from the extra keys row, the toolbar or Cmd-K.
- v1: Built-in variables: $HOST, $USER and, with shell integration, $CWD. The clipboard is inserted only on an explicit tap.
- v1: Command history per host from shell integration; without it, the history lists snippets run.
- v1: Multi-host run: each host runs the snippet on its own SSH exec channel, separate from the user's terminals. The results view shows per host the exit code, output, and duration; failed hosts are highlighted and can be re-run.
- v1: Safety: hosts tagged production require a confirmation that lists them by name. Commands matching a configurable danger list (rm -rf, mkfs, shutdown, reboot, DROP TABLE) need a second confirmation.
- v1: Broadcast typing: keystrokes mirrored into several open tabs (like tmux synchronize-panes), with a constant visible indicator on every affected tab.
- v1: Snippets import and export as JSON and sync through iCloud (section 15).

## 12. Remote desktop (VNC)

Remote desktop is deliberately simple: view and control a desktop well enough to fix something, not to replace a full remote desktop suite.

- v1: VNC (RFB) client with no-auth and VNC password authentication, plus Apple Remote Desktop authentication, which RoyalVNCKit supports and which macOS Screen Sharing is expected to accept (to confirm in testing).
- v1: Encrypted by default: VNC traffic is tunnelled through SSH to the same host or a jump host. Direct, unencrypted VNC needs a per-host opt-in and shows a warning.
- v1: Trackpad mode: relative pointer, tap to click, two-finger scroll, pinch to zoom, hold and drag to select, dedicated left and right buttons.
- v1: Direct touch mode: the pointer jumps to the finger; long-press is a right-click.
- v1: View: pinch zoom and pan with an overview map, fit to screen, follow the pointer; choose a monitor when the server exposes several.
- v1: Keyboard: the Shello keyboard with a key-combination menu (Ctrl-Alt-Del, Cmd-Tab, Super) and key mapping per target OS (macOS, Windows, Linux).
- v1: Quality: automatic (adapts compression and colour depth to bandwidth) or manual.
- v1: Text clipboard sync in both directions, opt-in per host.
- Later: Wake-on-LAN before connecting, for machines on the local network.
- Later: External display: the remote desktop full-size on a connected monitor, with the phone as trackpad and keyboard.
- Later: RDP for Windows hosts (FreeRDP is the obvious candidate; licence to confirm).

## 13. Keys, credentials and security model

Shello is designed against four threats: a lost or stolen phone, a compromised or malicious server, an attacker on the network, and other apps on the device. Every requirement below maps to at least one of them.

Keys:

- MVP: Generate keys. The default is ECDSA P-256 inside the Secure Enclave, which can never be exported. The Secure Enclave does not support Ed25519, so hardware-bound SSH keys are always P-256.
- MVP: Generate Ed25519 keys for hosts that require them, stored in the Keychain as device-only.
- MVP: Keys Shello generates never leave the device they were created on: no sync, no backup, no private key export. Each device has its own keys, so a lost device means revoking only its keys.
- MVP: Import OpenSSH private keys (OpenSSH and PEM formats, with or without passphrase) from the Files app or by pasting.
- MVP: Public key export: copy, share, and "install on host", which appends it to authorized\_keys over an authenticated session (like ssh-copy-id).
- MVP: Per key, choose when it unlocks: "while Shello is unlocked" (default), which shares the app-lock window below, or "every use", which asks for Face ID on each signature. The UI warns that "every use" makes every reconnect prompt.
- v1: QR code for public keys.
- v1: Public keys sync between the user's devices. A device that already has access can install a sibling device's public key on chosen hosts in one action, using multi-host run (section 11).
- v1: OpenSSH certificates: user certificates loaded alongside their key, and host certificates trusted through a configured certificate authority.
- v1: Shello as SSH agent for forwarded sessions and key-based sudo (section 9). Every signature request from a remote host shows which host asks and needs an explicit tap, even inside the unlocked window; Face ID is added when app lock has re-engaged.
- Later: FIDO2 security keys (sk-ssh-ed25519) over NFC and USB-C.

Secrets and the device:

- MVP: Passwords and passphrases live only in the Keychain, readable only while the device is unlocked and never synced unless the user opts in. They never appear in the database, logs, crash reports or scrollback.
- MVP: App lock with Face ID, Touch ID or passcode at launch and after a configurable time in the background (default 1 minute, from immediately to 15 minutes). The app switcher snapshot is blurred.
- MVP: One unlock window for app and keys. A successful app-lock authentication evaluates one shared LAContext, which every Keychain read and Secure Enclave signature uses ([kSecUseAuthenticationContext](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext)). Returning to Shello therefore costs at most one prompt, and none within the grace period. The context is invalidated when app lock re-engages.
- MVP: The local database uses the strongest iOS Data Protection class that works with Shello's writes. Reconnects happen only in the foreground (section 4), so the database does not need to be readable while the device is locked; the spike confirms the class (section 18).
- v1: Local security log: connections, host key changes, auto sudo fills and agent signatures. It can be exported and never leaves the device by itself.

## 14. Post-quantum cryptography

Post-quantum key exchange belongs in the MVP, not the future. [OpenSSH](https://www.openssh.org/pq.html) has used the hybrid mlkem768x25519-sha256 by default since version 10.0 (April 2025), and version 10.1 warns when a connection does not use a post-quantum key exchange. Post-quantum signatures stay in Later, because OpenSSH does not support them yet.

Phase 1, key exchange. It protects recorded traffic from being decrypted later by a quantum computer:

- MVP: offer mlkem768x25519-sha256 first, sntrup761x25519-sha512 second, then classical curve25519-sha256. libssh 0.12 implements both hybrids, so Shello composes nothing itself.
- v1: Each session shows which key exchange was negotiated, marked post-quantum or classical. A classical connection triggers a warning, which can be silenced per host.
- v1: Per-host "require post-quantum" option that refuses to connect with a classical key exchange.
- v1: Mosh and tunnelled VNC inherit this protection, because their keys or traffic travel over the SSH connection.

Phase 2, signatures. They protect authenticity at connection time, so they only matter once a capable quantum computer exists:

- Later: post-quantum host and user key types (likely ML-DSA) as soon as OpenSSH defines them. CryptoKit already offers ML-DSA, reportedly also inside the Secure Enclave, so hardware-bound post-quantum user keys look possible.

Crypto agility:

- MVP: Algorithm lists are configuration, not code: preference order can change per host and through app updates without touching the session logic.

## 15. Sync, backup and privacy

Shello works fully offline and without an account. Sync is opt-in and runs only through the user's own iCloud.

- MVP: Privacy: no account, no analytics, no advertising or tracking SDKs. Crash reports only through Apple's opt-in mechanism. Shello connects only to hosts the user configured, plus iCloud when sync is on. Target App Store privacy label: Data Not Collected.
- MVP: Export and import of all non-secret data (hosts, groups, tags, snippets, presets, settings) as one JSON file. During TestFlight it is also the safety net against data loss when the database schema changes.
- v1: iCloud sync through CloudKit's private database for the same data. Sensitive fields (addresses, usernames, notes, startup commands) use CloudKit's encrypted fields.
- v1: Secrets sync only through iCloud Keychain, opted into per item: passwords and imported keys. Synced Keychain items cannot use device-only protection classes ([kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable)), so the spec assumes they are protected by the device passcode and Shello's app lock rather than per-item Face ID, until the spike checks it (section 18). The UI says so.
- v1: Keys Shello generated never sync (section 13): on another device the host shows "key not on this device" and offers to create and install a new key.
- v1: Conflicts: last change wins per field; deletions sync with an undo window.
- v1: Encrypted full backup, protected by a passphrase the user chooses. It includes passwords and imported keys, never keys Shello generated.
- Later: Sync with non-Apple clients, if a Mac or Android client ever exists.

## 16. Non-functional requirements

Targets below are measured on the oldest iPhone that runs iOS 26; they are starting values to confirm during the MVP.

Performance:

- Launch to host list: under 1 second.
- Tap on a known LAN host to a usable prompt: under 2 seconds, excluding server-side delays.
- Keystroke to network send: under 10 ms. Rendering keeps up with the display refresh rate.
- Heavy output (for example printing a 10 MB log) never freezes input; rendering is throttled, input stays responsive.
- Memory: 10 tabs with full scrollback stay under 200 MB.

Battery and network:

- No background activity when no session or transfer is open. Host probing only while the host list is on screen.

Reliability and quality:

- Host data is never lost on a crash; writes are transactional.
- The terminal parser and protocol code are fuzz-tested; libssh's own fuzzers run as part of this.
- Test matrix: for the MVP, OpenSSH 8.8 and later on Linux, over slow or lossy networks. v1 adds older OpenSSH 8.x, Dropbear, several tmux versions and mosh-server.
- No home-made cryptographic primitives. Primitives come from CryptoKit or audited libraries; Shello only composes protocols from them.
- Every dependency is licence-reviewed before it ships and must be compatible with GPLv3.

Accessibility:

- VoiceOver labels on every control and every keyboard key.
- Terminal: an option to announce new output and to read the current line.
- Dynamic Type for app screens (the terminal font size is set separately), Reduce Motion stops the blinking cursor, colour is never the only signal.

Platforms and languages:

- iPhone and iPad on iOS and iPadOS 26 and later, including Stage Manager, external displays and hardware keyboards.
- English and German at launch.

## 17. Release phases

Shello ships in three phases, separated by two gates.

| Phase | What it is | Gate to enter |
| --- | --- | --- |
| MVP | A private TestFlight build used daily on the developer's own OpenSSH Linux servers. 46 requirements tagged MVP. | Gate 1: the SSH library spike passes (section 18). |
| v1 | The first App Store release: the Termigo baseline plus the differentiators, with the pricing below. | Gate 2: the MVP has replaced the developer's current SSH client for daily work. |
| Later | Items that wait on standards or demand. | Decided per item. |

Durations: to be set after the spike, for one developer working part-time.

Pricing (v1):

- Shello is a free download.
- A 14-day trial unlocks everything. It is a Tier-0 non-consumable named "14-day Trial", as [App Store Review Guideline 3.1.1](https://developer.apple.com/app-store/review/guidelines/) requires; before it starts, the app states its duration and what locks afterwards.
- A one-time Pro purchase unlocks the rest for good. There is no subscription: with no backend, there is no ongoing service to charge for.
- Free after the trial: the SSH terminal, the Shello keyboard and tmux auto-attach.
- Pro: Mosh, the tmux session browser, the Vim pad, VNC, multi-host run and iCloud sync.

## 18. Decisions, open questions and risks

Decided on Oct 12, 2026:

- SSH library: libssh 0.12 from the MVP on, bridged to Network.framework through a socketpair (section 2). It is confirmed once the spike below passes; if the Secure Enclave check fails, the fallback is SwiftNIO SSH. SwiftNIO SSH and Citadel were ruled out as the main stack because neither offers chacha20-poly1305, keyboard-interactive or post-quantum key exchange, and Citadel signs RSA with SHA-1 only.
- Licence: Shello is open source under GPLv3, which lets it ship upstream Mosh. Mosh's authors [will not object](https://codegraph.jelmer.uk/mosh/1.4.0-1/COPYING.iOS) to App Store distribution when the GPL is otherwise followed.
- Contributions: a LICENSE file and a contributor licence agreement are in place before the first outside contribution. VLC was [pulled from the App Store](https://thenextweb.com/news/apple-officially-pulls-vlc-from-the-app-store) in 2011 after one of its own developers objected that App Store terms conflict with the GPL.
- Business model: free download, 14-day trial, one-time Pro unlock (section 17).
- Auto sudo default: Shello asks once when a sudo password is saved (section 9).
- VNC library licence: RoyalVNCKit is MIT, compatible with GPLv3.

Spike checklist (two weeks, against real servers):

1. libssh 0.12 with OpenSSL 3.x builds as an iOS xcframework.
2. The socketpair bridge survives a network switch (Wi-Fi to cellular and back).
3. A Secure Enclave key authenticates through an in-app agent (ssh\_userauth\_agent, ssh\_set\_agent\_channel).
4. mlkem768x25519-sha256 is negotiated against OpenSSH 10.
5. Test on a device whether Face ID protection on a Keychain item survives iCloud Keychain sync (section 15).
6. The strongest Data Protection class for the local database works with Shello's writes (section 13).

Open questions and risks:

- Employer rights: under [Art. 17 of the Swiss Copyright Act](https://www.droit-bilingue.ch/de-en/2/23/231.1-17-21.html), only the employer may use software an employee writes in the course of their duties, and an employment contract can extend this. Check the contract or get written clearance before the first public release; GPL code, once published, cannot be withdrawn.
- Name: no App Store app is called "Shello", but [Shelly – SSH Client](https://apps.apple.com/app/id989642999) is an iOS SSH client one letter away. Have a trademark lawyer check the risk of confusion, then register the name before the repository goes public: in Switzerland with the IGE, and in the EU and US registers. For a GPL app, the name, not the code, is what stops a free fork on the App Store.
- pam\_rssh packaging per Linux distribution is unverified; the key-based sudo setup guide must cover installing it.
- VoiceOver in a terminal is genuinely hard; the accessibility targets in section 16 may need a narrower first version.
- Scope: this is a large app for a solo, part-time developer. The MVP line in section 17 (46 requirements) is the guard against building everything at once.
