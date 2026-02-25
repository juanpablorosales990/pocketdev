#include "pty_support.h"
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <signal.h>
#include <sys/wait.h>
#include <string.h>
#include <errno.h>

int pty_spawn_shell(pid_t *child_pid, unsigned short rows, unsigned short cols, const char *shell_path) {
    // Create pseudo-terminal pair using POSIX APIs
    int master_fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (master_fd < 0) {
        return -1;
    }

    if (grantpt(master_fd) < 0) {
        close(master_fd);
        return -1;
    }

    if (unlockpt(master_fd) < 0) {
        close(master_fd);
        return -1;
    }

    char *slave_name = ptsname(master_fd);
    if (!slave_name) {
        close(master_fd);
        return -1;
    }

    // Set initial window size on master
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows;
    ws.ws_col = cols;
    ioctl(master_fd, TIOCSWINSZ, &ws);

    // Fork child process
    pid_t pid = fork();
    if (pid < 0) {
        close(master_fd);
        return -1;
    }

    if (pid == 0) {
        // === Child process ===
        close(master_fd);

        // Create new session (detach from parent's controlling terminal)
        setsid();

        // Open the slave PTY — this becomes our controlling terminal
        int slave_fd = open(slave_name, O_RDWR);
        if (slave_fd < 0) {
            _exit(1);
        }

        // Set as controlling terminal
        ioctl(slave_fd, TIOCSCTTY, 0);

        // Set window size on slave
        ioctl(slave_fd, TIOCSWINSZ, &ws);

        // Redirect stdin/stdout/stderr to the slave PTY
        dup2(slave_fd, STDIN_FILENO);
        dup2(slave_fd, STDOUT_FILENO);
        dup2(slave_fd, STDERR_FILENO);
        if (slave_fd > STDERR_FILENO) {
            close(slave_fd);
        }

        // Set environment
        setenv("TERM", "xterm-256color", 1);
        setenv("LANG", "en_US.UTF-8", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("CLICOLOR", "1", 1);
        setenv("LSCOLORS", "GxFxCxDxBxegedabagaced", 1);

        // Try the requested shell first
        if (shell_path && strlen(shell_path) > 0) {
            // Extract just the shell name for argv[0]
            const char *shell_name = strrchr(shell_path, '/');
            shell_name = shell_name ? shell_name + 1 : shell_path;
            execl(shell_path, shell_name, "-l", (char *)NULL);
        }

        // Fallback chain
        execl("/bin/zsh", "zsh", "-l", (char *)NULL);
        execl("/bin/bash", "bash", "-l", (char *)NULL);
        execl("/bin/sh", "sh", "-l", (char *)NULL);
        _exit(1);
    }

    // === Parent process ===
    *child_pid = pid;

    // Set master fd to non-blocking for reads
    int flags = fcntl(master_fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);
    }

    return master_fd;
}

int pty_spawn_shell_ex(pid_t *child_pid, unsigned short rows, unsigned short cols,
                       const char *shell_path, const char *home_dir, const char *work_dir) {
    int master_fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (master_fd < 0) return -1;
    if (grantpt(master_fd) < 0) { close(master_fd); return -1; }
    if (unlockpt(master_fd) < 0) { close(master_fd); return -1; }
    char *slave_name = ptsname(master_fd);
    if (!slave_name) { close(master_fd); return -1; }

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows;
    ws.ws_col = cols;
    ioctl(master_fd, TIOCSWINSZ, &ws);

    pid_t pid = fork();
    if (pid < 0) { close(master_fd); return -1; }

    if (pid == 0) {
        // === Child process ===
        close(master_fd);
        setsid();
        int slave_fd = open(slave_name, O_RDWR);
        if (slave_fd < 0) _exit(1);
        ioctl(slave_fd, TIOCSCTTY, 0);
        ioctl(slave_fd, TIOCSWINSZ, &ws);
        dup2(slave_fd, STDIN_FILENO);
        dup2(slave_fd, STDOUT_FILENO);
        dup2(slave_fd, STDERR_FILENO);
        if (slave_fd > STDERR_FILENO) close(slave_fd);

        // Set environment for phone-like experience
        setenv("TERM", "xterm-256color", 1);
        setenv("LANG", "en_US.UTF-8", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("CLICOLOR", "1", 1);
        setenv("LSCOLORS", "GxFxCxDxBxegedabagaced", 1);

        if (home_dir && strlen(home_dir) > 0) {
            setenv("HOME", home_dir, 1);
            setenv("ZDOTDIR", home_dir, 1);
            setenv("USER", "pocketdev", 1);
            setenv("LOGNAME", "pocketdev", 1);
        }

        // Change working directory
        if (work_dir && strlen(work_dir) > 0) {
            chdir(work_dir);
        } else if (home_dir && strlen(home_dir) > 0) {
            chdir(home_dir);
        }

        // Launch shell
        if (shell_path && strlen(shell_path) > 0) {
            const char *shell_name = strrchr(shell_path, '/');
            shell_name = shell_name ? shell_name + 1 : shell_path;
            execl(shell_path, shell_name, "-l", (char *)NULL);
        }
        execl("/bin/zsh", "zsh", "-l", (char *)NULL);
        execl("/bin/bash", "bash", "-l", (char *)NULL);
        execl("/bin/sh", "sh", "-l", (char *)NULL);
        _exit(1);
    }

    *child_pid = pid;
    int flags = fcntl(master_fd, F_GETFL, 0);
    if (flags >= 0) fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);
    return master_fd;
}

long pty_write_data(int master_fd, const void *buf, unsigned long count) {
    // Temporarily make blocking for writes
    int flags = fcntl(master_fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(master_fd, F_SETFL, flags & ~O_NONBLOCK);
    }
    long result = write(master_fd, buf, count);
    if (flags >= 0) {
        fcntl(master_fd, F_SETFL, flags);
    }
    return result;
}

long pty_read_data(int master_fd, void *buf, unsigned long count) {
    return read(master_fd, buf, count);
}

int pty_resize(int master_fd, unsigned short rows, unsigned short cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows;
    ws.ws_col = cols;
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}

void pty_close(int master_fd, pid_t child_pid) {
    if (master_fd >= 0) {
        close(master_fd);
    }
    if (child_pid > 0) {
        kill(child_pid, SIGHUP);
        // Give it a moment, then force kill
        usleep(100000); // 100ms
        kill(child_pid, SIGKILL);
        waitpid(child_pid, NULL, WNOHANG);
    }
}
