#!/usr/bin/env python3
"""Check that a SOCKS5 endpoint answers — and that it refuses what it should.

The check speaks the SOCKS5 handshake itself. Nothing outside the endpoint is
involved: no HTTP, no echo API, no third-party service that can be down for
reasons that have nothing to do with the proxy. The target is a TCP address
the proxy has to open a connection to; the proxy never speaks its protocol.

Exit codes:
  0  the endpoint accepted the credentials and connected to the target
  2  the endpoint refused the credentials, or did not answer at all
  3  the endpoint accepted the credentials, but the target refused the
     connection — the proxy is alive, the outside is not reachable
  4  the endpoint accepted, connected, and then the data path failed
  5  the probe could not run (bad arguments, no network to the endpoint)

The password is read from the environment (SOCKS5_PROBE_PASSWORD), not from
the command line: a command line is visible in the process list, and a password
that leaks there has leaked.
"""

import argparse
import os
import socket
import struct
import sys

# SOCKS5: version, method counts, methods.
SOCKS5_VERSION = 0x05
METHOD_NONE = 0x00
METHOD_USERNAME = 0x02
AUTH_VERSION = 0x01
AUTH_SUCCESS = 0x00
CONNECT = 0x01
REPLY_SUCCEEDED = 0x00
REPLY_HOST_UNREACHABLE = 0x04
REPLY_CONNECTION_REFUSED = 0x05


def verdict(message, code, verdict_file=None):
    """Report the verdict once, on stdout and (optionally) in a file."""
    print(message)
    if verdict_file:
        try:
            with open(verdict_file, "w", encoding="utf-8") as handle:
                handle.write(message + "\n")
        except OSError:
            pass
    sys.exit(code)


def read_exactly(sock, count):
    """Read exactly `count` bytes, or return what arrived before the end."""
    chunks = []
    remaining = count
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="the endpoint's address")
    parser.add_argument("--port", required=True, type=int, help="the endpoint's port")
    parser.add_argument("--username", default="", help="the account to authenticate as")
    parser.add_argument("--target-host", default="1.1.1.1", help="the TCP target to connect to")
    parser.add_argument("--target-port", default=80, type=int, help="the target's port")
    parser.add_argument("--timeout", default=15.0, type=float, help="seconds to wait for each step")
    parser.add_argument(
        "--expect-data",
        action="store_true",
        help="also carry one byte in each direction — only for a target that answers",
    )
    parser.add_argument(
        "--verdict-file",
        default=None,
        help="write the verdict here as well — the caller reads it without handling secrets",
    )
    args = parser.parse_args()

    password = os.environ.get("SOCKS5_PROBE_PASSWORD", "")

    try:
        sock = socket.create_connection((args.host, args.port), timeout=args.timeout)
    except OSError as error:
        verdict(
            f"the endpoint did not answer on {args.host}:{args.port}: {error}",
            2,
            args.verdict_file,
        )
        return

    sock.settimeout(args.timeout)
    try:
        # 1. Greeting. We offer "no authentication" and "username/password"; the
        #    endpoint must pick the second one. An endpoint that picks the first
        #    one is an open relay, and that is a failure, not a pass.
        sock.sendall(bytes([SOCKS5_VERSION, 2, METHOD_NONE, METHOD_USERNAME]))
        reply = read_exactly(sock, 2)
        if len(reply) < 2:
            verdict(
                "the endpoint closed the connection before choosing an authentication method",
                2,
                args.verdict_file,
            )
        if reply[0] != SOCKS5_VERSION:
            verdict(f"the endpoint answered with an unknown SOCKS version {reply[0]}", 2, args.verdict_file)
        if reply[1] == METHOD_NONE:
            verdict(
                "the endpoint allows anonymous access — it is an open relay, not an endpoint",
                2,
                args.verdict_file,
            )
        if reply[1] != METHOD_USERNAME:
            verdict(
                f"the endpoint chose an authentication method this probe does not speak: {reply[1]}",
                2,
                args.verdict_file,
            )

        # 2. Authentication: the username and the password, as RFC 1929 says.
        user = args.username.encode("utf-8")
        secret = password.encode("utf-8")
        if len(user) > 255 or len(secret) > 255:
            verdict("the username or the password is too long for the protocol", 5, args.verdict_file)
        sock.sendall(
            bytes([AUTH_VERSION, len(user)]) + user + bytes([len(secret)]) + secret
        )
        reply = read_exactly(sock, 2)
        if len(reply) < 2:
            verdict("the endpoint closed the connection during authentication", 2, args.verdict_file)
        if reply[1] != AUTH_SUCCESS:
            verdict(
                f"the endpoint refused the credentials for '{args.username}' (status {reply[1]})",
                2,
                args.verdict_file,
            )

        # 3. The request itself: CONNECT to the target.
        try:
            address = socket.inet_aton(args.target_host)
            atyp = 1
        except OSError:
            address = socket.inet_pton(socket.AF_INET6, args.target_host)
            atyp = 4
        sock.sendall(
            bytes([SOCKS5_VERSION, CONNECT, 0x00, atyp])
            + address
            + struct.pack("!H", args.target_port)
        )
        reply = read_exactly(sock, 4)
        if len(reply) < 4:
            verdict("the endpoint closed the connection instead of answering the request", 2, args.verdict_file)
        if reply[1] != REPLY_SUCCEEDED:
            if reply[1] == REPLY_CONNECTION_REFUSED:
                verdict(
                    f"the endpoint is alive and authenticated, but the target "
                    f"{args.target_host}:{args.target_port} refused the connection",
                    3,
                    args.verdict_file,
                )
            if reply[1] == REPLY_HOST_UNREACHABLE:
                verdict(
                    f"the endpoint is alive and authenticated, but the target "
                    f"{args.target_host}:{args.target_port} is unreachable",
                    3,
                    args.verdict_file,
                )
            verdict(
                f"the endpoint answered the request with a failure code {reply[1]}",
                2,
                args.verdict_file,
            )

        # 4. The data path, when the caller asked for it. A proxy that accepts
        #    and connects but carries nothing is broken in a way the handshake
        #    does not show — but the target has to be one that answers, so this
        #    step is opt-in.
        if args.expect_data:
            sock.sendall(b"\x00")
            echoed = sock.recv(1)
            if not echoed:
                verdict(
                    "the endpoint connected but carried no data — the data path is broken",
                    4,
                    args.verdict_file,
                )
    except socket.timeout:
        verdict("the endpoint did not answer in time", 2, args.verdict_file)
    except OSError as error:
        verdict(f"the connection to the endpoint failed: {error}", 2, args.verdict_file)
    finally:
        sock.close()

    verdict(
        f"the endpoint accepted the credentials and connected to "
        f"{args.target_host}:{args.target_port}",
        0,
        args.verdict_file,
    )


if __name__ == "__main__":
    main()
