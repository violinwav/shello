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

How to read it: every requirement carries a phase tag, MVP, v1 or Later, defined in section 17. Out of scope for now: Android, a native macOS app, and a local shell on the device.

## 2. Technical baseline

Shello is a native Swift app for iOS and iPadOS 26 and later. iOS 26 is the floor because it is the first release whose CryptoKit offers ML-KEM, which section 14 depends on.

- App shell: SwiftUI. Terminal view and Shello keyboard: UIKit, using a custom input view and input accessory view, which iOS allows inside your own app.
- Terminal emulation: SwiftTerm (MIT licence), already used by commercial SSH clients.
- SSH and SFTP: SwiftNIO SSH or Citadel (built on it). The chosen stack must support the algorithms in sections 4 and 14; post-quantum key exchange will likely need to be added on top of CryptoKit.
- Mosh: decision open because of its GPLv3 licence (section 18).
- VNC: RoyalVNCKit is the candidate; confirm its licence before committing.
- Storage: a local database (SwiftData or SQLite) for hosts, snippets and settings. Secrets live only in the Keychain or the Secure Enclave, never in the database.
- Architecture: a UI-independent session core (connections, channels, transfers, tmux queries) so it can later back a File Provider extension, a Mac app or a shared library.
- No Shello backend. Sync is optional and goes through the user's own iCloud (section 15).

## 3. Hosts and connection profiles

A host is a saved profile that holds everything needed to connect in one tap; secrets are referenced, never stored in the profile.

- MVP: Profile fields: name, address (hostname, IPv4 or IPv6), port, protocol (SSH, Mosh, VNC), username, auth method (key, password, keyboard-interactive, agent), key reference, group, tags, notes, startup command, environment variables, terminal type (default xterm-256color), keepalive interval, connect timeout, auto sudo mode (section 9).
- MVP: Groups and tags. A tag has a colour and an optional "production" flag that switches on safety confirmations (section 11).
- MVP: Search across name, address, user and tags. Favourites and recents ordering.
- MVP: Host key verification. First connect shows key type and SHA-256 fingerprint and asks the user to trust it. Keys are stored per host and port.
- MVP: A changed host key blocks the connection with a clear warning. Replacing the stored key requires an explicit action plus biometric confirmation.
- v1: Jump hosts: a chain of one or more saved hosts (ProxyJump), each with its own credentials.
- v1: Import from an OpenSSH config file and a known\_hosts file. Supported: Host, HostName, User, Port, IdentityFile, ProxyJump, LocalForward, RemoteForward. Unsupported directives are listed after import, never silently dropped.
- v1: Reachability and latency. While the host list is visible, each directly reachable host is probed with a TCP connect to its port, at most once per minute. Hosts behind a jump host show status only while connected. Probing can be turned off globally and per host.
- v1: Duplicate a host, and per-group defaults (user, key, jump host) that new hosts inherit.

## 4. Sessions and protocols

Work must survive the app leaving the foreground. iOS will suspend the app and the SSH connection will drop, so the work keeps running on the server in tmux or Mosh, and Shello reconnects and reattaches when the user returns.

