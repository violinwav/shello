# Shello UI v1

First UI design for Shello, made on 12 October 2026 in a Claude Design canvas. It covers visuals and screen flow only; `README.md` at the repo root is the functional specification.

Live canvas (private to its owner, clickable prototype): https://claude.ai/code/artifact/184d022f-92c8-4e8e-884c-9c1f17aad9ba

## Contents

- `canvas/canvas.json`: board layout (positions, titles, which boards are interactive).
- `canvas/*.dc.html`: one file per screen, in the canvas's Design Component format.

The `.dc.html` files need the canvas runtime (`support.js`) and do not open as standalone pages in a browser. View them in the live canvas, or export PNG or PDF from it.

## Screens

| File | Screen | Shows |
| --- | --- | --- |
| Main.dc.html | Hosts | Host list, live sessions, tag filters, tab bar |
| Terminal.dc.html | Terminal + Shello keyboard | SSH session, session tabs, extra keys row, keyboard with letter, symbol and fn layers (interactive) |
| Tmux.dc.html | tmux sessions | Session browser, window tabs, pane map, prefix actions |
| Vim.dc.html | Vim mode | Vim buffer with the Vim pad and mode switching (interactive) |
| Desktop.dc.html | Remote desktop | VNC view with overview map, trackpad and touch modes |
| NewHost.dc.html | New host | Connection sheet: protocol, auth, startup command, tags |
| Snippets.dc.html | Command palette | Snippet with variables, multi-host run |
| Keyboard.dc.html | Keyboard settings | Extra-key presets, key library, behaviour toggles |
| Appearance.dc.html | Appearance | Terminal theme, font, size, cursor, accent, interface mode |
| HostsLight.dc.html | Hosts, light | Light-mode variant of Hosts |
| System.dc.html | System | Logo, type, colour tokens, keys, controls |

## Design system

- Look: dark first, Apple-style grouped lists and sheets; monospace for titles, hostnames, keycaps and the terminal.
- Type: Geist for interface text, JetBrains Mono for titles, data, keys and terminal.
- Accent presets: Tiffany #0ABAB5 (default), Phosphor #9EF07A, Ice #7CCBFF, Iris #B9A4FF. Text on accent fills is #16130B.
- Dark surfaces: ground #0A0B0D, cell #15171A, key #2B2E33, hairline #23262B; text #EDEFF2, #A3A9B1, #868C94.
- Light surfaces: ground #F2F3F5, cell #FFFFFF, tile #EEF0F2, hairline #E0E2E6; text #111316, #4A5058, #60666E.
- Status: online #46D39A (filled dot), offline (hollow ring), error #FF6B5E.
- Signature: a blinking accent block cursor after every large title. Logo: a speech bubble holding a prompt.
- Frame: phone screens at 390 x 844. Status bar and system keyboard are not drawn; the OS provides them.

## Known gaps against the functional spec

- New host shows "id_ed25519 · Stored in Secure Enclave". The Secure Enclave only holds P-256 keys, so it should read "ecdsa-p256 · Secure Enclave" or "id_ed25519 · Keychain".
- Vim mode says "vim detected". The spec treats detection as a best guess with a manual toggle.
- No screens yet for the SFTP browser, auto sudo prompt, host key verification or the post-quantum indicator.
