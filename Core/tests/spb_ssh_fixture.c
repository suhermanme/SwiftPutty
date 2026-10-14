/*
 * spb_ssh_fixture - a local SSH server for tests (docs/TESTING.md, D-009).
 *
 *   spb_ssh_fixture <uppity> <hostkey.ppk> <workdir> [--port N]
 *
 * Runs upstream PuTTY's test server, uppity, on a Unix-domain socket in
 * <workdir>, and relays TCP connections on 127.0.0.1 to it. (uppity only
 * accepts TCP peers it can identify as the same user, which it does
 * through Linux's /proc; on macOS it accepts Unix-domain sockets only.
 * The relay keeps PuTTY's own TCP path under test.)
 *
 * Prints "PORT <n>" on stdout once ready, then runs until stdin closes,
 * which makes it exit with its parent test. uppity accepts any user name
 * with the password "weasel" (keyboard-interactive: "stoat", then
 * "weasel") and runs /bin/sh on a pty in <workdir>; its log goes to
 * <workdir>/uppity.log.
 *
 * Test-only: never install or ship.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static char socket_path[1024];
static volatile pid_t uppity_pid = -1;

/* Never leave uppity behind, however the fixture ends. */
static void stop_on_signal(int sig)
{
    if (uppity_pid > 0)
        kill(uppity_pid, SIGTERM);
    unlink(socket_path);
    _exit(128 + sig);
}

static void *relay(void *arg)
{
    int tcp = (int)(intptr_t)arg;
    int unix_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", socket_path);
    if (connect(unix_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(tcp);
        close(unix_fd);
        return NULL;
    }
    struct pollfd fds[2] = {
        { .fd = tcp, .events = POLLIN }, { .fd = unix_fd, .events = POLLIN },
    };
    char buf[65536];
    for (;;) {
        if (poll(fds, 2, -1) < 0 && errno != EINTR)
            break;
        for (int i = 0; i < 2; i++) {
            if (!(fds[i].revents & (POLLIN | POLLHUP | POLLERR)))
                continue;
            ssize_t n = read(fds[i].fd, buf, sizeof(buf));
            if (n <= 0)
                goto done;
            for (ssize_t off = 0; off < n; ) {
                ssize_t w = write(fds[1 - i].fd, buf + off, n - off);
                if (w <= 0)
                    goto done;
                off += w;
            }
        }
    }
  done:
    close(tcp);
    close(unix_fd);
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc != 4 && !(argc == 6 && !strcmp(argv[4], "--port"))) {
        fprintf(stderr, "usage: %s <uppity> <hostkey.ppk> <workdir> "
                "[--port N]\n", argv[0]);
        return 2;
    }
    const char *uppity = argv[1], *hostkey = argv[2], *workdir = argv[3];
    int port = argc == 6 ? atoi(argv[5]) : 0;
    signal(SIGPIPE, SIG_IGN);

    snprintf(socket_path, sizeof(socket_path), "%s/uppity.sock", workdir);
    if (strlen(socket_path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        fprintf(stderr, "workdir too long for a Unix socket path: %s\n",
                socket_path);
        return 2;
    }
    unlink(socket_path);

    signal(SIGTERM, stop_on_signal);
    signal(SIGINT, stop_on_signal);
    signal(SIGHUP, stop_on_signal);

    pid_t child = fork();
    if (child == 0) {
        setenv("SHELL", "/bin/sh", 1);
        setenv("HOME", workdir, 1);
        setenv("PS1", "$ ", 1);
        int devnull = open("/dev/null", O_RDWR);
        char log[1100];
        snprintf(log, sizeof(log), "%s/uppity.log", workdir);
        int logfd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0600);
        dup2(devnull, STDIN_FILENO);
        dup2(devnull, STDOUT_FILENO);
        if (logfd >= 0)
            dup2(logfd, STDERR_FILENO);  /* uppity's notes, for debugging */
        execl(uppity, uppity, "--listen", socket_path, "--hostkey", hostkey,
              "--sessiondir", workdir, (char *)NULL);
        perror("exec uppity");
        _exit(127);
    }

    uppity_pid = child;

    /* Wait for uppity's socket. */
    struct stat st;
    for (int i = 0; i < 500 && stat(socket_path, &st) < 0; i++)
        usleep(10000);
    if (stat(socket_path, &st) < 0) {
        fprintf(stderr, "uppity did not start\n");
        kill(child, SIGTERM);
        return 1;
    }

    int listener = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = { .sin_family = AF_INET,
                                .sin_port = htons(port),
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t len = sizeof(addr);
    if (bind(listener, (struct sockaddr *)&addr, len) < 0 ||
        listen(listener, 16) < 0 ||
        getsockname(listener, (struct sockaddr *)&addr, &len) < 0) {
        perror("listen");
        kill(child, SIGTERM);
        return 1;
    }
    printf("PORT %d\n", ntohs(addr.sin_port));
    fflush(stdout);

    struct pollfd fds[2] = {
        { .fd = listener, .events = POLLIN },
        { .fd = STDIN_FILENO, .events = POLLIN },
    };
    for (;;) {
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (fds[1].revents) {
            char c;
            if (read(STDIN_FILENO, &c, 1) <= 0)
                break;                 /* parent gone or done */
        }
        if (fds[0].revents & POLLIN) {
            int conn = accept(listener, NULL, NULL);
            if (conn >= 0) {
                pthread_t t;
                pthread_create(&t, NULL, relay, (void *)(intptr_t)conn);
                pthread_detach(t);
            }
        }
    }

    close(listener);
    kill(child, SIGTERM);
    waitpid(child, NULL, 0);
    unlink(socket_path);
    return 0;
}
