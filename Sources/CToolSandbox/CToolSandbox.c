#include "include/CToolSandbox.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void report_child_error(int fd, int error_number) {
    const char *bytes = (const char *)&error_number;
    size_t remaining = sizeof(error_number);
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

static void child_fail(int error_fd) {
    int error_number = errno;
    report_child_error(error_fd, error_number);
    _exit(127);
}

static int report_memory_status(int fd, int applied) {
    unsigned char status = applied ? 1 : 0;
    while (write(fd, &status, sizeof(status)) < 0) {
        if (errno != EINTR) {
            return -1;
        }
    }
    return 0;
}

static int set_limit(int resource, uint64_t value) {
    struct rlimit limit = {
        .rlim_cur = (rlim_t)value,
        .rlim_max = (rlim_t)value,
    };
    return setrlimit(resource, &limit);
}

int gizmate_dup2_clearing_cloexec(int source_fd, int destination_fd) {
    if (dup2(source_fd, destination_fd) < 0) {
        return -errno;
    }
    int flags = fcntl(destination_fd, F_GETFD);
    if (flags < 0) {
        return -errno;
    }
    if (fcntl(destination_fd, F_SETFD, flags & ~FD_CLOEXEC) != 0) {
        return -errno;
    }
    return 0;
}

static int read_child_status(int fd, int *error_number, int *memory_limit_applied) {
    unsigned char bytes[sizeof(*error_number) + 1];
    size_t received = 0;
    while (received < sizeof(bytes)) {
        ssize_t count = read(fd, bytes + received, sizeof(bytes) - received);
        if (count > 0) {
            received += (size_t)count;
        } else if (count == 0) {
            break;
        } else if (errno != EINTR) {
            return -errno;
        }
    }
    if (received == 1) {
        *memory_limit_applied = bytes[0] == 1;
        return 0;
    }
    if (received == sizeof(*error_number)) {
        __builtin_memcpy(error_number, bytes, sizeof(*error_number));
        return 1;
    }
    if (received == sizeof(bytes)) {
        *memory_limit_applied = bytes[0] == 1;
        __builtin_memcpy(error_number, bytes + 1, sizeof(*error_number));
        return 1;
    }
    return -EIO;
}

pid_t gizmate_spawn_limited(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int stdout_fd,
    int stderr_fd,
    uint64_t cpu_seconds,
    uint64_t address_space_bytes,
    uint64_t file_bytes,
    int *memory_limit_applied
) {
    if (memory_limit_applied == NULL) {
        return (pid_t)-EINVAL;
    }
    *memory_limit_applied = 0;
    int error_pipe[2];
    if (pipe(error_pipe) != 0) {
        return (pid_t)-errno;
    }
    if (fcntl(error_pipe[1], F_SETFD, FD_CLOEXEC) != 0) {
        int error_number = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        return (pid_t)-error_number;
    }

    pid_t pid = fork();
    if (pid < 0) {
        int error_number = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        return (pid_t)-error_number;
    }
    if (pid == 0) {
        close(error_pipe[0]);
        if (setpgid(0, 0) != 0) {
            child_fail(error_pipe[1]);
        }
        if (set_limit(RLIMIT_CPU, cpu_seconds) != 0) {
            child_fail(error_pipe[1]);
        }
        int memory_applied = set_limit(RLIMIT_AS, address_space_bytes) == 0;
        if (!memory_applied) {
#if defined(__APPLE__)
            if (errno != EINVAL) {
                child_fail(error_pipe[1]);
            }
#else
            child_fail(error_pipe[1]);
#endif
        }
        if (report_memory_status(error_pipe[1], memory_applied) != 0) {
            child_fail(error_pipe[1]);
        }
        if (set_limit(RLIMIT_FSIZE, file_bytes) != 0) {
            child_fail(error_pipe[1]);
        }
        int stdout_result = gizmate_dup2_clearing_cloexec(
            stdout_fd,
            STDOUT_FILENO
        );
        if (stdout_result < 0) {
            errno = -stdout_result;
            child_fail(error_pipe[1]);
        }
        int stderr_result = gizmate_dup2_clearing_cloexec(
            stderr_fd,
            STDERR_FILENO
        );
        if (stderr_result < 0) {
            errno = -stderr_result;
            child_fail(error_pipe[1]);
        }
        if (chdir(working_directory) != 0) {
            child_fail(error_pipe[1]);
        }
        execve(executable, argv, envp);
        child_fail(error_pipe[1]);
    }

    close(error_pipe[1]);
    if (setpgid(pid, pid) != 0 && errno != EACCES) {
        int error_number = errno;
        close(error_pipe[0]);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return (pid_t)-error_number;
    }

    int child_error = 0;
    int read_result = read_child_status(
        error_pipe[0],
        &child_error,
        memory_limit_applied
    );
    close(error_pipe[0]);
    if (read_result < 0) {
        kill(-pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return (pid_t)read_result;
    }
    if (read_result > 0) {
        waitpid(pid, NULL, 0);
        return (pid_t)-child_error;
    }
    return pid;
}

int gizmate_kill_process_group(pid_t pid) {
    if (pid <= 1) {
        return -EINVAL;
    }
    if (kill(-pid, SIGTERM) != 0) {
        return -errno;
    }

    struct timespec remaining = {
        .tv_sec = 0,
        .tv_nsec = 250000000,
    };
    while (nanosleep(&remaining, &remaining) != 0) {
        if (errno != EINTR) {
            return -errno;
        }
    }

    if (kill(-pid, SIGKILL) != 0) {
        return -errno;
    }
    return 0;
}