- MVP: SSH-2 client with publickey (Ed25519, ECDSA P-256 and P-384, RSA with SHA-256/512), password, keyboard-interactive (including one-time-code prompts) and agent authentication.
- MVP: Algorithm policy. Preferred key exchange: post-quantum hybrids first (section 14), then curve25519-sha256. Ciphers: chacha20-poly1305, AES-GCM, AES-CTR. MACs: HMAC-SHA2 encrypt-then-MAC. SHA-1, CBC ciphers and DSA keys are off; a legacy algorithm can be enabled per host only, with a visible warning on that host.
- MVP: Several concurrent sessions, each in its own tab, several tabs per host, fast switching between them.
- MVP: Lifecycle: connect, verify host key, authenticate, run the startup command, active. On network loss the tab shows "reconnecting" and retries automatically with backoff before giving up.
- MVP: Background: Shello uses the short background time iOS grants, then closes connections cleanly. It does not use workarounds such as silent audio or location updates to stay alive, because they risk App Store rejection and drain the battery.
- MVP: Return to foreground: reconnect automatically and, when the host uses tmux, reattach to the same tmux session. Local scrollback from before the drop is kept.
- MVP: Configurable keepalive. The latency shown in a session is the keepalive round-trip time.
- v1: Mosh sessions: bootstrapped over SSH, then UDP. They roam across networks, survive sleep and use local echo prediction. Requires mosh-server on the host; ships only after the licence decision in section 18.
- v1: Relaunch restore: after the app was terminated, the last open sessions are listed for one-tap reconnect and reattach.
- v1: Port forwarding: local, remote and dynamic (SOCKS), saved per host and started with the session. Local listeners only work while Shello is running, which the UI must state.
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
- MVP: Hardware keyboards: Ctrl, Option as Meta (configurable), an assignable Esc for keyboards without one, and Cmd shortcuts for the app (new tab, next tab, command palette, font size).
- MVP: Bell: haptic tap plus a visual flash; a badge on the tab if it rings in the background.
- MVP: Pinch to change font size; per-host font and theme overrides.
- v1: Links: URLs, IP addresses and file paths are detected and can be opened or copied.
- v1: OSC 52: lets the server write to the iOS clipboard. Off by default, enabled per host. Reading the clipboard from the server is never allowed.
- v1: Optional shell integration script for bash, zsh and fish, installed on the server by the user. It marks prompts and commands (OSC 133) and the working directory (OSC 7). That enables jumping between commands, copying one command's output, exit status per command, and command detection for the Vim pad (section 7).
- Later: Inline images (sixel or kitty graphics protocol).

## 6. Shello keyboard

The Shello keyboard replaces the system keyboard inside terminal tabs and puts every terminal key within one tap or one gesture. Typed input goes only to the active session and is never logged or analysed.

