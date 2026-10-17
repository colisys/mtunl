#include "MihomoWatchdog.h"
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <poll.h>
#include <errno.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int mtunl_watchdog_wait(pid_t pid, int *status, int nohang) {
    int result;
    do { result = (int)waitpid(pid, status, nohang ? WNOHANG : 0); }
    while (result < 0 && errno == EINTR);
    return result;
}

pid_t mtunl_watchdog_start(const char *binary, const char *directory, const char *config,
                         int output_fd, int *lease_fd, pid_t *kernel_pid) {
    int lease[2], ready[2];
    if (pipe(lease) < 0) return -1;
    if (pipe(ready) < 0) { close(lease[0]); close(lease[1]); return -1; }
    for (int i = 0; i < 2; i++) {
        fcntl(lease[i], F_SETFD, FD_CLOEXEC);
        fcntl(ready[i], F_SETFD, FD_CLOEXEC);
    }
    // All pointers and the descriptor limit are prepared before fork. The forked
    // branch uses only system calls: no Swift/Foundation or allocator locks.
    int limit = getdtablesize();
    char *argv[] = {(char *)binary, "-d", (char *)directory, "-f", (char *)config, NULL};
    char *env[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/empty", NULL};
    pid_t watchdog = fork();
    if (watchdog == 0) {
        close(lease[1]); close(ready[0]);
        for (int fd = 0; fd < limit; fd++) {
            if (fd != lease[0] && fd != ready[1] && fd != output_fd) close(fd);
        }
        setsid();
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN);
        signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
        signal(SIGCHLD, SIG_DFL);
        pid_t kernel = fork();
        if (kernel == 0) {
            close(lease[0]); close(ready[1]);
            dup2(output_fd, STDOUT_FILENO); dup2(output_fd, STDERR_FILENO);
            if (output_fd > STDERR_FILENO) close(output_fd);
            int input = open("/dev/null", O_RDONLY);
            if (input >= 0) { dup2(input, STDIN_FILENO); if (input > 2) close(input); }
            signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL);
            signal(SIGHUP, SIG_DFL); signal(SIGPIPE, SIG_DFL);
            sigset_t mask; sigemptyset(&mask); sigprocmask(SIG_SETMASK, &mask, NULL);
            if (chdir(directory) == 0) execve(binary, argv, env);
            _exit(127);
        }
        close(output_fd);
        ssize_t sent = write(ready[1], &kernel, sizeof(kernel));
        close(ready[1]);
        if (kernel < 0) _exit(125);
        int stopping = sent != sizeof(kernel), forced = 0, status = 0;
        double deadline = 0;
        if (stopping) { kill(kernel, SIGTERM); deadline = now() + 2; }
        for (;;) {
            int result = mtunl_watchdog_wait(kernel, &status, 1);
            if (result == kernel) break;
            if (result < 0) _exit(125);
            if (!stopping) {
                struct pollfd p = {lease[0], POLLIN, 0};
                int result = poll(&p, 1, 20);
                if ((result > 0 && p.revents) || (result < 0 && errno != EINTR)) {
                    stopping = 1; kill(kernel, SIGTERM); deadline = now() + 2;
                }
            } else {
                if (!forced && now() >= deadline) { kill(kernel, SIGKILL); forced = 1; }
                poll(NULL, 0, 20);
            }
        }
        close(lease[0]);
        _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
    }
    close(lease[0]); close(ready[1]);
    if (watchdog < 0) { close(lease[1]); close(ready[0]); return -1; }
    ssize_t received;
    do { received = read(ready[0], kernel_pid, sizeof(*kernel_pid)); }
    while (received < 0 && errno == EINTR);
    close(ready[0]);
    if (received != sizeof(*kernel_pid) || *kernel_pid <= 0) {
        close(lease[1]); int status; mtunl_watchdog_wait(watchdog, &status, 0); return -1;
    }
    *lease_fd = lease[1];
    return watchdog;
}
