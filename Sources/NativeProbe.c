#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

int care_pid_list(int *pids, int capacity) {
    int n = proc_listallpids(pids, capacity * (int)sizeof(int));
    return n > 0 && n < capacity ? n : -1;
}
int care_pid_row(int pid, int *parent, uint64_t *rss, uint64_t *age, char *path, int capacity) {
    struct proc_bsdinfo b = {0}; struct proc_taskinfo t = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b)) return 0;
    *parent = b.pbi_ppid; *age = time(NULL) > b.pbi_start_tvsec ? time(NULL) - b.pbi_start_tvsec : 0;
    *rss = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, sizeof(t)) == sizeof(t) ? t.pti_resident_size / 1024 : 0;
    if (proc_pidpath(pid, path, capacity) <= 0) snprintf(path, capacity, "/unknown/%s", b.pbi_comm);
    return 1;
}
int care_metrics(uint64_t *physical, uint64_t *compressed, uint64_t *wired, uint64_t *swap, int *pressure) {
    size_t size = sizeof(*physical);
    if (sysctlbyname("hw.memsize", physical, &size, NULL, 0)) return -1;
    size = sizeof(*pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", pressure, &size, NULL, 0)) return -1;
    struct xsw_usage usage = {0}; size = sizeof(usage);
    if (sysctlbyname("vm.swapusage", &usage, &size, NULL, 0)) return -1;
    *swap = usage.xsu_used;
    vm_statistics64_data_t vm = {0}; mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) return -1;
    vm_size_t page = 0; if (host_page_size(mach_host_self(), &page) != KERN_SUCCESS) return -1;
    *compressed = (uint64_t)vm.compressor_page_count * page; *wired = (uint64_t)vm.wire_count * page;
    return 0;
}
// Read argv only. Environment values in KERN_PROCARGS2 are never copied to the result.
int care_arguments(int pid, char *output, int capacity) {
    size_t length = 1024 * 1024; char *buffer = calloc(1, length);
    if (!buffer) return -1;
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
    if (sysctl(mib, 3, buffer, &length, NULL, 0) || length < sizeof(int)) { free(buffer); return -1; }
    int argc = 0; memcpy(&argc, buffer, sizeof(argc)); char *p = buffer + sizeof(argc), *end = buffer + length;
    while (p < end && *p) p++; while (p < end && !*p) p++;
    int used = 0;
    for (int i = 0; i < argc && p < end; i++) {
        size_t n = strnlen(p, end - p);
        if (used + n + 2 >= capacity) { free(buffer); return -1; }
        memcpy(output + used, p, n); used += n; output[used++] = ' '; p += n + 1;
    }
    output[used] = 0; free(buffer); return used;
}

// Return 0 only for the known local daemon/browser topology; fail closed on unreadable data.
int care_connections(int pid, const char *socket_path, int local_port, int daemon) {
    struct proc_fdinfo fds[4096]; int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, sizeof(fds));
    if (bytes <= 0 || bytes >= sizeof(fds)) return -1;
    int unix_count = 0, expected_socket = 0, tcp_count = 0;
    for (int i = 0; i < bytes / sizeof(fds[0]); i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo info = {0};
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &info, sizeof(info)) != sizeof(info)) return -1;
        if (info.psi.soi_kind == SOCKINFO_UN) {
            unix_count++;
            if (!strncmp(info.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path, socket_path, sizeof(info.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path))) expected_socket = 1;
        }
        if (info.psi.soi_kind == SOCKINFO_TCP && info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_ESTABLISHED) {
            if (daemon || ntohs(info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport) == local_port) tcp_count++;
        }
    }
    return daemon ? (unix_count == 4 && expected_socket && tcp_count == 1 ? 0 : 1) : (tcp_count == 1 ? 0 : 1);
}
int care_downloading(int pid) {
    struct proc_fdinfo fds[4096]; int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, sizeof(fds));
    if (bytes <= 0) return kill(pid, 0) ? 0 : -1;
    if (bytes >= sizeof(fds)) return -1;
    for (int i = 0; i < bytes / sizeof(fds[0]); i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
        struct vnode_fdinfowithpath info = {0};
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &info, sizeof(info)) != sizeof(info)) return -1;
        if (strstr(info.pvip.vip_path, ".crdownload")) return 1;
    }
    return 0;
}
