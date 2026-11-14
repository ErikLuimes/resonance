// Reads a file and prints it, or says why it couldn't.
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "r");
    if (!f) {
        printf("refused: %s\n", strerror(errno));
        return 1;
    }
    char b[200] = {0};
    fread(b, 1, 199, f);
    printf("read: %s", b);
    return 0;
}
