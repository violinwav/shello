# A Mosh tab is Mosh plus tmux plus a side connection

Mosh keeps no SSH connection after it starts, synchronises only the visible screen, drops the OSC 133 and OSC 7 sequences that shell integration relies on, and has no port forwarding. So a Mosh tab always attaches to a tmux session, takes its scrollback and search from tmux, and opens a side connection on demand for hidden channels (tmux browser, Vim detection), file transfer and port forwards.

## Consequences

- Hosts that use Mosh must have tmux.
- Shell integration is not offered in Mosh tabs; Vim detection there relies on tmux and the window title.
- Automatic auto sudo works in a Mosh tab only when the side connection can confirm through tmux that the foreground command is sudo.
