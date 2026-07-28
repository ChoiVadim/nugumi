#ifndef CTOOLSANDBOX_H
#define CTOOLSANDBOX_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

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
);

int gizmate_kill_process_group(pid_t pid);
int gizmate_dup2_clearing_cloexec(int source_fd, int destination_fd);

#ifdef __cplusplus
}
#endif

#endif
