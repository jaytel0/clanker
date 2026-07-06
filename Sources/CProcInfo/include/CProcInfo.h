#ifndef CPROCINFO_H
#define CPROCINFO_H

// Exposes libproc to Swift. `proc_pidinfo(PROC_PIDVNODEPATHINFO)` returns a
// process's current working directory in a single syscall — replacing the
// `lsof -a -p <pid> -d cwd` subprocess the scanner used to spawn per session
// per tick.
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/param.h>

#endif
