// Connects to a socket. With "send", sends one request and prints the answer;
// otherwise closes without sending anything.
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {0};
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, argv[1], sizeof a.sun_path - 1);
    if (connect(s, (struct sockaddr *)&a, sizeof a)) {
        printf("refused: %s\n", strerror(errno));
        return 1;
    }
    if (argc > 2) {
        write(s, "{\"id\":1,\"cmd\":\"probe\"}\n", 23);
        char b[100] = {0};
        read(s, b, 99);
        printf("connected: %s", b);
    } else {
        printf("connected (closed without sending)\n");
    }
    close(s);
    return 0;
}
