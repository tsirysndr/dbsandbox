"""Exercise actual raw keyboard input and terminal restoration, never a real VM."""
import re
import os, sys, pty, termios, fcntl, struct, select, subprocess, time, signal, json
from vt_screen import Screen
import codecs
binary = sys.argv[1]

def session(interrupt=False):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 120, 0, 0))
    command = [binary, 'tui'] if os.environ.get('DBSANDBOX_TEST_BINARY') else [binary, 'bin/dbsandbox.js', 'tui']
    proc = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    output = ''
    screen = Screen(120,32)
    decoder = codecs.getincrementaldecoder('utf8')('replace')
    def read():
        nonlocal output
        if select.select([master], [], [], .04)[0]:
            try:
                text=decoder.decode(os.read(master,262144));output+=text;screen.feed(text)
            except OSError: pass
    def wait(check, label):
        until = time.monotonic()+15
        while time.monotonic()<until:
            read()
            if check(): return
            if proc.poll() is not None: break
        raise AssertionError(label+'\n'+frame())
    def frame(): return screen.frame()
    def key(value): os.write(master, value.encode())
    try:
        wait(lambda: 'feature' in frame(), 'TUI readiness')
        assert 'error:' not in output
        if interrupt:
            key('\x03')
        else:
            assert 'GRAPH' in frame(), 'branch graph enabled by default'
            key('g'); time.sleep(.2)
            for _ in range(5): read()
            assert 'GRAPH' not in frame(), 'g switches to plain table'
            key('g'); wait(lambda: 'GRAPH' in frame(), 'g restores graph')
            key(']'); time.sleep(.1); key('[')
            key('\t')
            wait(lambda: 'SELECT DATABASE' in frame(), 'database dropdown opens')
            key('j\r')
            wait(lambda: 'vector-only' in frame() and 'feature' not in frame(), 'database selection isolates branches')
            key('\t'); time.sleep(.2); key('k\r')
            wait(lambda: 'feature' in frame() and 'vector-only' not in frame(), 'switch back to postgres')
            key('/ftr')
            wait(lambda: 'FIND A BRANCH' in frame(), 'fuzzy subsequence search'); time.sleep(.3)
            key('\r')
            time.sleep(.2); key('d'); time.sleep(.2)
            for _ in range(5): read()
            assert 'CONFIRM ACTION' not in frame(), 'active branch delete must be blocked'
            key('y'); wait(lambda: os.path.exists(os.environ['CLIPBOARD_LOG']), 'copy connection URL')
            key('l')
            wait(lambda: 'DATABASE LOGS' in frame() and 'DATABASE LOG FIXTURE' in frame(), 'database logs render inside TUI')
            key('t'); time.sleep(.15); key('t')
            key('/fixture\r'); time.sleep(.2)
            key('d'); wait(lambda: 'EXPORT LOGS AS TEXT' in frame(), 'log export prompt')
            wait(lambda: re.search(r'dbsandbox-server-[a-f0-9]{8}\.txt',frame()) is not None, 'export filename renders')
            filename=re.search(r'dbsandbox-server-[a-f0-9]{8}\.txt',frame()).group()
            key('\x7f'*len(filename)+os.environ['LOG_EXPORT_FILE']+'\r')
            wait(lambda: os.path.exists(os.environ['LOG_EXPORT_FILE']), 'raw text export')
            exported=open(os.environ['LOG_EXPORT_FILE']).read()
            assert 'SECOND LOG LINE' in exported and 'DO-NOT-LEAK' not in exported
            assert os.stat(os.environ['LOG_EXPORT_FILE']).st_mode & 0o777 == 0o600
            key('v'); wait(lambda: 'VM CONSOLE LOG' in frame() and 'VM CONSOLE FIXTURE' in frame(), 'VM logs render inside TUI')
            key('\x1b'); time.sleep(.2)
            key('b')
            wait(lambda: 'FORK BRANCH' in frame(), 'fork prompt')
            key('\x1b'); time.sleep(.2)
            key('?')
            wait(lambda: 'KEYBOARD SHORTCUTS' in frame(), 'help overlay')
            key('\x1b'); time.sleep(.2)
            key('s')
            wait(lambda: 'Stop postgres/feature?' in frame(), 'stop confirmation')
            key('y')
            wait(lambda: any(c.get('state')=='exited' for c in json.load(open(os.environ['FIXTURE_RUNTIME']))['containers']), 'selected fork stops')
            key('e')
            wait(lambda: 'VM RESOURCES' in frame(), 'resource prompt'); time.sleep(.15)
            key('\x7f'*6+'4 4096\r')
            time.sleep(.3)
            key('y')
            wait(lambda: json.load(open(os.environ['FIXTURE_RUNTIME'])).get('cpus')==4, 'resource overrides applied')
            key('/archive\r'); time.sleep(.3); key('d')
            wait(lambda: 'Delete postgres/archive' in frame(), 'inactive delete confirmation')
            key('n'); time.sleep(.2)
            assert any(b['name']=='archive' for b in json.load(open(os.environ['FIXTURE_RUNTIME']))['volumes'][0]['branches'])
            key('d'); time.sleep(.2); key('y')
            wait(lambda: all(b['name']!='archive' for b in json.load(open(os.environ['FIXTURE_RUNTIME']))['volumes'][0]['branches']), 'inactive branch deleted')
            # Resizing exercises the native resize event without losing the bottom bar.
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 20, 80, 0, 0))
            screen.resize(80,20)
            os.kill(proc.pid, signal.SIGWINCH)
            time.sleep(.2)
            key('q')
        wait(lambda: proc.poll() is not None, 'clean exit')
        for _ in range(3): read()
        assert proc.returncode == (130 if interrupt else 0), proc.returncode
        assert '\x1b[?1049l' in output, 'alternate screen not restored'
        assert '\x1b[?25h' in output, 'cursor not restored'
        assert termios.tcgetattr(slave)[3] & (termios.ICANON|termios.ECHO) == original[3] & (termios.ICANON|termios.ECHO), 'raw input was not restored'
        assert 'DO-NOT-LEAK' not in output, 'credentials escaped the managed log pane'
        assert 'Stopping container' not in output, 'child operation output overwrote the native TUI'
    finally:
        if proc.poll() is None: os.killpg(proc.pid, signal.SIGKILL);proc.wait()
        os.close(master);os.close(slave)

session()
session(True)
print(json.dumps({'keyboard':'fuzzy search, jump, fork, help, stop and VM resize','cleanup':'quit and Ctrl-C restore terminal'}))