- MVP: In-app keyboard with three layers: letters; symbols (digits plus ! @ # $ % ^ & \* ( ) \~ \` | \\ { } \[ \]); function (F1 to F12, Home, End, PgUp, PgDn, Ins, Del and common Ctrl shortcuts such as ^C ^D ^Z ^L ^R ^A ^E ^W).
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
- Later: Terminal gestures such as a two-finger swipe to switch tabs.

## 7. Vim pad and context detection

Shello only receives a stream of text, so it can never be certain Vim is running. The Vim pad therefore switches on from layered signals, and the user can always toggle it by hand.

Detection signals, most reliable first:

1. Inside tmux: the current command of the active pane, queried over a hidden SSH channel whenever the pane or screen mode changes.
2. With shell integration installed: the command name reported when a command starts.
3. Fallback: the alternate screen is switched on and the window title names vim or nvim.

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
- v1: Works through jump hosts and inside Mosh sessions. A minimum tmux version is set during testing; older versions fall back to plain attach.
- Later: tmux control mode (tmux -CC): tmux windows and panes shown as native Shello tabs and splits.
- Later: Attach helpers for GNU screen and Zellij.

## 9. Auto sudo

Auto sudo answers sudo password prompts for the user. The default is a one-tap confirmation, not a silent fill, because the main risk is sending a password to the wrong machine.

Modes, set per host:

1. Off.
2. Confirm (default once enabled): when a sudo prompt is detected, Shello shows which host and user are asking; Face ID or a tap sends the password.
3. Automatic: sends without asking. Turning it on for a host tagged production needs an extra confirmation.
4. Key-based sudo (recommended, no password at all): the server authenticates sudo against Shello's SSH agent using the PAM module [pam\_ssh\_agent\_auth](https://mankier.com/package/pam-ssh-agent-auth). Each sudo is approved with Face ID on the phone. Shello ships a setup guide and snippet for the server side.

Detection:

- v1: A prompt counts as a sudo prompt when the last line matches the sudo pattern for the expected user (default "\[sudo\] password for \<user>:", plus a custom pattern per host) and the cursor sits at its end.
- v1: With shell integration or tmux available, Shello also checks that the foreground command is sudo.

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
- v1: Works through jump hosts and uses the same host key checks as the terminal.
- Later: File Provider extension: hosts appear as locations in the Files app, so other apps can open and save remote files directly.
- Later: Legacy SCP protocol fallback for small devices without an SFTP server (some routers and embedded systems).
- Later: Edit root-owned files through sudo, using auto sudo for the password.

## 11. Snippets, command palette and multi-host run

Snippets turn repeated commands into one tap, and multi-host run applies them to several servers at once with results per host.

- MVP: Snippet fields: name, command, description, tags, scope (all hosts, a group, or chosen hosts) and variables written as $name. A variable can have a default, a list of choices, or be asked every time.
- MVP: Insert or run: insert types the command at the prompt without pressing return; run also presses return.
- MVP: Command palette with fuzzy search across snippets, hosts (connect or switch), tmux sessions and app actions (new tab, split, keyboard preset). Opened from the extra keys row, the toolbar or Cmd-K.
- v1: Built-in variables: $HOST, $USER and, with shell integration, $CWD. The clipboard is inserted only on an explicit tap.
- v1: Command history per host from shell integration; without it, the history lists snippets run.
- v1: Multi-host run: each host runs the snippet on its own SSH exec channel, separate from the user's terminals. The results view shows per host the exit code, output, and duration; failed hosts are highlighted and can be re-run.
- v1: Safety: hosts tagged production require a confirmation that lists them by name. Commands matching a configurable danger list (rm -rf, mkfs, shutdown, reboot, DROP TABLE) need a second confirmation.
- v1: Broadcast typing: keystrokes mirrored into several open tabs (like tmux synchronize-panes), with a constant visible indicator on every affected tab.
- v1: Snippets import and export as JSON and sync through iCloud (section 15).

## 12. Remote desktop (VNC)

Remote desktop is deliberately simple: view and control a desktop well enough to fix something, not to replace a full remote desktop suite.

- v1: VNC (RFB) client with no-auth and VNC password authentication, plus macOS Screen Sharing authentication if the chosen library supports it.
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

- MVP: Generate Ed25519 keys, stored in the Keychain, device-only and protected by biometrics.
- MVP: Generate ECDSA P-256 keys inside the Secure Enclave. They can never be exported. The Secure Enclave does not support Ed25519, so hardware-bound SSH keys are always P-256.
- MVP: Import OpenSSH private keys (OpenSSH and PEM formats, with or without passphrase) from the Files app or by pasting.
- MVP: Public key export: copy, share, QR code, and "install on host", which appends it to authorized\_keys over an authenticated session (like ssh-copy-id).
- MVP: Per key: require biometrics on every use, or once per app session.
- v1: OpenSSH certificates: user certificates loaded alongside their key, and host certificates trusted through a configured certificate authority.
- v1: Shello as SSH agent for forwarded sessions and key-based sudo (section 9). Every signature request from a remote host shows which host asks and needs approval.
- Later: FIDO2 security keys (sk-ssh-ed25519) over NFC and USB-C.

Secrets and the device:

- MVP: Passwords and passphrases live only in the Keychain, readable only while the device is unlocked and never synced unless the user opts in. They never appear in the database, logs, crash reports or scrollback.
- MVP: App lock with Face ID, Touch ID or passcode at launch and after a configurable time in the background. The app switcher snapshot is blurred.
- MVP: The local database uses the strongest iOS Data Protection class that still allows reconnecting from the background.
- v1: Local security log: connections, host key changes, auto sudo fills and agent signatures. It can be exported and never leaves the device by itself.

## 14. Post-quantum cryptography

Post-quantum key exchange belongs in v1, not the future. [OpenSSH](https://www.openssh.org/pq.html) has used the hybrid mlkem768x25519-sha256 by default since version 10.0 (April 2025), and version 10.1 warns when a connection does not use a post-quantum key exchange. Post-quantum signatures stay in Later, because OpenSSH does not support them yet.

Phase 1, key exchange. It protects recorded traffic from being decrypted later by a quantum computer:

- v1 (MVP if the SSH library allows it): offer mlkem768x25519-sha256 first, sntrup761x25519-sha512 second, then classical curve25519-sha256. ML-KEM-768 comes from CryptoKit, which offers it from iOS 26 ([guide](https://www.atelier-socle.com/en/articles/cryptokit-quantum-secure-guide)), combined with X25519.
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
- MVP: Export and import of all non-secret data (hosts, groups, tags, snippets, presets, settings) as one JSON file.
- v1: iCloud sync through CloudKit's private database for the same data. Sensitive fields (addresses, usernames, notes, startup commands) use CloudKit's encrypted fields.
- v1: Secrets sync only through iCloud Keychain, opted into per item. Secure Enclave keys never leave the device: on another device the host shows "key not on this device" and offers to create and install a new key.
- v1: Conflicts: last change wins per field; deletions sync with an undo window.
- v1: Encrypted full backup, secrets included, protected by a passphrase the user chooses.
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
- The terminal parser and protocol code are fuzz-tested.
- Test matrix: OpenSSH 8.x, 9.x and 10.x, Dropbear, several tmux versions, and slow or lossy networks.
- No home-made cryptographic primitives. Primitives come from CryptoKit or audited libraries; Shello only composes protocols from them.
- Every dependency is licence-reviewed before it ships.

Accessibility:

- VoiceOver labels on every control and every keyboard key.
- Terminal: an option to announce new output and to read the current line.
- Dynamic Type for app screens (the terminal font size is set separately), Reduce Motion stops the blinking cursor, colour is never the only signal.

Platforms and languages:

- iPhone and iPad on iOS and iPadOS 26 and later, including Stage Manager, external displays and hardware keyboards.
- English and German at launch.

## 17. Release phases

Shello ships in three phases. MVP is a private TestFlight build used daily on the developer's own servers. v1 is the first App Store release and covers the Termigo baseline plus the differentiators. Later holds items that wait on standards or demand.

&#91;embedded content: release phases · 3 phases, 2 gates\]

Durations are rough estimates for one developer working part-time; re-plan them after the SSH library spike.

## 18. Open questions and risks

The Mosh licence and the SSH library choice are the two decisions that most affect scope, and both should be settled during the MVP.

- Mosh licence: Mosh is GPLv3. Its authors [will not object](https://codegraph.jelmer.uk/mosh/1.4.0-1/COPYING.iOS) to App Store distribution if the GPL is otherwise followed, which in practice means open-sourcing Shello. The options: open-source Shello, write an own Mosh-protocol implementation, or skip Mosh and rely on tmux auto-reattach.
- SSH library: SwiftNIO SSH, Citadel or libssh2. Coverage of RSA, post-quantum key exchange, certificates and agent forwarding decides; a two-week spike against real servers should settle it.
- Auto sudo default: when a sudo password is saved, should the mode start as Confirm or stay Off until the user turns it on?
- Business model: one-time purchase, subscription or free with Pro features. This changes what goes into MVP.
- VNC library licence (RoyalVNCKit) to confirm before v1 work starts.
- VoiceOver in a terminal is genuinely hard; the accessibility targets in section 16 may need a narrower first version.
- Name: check "Shello" against App Store listings and trademark registers (Switzerland, EU, US) before any public use.
- Scope: this is a large app for a solo, part-time developer. The MVP line in section 17 is the guard against building everything at once.
