#!/usr/bin/env python3
"""Boot the installer USB in QEMU and photograph what it puts on screen.

This exists because nothing else available to us can show that the graphical
installer actually works. The image assertion in CI proves the pieces are
present and wired; it cannot prove weston starts, that the app renders, or that
the embedder taken from the HMI image links against our bundle -- that last one
either works or the app dies at startup, and only a boot tells you which.

QEMU's QMP `screendump` captures the guest framebuffer with no cooperation from
the guest, and `input-send-event` can tap the screen, so the whole
input-method-v1 -> text-input-v1 -> Flutter keyboard path is testable headlessly.

Three shots, each answering something the one before it cannot:

    01-disk.png       black => weston never started; an empty desktop => the app
                      died, most likely the embedder not matching the bundle
    02-station.png    still the disk step => the tap did not reach the app
    03-keyboard.png   no panel at the bottom => the field took focus but the
                      input method did not raise, which is the failure this
                      whole app exists to avoid

A shot proves a screen was drawn, never that it is the right one -- read them.

    boot-test.py --usb out/usb-installer.img --out out/boot-test

Accelerated where KVM exists (CI, any Linux box) and plain TCG where it does
not. TCG is roughly 15x slower, which is tedious but not disqualifying: the
timeouts below are generous and scale with --slow.
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

# A frame this uniform is a blank screen, not a UI. Measured against the disk
# step -- the emptiest of the three -- of run 34743482120: 86.8% of sampled
# pixels are 002b36, which is Solarized base03, the app's own background. So the
# floor is the background, and the margin to this ceiling is real.
UNIFORM_MAX = 0.99

# Sampling stride, in pixels, for both measurements below.
STRIDE = 97

# A tap that navigates repaints most of the screen. Measured on run
# 34744364926's frames, where the flow never left the disk screen:
#
#   cursor moved + Continue's hover highlight   0.995%  and  1.014%
#   an actually repainted content area         55.8%
#
# So "nothing happened" is not near zero -- a hover highlight on a 190x60
# button is about 1% of the sampled set on its own, and a 1% threshold would
# have passed one of the two dead frames above. 10% sits an order of magnitude
# clear of hover and five times clear of a real repaint.
CHANGE_MIN = 0.10

# Two consecutive frames within this of each other count as "stopped moving".
# Generous enough to ignore a blinking text cursor, tight enough that a
# sliding keyboard panel does not qualify.
STILL_MAX = 0.01


def uniformity(px):
    """Fraction of sampled pixels that are the single most common colour.

    A compositor that never draws, or an app that died leaving an empty
    desktop, produces a frame that is essentially one colour.
    """
    counts = {}
    # Every 97th pixel: a prime stride, so it cannot land on a column or row
    # period and read one stripe of the screen as the whole screen.
    for k in range(0, len(px) - 3, STRIDE * 3):
        c = px[k:k + 3]
        counts[c] = counts.get(c, 0) + 1
    total = sum(counts.values())
    return (max(counts.values()) / total) if total else 1.0


def changed(a, b):
    """Fraction of sampled pixels that differ between two frames."""
    if a is None or len(a) != len(b):
        return 1.0
    n = diff = 0
    for k in range(0, len(b) - 3, STRIDE * 3):
        n += 1
        if a[k:k + 3] != b[k:k + 3]:
            diff += 1
    return (diff / n) if n else 0.0


def wait_for_change(get_frame, prev, timeout, poll):
    """Wait for the screen to move, then for it to stop moving.

    Returns (fraction_changed, frame), measured on the settled frame.

    Both halves are needed. Without the first, a fixed sleep is either a false
    failure on a loaded runner or dead time on every green run. Without the
    second, the poll returns on the first frame past the threshold, which for
    an animating widget is the middle of the animation -- run 34746637743
    photographed the on-screen keyboard with one key row showing and the rest
    still below the fold. It passed, at 11.8% against a 10% bar, and the
    screenshot was worse evidence than the fixed sleep it replaced.

    "Stopped moving" is two consecutive frames within STILL_MAX of each other,
    which a blinking text cursor stays under.
    """
    deadline = time.monotonic() + timeout
    px = get_frame()
    while changed(prev, px) < CHANGE_MIN and time.monotonic() < deadline:
        time.sleep(poll)
        px = get_frame()
    # Settle. Bounded by the same deadline, so a permanently animating screen
    # cannot hang the run -- it just gets photographed mid-animation.
    while time.monotonic() < deadline:
        time.sleep(poll)
        nxt = get_frame()
        if changed(px, nxt) < STILL_MAX:
            px = nxt
            break
        px = nxt
    return changed(prev, px), px


def find_ovmf():
    """OVMF's filename is not stable across distributions."""
    code = [
        '/usr/share/OVMF/OVMF_CODE_4M.fd',
        '/usr/share/OVMF/OVMF_CODE.fd',
        '/usr/share/edk2/x64/OVMF_CODE.4m.fd',
        '/opt/homebrew/opt/qemu/share/qemu/edk2-x86_64-code.fd',
    ]
    varsf = [
        '/usr/share/OVMF/OVMF_VARS_4M.fd',
        '/usr/share/OVMF/OVMF_VARS.fd',
        '/usr/share/edk2/x64/OVMF_VARS.4m.fd',
        '/opt/homebrew/opt/qemu/share/qemu/edk2-i386-vars.fd',
    ]
    c = next((p for p in code if os.path.exists(p)), None)
    v = next((p for p in varsf if os.path.exists(p)), None)
    if not c or not v:
        sys.exit('no OVMF firmware found; install ovmf (Debian/Ubuntu) or qemu (brew)')
    return c, v

