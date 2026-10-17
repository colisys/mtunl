// stdin: uint32 big-endian UTF-8 length + secret (zero length = key-first discovery).
// Bridge stdout is unused. Bridge stderr contains only fixed, non-secret events.
#include <util.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <termios.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <errno.h>
#ifndef SSH_EXECUTABLE
#define SSH_EXECUTABLE "/usr/bin/ssh"
#endif
#define AUTH_FAILURE 77
#define UNSUPPORTED 78
#define PASSWORD_REQUIRED 79
#define HOSTKEY_REQUIRED 80
#define HOSTKEY_FAILED 81
#define MAX_ACCEPTED_HOST_KEYS 128
static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }
static void wipe(void *p, size_t n) { volatile unsigned char *v = p; while (n--) *v++ = 0; }
static int read_exact(int fd, void *buf, size_t n) {
    unsigned char *p = buf;
    while (n && !stopping) {
        fd_set f; FD_ZERO(&f); FD_SET(fd, &f);
        struct timeval t = {5, 0};
        if (select(fd + 1, &f, NULL, NULL, &t) <= 0) return 0;
        ssize_t r = read(fd, p, n);
        if (r <= 0) return 0;
        p += r; n -= (size_t)r;
    }
    return n == 0;
}
static void reap(pid_t child) {
    if (child <= 0) return;
    kill(-child, SIGKILL); kill(child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}
static void sanitize_askpass(void) {
    // Preserve the existing system agent environment; never add secret/helper variables.
    unsetenv("SSH_ASKPASS"); unsetenv("SSH_ASKPASS_REQUIRE");
}
// Target identity and password prompt come only from the real `ssh -v` output of the
// final connection, never from a separate `ssh -G` evaluation.
struct identity { char user[256], host[512], port[8], prompt[800]; };
struct accepted_host_key { char host[512], fingerprint[128]; };
static const char *expect_user, *expect_host, *expect_port;
static struct accepted_host_key accepted_host_keys[MAX_ACCEPTED_HOST_KEYS];
static size_t accepted_host_key_count;
static char requested_host[512], requested_fingerprint[128];
static uint32_t secret_length;
static int identifier(const char *s) {
    if (!*s) return 0;
    for (; *s; s++) {
        unsigned char c = *s;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || strchr("._-:[]", c))) return 0;
    }
    return 1;
}
// Parses the tail of "debug1: Authenticating to HOST:PORT as 'USER'".
// Port is the last ':' component so IPv6 hosts keep their colons.
static int parse_target(const char *s, struct identity *id) {
    const char *as = strstr(s, " as '");
    if (!as) return 0;
    size_t host_len = (size_t)(as - s);
    const char *user = as + 5;
    size_t user_len = strlen(user);
    if (user_len < 2 || user[user_len - 1] != '\'' || user_len - 1 >= sizeof(id->user)) return 0;
    if (host_len == 0 || host_len >= sizeof(id->host)) return 0;
    char hostport[512]; memcpy(hostport, s, host_len); hostport[host_len] = 0;
    char *colon = strrchr(hostport, ':');
    if (!colon) return 0;
    *colon = 0;
    char *end; long port = strtol(colon + 1, &end, 10);
    if (!colon[1] || *end || port < 1 || port > 65535) return 0;
    memcpy(id->user, user, user_len - 1); id->user[user_len - 1] = 0;
    strcpy(id->host, hostport);
    snprintf(id->port, sizeof(id->port), "%ld", port);
    if (!identifier(id->user) || !identifier(id->host)) return 0;
    snprintf(id->prompt, sizeof(id->prompt), "%s@%s's password: ", id->user, id->host);
    return 1;
}
struct auth { int context, target_ok, password_allowed, password_phase, authenticated, failed, ambiguous, hostkey_failed; };
static int has_method(const char *s, const char *method) {
    while (*s) {
        size_t n = strcspn(s, ",");
        if (n == strlen(method) && !strncmp(s, method, n)) return 1;
        s += n; if (*s == ',') s++;
    }
    return 0;
}
static void diagnostic(const char *line, struct identity *id, struct auth *a) {
    if (strstr(line, "Host key verification failed.")) { a->hostkey_failed = 1; return; }
    const char *begin = "debug1: Authenticating to ";
    if (!strncmp(line, begin, strlen(begin))) {
        // A second target means ProxyJump/reconnect state we cannot attribute: fail closed.
        if (a->context || !parse_target(line + strlen(begin), id)) { a->ambiguous = 1; return; }
        a->context = 1;
        a->target_ok = expect_user && !strcmp(expect_user, id->user) &&
                       !strcmp(expect_host, id->host) && !strcmp(expect_port, id->port);
        if (secret_length && !a->target_ok) { a->ambiguous = 1; return; }
        fprintf(stderr, "MTUNL_TARGET %s %s %s\n", id->user, id->host, id->port); fflush(stderr);
        return;
    }
    if (!a->context) return;
    const char *methods = "debug1: Authentications that can continue: ";
    if (!strncmp(line, methods, strlen(methods))) {
        a->password_allowed = has_method(line + strlen(methods), "password");
        a->password_phase = 0;
    }
    // Password is only the active method when ssh itself selects it after publickey.
    if (!strcmp(line, "debug1: Next authentication method: password"))
        a->password_phase = a->password_allowed && !a->authenticated;
    if (strstr(line, "with partial success")) a->ambiguous = 1; // MFA is not password fallback.
    char prefix[600]; snprintf(prefix, sizeof(prefix), "Authenticated to %s (", id->host);
    if (!strncmp(line, prefix, strlen(prefix)) &&
        (strstr(line, " using \"publickey\".") || strstr(line, " using \"password\"."))) {
        char port[32]; snprintf(port, sizeof(port), "]:%s)", id->port);
        if (!strstr(line, port) && !strstr(line, " (via proxy) using ")) { a->ambiguous = 1; return; }
        if (!a->authenticated) { fputs("MTUNL_AUTHENTICATED\n", stderr); fflush(stderr); }
        a->authenticated = 1; a->password_phase = 0;
    }
    if (strstr(line, "Permission denied") || strstr(line, "No more authentication methods to try")) a->failed = 1;
}
static int valid_fingerprint(const char *s) {
    if (strncmp(s, "SHA256:", 7) || !s[7] || strlen(s) >= sizeof(requested_fingerprint)) return 0;
    for (s += 7; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=')) return 0;
    }
    return 1;
}
static int could_be_hostkey_prompt(const char *s, size_t n) {
    static const char prefix[] = "The authenticity of host '";
    size_t length = sizeof(prefix) - 1;
    return n <= length ? !memcmp(s, prefix, n) : !memcmp(s, prefix, length);
}
static int ends_with(const char *s, const char *suffix) {
    size_t n = strlen(s), m = strlen(suffix);
    return n >= m && !memcmp(s + n - m, suffix, m);
}
static int parse_hostkey_prompt(const char *prompt, char *host, size_t host_size,
                                char *fingerprint, size_t fingerprint_size) {
    static const char prefix[] = "The authenticity of host '";
    static const char marker[] = " key fingerprint is ";
    static const char suffix[] = "(yes/no/[fingerprint])? ";
    if (strncmp(prompt, prefix, sizeof(prefix) - 1) || !ends_with(prompt, suffix)) return 0;
    const char *start = prompt + sizeof(prefix) - 1;
    const char *host_end = strstr(start, " (");
    const char *fp = strstr(start, marker);
    if (!host_end || !fp || host_end <= start || fp <= host_end) return 0;
    size_t host_length = (size_t)(host_end - start);
    if (!host_length || host_length >= host_size) return 0;
    memcpy(host, start, host_length); host[host_length] = 0;
    const char *fp_start = fp + sizeof(marker) - 1;
    const char *fp_end = fp_start;
    while (*fp_end && *fp_end != '\r' && *fp_end != '\n') fp_end++;
    if (fp_end > fp_start && fp_end[-1] == '.') fp_end--;
    size_t fp_length = (size_t)(fp_end - fp_start);
    if (!fp_length || fp_length >= fingerprint_size) return 0;
    memcpy(fingerprint, fp_start, fp_length); fingerprint[fp_length] = 0;
    if (!identifier(host) || !valid_fingerprint(fingerprint)) return 0;
    return 1;
}
static int accepted_hostkey(const char *host, const char *fingerprint) {
    for (size_t i = 0; i < accepted_host_key_count; i++)
        if (!strcmp(accepted_host_keys[i].host, host) &&
            !strcmp(accepted_host_keys[i].fingerprint, fingerprint)) return 1;
    return 0;
}
static int answer_yes(int fd) {
    static const char answer[] = "yes\n";
    struct termios original, quiet;
    int restore = tcgetattr(fd, &original) == 0;
    if (restore) {
        quiet = original; quiet.c_lflag &= (tcflag_t)~ECHO;
        if (tcsetattr(fd, TCSANOW, &quiet) != 0) restore = 0;
    }
    ssize_t written = write(fd, answer, sizeof(answer) - 1);
    if (restore) tcsetattr(fd, TCSANOW, &original);
    return written == (ssize_t)(sizeof(answer) - 1);
}
int main(int argc, char **argv) {
    struct rlimit core = {0, 0}; setrlimit(RLIMIT_CORE, &core);
    signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGHUP, stop); signal(SIGPIPE, SIG_IGN);
    unsigned char header[4], password[1024] = {0};
    int result = UNSUPPORTED, master = -1, logs[2] = {-1, -1}, status = 0;
    pid_t child = -1;
    int separator = -1, expect_seen = 0;
    for (int i = 1; i < argc;) {
        if (!strcmp(argv[i], "--")) { separator = i; break; }
        if (!strcmp(argv[i], "--expect") && i + 3 < argc && !expect_seen) {
            expect_user = argv[i + 1]; expect_host = argv[i + 2]; expect_port = argv[i + 3];
            expect_seen = 1; i += 4; continue;
        }
        if (!strcmp(argv[i], "--accept") && i + 2 < argc && accepted_host_key_count < MAX_ACCEPTED_HOST_KEYS) {
            const char *host = argv[i + 1], *fingerprint = argv[i + 2];
            if (!identifier(host) || strlen(host) >= sizeof(accepted_host_keys[0].host) ||
                !valid_fingerprint(fingerprint)) goto done;
            strcpy(accepted_host_keys[accepted_host_key_count].host, host);
            strcpy(accepted_host_keys[accepted_host_key_count].fingerprint, fingerprint);
            accepted_host_key_count++; i += 3; continue;
        }
        goto done;
    }
    if (separator < 0) goto done;
    argc -= separator; argv += separator;
    if (argc < 2 || !read_exact(0, header, 4)) goto done;
    uint32_t length = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) | ((uint32_t)header[2] << 8) | header[3];
    if (length > 1023 || !read_exact(0, password, length)) goto done;
    for (uint32_t i = 0; i < length; i++) if (password[i] < 32 || password[i] == 127) goto done;
    if (length && !expect_user) goto done;
    secret_length = length;
    struct identity id = {0};
    int null_input = open("/dev/null", O_RDONLY);
    if (null_input < 0) goto done;
    dup2(null_input, 0); close(null_input);
    if (pipe(logs)) goto done;
    child = forkpty(&master, NULL, NULL, NULL);
    if (child == 0) {
        // -E belongs only to the final ssh process, not its ProxyJump ssh children.
        // OpenSSH closes descriptors > 2 on startup. stdout survives and -N
        // has no remote stdout. ProxyJump's stdout is its transport, not this pipe.
        dup2(logs[1], STDOUT_FILENO);
        close(logs[0]); close(logs[1]);
        int null = open("/dev/null", O_WRONLY); dup2(null, 2); close(null);
        sanitize_askpass(); wipe(password, sizeof(password));
        char *fdpath = "/dev/fd/1";
        char **args = calloc((size_t)argc + 6, sizeof(char *));
        if (!args) _exit(126);
        args[0] = SSH_EXECUTABLE; args[1] = "-v"; args[2] = "-E"; args[3] = fdpath;
        args[4] = "-o"; args[5] = "LogLevel=DEBUG1";
        for (int i = 1; i < argc; i++) args[i + 5] = argv[i];
        execv(SSH_EXECUTABLE, args); _exit(126);
    }
    close(logs[1]); logs[1] = -1;
    if (child < 0) goto done;
    fcntl(master, F_SETFL, O_NONBLOCK); fcntl(logs[0], F_SETFL, O_NONBLOCK);
    char prompt[2048] = {0}, line[4096] = {0}; size_t used = 0, line_used = 0;
    int sent = 0, tty_open = 1, log_open = 1;
    struct auth auth = {0}; time_t prompt_since = 0;
    result = 0;
    for (;;) {
        if (stopping) break;
        fd_set f; FD_ZERO(&f);
        if (tty_open) FD_SET(master, &f);
        if (log_open) FD_SET(logs[0], &f);
        struct timeval t = {0, 100000}; int maxfd = master > logs[0] ? master : logs[0];
        int ready = select(maxfd + 1, &f, NULL, NULL, &t);
        if (ready < 0 && errno != EINTR) { result = UNSUPPORTED; break; }
        // Drain every pending log line before judging a prompt: the log and PTY are separate
        // descriptors, and the auth method line must be known before the prompt is answered.
        while (log_open && !result && !auth.ambiguous) {
            char b[1024]; ssize_t n = read(logs[0], b, sizeof(b));
            if (n == 0) { log_open = 0; break; }
            if (n < 0) { if (errno != EAGAIN && errno != EINTR) log_open = 0; break; }
            for (ssize_t i = 0; i < n; i++) {
                // OpenSSH writes CRLF into -E logs; the CR is line framing, not content.
                if (b[i] == '\r') continue;
                if (b[i] == '\n') {
                    line[line_used] = 0; diagnostic(line, &id, &auth); line_used = 0;
                } else if (!b[i] || line_used + 1 >= sizeof(line)) { result = UNSUPPORTED; break; }
                else line[line_used++] = b[i];
            }
        }
        if (result || auth.ambiguous) { result = UNSUPPORTED; break; }
        if (auth.authenticated) wipe(password, sizeof(password));
        if (ready > 0 && tty_open && FD_ISSET(master, &f)) {
            char b[512]; ssize_t n = read(master, b, sizeof(b));
            if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) tty_open = 0;
            else if (n > 0) {
                for (ssize_t i = 0; i < n; i++) {
                    // ssh writes a bare CR before some prompts; it is not part of the prompt.
                    if (used == 0 && (b[i] == '\r' || b[i] == '\n')) continue;
                    if (!b[i] || used + 1 >= sizeof(prompt)) { result = UNSUPPORTED; break; }
                    if (used == 0) prompt_since = time(NULL);
                    prompt[used++] = b[i]; prompt[used] = 0;
                }
            }
        }
        if (result) break;
        if (used && could_be_hostkey_prompt(prompt, used)) {
            static const char suffix[] = "(yes/no/[fingerprint])? ";
            if (!ends_with(prompt, suffix)) {
                if (time(NULL) - prompt_since >= 3) { result = UNSUPPORTED; break; }
                continue;
            }
            if (!parse_hostkey_prompt(prompt, requested_host, sizeof(requested_host),
                                      requested_fingerprint, sizeof(requested_fingerprint))) {
                result = UNSUPPORTED; break;
            }
            if (accepted_hostkey(requested_host, requested_fingerprint)) {
                if (!answer_yes(master)) { result = UNSUPPORTED; break; }
                used = 0; prompt[0] = 0; prompt_since = 0;
            } else {
                result = HOSTKEY_REQUIRED; break;
            }
        }
        if (used && !auth.context) {
            // Jump-host prompts and passphrases arrive before final-target authentication.
            result = UNSUPPORTED; break;
        }
        if (used && !strcmp(prompt, id.prompt)) {
            struct termios attrs;
            if (!auth.password_phase || sent || tcgetattr(master, &attrs) || (attrs.c_lflag & ECHO)) { result = UNSUPPORTED; break; }
            if (!length) { result = PASSWORD_REQUIRED; break; }
            password[length] = '\n';
            if (write(master, password, length + 1) != (ssize_t)length + 1) { result = UNSUPPORTED; break; }
            wipe(password, sizeof(password)); sent = 1; used = 0; prompt[0] = 0; prompt_since = 0;
        } else if (used && (strncmp(id.prompt, prompt, used) || time(NULL) - prompt_since >= 3)) {
            // Any other prompt (passphrase, keyboard-interactive, MFA, host-key) is not ours.
            result = UNSUPPORTED; break;
        }
        pid_t exited = (!tty_open && !log_open) ? waitpid(child, &status, WNOHANG) : 0;
        if (exited == child) {
            child = -1;
            result = used ? UNSUPPORTED : (auth.hostkey_failed ? HOSTKEY_FAILED :
                     (auth.failed ? AUTH_FAILURE : (WIFEXITED(status) ? WEXITSTATUS(status) : 1)));
            break;
        }
    }
    wipe(prompt, sizeof(prompt)); wipe(line, sizeof(line));
done:
    wipe(password, sizeof(password));
    // Close before wait: macOS tty teardown can wait for unread output to drain.
    if (master >= 0) close(master);
    reap(child);
    if (logs[0] >= 0) close(logs[0]);
    if (logs[1] >= 0) close(logs[1]);
    if (result == PASSWORD_REQUIRED) fputs("MTUNL_PASSWORD_REQUIRED\n", stderr);
    else if (result == HOSTKEY_REQUIRED) fprintf(stderr, "MTUNL_HOSTKEY %s %s\n", requested_host, requested_fingerprint);
    else if (result == HOSTKEY_FAILED) fputs("SSH host key verification failed\n", stderr);
    else if (result == AUTH_FAILURE) fputs("SSH authentication failed\n", stderr);
    else if (result == UNSUPPORTED) fputs("SSH target identity or authentication prompt is ambiguous/unsupported; encrypted keys may need ssh-add\n", stderr);
    else if (result) fputs("SSH connection ended\n", stderr);
    return stopping ? 0 : result;
}
