#include <sys/types.h>
// The caller owns lease_fd. Closing it requests TERM, then KILL after two seconds.
// The watchdog retains the child as an unreaped child until signaling is done.
pid_t mtunl_watchdog_start(const char *binary, const char *directory, const char *config,
                         int output_fd, int *lease_fd, pid_t *kernel_pid);
int mtunl_watchdog_wait(pid_t watchdog, int *status, int nohang);