class Qmp:
    def __init__(self, path, timeout=120):
        deadline = time.time() + timeout
        while True:
            try:
                self.s = socket.socket(socket.AF_UNIX)
                self.s.connect(path)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.5)
        self.f = self.s.makefile('rw', encoding='utf-8', newline='\n')
        self._read()                      # greeting
        self.cmd('qmp_capabilities')

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise RuntimeError('QMP closed')
            msg = json.loads(line)
            if 'event' in msg:            # asynchronous, not our reply
                continue
            return msg

    def cmd(self, name, **args):
        self.f.write(json.dumps({'execute': name, 'arguments': args} if args
                                else {'execute': name}) + '\n')
        self.f.flush()
        r = self._read()
        if 'error' in r:
            raise RuntimeError(f'{name}: {r["error"]}')
        return r.get('return')

    def screenshot(self, path):
        # format=png needs QEMU >= 7.1; fall back to PPM, which every version
        # can write, rather than failing the whole test over an image container.
        try:
            self.cmd('screendump', filename=path, format='png')
        except RuntimeError:
            ppm = path.replace('.png', '.ppm')
            self.cmd('screendump', filename=ppm)
            return ppm
        return path

    def frame(self):
        """The guest's current framebuffer as (width, height, RGB bytes).

        A PPM dump rather than the PNG beside it: P6 is a header and then raw
        RGB triples, where reading a PNG back would mean an inflate and an
        unfilter pass for numbers this coarse.
        """
        tmp = os.path.join(tempfile.gettempdir(), 'frame.ppm')
        self.cmd('screendump', filename=tmp)
        with open(tmp, 'rb') as f:
            data = f.read()
        os.unlink(tmp)
        # P6\n<w> <h>\n<maxval>\n then w*h*3 bytes. Fields are whitespace
        # separated and a comment line may follow the magic.
        fields, i = [], 2
        while len(fields) < 3:
            while i < len(data) and data[i:i + 1].isspace():
                i += 1
            if data[i:i + 1] == b'#':
                while data[i:i + 1] not in (b'\n', b''):
                    i += 1
                continue
            j = i
            while j < len(data) and not data[j:j + 1].isspace():
                j += 1
            fields.append(int(data[i:j]))
            i = j
        return fields[0], fields[1], data[i + 1:]

    def tap(self, x, y):
        """Tap at x,y as a fraction (0..1) of the screen.

        Press and release go in SEPARATE input-send-event calls. QEMU applies
        one call's events and then emits a single sync, and the guest samples
        button state at sync boundaries -- so a batch containing both down and
        up nets out to no change and the guest never sees the button pressed.
        Observed exactly that: the pointer moved and the button under it lit up
        with hover, and nothing was ever activated.

        The move is still one batch, so the tablet cannot be sampled
        mid-way between the old position and the new.
        """
        X, Y = int(x * 32767), int(y * 32767)
        self.cmd('input-send-event', events=[
            {'type': 'abs', 'data': {'axis': 'x', 'value': X}},
            {'type': 'abs', 'data': {'axis': 'y', 'value': Y}}])
        time.sleep(0.2)
        self.cmd('input-send-event',
                 events=[{'type': 'btn', 'data': {'down': True, 'button': 'left'}}])
        time.sleep(0.12)
        self.cmd('input-send-event',
                 events=[{'type': 'btn', 'data': {'down': False, 'button': 'left'}}])

