/* Regression test for connecting a datagram socket to port 0 (scripts/patches/wine/0003 and 0016).
 *  - connect to 8.8.8.8:0 succeeds and getsockname then gives the local address: how Steam finds it; macOS
 *    refuses port 0, so Wine connects to another port there (no packet is sent).
 *  - connect to 0.0.0.0:0 must not leave the socket connected to anything: a datagram from another socket
 *    still arrives. (macOS takes 0.0.0.0 as this Mac, and the socket then drops what other senders send.)
 * Exit 0 = both pass. */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>

static struct sockaddr_in addr(const char *ip, unsigned short port)
{
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = inet_addr(ip);
    return a;
}

int main(void)
{
    WSADATA wsa;
    struct sockaddr_in a, local;
    int len, failures = 0, rc, err;
    SOCKET s, t;
    fd_set readable;
    struct timeval wait = {3, 0};
    char buf[8];

    if (WSAStartup(MAKEWORD(2, 2), &wsa)) { printf("FAIL WSAStartup\n"); return 2; }

    s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    a = addr("8.8.8.8", 0);
    rc = connect(s, (struct sockaddr *)&a, sizeof(a));
    err = rc ? WSAGetLastError() : 0;
    len = sizeof(local);
    memset(&local, 0, sizeof(local));
    if (!rc && !getsockname(s, (struct sockaddr *)&local, &len) && local.sin_addr.s_addr)
        printf("PASS UDP connect to 8.8.8.8:0 gives the local address\n");
    else { printf("FAIL UDP connect to 8.8.8.8:0: error %d, local address %s\n", err, inet_ntoa(local.sin_addr)); failures++; }
    closesocket(s);

    s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    a = addr("127.0.0.1", 0);
    len = sizeof(local);
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) || getsockname(s, (struct sockaddr *)&local, &len)) {
        printf("FAIL bind: error %d\n", WSAGetLastError());
        return 2;
    }
    a = addr("0.0.0.0", 0);
    rc = connect(s, (struct sockaddr *)&a, sizeof(a));
    err = rc ? WSAGetLastError() : 0;
    t = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    sendto(t, "x", 1, 0, (struct sockaddr *)&local, sizeof(local));
    FD_ZERO(&readable);
    FD_SET(s, &readable);
    if (select(0, &readable, NULL, NULL, &wait) == 1 && recv(s, buf, sizeof(buf), 0) == 1)
        printf("PASS UDP still receives after connect to 0.0.0.0:0 (connect error %d)\n", err);
    else { printf("FAIL UDP receives nothing after connect to 0.0.0.0:0 (connect error %d)\n", err); failures++; }
    fflush(stdout);
    return failures ? 1 : 0;
}
