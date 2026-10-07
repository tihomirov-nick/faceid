/*
 * pam_faceid: sudo with FaceID.
 *
 * sudo loads this module through /etc/pam.d/sudo_local:
 *     auth       sufficient     /usr/local/lib/pam/pam_faceid.so
 * The module asks the FaceID app of the user who runs sudo to recognize the owner's face. It connects to
 * ~/Library/Application Support/FaceID/sudo.sock and only talks to the socket if
 *   - the process behind it runs as that user, and
 *   - its code signature satisfies the requirement in /usr/local/etc/faceid/pam.conf (written by the FaceID
 *     installer, owned by root), so another program cannot pose as FaceID and answer "OK".
 * The protocol is described in Sources/FaceCore/SudoProtocol.swift.
 *
 * Any problem (FaceID not running, not set up, an SSH session, a timeout) returns PAM_IGNORE or PAM_AUTH_ERR,
 * and sudo goes on to the next method: Touch ID or the password. The module never prompts for input.
 *
 * Options: timeout=<seconds> (default 40), debug.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/ucred.h>
#include <sys/un.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define PAM_SM_AUTH
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <security/openpam.h>

#ifdef FACEID_TEST_CONFIG
/* scripts/test_pam.sh: a config file owned by the developer instead of root. Never in the installed module. */
#define CONFIG_PATH FACEID_TEST_CONFIG
#else
#define CONFIG_PATH "/usr/local/etc/faceid/pam.conf"
#endif
#ifdef FACEID_TEST_SOCKET
#define SOCKET_SUBPATH FACEID_TEST_SOCKET
#else
#define SOCKET_SUBPATH "Library/Application Support/FaceID/sudo.sock"
#endif
#define MAGIC "FACEID 1"

static int debug_enabled = 0;

static void debug(const char *format, ...) {
    if (!debug_enabled) return;
    va_list args;
    va_start(args, format);
    vsyslog(LOG_AUTH | LOG_DEBUG, format, args);
    va_end(args);
}

/* The code requirement of the FaceID app, from a root-owned config file nobody else can write. */
static int read_requirement(char *out, size_t size) {
    int fd = open(CONFIG_PATH, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    struct stat st;
#ifdef FACEID_TEST_CONFIG
    uid_t owner = getuid();
#else
    uid_t owner = 0;
#endif
    if (fstat(fd, &st) != 0 || st.st_uid != owner || (st.st_mode & (S_IWGRP | S_IWOTH)) || !S_ISREG(st.st_mode)) {
        close(fd);
        return 0;
    }
    char buffer[4096];
    ssize_t length = read(fd, buffer, sizeof(buffer) - 1);
    close(fd);
    if (length <= 0) return 0;
    buffer[length] = 0;
    for (char *line = strtok(buffer, "\n"); line; line = strtok(NULL, "\n")) {
        if (strncmp(line, "requirement=", 12) == 0 && strlen(line + 12) < size) {
            strcpy(out, line + 12);
            return out[0] != 0;
        }
    }
    return 0;
}

/* The process at the other end of the socket is the FaceID app (its signature satisfies the requirement). */
static int peer_is_faceid(int fd, const char *requirement) {
    audit_token_t token;
    socklen_t length = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) != 0 || length != sizeof(token)) return 0;

    int valid = 0;
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
    const void *keys[] = {kSecGuestAttributeAudit};
    const void *values[] = {data};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    CFStringRef text = CFStringCreateWithCString(NULL, requirement, kCFStringEncodingUTF8);
    SecCodeRef code = NULL;
    SecRequirementRef parsed = NULL;
    if (data && attributes && text &&
        SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecRequirementCreateWithString(text, kSecCSDefaultFlags, &parsed) == errSecSuccess) {
        OSStatus status = SecCodeCheckValidity(code, kSecCSDefaultFlags, parsed);
        valid = status == errSecSuccess;
        if (!valid) debug("pam_faceid: peer signature check failed (%d)", (int)status);
    }
    if (parsed) CFRelease(parsed);
    if (code) CFRelease(code);
    if (text) CFRelease(text);
    if (attributes) CFRelease(attributes);
    if (data) CFRelease(data);
    return valid;
}

/* sudo's own command line ("sudo ls /var/root"), shown in the FaceID prompt. */
static void command_line(char *out, size_t size) {
    out[0] = 0;
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, getpid()};
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0 || length < sizeof(int)) return;
    char *buffer = malloc(length);
    if (!buffer) return;
    if (sysctl(mib, 3, buffer, &length, NULL, 0) == 0) {
        int argc;
        memcpy(&argc, buffer, sizeof(argc));
        char *p = buffer + sizeof(argc), *end = buffer + length;
        while (p < end && *p) p++;  /* executable path */
        while (p < end && !*p) p++; /* padding */
        size_t used = 0;
        for (int i = 0; i < argc && p < end; i++) {
            const char *arg = p;
            const char *name = i == 0 ? (strrchr(arg, '/') ? strrchr(arg, '/') + 1 : arg) : arg;
            int written = snprintf(out + used, size - used, "%s%s", used ? " " : "", name);
            if (written < 0 || (size_t)written >= size - used) {
                used = size - 1;
                break;
            }
            used += written;
            while (p < end && *p) p++;
            p++;
        }
    }
    free(buffer);
}

