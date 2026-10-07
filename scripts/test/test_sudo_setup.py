#!/usr/bin/env python3
"""Runs the root setup script of the sudo module (compiled into Sources/FaceID/PamInstaller.swift) on a fake file
system in a temporary folder: /etc/pam.d, /usr/local/lib/pam and /usr/local/etc/faceid become folders there and
chown is a no-op, so nothing needs root and nothing on the Mac changes.

    python3 scripts/test/test_sudo_setup.py
"""
import hashlib
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
source = open(os.path.join(ROOT, "Sources/FaceID/PamInstaller.swift")).read()
match = re.search(r'static let script = #"""\n(.*?)\n    """#', source, re.S)
script = "\n".join(line[4:] for line in match.group(1).split("\n"))

STUBS = """
chown() { :; }
install() {  # only "install -d -o … -g … -m … <dirs>" is used
    while [ $# -gt 0 ]; do
        case "$1" in -d) shift ;; -o|-g|-m) shift 2 ;; *) mkdir -p "$1"; shift ;; esac
    done
}
sudo_check() {  # stands in for the real sudo started at the end of install
    [ "${SUDO_FAILS:-0}" = 0 ] || { echo "sudo: unable to initialize PAM: test" >&2; return 1; }
}
"""
SUDO_CHECK = "/usr/bin/sudo -n /usr/bin/true"

TEMPLATE = """# sudo_local: local config file which survives system update and is included for sudo
# uncomment following line to enable Touch ID for sudo
#auth       sufficient     pam_tid.so
"""
LINE = "auth       sufficient     {root}/lib/pam/pam_faceid.so"


OWNER_CHECK = re.compile(r"\n *for dir in /usr .*?\n *done\n", re.S)
assert OWNER_CHECK.search(script), "the folder ownership check is missing"
assert SUDO_CHECK in script, "the sudo check at the end of install is missing"


def run(root, *args, owner_check=False, sudo_fails=False, stubs=""):
    body = script if owner_check else OWNER_CHECK.sub("\n", script)
    body = (body.replace("/usr/local/lib/pam", f"{root}/lib/pam")
                .replace("/usr/local/etc/faceid", f"{root}/etc/faceid")
                .replace("/etc/pam.d", f"{root}/pam.d")
                .replace(SUDO_CHECK, "sudo_check"))
    env = dict(os.environ, SUDO_FAILS="1" if sudo_fails else "0")
    return subprocess.run(["/bin/sh", "-c", STUBS + stubs + body, "faceid-sudo-setup", *args],
                          capture_output=True, text=True, env=env)


def check(condition, message):
    if not condition:
        sys.exit(f"FAIL: {message}")
    print(f"ok: {message}")


with tempfile.TemporaryDirectory() as root:
    os.makedirs(f"{root}/pam.d")
    module = f"{root}/module.so"
    open(module, "wb").write(b"\xcf\xfa\xed\xfe fake module")
    digest = hashlib.sha256(open(module, "rb").read()).hexdigest()
    requirement = 'identifier "com.faceid.app" and anchor apple generic'
    line = LINE.format(root=root)
    local = f"{root}/pam.d/sudo_local"

    # No sudo_local yet: made from the template, the line goes to the end (Touch ID is only commented out).
    open(f"{root}/pam.d/sudo_local.template", "w").write(TEMPLATE)
    result = run(root, "install", module, digest, requirement)
    check(result.returncode == 0, f"install from the template ({result.stderr.strip()})")
    lines = open(local).read().splitlines()
    check(lines[:3] == TEMPLATE.splitlines() and lines[3] == line, "the line follows the template")
    check(open(f"{root}/lib/pam/pam_faceid.so", "rb").read() == open(module, "rb").read(), "the module is copied")
    check(open(f"{root}/etc/faceid/pam.conf").read() == f"requirement={requirement}\n", "the requirement is written")

    # Again: nothing is duplicated.
    run(root, "install", module, digest, requirement)
    check(open(local).read().count("pam_faceid.so") == 1, "installing twice adds the line once")

    # An existing sudo_local with pam_reattach and Touch ID: the face goes after reattach, before Touch ID.
    check(os.stat(local).st_mode & 0o777 == 0o444, "sudo_local is read-only, as macOS ships it")
    os.chmod(local, 0o644)
    open(local, "w").write("auth       optional       /opt/homebrew/lib/pam/pam_reattach.so\nauth       sufficient     pam_tid.so\n")
    result = run(root, "install", module, digest, requirement)
    check(result.returncode == 0, f"install over an existing sudo_local ({result.stderr.strip()})")
    lines = open(local).read().splitlines()
    check(lines == ["auth       optional       /opt/homebrew/lib/pam/pam_reattach.so", line, "auth       sufficient     pam_tid.so"],
          "inserted between pam_reattach and pam_tid")
    check(os.path.exists(f"{root}/etc/faceid/sudo_local.backup"), "the previous sudo_local is kept as a backup")
    check(sorted(os.listdir(f"{root}/pam.d")) == ["sudo_local", "sudo_local.template"], "nothing else is written to /etc/pam.d")

    # macOS refusing the write (no Full Disk Access) is reported as exit 4 and leaves sudo_local as it was.
    before = open(local).read()
    os.chmod(f"{root}/pam.d", 0o555)
    os.chmod(local, 0o444)
    result = run(root, "uninstall")
    check(result.returncode == 4 and open(local).read() == before, "a refused write is exit 4 and changes nothing")
    os.chmod(f"{root}/pam.d", 0o755)
    os.chmod(local, 0o644)

    # Uninstall: the line goes first, then the files; the user's own lines stay.
    result = run(root, "uninstall")
    check(result.returncode == 0, "uninstall")
    check(open(local).read() == "auth       optional       /opt/homebrew/lib/pam/pam_reattach.so\nauth       sufficient     pam_tid.so\n",
          "only the FaceID line is removed")
    check(not os.path.exists(f"{root}/lib/pam/pam_faceid.so") and not os.path.exists(f"{root}/etc/faceid/pam.conf"),
          "the module and its settings are removed")

    # Folders a user could write to (the temporary folders here are yours, not root's) stop the install.
    result = run(root, "install", module, digest, requirement, owner_check=True)
    check(result.returncode == 3 and not os.path.exists(f"{root}/lib/pam/pam_faceid.so"),
          "folders not owned by root alone stop the install")

    # A module that is not the one checked by the app is never installed.
    result = run(root, "install", module, "0" * 64, requirement)
    check(result.returncode == 2 and not os.path.exists(f"{root}/lib/pam/pam_faceid.so"), "a wrong checksum stops the install")
    check("pam_faceid.so" not in open(local).read(), "sudo_local is untouched after a failed install")

    # sudo that no longer starts with the module in its settings: the line goes again and the user's lines stay.
    # chmod is a no-op here: only root can rewrite the read-only file twice in one run.
    os.chmod(local, 0o644)
    result = run(root, "install", module, digest, requirement, sudo_fails=True, stubs="chmod() { :; }\n")
    check(result.returncode == 5 and "unable to initialize PAM" in result.stderr, "sudo failing after the install is exit 5")
    check(open(local).read() == "auth       optional       /opt/homebrew/lib/pam/pam_reattach.so\nauth       sufficient     pam_tid.so\n",
          "the line is taken out again and the user's lines stay")

print("all good")
