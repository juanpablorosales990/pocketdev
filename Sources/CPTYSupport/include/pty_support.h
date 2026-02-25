#ifndef PTY_SUPPORT_H
#define PTY_SUPPORT_H

#include <sys/types.h>

/// Spawn a shell in a new PTY.
/// Returns the master file descriptor (>= 0) on success, -1 on failure.
/// child_pid is set to the PID of the spawned shell process.
int pty_spawn_shell(pid_t *child_pid, unsigned short rows, unsigned short cols, const char *shell_path);

/// Write data to the PTY master fd.
long pty_write_data(int master_fd, const void *buf, unsigned long count);

/// Read data from the PTY master fd.
long pty_read_data(int master_fd, void *buf, unsigned long count);

/// Resize the PTY window.
int pty_resize(int master_fd, unsigned short rows, unsigned short cols);

/// Close the PTY and terminate the child process.
void pty_close(int master_fd, pid_t child_pid);

#endif
