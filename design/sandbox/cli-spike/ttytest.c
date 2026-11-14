// Which terminal calls does the sandbox allow? Prints each step's result.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

static void report(const char *what, int ok) {
    fprintf(stderr, "%-28s %s\n", what, ok ? "ok" : strerror(errno));
}

int main(void) {
    report("isatty(stdin)", isatty(0));
    struct termios t;
    int got = tcgetattr(0, &t) == 0;
    report("tcgetattr(stdin)", got);
    if (got) {
        struct termios raw = t;
        cfmakeraw(&raw);
        report("tcsetattr(stdin, raw)", tcsetattr(0, TCSANOW, &raw) == 0);
        tcsetattr(0, TCSANOW, &t);
    }
    struct winsize w;
    report("ioctl(stdout, TIOCGWINSZ)", ioctl(1, TIOCGWINSZ, &w) == 0);
    int fd = open("/dev/tty", O_RDWR);
    report("open(/dev/tty)", fd >= 0);
    if (fd >= 0) { struct termios u; tcgetattr(fd, &u); struct termios r = u; cfmakeraw(&r); report("tcsetattr(/dev/tty, raw)", tcsetattr(fd, TCSANOW, &r) == 0); tcsetattr(fd, TCSANOW, &u); close(fd); }
    return 0;
}
