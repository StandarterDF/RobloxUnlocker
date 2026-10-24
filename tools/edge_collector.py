"""RobloxUnlocker - сбор живых edge-адресов CDN Roblox.

Продвинутая альтернатива встроенному PowerShell-скрипту: опрашивает не только
DoH, но и обычный UDP DNS на 28 резолверах (каждый сидит в своей сети и отдаёт
свой набор edge-адресов), затем проверяет каждый адрес TCP+TLS и печатает
готовые строки для hosts.

Запуск:
    python tools/edge_collector.py
    python tools/edge_collector.py --check          # с проверкой адресов
    python tools/edge_collector.py --domain tr.rbxcdn.com

Зависимостей нет — только стандартная библиотека.
"""

import argparse
import concurrent.futures
import ipaddress
import json
import random
import socket
import ssl
import struct
import sys
import time
import urllib.parse
import urllib.request

DEFAULT_DOMAINS = ("fts.rbxcdn.com", "tr.rbxcdn.com")
TIMEOUT = 4.0

DOH_PROVIDERS = [
    "https://cloudflare-dns.com/dns-query",
    "https://dns.google/resolve",
    "https://dns.quad9.net:5053/dns-query",
    "https://dns.adguard-dns.com/dns-query",
    "https://dns.alidns.com/resolve",
    "https://doh.pub/dns-query",
]

UDP_RESOLVERS = [
    ("77.88.8.8", "Yandex"),
    ("77.88.8.1", "Yandex-2"),
    ("1.1.1.1", "Cloudflare"),
    ("1.0.0.1", "Cloudflare-2"),
    ("8.8.8.8", "Google"),
    ("8.8.4.4", "Google-2"),
    ("9.9.9.9", "Quad9"),
    ("149.112.112.112", "Quad9-2"),
    ("208.67.222.222", "OpenDNS"),
    ("208.67.220.220", "OpenDNS-2"),
    ("94.140.14.14", "AdGuard"),
    ("94.140.15.15", "AdGuard-2"),
    ("84.200.69.80", "DNS.WATCH"),
    ("84.200.70.40", "DNS.WATCH-2"),
    ("76.76.2.0", "ControlD"),
    ("76.76.10.0", "ControlD-2"),
    ("4.2.2.1", "Level3"),
    ("4.2.2.2", "Level3-2"),
    ("64.6.64.6", "Verisign"),
    ("64.6.65.6", "Verisign-2"),
    ("8.26.56.26", "Comodo"),
    ("8.20.247.20", "Comodo-2"),
    ("185.228.168.9", "CleanBrowsing"),
    ("185.228.169.9", "CleanBrowsing-2"),
    ("195.46.39.39", "SafeDNS"),
    ("195.46.39.40", "SafeDNS-2"),
    ("156.154.70.1", "Neustar"),
    ("156.154.71.1", "Neustar-2"),
]


def build_query(name: str, qtype: int = 1) -> bytes:
    tid = random.randint(0, 0xFFFF)
    header = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    qname = b"".join(
        bytes([len(part)]) + part.encode("ascii")
        for part in name.rstrip(".").split(".")
    )
    return header + qname + b"\x00" + struct.pack(">HH", qtype, 1)


def read_name(data: bytes, offset: int):
    labels = []
    jumped = False
    end = offset
    while True:
        length = data[offset]
        if length == 0:
            if not jumped:
                end = offset + 1
            break
        if length & 0xC0 == 0xC0:
            pointer = struct.unpack(">H", data[offset : offset + 2])[0] & 0x3FFF
            if not jumped:
                end = offset + 2
            jumped = True
            offset = pointer
            continue
        offset += 1
        labels.append(data[offset : offset + length].decode("ascii", "replace"))
        offset += length
    return ".".join(labels), end


def parse_answers(data: bytes):
    if len(data) < 12:
        return []
    _tid, _flags, qdcount, ancount, _ns, _ar = struct.unpack(">HHHHHH", data[:12])
    offset = 12
    for _ in range(qdcount):
        _name, offset = read_name(data, offset)
        offset += 4
    answers = []
    for _ in range(ancount):
        _name, offset = read_name(data, offset)
        rtype, _rclass, _ttl, rdlength = struct.unpack(
            ">HHIH", data[offset : offset + 10]
        )
        offset += 10
        rdata_start = offset
        offset += rdlength
        if rtype == 1 and rdlength == 4:
            answers.append(("A", str(ipaddress.IPv4Address(data[rdata_start:offset]))))
        elif rtype == 5:
            cname, _ = read_name(data, rdata_start)
            answers.append(("CNAME", cname.rstrip(".")))
    return answers


