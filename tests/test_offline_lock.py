import socket

from rimeai_daemon.offline import offline_network_guard


def test_offline_network_guard_denies_internet_but_allows_unix_sockets():
    with offline_network_guard():
        try:
            socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        except PermissionError:
            pass
        else:
            raise AssertionError("Offline Lock allowed an IPv4 socket")

        try:
            socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        except PermissionError:
            pass
        else:
            raise AssertionError("Offline Lock allowed an IPv6 socket")

        unix_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        unix_socket.close()
