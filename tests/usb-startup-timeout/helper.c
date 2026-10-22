// Test helper only: no USB devices, sockets, or privileges.
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *mode = argc > 3 ? argv[3] : getenv("ML_USB_TEST_LIST_MODE");
    if (!mode) mode = "list";
    if (!strcmp(mode, "silent")) { for (;;) pause(); }
    if (!strcmp(mode, "ignore-term")) {
        signal(SIGTERM, SIG_IGN);
        puts("READY 321"); fflush(stdout);
        for (;;) pause();
    }
    if (!strcmp(mode, "partial")) {
        fputs("READY 321", stdout); fflush(stdout);
        for (;;) pause();
    }
    if (!strcmp(mode, "closed-stdout")) {
        fputs("[]", stdout); fflush(stdout); close(STDOUT_FILENO);
        for (;;) pause();
    }
    if (!strcmp(mode, "overlong")) {
        for (int i = 0; i < 4097; ++i) putchar('x');
        putchar('\n'); fflush(stdout);
        for (;;) pause();
    }
    if (!strcmp(mode, "list")) { puts("[]"); return 0; }
    if (!strcmp(mode, "stderr")) {
        for (int i = 0; i < 1024 * 1024; ++i) fputc('x', stderr);
        fflush(stderr);
    }
    puts("READY 321"); fflush(stdout);
    while (getchar() != EOF) {}
    return 0;
}
