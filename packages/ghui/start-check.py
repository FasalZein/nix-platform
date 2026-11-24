# Start check for ghui (flake check ghui-start). Usage: start-check.py GHUI LOG SECONDS
# Runs GHUI in a pseudo-terminal (120x40) until its debug log (GHUI_DEBUG_LOG=LOG)
# shows the first pull request list loaded, which happens only after the app
# bundle has loaded and mounted. Exit 0 then; exit 1 after SECONDS, with the
# screen text, which shows the boot error (for example "Migrator2 is not defined").
import os, pty, re, select, signal, struct, sys, termios, fcntl, time

ghui, log, limit = sys.argv[1], sys.argv[2], float(sys.argv[3])
pid, fd = pty.fork()
if pid == 0:
    os.execv(ghui, [ghui])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
screen = bytearray()


def drain(wait):
    ready, _, _ = select.select([fd], [], [], wait)
    if ready:
        try:
            screen.extend(os.read(fd, 65536))
        except OSError:
            pass


def mounted():
    try:
        with open(log, "rb") as f:
            return b"[pullRequestsAtom:done]" in f.read()
    except FileNotFoundError:
        return False


deadline = time.time() + limit
ok = False
while time.time() < deadline and not ok:
    drain(0.2)
    ok = mounted()
os.kill(pid, signal.SIGKILL)
# macOS keeps a killed process until its terminal output is read, so keep reading.
while os.waitpid(pid, os.WNOHANG) == (0, 0):
    drain(0.1)

text = re.sub(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b[()][0-9A-Za-z]|\x1b[=>78]", " ", screen.decode("utf-8", "replace"))
text = re.sub(r"[ \t]+", " ", re.sub(r"[^\S\n]+|[\x00-\x08\x0b-\x1f]", " ", text))
if ok:
    print("ghui-start: app mounted and loaded the mock pull request list")
    sys.exit(0)
print(f"ghui-start: FAILED, no pull request list after {limit:.0f}s; screen text:")
# Without the spinner frames (braille block), the boot hints and errors remain.
print(" ".join(re.sub(r"[\u2800-\u28ff]", " ", text).split())[:1500])
sys.exit(1)