def check_vnc(port, timeout):
    """Read the RFB greeting from the forwarded VNC port. Returns problems."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=5) as s:
                s.settimeout(5)
                greeting = s.recv(12)
            if greeting.startswith(b'RFB 00'):
                print(f'  vnc: {greeting.decode(errors="replace").strip()} '
                      f'on forwarded port {port}')
                return []
            last = f'greeting was {greeting!r}, not an RFB version string'
        except OSError as e:
            last = str(e)
        time.sleep(1)
    return [f'nothing answered RFB on the guest\'s VNC output ({last}) -- '
            f'weston did not bring up the drm,vnc mirror']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--usb', required=True, help='raw installer USB image')
    ap.add_argument('--out', required=True, help='directory for screenshots and logs')
    ap.add_argument('--slow', type=float, default=1.0,
                    help='multiply every wait; use ~10 for TCG with no KVM')
    ap.add_argument('--keep-running', action='store_true')
    ap.add_argument('--vnc-port', type=int, default=5901,
                    help='host port forwarded to the guest VNC output')
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    code, varsf = find_ovmf()
    tmp = tempfile.mkdtemp()
    nvram = os.path.join(tmp, 'OVMF_VARS.fd')
    shutil.copy(varsf, nvram)
    target = os.path.join(tmp, 'target.qcow2')
    subprocess.run(['qemu-img', 'create', '-f', 'qcow2', target, '32G'],
                   check=True, stdout=subprocess.DEVNULL)

    accel = ['-enable-kvm', '-cpu', 'host'] if os.access('/dev/kvm', os.W_OK) \
            else ['-accel', 'tcg', '-cpu', 'max']
    print(f'accelerator: {"kvm" if "-enable-kvm" in accel else "tcg (slow)"}')

    qmp = os.path.join(tmp, 'qmp.sock')
    serial = os.path.join(a.out, 'serial.log')
    cmd = ['qemu-system-x86_64', *accel, '-m', '2G', '-smp', '2', '-machine', 'q35',
           '-drive', f'if=pflash,format=raw,unit=0,readonly=on,file={code}',
           '-drive', f'if=pflash,format=raw,unit=1,file={nvram}',
           '-device', 'nvme,serial=deadbeef,drive=nvm',
           '-drive', f'file={target},format=qcow2,if=none,id=nvm,cache=unsafe',
           '-device', 'usb-ehci,id=ehci',
           '-device', 'usb-storage,bus=ehci.0,drive=usbdisk',
           # snapshot=on: a test boot must not write a machine-id or a journal
           # into an artifact that later gets written to a real key.
           '-drive', f'file={a.usb},format=raw,if=none,id=usbdisk,snapshot=on',
           '-device', 'virtio-vga',
           '-device', 'virtio-tablet-pci',   # absolute pointer, for tap()
           # Explicit, where there used to be nothing: QEMU adds a default
           # user-mode NIC when no -netdev is given, which is why the installer
           # already showed a 10.0.2.x address in these screenshots. Naming it
           # is what allows the hostfwd, and the hostfwd is what lets the test
           # prove weston's VNC output is listening -- the one thing about the
           # drm,vnc mirror that cannot be read off a screenshot.
           '-netdev', f'user,id=net0,hostfwd=tcp::{a.vnc_port}-:5900',
           '-device', 'virtio-net-pci,netdev=net0',
           '-display', 'none',
           '-serial', f'file:{serial}',
           '-qmp', f'unix:{qmp},server,nowait']
    print(' '.join(cmd))
    proc = subprocess.Popen(cmd)
    rc = 0
    try:
        q = Qmp(qmp, timeout=60 * a.slow)
        # Coordinates are fractions of the 1280x800 the installer runs at, read
        # off 01-disk.png rather than guessed: the first attempt tapped the
        # middle of the screen, landed on empty canvas, and proved only that the
        # pointer moves. Taken in order, so a shot that does not advance says
        # which step stopped working.
        #
        #   45s  firmware, GRUB, kernel, seatd, weston, and the app's first frame
        #   then the app waits for a human on the disk step
        # label, tap point, seconds to allow, must the screen change
        script = [
            ('01-disk',     None,          45, False),  # booted and drew at all
            ('02-station',  (0.90, 0.94),  20, True),   # Continue -> station step
            ('03-keyboard', (0.30, 0.26),  20, True),   # first field -> keyboard
        ]
        problems, prev = [], None
        for label, point, wait, must_change in script:
            if point:
                q.tap(*point)
            if must_change:
                # Wait FOR the repaint rather than a fixed guess at how long one
                # takes. A fixed sleep is wrong in both directions: too short is
                # a false failure on a loaded runner, too long is dead time on
                # every green run. Returns as soon as the screen has moved, so
                # the generous ceiling costs nothing when things work.
                d, px = wait_for_change(lambda: q.frame()[2], prev,
                                        wait * a.slow, 0.5 * a.slow)
            else:
                time.sleep(wait * a.slow)
                _, _, px = q.frame()
                d = changed(prev, px)
            # Taken after the wait, so the PNG is the frame that was judged.
            shot = q.screenshot(os.path.join(a.out, f'{label}.png'))
            u = uniformity(px)
            print(f'  {label}: {shot}  ({u:.1%} one colour, {d:.1%} changed)')
            if u > UNIFORM_MAX:
                problems.append(f'{label} is {u:.1%} a single colour -- nothing drawn')
            # A tap that lands on a button but never activates it still moves
            # the cursor, so the frame is not identical and an equality test
            # would pass. Run 34744364926 was green exactly that way: the
            # pointer hovered Continue, the button lit up, and the installer
            # never left screen one.
            if must_change and d < CHANGE_MIN:
                problems.append(
                    f'{label}: only {d:.1%} of the screen changed in '
                    f'{wait * a.slow:.0f}s after the tap -- the step did not advance')
            prev = px
        # The remote view. weston mirrors the panel onto a VNC output
        # (--backend=drm,vnc plus [output] mirror-of=), and a screenshot cannot
        # tell you whether that second head came up -- the panel looks
        # identical either way. One TCP read can: an RFB greeting means weston
        # loaded the vnc backend as a secondary, bound the port, and is serving.
        # It does not prove the mirror shows the right pixels, which needs eyes
        # on a client, but it does prove the chain exists.
        problems.extend(check_vnc(a.vnc_port, timeout=30 * a.slow))

        if problems:
            raise RuntimeError('; '.join(problems))
        if not a.keep_running:
            try:
                q.cmd('quit')
            except Exception:
                pass
    except Exception as e:
        print(f'::error::boot test failed: {e}')
        rc = 1
    finally:
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
        if os.path.exists(serial):
            print('--- serial tail ---')
            with open(serial, errors='replace') as f:
                print(''.join(f.readlines()[-40:]))
    sys.exit(rc)

if __name__ == '__main__':
    main()
