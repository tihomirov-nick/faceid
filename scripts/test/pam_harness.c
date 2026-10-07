/*
 * Calls pam_faceid's pam_sm_authenticate the way sudo does, without sudo: scripts/test_pam.sh.
 *     pam_harness <module.so> [options…]
 * Prints what the module shows in the terminal and the PAM result.
 */
#include <dlfcn.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <security/pam_appl.h>

static int conversation(int count, const struct pam_message **messages, struct pam_response **responses, void *data) {
    (void)data;
    *responses = calloc((size_t)count, sizeof(struct pam_response));
    for (int i = 0; i < count; i++) printf("[pam message %d] %s\n", messages[i]->msg_style, messages[i]->msg);
    return PAM_SUCCESS;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: pam_harness <module.so> [options…]\n");
        return 64;
    }
    struct passwd *pw = getpwuid(getuid());
    struct pam_conv conv = {conversation, NULL};
    pam_handle_t *pamh = NULL;
    if (pam_start("sudo", pw->pw_name, &conv, &pamh) != PAM_SUCCESS) {
        fprintf(stderr, "pam_start failed\n");
        return 1;
    }
    pam_set_item(pamh, PAM_TTY, ttyname(0) ? ttyname(0) : "/dev/ttys999");
    void *module = dlopen(argv[1], RTLD_NOW);
    if (!module) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    int (*authenticate)(pam_handle_t *, int, int, const char **) = dlsym(module, "pam_sm_authenticate");
    int result = authenticate(pamh, 0, argc - 2, (const char **)argv + 2);
    printf("result: %s (%d)\n", result == PAM_SUCCESS ? "PAM_SUCCESS" : result == PAM_IGNORE ? "PAM_IGNORE" : pam_strerror(pamh, result), result);
    pam_end(pamh, result);
    return 0;
}
