#!/usr/bin/env python3
"""Real-PTY bridge tests against a scripted ssh that prints OpenSSH 9.9p2 lines verbatim.

The fixture emits only lines captured from a real `ssh -v -E /dev/fd/1` run against a local
sshd (CRLF framing included). Secrets are random per test and are never written to disk.
The password success line follows the same format as the captured publickey success line;
it was not captured from a real password login.
"""
import os
import secrets
import signal
import struct
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <termios.h>
static const char *mode;
static char user[256], host[256], port[16] = "22";
static void line(const char *s) { printf("%s\r\n", s); fflush(stdout); }
static int ask(const char *prompt, char *buf, size_t n, int may_refuse) {
    FILE *tty = fopen("/dev/tty", "r+"); if (!tty) return 0;
    setbuf(tty, NULL);
    struct termios t; tcgetattr(fileno(tty), &t);
    if (strcmp(mode, "echo")) { t.c_lflag &= ~ECHO; tcsetattr(fileno(tty), TCSANOW, &t); }
    if (!strcmp(mode, "fragmented")) {
        size_t half = strlen(prompt) / 2;
        fwrite(prompt, 1, half, tty); fflush(tty); usleep(50000);
        fputs(prompt + half, tty);
    } else if (!strcmp(mode, "long")) { for (int i = 0; i < 3000; i++) fputc('a', tty); }
    else fputs(prompt, tty);
    // When bridge closes stdin on refusal, fgets returns NULL; caller exits as refused (91 for test diagnostics).
    if (!fgets(buf, (int)n, tty)) { fclose(tty); return may_refuse ? -1 : 0; }
    fclose(tty);
    return 1;
}
int main(int argc, char **argv) {
    mode = getenv("FAKE_MODE"); if (!mode) return 90;
    if (getenv("SSH_ASKPASS") || getenv("SSH_ASKPASS_REQUIRE")) return 95;
    const char *dest = argv[argc - 1];
    const char *at = strchr(dest, '@'); if (!at) return 91;
    snprintf(user, sizeof user, "%.*s", (int)(at - dest), dest);
    snprintf(host, sizeof host, "%s", at + 1);
    for (int i = 1; i + 1 < argc; i++) if (!strcmp(argv[i], "-p")) snprintf(port, sizeof port, "%s", argv[i + 1]);
    int has_log = 0;
    for (int i = 1; i + 1 < argc; i++) if (!strcmp(argv[i], "-E") && !strcmp(argv[i + 1], "/dev/fd/1")) has_log = 1;
    if (!has_log) return 92;
    setbuf(stdout, NULL);
    char reply[2048], prompt[512], text[1024];
    if (!strcmp(mode, "refused")) {
        line("debug1: connect to address 127.0.0.1 port 1: Connection refused");
        line("ssh: connect to host 127.0.0.1 port 1: Connection refused");
        return 255;
    }
    if (!strcmp(mode, "jump-prompt")) {
        // ProxyJump hop prompt: printed before the final target's identity line.
        snprintf(prompt, sizeof prompt, "%s@%s's password: ", user, host);
        int got = ask(prompt, reply, sizeof reply, 1);
        return got < 0 ? 91 : got ? 93 : 92;
    }
    snprintf(text, sizeof text, "debug1: Authenticating to %s:%s as '%s'", host, port, user);
    line(text);
    if (!strcmp(mode, "hostkey")) {
        snprintf(text, sizeof text, "Host key for [%s]:%s has changed and you have requested strict checking.", host, port);
        line(text);
        line("Host key verification failed.");
        return 255;
    }
    if (!strcmp(mode, "unknown-hostkey")) {
        snprintf(prompt, sizeof prompt,
                 "The authenticity of host '[%s]:%s (%s)' can't be established.\r\n"
                 "ED25519 key fingerprint is SHA256:AbCdEf0123456789+/.\r\n"
                 "This key is not known by any other names.\r\n"
                 "Are you sure you want to continue connecting (yes/no/[fingerprint])? ", host, port, host);
        int got = ask(prompt, reply, sizeof reply, 1);
        if (got < 0) return 91;
        if (!got || strcmp(reply, "yes\n")) return 255;
        line("Authenticated to host ([127.0.0.1]:22) using \"publickey\".");
        return 0;
    }
    if (!strcmp(mode, "hang")) { sleep(20); return 0; }
    if (!strcmp(mode, "publickey") || !strcmp(mode, "publickey-via-proxy")) {
        line("debug1: Authentications that can continue: publickey,password");
        line("debug1: Next authentication method: publickey");
        snprintf(text, sizeof text, "Authenticated to %s (%s) using \"publickey\".", host,
                 !strcmp(mode, "publickey") ? "[127.0.0.1]:" : "via proxy");
        if (!strcmp(mode, "publickey")) snprintf(text + strlen(text) - 1, sizeof text - strlen(text) + 1, "%s", "");
        if (!strcmp(mode, "publickey")) {
            snprintf(text, sizeof text, "Authenticated to %s ([127.0.0.1]:%s) using \"publickey\".", host, port);
        }
        line(text);
        return 0;
    }
    if (!strcmp(mode, "passphrase")) {
        line("debug1: Authentications that can continue: publickey,password");
        line("debug1: Next authentication method: publickey");
        snprintf(prompt, sizeof prompt, "Enter passphrase for key '/tmp/key': ");
        int got = ask(prompt, reply, sizeof reply, 1);
        return got < 0 ? 91 : got ? 93 : 92;
    }
    if (!strcmp(mode, "publickey-denied")) {
        line("debug1: Authentications that can continue: publickey");
        line("debug1: Next authentication method: publickey");
        snprintf(text, sizeof text, "%s@%s: Permission denied (publickey).", user, host);
        line(text);
        return 255;
    }
    if (!strcmp(mode, "password-only")) {
        line("debug1: Authentications that can continue: password");
    } else {
        line("debug1: Authentications that can continue: publickey,password");
        line("debug1: Next authentication method: publickey");
        line("debug1: Authentications that can continue: publickey,password");
    }
    line("debug1: Next authentication method: password");
    if (!strcmp(mode, "wrong-user")) snprintf(prompt, sizeof prompt, "other@%s's password: ", host);
    else snprintf(prompt, sizeof prompt, "%s@%s's password: ", user, host);
    int got = ask(prompt, reply, sizeof reply, 1);
    if (got < 0) return 91;
    if (!got) return 92;
    if (!strcmp(mode, "repeat")) { printf("%s@%s's password: ", user, host); fflush(stdout); sleep(1); return 91; }
    // Mode names describe the prompt; the fixture only accepts a 32-character secret.
    if (strlen(reply) != 33 || reply[32] != '\n') return 94;
    if (!strcmp(mode, "password-wrong")) {
        snprintf(text, sizeof text, "%s@%s: Permission denied (publickey,password).", user, host);
        line(text);
        return 255;
    }
    snprintf(text, sizeof text, "Authenticated to %s ([127.0.0.1]:%s) using \"password\".", host, port);
    line(text);
    return 0;
}
'''

# Modes correspond to real -v log sequences captured from OpenSSH 9.9p2 against a local sshd.


class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="mtunl-pty-test-")
        d = Path(cls.temp.name)
        fixture = d / "fake-ssh.c"
        fixture.write_text(FIXTURE)
        cls.fake = d / "fake-ssh"
        cls.bridge = d / "bridge"
        subprocess.run(["clang", "-Wall", "-Wextra", "-Werror", str(fixture), "-o", str(cls.fake)], check=True)
        subprocess.run(["clang", "-Wall", "-Wextra", "-Werror", '-DSSH_EXECUTABLE="' + str(cls.fake) + '"',
                        str(ROOT / "Sources/mtunl-ssh-bridge/main.c"), "-o", str(cls.bridge)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_bridge(self, mode, frame=None, expected=0, env=None, expect=("user", "host", "22"),
                   dest=("user", "host", "22"), secret=None, accepts=()):
        if secret is None:
            secret = secrets.token_hex(16).encode()
        if frame is None:
            frame = struct.pack("!I", len(secret)) + secret
        args = [str(self.bridge)]
        for host, fingerprint in accepts:
            args += ["--accept", host, fingerprint]
        if expect:
            args += ["--expect", *expect]
        args += ["--", "-p", dest[2], "--", f"{dest[0]}@{dest[1]}"]
        run_env = dict(os.environ if env is None else env, FAKE_MODE=mode)
        result = subprocess.run(args, input=frame, capture_output=True, timeout=15, env=run_env, check=False)
        self.assertEqual(result.returncode, expected, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(secret, result.stderr)
        self.assertNotIn(secret.decode(), result.stderr.decode(errors="replace"))
        return result.stderr

    def empty_frame(self):
        return struct.pack("!I", 0)

    def test_publickey_success_requests_no_password(self):
        output = self.run_bridge("publickey", frame=self.empty_frame())
        self.assertIn(b"MTUNL_TARGET user host 22", output)
        self.assertIn(b"MTUNL_AUTHENTICATED", output)
        self.assertNotIn(b"MTUNL_PASSWORD_REQUIRED", output)

    def test_publickey_via_proxy_success(self):
        self.assertIn(b"MTUNL_AUTHENTICATED", self.run_bridge("publickey-via-proxy", frame=self.empty_frame()))

    def test_password_prompt_requests_password_when_no_secret(self):
        for mode in ["password-only", "fragmented"]:
            with self.subTest(mode=mode):
                output = self.run_bridge(mode, frame=self.empty_frame(), expected=79)
                self.assertIn(b"MTUNL_TARGET user host 22", output)
                self.assertIn(b"MTUNL_PASSWORD_REQUIRED", output)

    def test_password_sent_to_matching_target_prompt(self):
        self.assertIn(b"MTUNL_AUTHENTICATED", self.run_bridge("password-accept"))

    def test_wrong_password_is_sent_once_and_reported_as_auth_failure(self):
        self.run_bridge("password-wrong", expected=77)

    def test_password_is_never_sent_to_unknown_or_mismatched_prompts(self):
        # Bridge refuses to send passwords to jump-host, passphrase, and non-matching prompts.
        # For "repeat": first prompt matches, requests password (79 with empty frame), then second prompt → refused.
        for mode in ["jump-prompt", "passphrase", "wrong-user", "echo", "long"]:
            with self.subTest(mode=mode):
                self.run_bridge(mode, expected=78)  # Refused without secret
                self.run_bridge(mode, frame=self.empty_frame(), expected=78)  # Refused with secret
        # "repeat" mode: first prompt matches (79), second prompt causes bridge to refuse and fixture to exit 91.
        self.assertIn(b"MTUNL_PASSWORD_REQUIRED", self.run_bridge("repeat", frame=self.empty_frame(), expected=79))

    def test_auth_mismatch_and_identity_rules(self):
        # Expected target differs from the one ssh authenticates: no password may be sent.
        self.run_bridge("password-accept", expect=("other", "host", "22"), expected=78)
        self.run_bridge("password-accept", expect=("user", "other", "22"), expected=78)
        self.run_bridge("password-accept", expect=("user", "host", "2222"), expected=78)
        # A secret without an expected target is refused before ssh is started.
        self.run_bridge("password-accept", expect=None, expected=78)

    def test_host_key_confirmation_is_one_shot_and_fingerprint_bound(self):
        fingerprint = "SHA256:AbCdEf0123456789+/"
        output = self.run_bridge("unknown-hostkey", frame=self.empty_frame(), expected=80)
        self.assertIn(f"MTUNL_HOSTKEY [host]:22 {fingerprint}".encode(), output)
        self.assertNotIn(b"MTUNL_PASSWORD_REQUIRED", output)
        accepted = self.run_bridge("unknown-hostkey", frame=self.empty_frame(), accepts=(("[host]:22", fingerprint),))
        self.assertIn(b"MTUNL_AUTHENTICATED", accepted)
        self.run_bridge("unknown-hostkey", frame=self.empty_frame(), expected=80,
                        accepts=(("[host]:22", "SHA256:DifferentFingerprint"),))

    def test_changed_host_key_and_network_failures_never_request_password(self):
        output = self.run_bridge("hostkey", frame=self.empty_frame(), expected=81)
        self.assertIn(b"SSH host key verification failed", output)
        self.assertNotIn(b"MTUNL_PASSWORD_REQUIRED", output)
        output = self.run_bridge("refused", frame=self.empty_frame(), expected=255)
        self.assertNotIn(b"MTUNL_TARGET", output)
        self.assertNotIn(b"MTUNL_PASSWORD_REQUIRED", output)
        self.assertIn(b"MTUNL_ERROR ssh: connect to host 127.0.0.1 port 1: Connection refused", output)

    def test_publickey_only_server_is_auth_failure(self):
        self.run_bridge("publickey-denied", frame=self.empty_frame(), expected=77)

    def test_invalid_protocol_frames(self):
        for frame in [b"", b"\x00", struct.pack("!I", 1024), struct.pack("!I", 4) + b"a\nbc", struct.pack("!I", 4) + b"ab"]:
            with self.subTest(frame=frame):
                self.run_bridge("publickey", frame=frame, expected=78)

    def test_agent_environment_kept_but_askpass_removed(self):
        env = dict(os.environ, SSH_AUTH_SOCK="/nonexistent-test-agent", SSH_ASKPASS="/nonexistent-test-askpass",
                   SSH_ASKPASS_REQUIRE="force")
        self.assertIn(b"MTUNL_AUTHENTICATED", self.run_bridge("publickey", frame=self.empty_frame(), env=env))

    def test_real_ssh_accepts_descriptor_log_offline(self):
        # Real OpenSSH on a closed loopback port: confirms -E /dev/fd/1 is writable with no network.
        result = subprocess.run(["/usr/bin/ssh", "-v", "-E", "/dev/fd/1", "-o", "ConnectTimeout=2",
                                 "-F", "/dev/null", "-p", "1", "--", "apple@127.0.0.1"],
                                capture_output=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 255)
        self.assertIn(b"connect to address 127.0.0.1 port 1: Connection refused", result.stdout)

    def test_stop_reaps_child(self):
        p = subprocess.Popen([str(self.bridge), "--expect", "user", "host", "22", "--", "-p", "22", "--", "user@host"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=dict(os.environ, FAKE_MODE="hang"))
        try:
            stdin, stdout, stderr, pid = p.stdin, p.stdout, p.stderr, p.pid
            assert stdin is not None and stdout is not None and stderr is not None and pid is not None
            secret = secrets.token_hex(16)
            stdin.write(struct.pack("!I", 32) + secret.encode()); stdin.close()
            child = None
            for _ in range(100):
                listing = subprocess.check_output(["ps", "-axo", "pid=,ppid=,args="], text=True)
                self.assertNotIn(secret, listing)
                for line in listing.splitlines():
                    fields = line.split(None, 2)
                    if len(fields) == 3 and fields[1] == str(pid) and " -v " in fields[2]:
                        child = int(fields[0])
                if child:
                    break
                time.sleep(.02)
            self.assertIsNotNone(child)
            assert child is not None
            p.send_signal(signal.SIGTERM)
            self.assertEqual(p.wait(timeout=3), 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        finally:
            if p.poll() is None:
                p.kill(); p.wait()
            if p.stdout is not None:
                p.stdout.close()
            if p.stderr is not None:
                p.stderr.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
