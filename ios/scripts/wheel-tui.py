"""A full-screen program with its own history, as Claude Code draws one: on
the alternate screen, with mouse reporting on, it shows the lines 1…400 and
moves through them only on mouse wheel reports. The terminal holds no
history of its own, so only the wheel can reveal earlier lines.
For the UI tests (scripts/ui-test.sh)."""

import os
import re
import select
import shutil
import signal
import sys
import termios
import tty

LINES = [str(n) for n in range(1, 401)]
offset = 0  # lines scrolled up from the newest


def draw():
    cols, rows = shutil.get_terminal_size()
    global offset
    offset = max(0, min(offset, len(LINES) - rows))
    end = len(LINES) - offset
    shown = LINES[max(0, end - rows):end]
    out = "\x1b[H\x1b[2J" + "\r\n".join(line[:cols] for line in shown)
    os.write(1, out.encode())


def main():
    global offset
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    # Alternate screen, button tracking, SGR encoding.
    os.write(1, b"\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h")
    signal.signal(signal.SIGWINCH, lambda *_: draw())
    draw()
    pending = b""
    try:
        while True:
            try:
                ready, _, _ = select.select([fd], [], [])
            except InterruptedError:
                continue
            if not ready:
                continue
            pending += os.read(fd, 4096)
            for match in re.finditer(rb"\x1b\[<(\d+);\d+;\d+[Mm]", pending):
                button = int(match.group(1)) & ~0b11100
                if button == 64:
                    offset += 1
                elif button == 65:
                    offset -= 1
            pending = pending[pending.rfind(b"\x1b"):] if b"\x1b" in pending[-16:] else b""
            draw()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


main()