def query_udp(server: str, name: str, depth: int = 0):
    if depth > 5:
        return []
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(TIMEOUT)
    try:
        sock.sendto(build_query(name), (server, 53))
        data, _ = sock.recvfrom(4096)
    except OSError:
        return []
    finally:
        sock.close()

    answers = parse_answers(data)
    ips = [value for kind, value in answers if kind == "A"]
    if ips:
        return ips
    for kind, value in answers:
        if kind == "CNAME" and value.lower() != name.lower():
            return query_udp(server, value, depth + 1)
    return []


def query_doh(provider: str, name: str, depth: int = 0):
    if depth > 5:
        return []
    url = provider + "?name=" + urllib.parse.quote(name) + "&type=A"
    request = urllib.request.Request(url, headers={"accept": "application/dns-json"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception:
        return []

    if payload.get("Status") != 0:
        return []

    ips = []
    cname = None
    for entry in payload.get("Answer", []):
        if entry.get("type") == 1:
            try:
                ips.append(str(ipaddress.IPv4Address(entry["data"])))
            except (ValueError, KeyError):
                continue
        elif entry.get("type") == 5:
            cname = str(entry.get("data", "")).rstrip(".")

    if ips:
        return ips
    if cname and cname.lower() != name.lower():
        return query_doh(provider, cname, depth + 1)
    return []


def collect(domain: str):
    seen, order = set(), []
    answered = 0
    total = len(UDP_RESOLVERS) + len(DOH_PROVIDERS)

    with concurrent.futures.ThreadPoolExecutor(max_workers=total) as pool:
        futures = {}
        for server, _label in UDP_RESOLVERS:
            futures[pool.submit(query_udp, server, domain)] = server
        for provider in DOH_PROVIDERS:
            futures[pool.submit(query_doh, provider, domain)] = provider

        for future in concurrent.futures.as_completed(futures):
            try:
                ips = future.result()
            except Exception:
                continue
            if ips:
                answered += 1
            for ip in ips:
                if ip not in seen:
                    seen.add(ip)
                    order.append(ip)

    return order, answered, total


def probe(ip: str, domain: str, timeout: float = 2.0):
    """Возвращает время TCP+TLS в мс или None, если адрес мёртв."""
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    started = time.monotonic()
    try:
        with socket.create_connection((ip, 443), timeout=timeout) as sock:
            sock.settimeout(timeout)
            with context.wrap_socket(sock, server_hostname=domain):
                pass
    except OSError:
        return None
    return int((time.monotonic() - started) * 1000)


def main() -> int:
    parser = argparse.ArgumentParser(description="Сбор живых edge-адресов Roblox CDN")
    parser.add_argument("--domain", action="append", help="домен (можно несколько раз)")
    parser.add_argument("--check", action="store_true", help="проверить TCP+TLS")
    parser.add_argument("--limit", type=int, default=6, help="сколько адресов оставить")
    args = parser.parse_args()

    domains = args.domain or list(DEFAULT_DOMAINS)
    result_lines = []

    for domain in domains:
        print(f"\n[i] {domain}: опрашиваю резолверы...")
        ips, answered, total = collect(domain)
        print(f"    ответили {answered} из {total}, адресов: {len(ips)}")

        if not ips:
            print("    [!] ни один резолвер не ответил")
            continue

        if args.check:
            print("    [i] проверяю TCP+TLS...")
            checked = []
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
                futures = {pool.submit(probe, ip, domain): ip for ip in ips}
                for future in concurrent.futures.as_completed(futures):
                    ms = future.result()
                    if ms is not None:
                        checked.append((ms, futures[future]))

            checked.sort()
            alive = checked[: args.limit]
            dead = len(ips) - len(checked)
            print(f"    живых: {len(checked)}, мёртвых: {dead}")

            for ms, ip in alive:
                print(f"    {ip:<16} {ms} ms")
                result_lines.append(f"{ip} {domain}")
        else:
            for ip in ips[: args.limit]:
                result_lines.append(f"{ip} {domain}")

    print("\n=== Готовые строки для hosts ===")
    for line in result_lines:
        print(line)

    if not result_lines:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
