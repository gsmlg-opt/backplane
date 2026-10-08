"""Linux PTY host fixture; all descendants retain LocalCommand's owned group."""

import errno
import fcntl
import os
import select
import signal
import struct
import sys
import termios

master, slave = os.openpty()
rows, columns = map(int, sys.argv[1:3])
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
os.tcsetpgrp(slave, os.getpgrp())
signal.signal(signal.SIGINT, signal.SIG_IGN)
child = os.fork()

if child == 0:
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.close(master)
    for descriptor in (0, 1, 2):
        os.dup2(slave, descriptor)
    if slave > 2:
        os.close(slave)
    os.execv(sys.argv[3], sys.argv[3:])

os.close(slave)
while True:
    ready, _, _ = select.select([0, master], [], [])
    if 0 in ready:
        data = os.read(0, 4096)
        if not data:
            break
        os.write(master, data)
    if master in ready:
        try:
            data = os.read(master, 4096)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not data:
            break
        os.write(1, data)

os.close(master)
_, status = os.waitpid(child, 0)
sys.exit(os.waitstatus_to_exitcode(status))