/* Appends key=value with \\ and \n escaped. */
static void append_field(char *out, size_t size, const char *key, const char *value) {
    size_t used = strlen(out);
    int written = snprintf(out + used, size - used, "%s=", key);
    if (written < 0 || (size_t)written >= size - used) return;
    used += written;
    for (const char *c = value ? value : ""; *c && used + 3 < size; c++) {
        if (*c == '\\') { out[used++] = '\\'; out[used++] = '\\'; }
        else if (*c == '\n') { out[used++] = '\\'; out[used++] = 'n'; }
        else out[used++] = *c;
    }
    if (used + 1 < size) out[used++] = '\n';
    out[used] = 0;
}

static int write_all(int fd, const char *data, size_t length) {
    while (length > 0) {
        ssize_t written = write(fd, data, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        data += written;
        length -= (size_t)written;
    }
    return 1;
}

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags;
    int timeout = 40;
    debug_enabled = 0;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "debug") == 0) debug_enabled = 1;
        else if (strncmp(argv[i], "timeout=", 8) == 0) timeout = atoi(argv[i] + 8);
    }
    if (timeout < 5) timeout = 5;
    if (timeout > 120) timeout = 120;

    const char *user = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || !user || !*user) return PAM_IGNORE;

    /* Never for remote logins: the face in front of the Mac is not the person on the other end. */
    const void *rhost = NULL;
    if (pam_get_item(pamh, PAM_RHOST, &rhost) == PAM_SUCCESS && rhost && *(const char *)rhost) return PAM_IGNORE;
    if (getenv("SSH_CONNECTION") || getenv("SSH_CLIENT") || getenv("SSH_TTY")) return PAM_IGNORE;

    struct passwd *pw = getpwnam(user);
    if (!pw || !pw->pw_dir) return PAM_IGNORE;
    uid_t uid = pw->pw_uid;

    char requirement[2048];
    if (!read_requirement(requirement, sizeof(requirement))) {
        debug("pam_faceid: no requirement in %s", CONFIG_PATH);
        return PAM_IGNORE;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (snprintf(address.sun_path, sizeof(address.sun_path), "%s/%s", pw->pw_dir, SOCKET_SUBPATH) >= (int)sizeof(address.sun_path)) {
        return PAM_IGNORE;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return PAM_IGNORE;
    int nosigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        debug("pam_faceid: FaceID is not running (%s)", strerror(errno));
        close(fd);
        return PAM_IGNORE;
    }

    struct xucred credentials;
    socklen_t length = sizeof(credentials);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) != 0 ||
        credentials.cr_version != XUCRED_VERSION || credentials.cr_uid != uid) {
        debug("pam_faceid: socket is not owned by %s", user);
        close(fd);
        return PAM_IGNORE;
    }
    if (!peer_is_faceid(fd, requirement)) {
        close(fd);
        return PAM_IGNORE;
    }

    const void *service = NULL, *tty = NULL, *ruser = NULL;
    pam_get_item(pamh, PAM_SERVICE, &service);
    pam_get_item(pamh, PAM_TTY, &tty);
    pam_get_item(pamh, PAM_RUSER, &ruser);
    char command[512], pid[32], request[2048];
    command_line(command, sizeof(command));
    snprintf(pid, sizeof(pid), "%d", (int)getpid());
    snprintf(request, sizeof(request), "%s\n", MAGIC);
    append_field(request, sizeof(request), "user", user);
    append_field(request, sizeof(request), "service", service ? service : "");
    append_field(request, sizeof(request), "tty", tty ? tty : "");
    append_field(request, sizeof(request), "ruser", ruser ? ruser : "");
    append_field(request, sizeof(request), "pid", pid);
    append_field(request, sizeof(request), "command", command);
    strlcat(request, "\n", sizeof(request));
    if (!write_all(fd, request, strlen(request))) {
        close(fd);
        return PAM_IGNORE;
    }

    /* Read INFO lines (shown in the terminal) until OK or DENY. */
    int result = PAM_AUTH_ERR;
    char line[1024];
    size_t used = 0;
    double deadline = now_seconds() + timeout;
    for (;;) {
        double left = deadline - now_seconds();
        if (left <= 0) {
            debug("pam_faceid: timed out");
            break;
        }
        struct pollfd pfd = {fd, POLLIN, 0};
        int ready = poll(&pfd, 1, (int)(left * 1000));
        if (ready < 0) {
            if (errno == EINTR) break; /* ^C: let sudo carry on */
            break;
        }
        if (ready == 0) continue;
        ssize_t got = read(fd, line + used, sizeof(line) - 1 - used);
        if (got <= 0) break;
        used += (size_t)got;
        line[used] = 0;
        char *newline;
        int done = 0;
        while ((newline = strchr(line, '\n'))) {
            *newline = 0;
            if (strncmp(line, "INFO ", 5) == 0) {
                pam_info(pamh, "%s", line + 5);
            } else if (strcmp(line, "OK") == 0) {
                result = PAM_SUCCESS;
                done = 1;
            } else if (strncmp(line, "DENY", 4) == 0) {
                if (line[4] == ' ' && line[5]) pam_info(pamh, "%s", line + 5);
                result = PAM_AUTH_ERR;
                done = 1;
            }
            size_t consumed = (size_t)(newline - line) + 1;
            memmove(line, newline + 1, used - consumed + 1);
            used -= consumed;
            if (done) break;
        }
        if (done) break;
        if (used >= sizeof(line) - 1) break; /* a line that long is not from FaceID */
    }
    close(fd);
    debug("pam_faceid: %s", result == PAM_SUCCESS ? "recognized" : "not recognized");
    return result;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_IGNORE;
}

PAM_MODULE_ENTRY("pam_faceid");
