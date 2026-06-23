---
title: Diagnosing Network Routing, Latency and Congestion Issues
category: tech
tags: [network, diagnostics, linux, troubleshoot]
---

* TOC
{:toc}

# Overview

When a network connection fails or performs poorly, the problem can lie at
many layers: DNS resolution, TCP connectivity, TLS handshake, routing path,
congestion, or even deep packet inspection (DPI). This post walks through the
diagnostic tools available on Linux, explains the principle behind each one,
and shows how to apply them systematically to SSH, HTTP, and HTTPS scenarios.

The general diagnostic strategy follows a **bottom-up approach**: start at
the network layer (can I reach the host?), then move up to the transport
layer (can I connect to the port?), and finally the application layer (does
the protocol handshake succeed?).

```
Application   curl, wget, openssl s_client     (HTTP/TLS)
Transport     nc, ss, tcpdump                  (TCP/UDP)
Network       ping, traceroute, mtr            (ICMP/IP)
Resolution    dig, nslookup, host              (DNS)
```

# DNS Diagnostics

Before anything else, verify that the hostname resolves to the correct IP
address. DNS problems are one of the most common causes of "connection
refused" or "host not found" errors.

## dig

```bash
dig example.com +short
dig example.com A
dig @8.8.8.8 example.com    # query a specific DNS server
```

**Principle**: `dig` sends a DNS query (typically UDP port 53) to a recursive
resolver and displays the response. The `+short` flag shows only the answer.
Querying an alternative DNS server (like `8.8.8.8`) helps determine whether
the issue is with your local resolver or the authoritative DNS.

## nslookup / host

```bash
nslookup example.com
host example.com
```

These are simpler alternatives to `dig`. They use the system resolver by
default and show the resolved address.

**What to look for**:

- Does the domain resolve at all?
- Does it resolve to the expected IP?
- Is the TTL unusually low (possible DNS hijacking)?
- Does it resolve differently from different DNS servers?

## Reverse DNS (PTR Records)

Normal (forward) DNS maps a domain name to an IP address (`A` record).
**Reverse DNS** does the opposite — it maps an IP address back to a
hostname (`PTR` record).

```bash
# Reverse DNS lookup
dig -x IP_ADDR
host IP_ADDR
nslookup IP_ADDR
```

Example output:

```
$ dig -x IP_ADDR +short
IP_ADDR-host.colocrossing.com.

$ host IP_ADDR
38.78.94.23.in-addr.arpa domain name pointer IP_ADDR-host.colocrossing.com.
```

**How it works**: Reverse DNS uses a special domain called `in-addr.arpa`.
The IP address is reversed and appended to this domain. For example, to look
up `IP_ADDR`, the DNS system queries for:

```
38.78.94.23.in-addr.arpa.   PTR   ?
```

The octets are reversed because DNS is hierarchical from right to left. The
`in-addr.arpa` zone is delegated to IP block owners:

```
arpa.                    ← IANA manages
  in-addr.arpa.          ← IP address reverse zone
    23.in-addr.arpa.     ← delegated to the owner of 23.0.0.0/8
      94.23.in-addr.arpa.  ← further delegated
        78.94.23.in-addr.arpa.  ← ColoCrossing manages this /24
          38.78.94.23.in-addr.arpa.  PTR  IP_ADDR-host.colocrossing.com.
```

For IPv6, the equivalent is `ip6.arpa`, using individual hex nibbles:

```
$ dig -x 2001:4860:4860::8888
8.8.8.8.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.6.8.4.0.6.8.4.1.0.0.2.ip6.arpa.
```

**Forward vs reverse DNS are independent**: A forward lookup for
`example.com` may return `1.2.3.4`, but a reverse lookup for `1.2.3.4` may
return a completely different name (or nothing). They are separate records
managed by different parties — the domain owner controls forward DNS, while
the IP block owner (hosting provider) controls reverse DNS.

### Where reverse DNS appears in practice

**1. mtr / traceroute output**:

When you run `mtr IP_ADDR`, the hostnames shown at each hop are reverse
DNS lookups. This is how you see informative names like:

```
 9.|-- 223.120.13.173   →  (CMI backbone)
11.|-- be5298.agr21.sjc03.atlas.cogentco.com  →  Cogent, San Jose
17.|-- IP_ADDR-host.colocrossing.com      →  ColoCrossing datacenter
```

Without reverse DNS, you'd only see IP addresses, making it much harder to
identify which network each hop belongs to.

**2. SSH login banners**:

SSH often performs a reverse DNS lookup on the connecting client's IP. If
reverse DNS is slow or times out, SSH login can be delayed by 10-30 seconds.
Fix by setting `UseDNS no` in `/etc/ssh/sshd_config`.

**3. Email (SMTP)**:

Mail servers heavily rely on reverse DNS. Many mail servers reject email from
IPs without valid PTR records, or where the PTR doesn't match the sending
domain. This is a basic anti-spam measure.

**4. Web server logs**:

Logs like nginx access logs show client IPs. Reverse DNS can identify the
organization behind an IP:

```bash
# Who is visiting my site?
dig -x 66.249.65.1 +short
crawl-66-249-65-1.googlebot.com.     ← it's Googlebot
```

### Diagnostic use of reverse DNS

```bash
# Identify what network an IP belongs to
dig -x 221.183.92.22 +short
# → reveals it's China Mobile backbone

# Identify a hosting provider
dig -x IP_ADDR +short
# → IP_ADDR-host.colocrossing.com (ColoCrossing = RackNerd's DC)

# Check if a VPS has proper PTR record (important for email)
dig -x YOUR_SERVER_IP +short

# Use whois for more detail when reverse DNS is unhelpful
whois IP_ADDR | grep -i -E "org|net|descr"
```

**Tip**: Reverse DNS hostnames often encode location and network info in
their naming convention:

| Pattern | Meaning |
|---------|---------|
| `sjc03` | San Jose datacenter, pod 03 |
| `be5298` | Bundle Ethernet interface #5298 |
| `agr21` | Aggregation router #21 |
| `ccr41` | Core router #41 |
| `rcr71` | Regional/access router #71 |
| `atlas.cogentco.com` | Cogent Communications backbone |

# Network Layer: Reachability

## ping

```bash
ping -c 5 IP_ADDR
```

**Principle**: `ping` sends ICMP Echo Request packets to the target host. The
target's kernel replies with ICMP Echo Reply packets. The round-trip time
(RTT) is measured for each packet.

```
64 bytes from IP_ADDR: icmp_seq=1 ttl=49 time=177 ms
64 bytes from IP_ADDR: icmp_seq=2 ttl=49 time=178 ms
```

**Key metrics**:

| Metric | Meaning |
|--------|---------|
| `time=177 ms` | Round-trip latency |
| `ttl=49` | Time-to-live (hops remaining); initial TTL is usually 64 or 128, so 49 means ~15 hops |
| `0% packet loss` | All packets received a reply |

**Limitations**: Ping uses ICMP, which is a different protocol from TCP. A
host can be reachable via ping but have all TCP ports blocked, or vice versa.
Some hosts disable ICMP entirely (ping fails, but services work fine). Never
rely on ping alone to declare a host "down."

## traceroute / tracepath

```bash
traceroute IP_ADDR
tracepath IP_ADDR
```

**Principle**: `traceroute` exploits the IP **TTL (Time-to-Live)** field. It
sends packets with incrementally increasing TTL values (1, 2, 3, ...). Each
router along the path decrements TTL by 1; when TTL reaches 0, the router
drops the packet and sends back an ICMP "Time Exceeded" message. By
collecting these ICMP responses, traceroute reconstructs the path
hop-by-hop.

```
 1  _gateway (192.168.1.1)      3.6 ms
 2  172.70.0.1                   8.4 ms
 3  183.233.67.165              11.6 ms    ← ISP backbone
 ...
 9  223.120.13.173             178.3 ms    ← trans-Pacific cable
10  223.120.6.70               178.1 ms    ← US landing point
```

**Variants**:

| Tool | Probe type | Notes |
|------|-----------|-------|
| `traceroute` | UDP (default), ICMP (`-I`), TCP (`-T`) | Most flexible |
| `tracepath` | UDP | No root needed, also discovers path MTU |
| `traceroute -T -p 443` | TCP SYN to port 443 | Tests the actual port you care about |

**Reading the output**:

- `* * *` (three asterisks) means the router did not respond. This is common
  and does not necessarily indicate a problem — many routers are configured to
  silently drop TTL-expired packets.
- A sudden latency jump (e.g., 19 ms → 179 ms) indicates a long physical
  link, typically an undersea cable crossing.
- Increasing latency at consecutive hops indicates congestion.

## mtr (My Traceroute)

```bash
mtr -r -c 10 IP_ADDR              # ICMP, report mode
mtr -T -r -c 10 -P 22 IP_ADDR    # TCP port 22
mtr -T -r -c 10 -P 443 IP_ADDR   # TCP port 443
```

**Principle**: `mtr` combines `ping` and `traceroute` into a single tool. It
continuously sends probes and displays **per-hop statistics** including packet
loss, average latency, jitter (standard deviation), and best/worst times. The
`-T` flag uses TCP SYN probes instead of ICMP, and `-P` specifies the
destination port.

This is the most powerful tool for diagnosing routing and congestion issues.

### Reading mtr output

```
HOST                          Loss%   Snt   Last   Avg  Best  Wrst StDev
 1.|-- _gateway                0.0%    10    8.7   6.9   3.6  12.0   2.4
 ...
 9.|-- 223.120.13.173          0.0%    10  178.3 179.4 175.8 182.9   2.3
10.|-- 223.120.6.70            0.0%    10  178.1 179.6 175.8 187.4   3.3
11.|-- be5298.agr21.sjc03...   0.0%    10  188.3 294.5 184.0 1235. 330.6
```

| Column | Meaning |
|--------|---------|
| Loss% | Percentage of probes that received no reply |
| Snt | Number of probes sent |
| Last | Latency of the most recent probe |
| Avg | Average latency across all probes |
| Best | Minimum latency observed |
| Wrst | Maximum latency observed |
| StDev | Standard deviation — measures **jitter** (consistency) |

### Key patterns to recognize

**Pattern 1: Latency jump at one hop, stable afterwards**

```
 8.|-- 221.183.68.126          19.1 ms
 9.|-- 223.120.13.173         179.4 ms   ← +160ms jump
10.|-- 223.120.6.70           179.6 ms   ← stable after jump
```

This is a **long physical link** (e.g., undersea cable). The latency
increases at the jump and stays elevated. This is normal and not a problem.

**Pattern 2: Latency increases progressively at consecutive hops**

```
11.|-- cogent-sjc03           294.5 ms avg, StDev 330
12.|-- cogent-sjc03           291.8 ms avg, StDev 323
13.|-- cogent-sjc13          1442.0 ms avg, StDev 1354
14.|-- cogent-sjc13           489.8 ms avg, StDev 682
```

This is **network congestion**. Packets are queuing in router buffers,
causing both higher latency and extreme jitter (high StDev). The congestion
is within the Cogent network (same ISP at all affected hops).

**Pattern 3: High loss at one hop, no loss at subsequent hops**

```
 5.|-- ???                    100.0%   ← no response
 6.|-- 221.183.137.177         0.0%   ← fine
```

This is **ICMP rate-limiting**, not packet loss. The router at hop 5 is
configured to deprioritize or drop ICMP/traceroute responses. Since
subsequent hops have 0% loss, traffic is flowing normally. Ignore this.

**Pattern 4: Loss starts at a hop and continues to the destination**

```
12.|-- router-x               30.0%
13.|-- router-y               30.0%
14.|-- destination             30.0%
```

This is **real packet loss** at hop 12. The loss propagates to all
subsequent hops because packets are being dropped at that point.

**Pattern 5: Port-specific behavior**

Running mtr on different ports can reveal port-level filtering:

```bash
mtr -T -P 22 IP_ADDR    # reaches destination
mtr -T -P 443 IP_ADDR   # reaches destination
mtr -T -P 8080 IP_ADDR  # stops at hop 4
```

If only certain ports are blocked, it indicates a **firewall or DPI system**
along the path selectively filtering traffic.

### Interpreting hop hostnames

Hop hostnames often encode useful information:

| Hostname pattern | Meaning |
|-----------------|---------|
| `sjc03.atlas.cogentco.com` | Cogent Communications, San Jose datacenter |
| `223.120.x.x` | China Mobile International (CMI) |
| `221.183.x.x` | China Mobile (CMNET) backbone |
| `be5298.agr21...` | `be` = bundle Ethernet (link aggregation), `agr` = aggregation router |

# Transport Layer: Port Connectivity

## nc (netcat / ncat)

```bash
nc -zv IP_ADDR 443 -w 5
nc -zv IP_ADDR 22 -w 5
nc -zv IP_ADDR 8080 -w 5
```

**Principle**: `nc -zv` attempts a TCP three-way handshake (SYN → SYN-ACK →
ACK) to the specified port. The `-z` flag means "scan" (don't send data),
`-v` means verbose, and `-w 5` sets a 5-second timeout.

**Interpreting results**:

| Result | Meaning |
|--------|---------|
| `Connected` | TCP handshake succeeded — port is open and a service is listening |
| `Connection refused` | Server received SYN, replied with RST — port is **reachable** but nothing is listening |
| `TIMEOUT` | No response at all — port is **blocked** by a firewall (packets silently dropped) |

The distinction between "refused" and "timeout" is critical:

- **Connection refused** = network path is clear, just no service on that port.
  If you start a service, it will work immediately.
- **Timeout** = something along the path is **dropping packets**. Could be a
  host firewall (iptables/nftables), cloud security group, or ISP/DPI
  filtering.

## ss (Socket Statistics)

```bash
ss -tlnp                # TCP listening sockets with process info
ss -tlnp | grep 443     # check if anything listens on port 443
ss -tunap               # all TCP/UDP sockets with state
```

**Principle**: `ss` reads socket information directly from the kernel's
**netlink** interface (`NETLINK_SOCK_DIAG`), bypassing `/proc/net/tcp`
entirely. This makes it faster and more reliable than the older `netstat`
(which parses procfs text files). On a busy server with thousands of
connections, `ss` is significantly faster.

### Flag Reference

| Flag | Meaning |
|------|---------|
| `-t` | TCP sockets |
| `-u` | UDP sockets |
| `-x` | Unix domain sockets |
| `-l` | Listening (server) sockets only |
| `-a` | All sockets (listening + established + waiting) |
| `-n` | Numeric (don't resolve hostnames/service names) |
| `-p` | Show process name and PID (requires root for others' processes) |
| `-e` | Extended info (UID, inode, cookie) |
| `-i` | Internal TCP info (RTT, congestion window, retransmits) |
| `-m` | Memory usage per socket |
| `-s` | Summary statistics |
| `-4` / `-6` | IPv4 / IPv6 only |
| `-o` | Show timer information |

### Common Usage Patterns

**1. Check what's listening (the most common use)**:

```bash
$ ss -tlnp
State   Recv-Q  Send-Q   Local Address:Port   Peer Address:Port  Process
LISTEN  0       4096     0.0.0.0:443           0.0.0.0:*          users:(("xray",pid=549,fd=3))
LISTEN  0       511      0.0.0.0:80            0.0.0.0:*          users:(("nginx",pid=62471,fd=5))
LISTEN  0       128      0.0.0.0:22            0.0.0.0:*          users:(("sshd",pid=412,fd=3))
```

Reading the columns:

| Column | Meaning |
|--------|---------|
| State | `LISTEN` = waiting for connections |
| Recv-Q | For LISTEN: number of pending connections in the accept queue |
| Send-Q | For LISTEN: maximum backlog size (how many connections can queue) |
| Local Address:Port | `0.0.0.0:443` = listening on all interfaces, port 443; `127.0.0.1:8080` = localhost only |
| Process | Which process owns this socket |

**2. View all established connections**:

```bash
$ ss -tnp
State    Recv-Q  Send-Q  Local Address:Port    Peer Address:Port   Process
ESTAB    0       0       IP_ADDR:22        120.235.173.19:3280  users:(("sshd",pid=1234,fd=4))
ESTAB    0       36      IP_ADDR:443       120.235.173.19:51432 users:(("xray",pid=549,fd=7))
```

This shows **active connections** — who is connected to your server right now.

**3. View TCP internal info (RTT, congestion)**:

```bash
$ ss -ti
ESTAB 0 0 IP_ADDR:22 120.235.173.19:3280
     cubic wscale:7,7 rto:408 rtt:196.5/12.3 ato:40 mss:1380
     cwnd:10 ssthresh:7 send 562.1Kbps retrans:0/3 rcv_space:14480
```

| Field | Meaning |
|-------|---------|
| `cubic` | Congestion control algorithm in use |
| `rtt:196.5/12.3` | Smoothed RTT / RTT variance (ms). 196ms matches trans-Pacific latency |
| `rto:408` | Retransmission timeout (ms). If no ACK in 408ms, TCP retransmits |
| `cwnd:10` | Congestion window (segments). How many segments can be in-flight |
| `ssthresh:7` | Slow-start threshold. Below this, cwnd grows exponentially |
| `retrans:0/3` | Current retransmit count / total retransmits for this connection |
| `mss:1380` | Maximum segment size |
| `send 562.1Kbps` | Estimated send bandwidth |

This is invaluable for diagnosing **performance issues** on established
connections. High `retrans` counts indicate packet loss. A small `cwnd`
after a connection has been active for a while indicates congestion. A high
`rtt` variance indicates jitter.

**4. Filter by state**:

```bash
# Only established connections
ss -tn state established

# Only connections in TIME-WAIT (lingering after close)
ss -tn state time-wait

# Only connections to a specific port
ss -tn '( dport = :443 )'

# Connections to a specific remote host
ss -tn dst 120.235.173.19

# Connections from a specific subnet
ss -tn src 192.168.1.0/24
```

**5. Show socket memory usage**:

```bash
$ ss -tm
ESTAB 0 0 IP_ADDR:22 120.235.173.19:3280
     skmem:(r0,rb131072,t0,tb87040,f0,w0,o0,bl0,d0)
```

| Field | Meaning |
|-------|---------|
| `r` | Receive queue memory used |
| `rb` | Receive buffer size |
| `t` | Transmit queue memory used |
| `tb` | Transmit buffer size |
| `f` | Forward-allocated memory |
| `w` | Memory queued for write |
| `bl` | Backlog memory |

**6. Summary statistics**:

```bash
$ ss -s
Total: 187
TCP:   23 (estab 5, closed 2, orphaned 0, timewait 2)

Transport Total     IP        IPv6
RAW       1         0         1
UDP       4         3         1
TCP       21        15        6
INET      26        18        8
FRAG      0         0         0
```

### TCP Socket States

`ss` shows TCP sockets in various states. Understanding these states helps
diagnose connection issues:

```
Client                          Server
  |                               |
  |  -- SYN -->   SYN-SENT        |  LISTEN
  |               ESTABLISHED  <-- SYN-ACK --  SYN-RECEIVED
  |  -- ACK -->                    |  ESTABLISHED
  |                               |
  |  ... data exchange ...         |
  |                               |
  |  -- FIN -->   FIN-WAIT-1      |
  |               FIN-WAIT-2   <-- ACK --
  |               TIME-WAIT    <-- FIN --
  |  -- ACK -->                    |  LAST-ACK → CLOSED
  |   (2*MSL)  → CLOSED           |
```

| State | Meaning | Diagnostic relevance |
|-------|---------|---------------------|
| `LISTEN` | Server waiting for connections | Expected on servers |
| `SYN-SENT` | Client sent SYN, waiting for SYN-ACK | Many of these = connection timeouts |
| `SYN-RECV` | Server received SYN, sent SYN-ACK | Many of these = possible SYN flood |
| `ESTABLISHED` | Connection active and data flowing | Normal |
| `TIME-WAIT` | Connection closed, waiting 2*MSL | Normal; too many = high connection churn |
| `CLOSE-WAIT` | Remote side closed, local hasn't | Indicates application bug (not calling close) |
| `FIN-WAIT-2` | Local side closed, waiting for remote FIN | May indicate remote app hung |

**Red flags**:

- Many `SYN-SENT` sockets: your server can't connect to a remote host
  (network issue or remote server down)
- Many `CLOSE-WAIT` sockets: application bug — the app isn't closing sockets
  after the remote side disconnects
- Many `TIME-WAIT` sockets: high connection turnover (normal for busy web
  servers, but can exhaust ephemeral ports if extreme)
- Large `Recv-Q` on LISTEN socket: application isn't accepting connections
  fast enough (overloaded)
- Large `Recv-Q` on ESTABLISHED socket: application isn't reading data fast
  enough
- Large `Send-Q` on ESTABLISHED socket: data queued but not ACK'd (network
  congestion or remote side not reading)

### ss vs netstat

| Feature | `ss` | `netstat` |
|---------|------|-----------|
| Data source | Kernel netlink (direct) | `/proc/net/tcp` (text parsing) |
| Speed | Fast (efficient on 10k+ sockets) | Slow on busy servers |
| Filtering | Built-in state/address filters | Requires `grep` piping |
| TCP internals | `-i` shows RTT, cwnd, retrans | Not available |
| Memory info | `-m` shows per-socket memory | Not available |
| Status | Actively maintained | Deprecated (net-tools package) |

Use `ss` for everything. There is no reason to use `netstat` on modern
Linux.

**When to use**: Always check `ss -tlnp` on the server side when a
connection fails. It answers: "Is the service actually listening on the
expected port?" Use `ss -ti` to diagnose slow connections, and `ss -tn state
established` to see who's connected.

## Checking firewalls on the server

When `nc` times out but `ss` confirms a service is listening, check for
firewall rules:

```bash
iptables -L -n                       # legacy iptables rules
nft list ruleset                     # nftables rules
firewall-cmd --list-all              # firewalld
ufw status verbose                   # Ubuntu's UFW
```

Also check for **cloud-level firewalls** (AWS Security Groups, GCP Firewall
Rules, etc.) which are invisible from inside the VM.

# Application Layer: Protocol Diagnostics

## curl (HTTP/HTTPS)

```bash
# Basic HTTP request
curl -v http://example.com/

# HTTPS with timing details
curl -v -o /dev/null -w "
    DNS:        %{time_namelookup}s
    Connect:    %{time_connect}s
    TLS:        %{time_appconnect}s
    TTFB:       %{time_starttransfer}s
    Total:      %{time_total}s
    HTTP Code:  %{http_code}
" https://example.com/

# Test via a proxy
curl -x http://127.0.0.1:8080 http://ifconfig.me
curl -x socks5://127.0.0.1:1080 http://ifconfig.me

# Specify TLS version and SNI
curl --tlsv1.3 --resolve example.com:443:1.2.3.4 https://example.com/
```

**Principle**: `curl` is an HTTP client that shows the full request/response
cycle. The `-v` flag reveals every step: DNS resolution, TCP connect, TLS
handshake (cipher negotiation, certificate verification), HTTP
request/response headers.

**Timing breakdown with `-w`**:

| Metric | What it measures |
|--------|-----------------|
| `time_namelookup` | DNS resolution |
| `time_connect` | TCP handshake (SYN → SYN-ACK → ACK) |
| `time_appconnect` | TLS handshake complete |
| `time_starttransfer` | Time to first byte (TTFB) |
| `time_total` | Entire request/response |

If `time_connect` is high, the problem is network latency. If
`time_appconnect - time_connect` is high, the TLS handshake is slow. If
`time_starttransfer - time_appconnect` is high, the server is slow to
generate a response.

## openssl s_client (TLS Diagnostics)

```bash
openssl s_client -connect IP_ADDR:443 -servername example.com
openssl s_client -connect example.com:443 -showcerts
```

**Principle**: `openssl s_client` performs a TLS handshake and displays the
full certificate chain, negotiated cipher suite, TLS version, and session
details. It then drops into an interactive mode where you can type raw
HTTP requests.

**What to look for**:

- Does the TLS handshake complete or hang?
- Is the certificate valid and for the correct domain?
- What TLS version was negotiated (1.2 vs 1.3)?
- What cipher suite was selected?

**Common error patterns**:

| Symptom | Likely cause |
|---------|-------------|
| Handshake hangs (no ServerHello) | Port blocked, server misconfigured, or DPI interference |
| `certificate verify failed` | Self-signed cert, wrong domain, or expired cert |
| `tlsv1 alert protocol version` | TLS version mismatch |
| `Connection refused` | Nothing listening on that port |

## SSH Diagnostics

```bash
ssh -vvv user@host            # verbose SSH (shows handshake steps)
ssh -o ConnectTimeout=5 user@host
ssh -p 2222 user@host         # non-standard port
```

**Principle**: SSH uses its own protocol over TCP (default port 22). The
`-vvv` flag enables maximum verbosity, showing:

1. TCP connection establishment
2. SSH protocol version exchange
3. Key exchange algorithm negotiation
4. Server host key verification
5. User authentication (publickey, password, etc.)

**Where SSH can hang**:

| Stage | Symptom with `-vvv` | Cause |
|-------|-------------------|-------|
| TCP connect | `Connecting to host port 22...` hangs | Port blocked, server down |
| Banner exchange | `Connection established` then hangs | SSH service not responding |
| Key exchange | `SSH2_MSG_KEXINIT sent` then hangs | DPI interference, incompatible algorithms |
| Authentication | `Trying key...` then hangs | Server-side auth issue (PAM, LDAP) |

# Diagnosing Specific Scenarios

## Scenario 1: SSH Connection Timeout

```bash
# Step 1: Is the host alive?
ping -c 3 target-host

# Step 2: Is port 22 open?
nc -zv target-host 22 -w 5

# Step 3: If timeout, is it port-specific?
nc -zv target-host 80 -w 5
nc -zv target-host 443 -w 5

# Step 4: Trace the route on port 22
mtr -T -r -c 10 -P 22 target-host

# Step 5: On the server, verify service
ss -tlnp | grep 22
systemctl status sshd
```

## Scenario 2: Website Not Loading (HTTP)

```bash
# Step 1: DNS resolution
dig example.com +short

# Step 2: TCP connectivity to port 80
nc -zv example.com 80 -w 5

# Step 3: HTTP request with verbose output
curl -v http://example.com/

# Step 4: On the server
ss -tlnp | grep 80
nginx -t                    # check nginx config
tail -20 /var/log/nginx/error.log
```

**Common HTTP pitfalls**:

| curl output | Cause |
|------------|-------|
| `Empty reply from server` | Server closed connection without response (e.g., nginx `return 444`) |
| `Connection reset by peer` | Server or middlebox sent TCP RST |
| `Recv failure` | Connection dropped during data transfer |
| HTTP 301/302 loop | Misconfigured redirect rules |

## Scenario 3: HTTPS Certificate / TLS Issues

```bash
# Step 1: Test TLS handshake
openssl s_client -connect example.com:443 -servername example.com

# Step 2: Check certificate expiry
echo | openssl s_client -connect example.com:443 2>/dev/null | \
  openssl x509 -noout -dates

# Step 3: Test with curl
curl -vI https://example.com/ 2>&1 | grep -E "subject:|issuer:|expire"

# Step 4: Test specific TLS version
curl --tlsv1.2 https://example.com/
curl --tlsv1.3 https://example.com/
```

## Scenario 4: Proxy Connection Issues

When using a proxy (SOCKS5, HTTP proxy, or tunnel like Xray/V2Ray):

```bash
# Step 1: Is the local proxy listening?
ss -tlnp | grep 1080

# Step 2: Can you reach the remote proxy server?
nc -zv proxy-server 443 -w 5

# Step 3: Test the route to the proxy server
mtr -T -r -c 10 -P 443 proxy-server

# Step 4: Test via the proxy
curl -x socks5://127.0.0.1:1080 http://ifconfig.me
curl -x http://127.0.0.1:8080 http://ifconfig.me

# Step 5: Compare routes on different ports
mtr -T -r -c 10 -P 22 proxy-server     # SSH port (usually works)
mtr -T -r -c 10 -P 443 proxy-server    # HTTPS port
mtr -T -r -c 10 -P 2053 proxy-server   # non-standard port
```

If standard ports (80, 443) time out but non-standard ports show "connection
refused" (meaning they are reachable), the issue is **port-level filtering**
by a firewall or DPI system, not general connectivity.

# Packet-level Diagnostics

## tcpdump

[pcap filter](https://www.tcpdump.org/manpages/pcap-filter.7.html)

```bash
# Capture traffic on port 443
tcpdump -i eth0 -nn port 443

# Capture and save to file for Wireshark analysis
tcpdump -i eth0 -nn -w /tmp/capture.pcap port 443

# Watch TCP handshake flags
tcpdump -i eth0 -nn 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0' and port 443

# Watch a specific host
tcpdump -i eth0 -nn host IP_ADDR
```

**Principle**: `tcpdump` captures raw packets at the network interface level
using the kernel's packet filter (BPF). It shows individual TCP segments,
including SYN/SYN-ACK/ACK handshakes, data packets, FIN/RST teardowns, and
retransmissions.

**What to look for**:

| Pattern | Meaning |
|---------|---------|
| SYN sent, no SYN-ACK received | Port blocked (firewall dropping packets) |
| SYN sent, RST received | Port reachable but closed |
| SYN-ACK received, then RST | Connection established then immediately torn down (DPI) |
| Multiple SYN retransmissions | Packets being dropped, TCP retrying with exponential backoff |
| TLS ClientHello sent, no ServerHello | TLS handshake blocked or server not responding |

**TCP retransmission timing**: When a SYN packet is dropped, TCP retransmits
with exponential backoff: 1s, 2s, 4s, 8s, 16s. If you see a connection
taking ~31 seconds, it means 5 SYN retransmissions before success, indicating
heavy packet loss or filtering.

## Wireshark

While `tcpdump` excels at live capture and quick CLI inspection, **Wireshark**
is the tool of choice for deep-dive analysis. It provides a graphical
interface for dissecting protocols, tracking conversations, graphing TCP
behavior, and navigating packet captures that would be tedious to inspect
line-by-line.

### Capturing Traffic for Wireshark

[Wireshark wiki capture filters](https://wiki.wireshark.org/CaptureFilters)

Wireshark can capture live, but often you capture remotely and analyze
locally:

```bash
## Capture on a remote server, analyze in Wireshark locally
## On the server:
tcpdump -i eth0 -nn -w /tmp/capture.pcap port 443

## Copy to local machine, then open in Wireshark:
wireshark capture.pcap
```

For live remote capture with Wireshark's GUI:

```bash
## Pipe tcpdump from a remote server into local Wireshark in real-time
ssh root@server 'tcpdump -i eth0 -nn -w - port 443' | wireshark -k -i -
```

### Display Filters vs Capture Filters

[Wireshark Tutorial: Display Filter Expressions](https://unit42.paloaltonetworks.com/using-wireshark-display-filter-expressions/)

[Wireshark wiki display filters](https://wiki.wireshark.org/DisplayFilters)


Wireshark has two independent filter systems that serve different purposes:

| Filter Type | Syntax | Applied | Purpose |
|------------|--------|---------|---------|
| **Capture filter** | BPF (Berkeley Packet Filter) | Before capture | Limits which packets are stored; reduces file size |
| **Display filter** | Wireshark-specific syntax | After capture | Limits which captured packets are shown; full data is preserved |

**Capture filters** reduce what you record (good for long-running captures
where you only care about specific traffic). **Display filters** hide
irrelevant packets from view but keep everything in the file — you can
toggle the filter off to see the full capture at any time.

#### Common Capture Filters (BPF Syntax)

```text
port 443                           # only traffic on port 443
host 192.168.1.100                 # only traffic to/from this host
tcp port 80 or tcp port 443        # HTTP or HTTPS
not host 192.168.1.1               # exclude traffic from this host
src net 10.0.0.0/8                 # only traffic originating from this subnet
icmp                               # only ICMP (ping, traceroute)
tcp and port not 22                # all TCP except SSH
```

These use the same BPF syntax as `tcpdump` — anything you can pass to
`tcpdump` as a filter expression works as a Wireshark capture filter.

### Common Display Filters

Display filters are where Wireshark really shines. The syntax is
hierarchical: `protocol.field` with comparison operators and boolean
combinators.

#### TCP Filters

```text
## Connection basics
tcp.port == 443                    # any packet with source or dest port 443
tcp.srcport == 443                 # only packets FROM port 443
tcp.dstport == 443                 # only packets TO port 443
tcp.port in {80 443 8080}          # multiple ports
ip.addr == 192.168.1.100           # any packet involving this IP (TCP, UDP, ICMP...)
ip.src == 10.0.0.1                 # only packets FROM this IP
ip.dst == 10.0.0.1                 # only packets TO this IP
```

```text
## TCP flags
tcp.flags.syn == 1 && tcp.flags.ack == 0    # pure SYN (connection initiation)
tcp.flags.syn == 1 && tcp.flags.ack == 1    # SYN-ACK (server response)
tcp.flags.reset == 1                         # RST (connection refused or torn down)
tcp.flags.fin == 1                           # FIN (graceful close)
tcp.flags == 0x002                           # SYN only (hex mask equivalent)
```

**Why flag filters matter**: During troubleshooting, isolating control
packets from data packets saves time:

```text
## Show only TCP control packets — hides all the ACKs and data segments
tcp.flags.syn == 1 || tcp.flags.reset == 1 || tcp.flags.fin == 1
```

```text
## TCP problems — critical filters for performance debugging
tcp.analysis.retransmission        # retransmitted segments (packet loss)
tcp.analysis.duplicate_ack         # duplicate ACKs (reordering or loss)
tcp.analysis.fast_retransmission   # fast retransmit triggered by 3 dup ACKs
tcp.analysis.spurious_retransmission   # unnecessarily retransmitted (false alarm)
tcp.analysis.lost_segment          # segment believed lost
tcp.analysis.window_update         # TCP window size changes
tcp.analysis.keep_alive            # TCP keepalive probes
tcp.analysis.zero_window           # receiver advertised zero window (backpressure)
tcp.analysis.acked_lost_segment    # ACK for a previously-lost segment
tcp.analysis.out_of_order          # segment arrived out of sequence
```

**Interpreting the TCP analysis flags**: Wireshark infers these from
sequence numbers and timing. A few retransmissions on a long path is
normal; sustained retransmissions indicate packet loss. `zero_window`
means the receiver can't keep up — its receive buffer is full. `out_of_order`
combined with `duplicate_ack` often indicates path asymmetry or per-packet
load balancing.

```text
## Follow a specific TCP connection
tcp.stream eq 5                    # isolate one TCP conversation
tcp.stream eq 5 and tcp.analysis.retransmission  # retransmissions in that stream
```

Every TCP connection in a capture is assigned a stream index. Right-click
a packet → "Follow → TCP Stream" to see the reconstructed data and note
the stream number for filtering.

#### TLS/HTTPS Filters

```text
## TLS handshake phases
tls.handshake.type == 1            # ClientHello
tls.handshake.type == 2            # ServerHello
tls.handshake.type == 11           # Certificate
tls.handshake.type == 14           # ServerHelloDone
tls.handshake.type == 15           # CertificateVerify
tls.handshake.type == 16           # ClientKeyExchange
tls.handshake.type == 20           # Finished
```

```text
## TLS content — SNI, version, ciphers
tls.handshake.extensions_server_name           # contains the SNI hostname
tls.handshake.extensions_server_name contains "example.com"
tls.handshake.version                           # TLS version in handshake
tls.record.version                              # TLS version in record layer
tls.handshake.ciphersuites                      # offered cipher suites
tls.handshake.ciphersuite                       # selected cipher suite
tls.record.content_type == 21                   # TLS Alert (error) records
```

```text
## TLS alerts — handshake failures
tls.alert_message.desc == 40        # Handshake Failure
tls.alert_message.desc == 70        # Protocol Version (TLS version mismatch)
tls.alert_message.desc == 112       # Unrecognized Name (SNI not recognized)
```

When a TLS handshake fails, the server (or client) sends a `Fatal Alert`
with a description code. Filtering by `tls.alert_message.desc` reveals
exactly why the handshake was rejected — far more precise than guessing
from connection timeouts.

#### HTTP Filters

```text
http.request                        # HTTP requests
http.response                       # HTTP responses
http.request.method == "POST"       # POST requests only
http.response.code >= 400           # HTTP errors (4xx, 5xx)
http.response.code == 502           # Bad Gateway
http.host contains "example.com"    # requests to specific host
http.user_agent                     # User-Agent header
http.request.uri contains "/api"    # requests to specific path
http.content_type contains "json"   # JSON responses
```

#### DNS Filters

```text
dns                                # all DNS traffic
dns.flags.response == 0            # only queries (not responses)
dns.flags.response == 1            # only responses
dns.flags.rcode != 0               # DNS errors (NXDOMAIN, SERVFAIL, etc.)
dns.qry.name contains "example"    # queries for a specific domain
dns.resp.name contains "example"   # responses for a specific domain
dns.qry.type == 1                  # A record queries (IPv4 address)
dns.qry.type == 28                 # AAAA record queries (IPv6 address)
dns.qry.type == 15                 # MX record queries (mail exchange)
dns.qry.type == 16                 # TXT record queries
dns.a                              # filter to A record responses specifically
```

#### Common Filter Combinations

```text
## Exclude noise — hide routine traffic to focus on anomalies
!(tcp.port == 443 or tcp.port == 80 or dns or arp or icmp)

## Show only TCP SYN packets for a specific host (connection attempts)
tcp.flags.syn == 1 && tcp.flags.ack == 0 && ip.addr == 192.168.1.100

## All packets between two specific hosts
ip.addr == 10.0.0.5 && ip.addr == 10.0.0.10

## Detect possible DPI interference — look for RSTs with unexpected TTL
tcp.flags.reset == 1 && !(ip.src == server.ip)

## TLS ClientHello with specific SNI
tls.handshake.type == 1 && tls.handshake.extensions_server_name contains "google"

## TCP problems on a specific connection
tcp.stream eq 3 && (tcp.analysis.retransmission || tcp.analysis.duplicate_ack)

## All DNS queries that returned an error
dns.flags.response == 1 && dns.flags.rcode != 0
```

### Key Wireshark Features for Troubleshooting

#### Follow TCP Stream

Right-click any packet → **Follow → TCP Stream**. This reconstructs the
bidirectional data stream as the application sees it — reassembled, in
order, without TCP headers. For HTTP, you see the full request and
response. For TLS, you see the encrypted bytes. For SSH, you see the
protocol banner and then ciphertext.

This is the single most-used feature in Wireshark. It turns a pile of
packets into a coherent conversation.

#### Flow Graph (Statistics → Flow Graph)

Shows a time-sequenced diagram of which side sent what, when. Useful for
understanding the handshake flow and spotting abnormal sequences:

```
Time      Client                Server
0.000     SYN ─────────────────►
0.050     ◄───────────────── SYN-ACK
0.051     ACK ─────────────────►
0.052     ClientHello ─────────►     ← TLS begins
0.100     ◄───────────────── ServerHello
          ◄───────────────── Certificate
          ◄───────────────── ServerHelloDone
0.105     ClientKeyExchange ───►
          ChangeCipherSpec ────►
          Finished ────────────►
0.155     ◄───────────────── ChangeCipherSpec
          ◄───────────────── Finished
0.156     Application Data ────►     ← encrypted from here
...
```

Errors stand out immediately: no ServerHello after ClientHello, a RST
after ClientHello, missing Certificate, or long gaps between messages
(indicating a hung handshake or middlebox interference).

#### IO Graph (Statistics → IO Graph)

Plots packets per second or bytes per second over time. Essential for
spotting throughput drops, traffic bursts, or periodic patterns. Configure
multiple graph layers with different display filters to compare:

```text
Graph 1 (blue):  tcp.port == 443          # total HTTPS throughput
Graph 2 (red):   tcp.analysis.retransmission  # retransmits over time
Graph 3 (green): tcp.analysis.zero_window     # zero-window events
```

If red spikes correlate with throughput drops, the problem is packet loss.
If green spikes correlate, the receiver is overwhelmed.

#### TCP Stream Graphs (Statistics → TCP Stream Graphs)

Wireshark provides several visualizations of TCP behavior for a single
connection:

| Graph | What it shows | Diagnostic value |
|-------|--------------|-----------------|
| **Time-Sequence (Stevens)** | Sequence number over time (line = bytes sent) | Slope = throughput; flat sections = idle; gaps = lost segments |
| **Time-Sequence (tcptrace)** | Similar but with ACK line overlay | ACK line below seq line = data in flight |
| **Throughput** | Bytes/second over time | Identify throughput collapse events |
| **Round Trip Time** | RTT per segment over time | Spikes in RTT = queuing delays / congestion |
| **Window Scaling** | Advertised receive window over time | Shrinking window = receiver bottleneck |

The **Round Trip Time** graph is particularly useful: a sudden jump in RTT
from 20ms to 200ms mid-connection often indicates router bufferbloat or a
path change (rerouting).

#### Expert Info (Analyze → Expert Info)

Wireshark automatically flags protocol anomalies and rates them by
severity:

| Level | Meaning | Example |
|-------|---------|---------|
| **Error** | Protocol violation | Malformed packet, invalid checksum |
| **Warning** | Unusual but not illegal | Retransmission, duplicate ACK, zero window |
| **Note** | Informational | TCP keep-alive, window update |
| **Chat** | Normal protocol chatter | SYN, FIN, RST |

Open Expert Info after loading a capture to see a summary of every
anomaly Wireshark detected. Click any entry to jump directly to that
packet. Always check Expert Info first — it may immediately highlight
the root cause without manual inspection.

#### Endpoints and Conversations (Statistics → Endpoints / Conversations)

Shows aggregate statistics per host (Endpoints) or per host-pair
(Conversations): packet count, byte count, throughput, duration.
Sort by bytes to identify which conversation dominates the capture.
Sort by packets to find chatty protocols.

### Troubleshooting Workflows

#### Workflow 1: Finding the cause of TCP retransmissions

```text
Step 1: Apply display filter → tcp.analysis.retransmission
Step 2: Check Expert Info (Analyze → Expert Info) for Warnings
Step 3: IO Graph with two layers:
        - tcp.port == <problem_port>  (throughput)
        - tcp.analysis.retransmission (retransmit count)
        Correlation = packet loss is the cause
Step 4: TCP Stream Graph → Round Trip Time
        RTT spikes before retransmissions = congestion
        RTT stable, retransmissions continue = path packet loss
Step 5: Check specific stream → tcp.stream eq N
        Follow TCP Stream → see if application data is correct
```

#### Workflow 2: Diagnosing a TLS handshake failure

```text
Step 1: Filter to the connection attempt
        → ip.addr == <server_ip> && tcp.port == 443
Step 2: Check TCP handshake
        → Is there a SYN → SYN-ACK → ACK? (TCP is established?)
Step 3: Check for ClientHello
        → tls.handshake.type == 1
        If missing: TCP connected but TLS never started (port mismatch)
Step 4: Check for ServerHello
        → tls.handshake.type == 2
        If missing after ClientHello: server doesn't speak TLS on this port
        or a middlebox is blocking the ClientHello
Step 5: Check for alerts
        → tls.alert_message.desc
        Fatal alert present → read the description code for exact reason
Step 6: If handshake hung, check timing
        → Flow Graph (Statistics → Flow Graph)
        Look for gaps > 5 seconds between ClientHello and ServerHello
        → middlebox interference or server-side issue
```

#### Workflow 3: Tracing DNS resolution issues

```text
Step 1: Filter → dns
Step 2: Check for queries with no response
        → dns.flags.response == 0
        Compare query count vs response count — unmatched = dropped queries
Step 3: Check for error responses
        → dns.flags.rcode != 0
        rcode 3 = NXDOMAIN (domain doesn't exist)
        rcode 2 = SERVFAIL (server couldn't process query)
        rcode 5 = REFUSED (server refused to answer)
Step 4: Check which DNS server responded
        → ip.src filter combined with dns
        Confirm responses come from your configured DNS, not an interceptor
Step 5: Check response time
        → dns.time (shown in response packet, time since query)
        > 1 second = slow DNS server or network latency to resolver
```

#### Workflow 4: Analyzing a slow connection

```text
Step 1: Identify the connection → tcp.stream eq N
Step 2: TCP Stream Graph → Time-Sequence (Stevens)
        Flat slope = low throughput
        Gaps in the line = idle periods (application think time or stalls)
Step 3: TCP Stream Graph → Round Trip Time
        Check baseline RTT — if high, latency is the issue
        Check for RTT spikes — if present, intermittent congestion
Step 4: Wireshark IO Graph → bytes/sec for this stream
        Compare with expected throughput
Step 5: Check window scaling
        → tcp.window_size
        Small window throughout = receiver bottleneck
        Shrinking window = receiver can't keep up
Step 6: Check retransmissions
        → tcp.analysis.retransmission
        > 1% retransmit rate = packet loss is slowing throughput
```

### Tips for Efficient Wireshark Use

1. **Always apply capture filters for long-running captures** — a
   busy server can generate gigabytes of pcap in minutes. A capture filter
   like `port 443` limits file size before it becomes a problem.

2. **Use `tcp.stream eq N` to focus** — once you find a problematic
   connection, isolate it with its stream index. This hides thousands of
   unrelated packets and makes patterns visible.

3. **Check Expert Info first** — before manually scanning packets, open
   Analyze → Expert Info. It may immediately point to the problem.

4. **Use the IO Graph to correlate events** — plot retransmits, zero
   windows, and throughput on the same graph. Correlation reveals causation.

5. **Use `frame.time_relative` to measure delays** — add a column for
   `frame.time_relative` (time since first captured packet) to see exact
   timing between events. Useful for quantifying slow-handshake issues.

6. **Export filtered results** — once you've isolated the relevant packets
   with a display filter, use File → Export Specified Packets to save a
   smaller pcap that you can share with colleagues.

# Quick Reference

## Diagnostic Decision Tree

```
Connection fails
├── Does the hostname resolve?
│   └── No → DNS problem (dig, nslookup)
├── Does ping work?
│   └── No → Host down or ICMP blocked (not conclusive)
├── Does nc to the port work?
│   ├── TIMEOUT → port blocked (firewall/DPI)
│   │   └── Compare other ports with nc
│   │       ├── All ports timeout → host-level block
│   │       └── Only some ports → port-level filtering
│   ├── REFUSED → port reachable, service not running
│   │   └── Check ss -tlnp on server
│   └── CONNECTED → port open, protocol issue
│       ├── HTTP? → curl -v
│       ├── HTTPS? → openssl s_client + curl -v
│       └── SSH? → ssh -vvv
├── High latency or intermittent?
│   └── mtr -T -P <port> to identify congested hop
└── TLS handshake hangs?
    └── openssl s_client / tcpdump for packet-level analysis
```

## Tool Summary

| Tool | Layer | Protocol | Root? | Best for |
|------|-------|----------|-------|----------|
| dig | DNS | UDP/53 | No | DNS resolution verification |
| ping | Network | ICMP | No | Basic reachability and RTT |
| traceroute | Network | UDP/ICMP/TCP | Yes (TCP) | Path discovery |
| mtr | Network | ICMP/TCP | Yes (TCP) | Sustained path quality analysis |
| nc | Transport | TCP | No | Port-level connectivity test |
| ss | Transport | — | No | Local socket/service status |
| curl | Application | HTTP/HTTPS | No | Full HTTP request diagnostics |
| openssl | Application | TLS | No | TLS handshake and cert analysis |
| ssh -vvv | Application | SSH | No | SSH handshake debugging |
| tcpdump | All | Raw packets | Yes | Packet-level analysis |
| iptables/nft | Transport | — | Yes | Server firewall rule inspection |

# How SSH Works

## Protocol Overview

SSH (Secure Shell) provides encrypted remote access over an untrusted
network. It runs over TCP, typically on port 22. An SSH connection goes
through several distinct phases:

```
Client                                Server
  |                                     |
  |  -------- TCP SYN --------->        |  1. TCP handshake
  |  <------ TCP SYN-ACK ------        |
  |  -------- TCP ACK --------->        |
  |                                     |
  |  <-- "SSH-2.0-OpenSSH_9.7" --      |  2. Protocol version exchange
  |  -- "SSH-2.0-OpenSSH_9.6" -->      |     (plaintext banners)
  |                                     |
  |  ---- SSH_MSG_KEXINIT ----->        |  3. Algorithm negotiation
  |  <--- SSH_MSG_KEXINIT -----        |     (key exchange, cipher, MAC, compression)
  |                                     |
  |  <==== Key Exchange ======>        |  4. Key exchange (e.g., curve25519-sha256)
  |       (Diffie-Hellman)              |     Both sides compute shared secret
  |                                     |
  |  ==== Encrypted Channel ===        |  5. Everything after this is encrypted
  |                                     |
  |  ---- Authentication ----->        |  6. User auth (publickey, password, etc.)
  |  <--- Auth success/fail ---        |
  |                                     |
  |  ---- Channel open ------->        |  7. Session established
  |  <--- Shell/exec ----------        |
```

## Phase 1: TCP Handshake

SSH begins with a standard TCP three-way handshake. If this fails (timeout
or refused), the problem is at the network/transport layer, not SSH-specific.
Diagnose with `nc -zv host 22`.

## Phase 2: Protocol Version Exchange

After TCP connects, both sides exchange SSH version strings in plaintext:

```
SSH-2.0-OpenSSH_9.7 FreeBSD-20240806
```

This is the **only plaintext data** in an SSH session. A DPI system can see
these banners and identify the connection as SSH. This is also why SSH
connections can be selectively blocked — the banner is easily fingerprinted.

## Phase 3: Algorithm Negotiation (KEXINIT)

Both sides send lists of supported algorithms for:

- **Key exchange**: how to establish a shared secret (e.g.,
  `curve25519-sha256`, `diffie-hellman-group16-sha512`)
- **Host key**: how the server proves its identity (e.g., `ssh-ed25519`,
  `rsa-sha2-512`)
- **Cipher**: symmetric encryption for the session (e.g.,
  `chacha20-poly1305@openssh.com`, `aes256-gcm@openssh.com`)
- **MAC**: message authentication code (e.g., `hmac-sha2-256-etm@openssh.com`)

They select the first algorithm from the client's list that the server also
supports.

## Phase 4: Key Exchange (Diffie-Hellman)

The key exchange is the cryptographic core of SSH. Using Diffie-Hellman (or
its elliptic curve variant), both sides independently compute a **shared
secret** without ever transmitting it:

```
Client picks random secret a, computes A = g^a mod p, sends A
Server picks random secret b, computes B = g^b mod p, sends B
Client computes shared_secret = B^a mod p
Server computes shared_secret = A^b mod p
Both arrive at the same value without revealing a or b
```

The server also signs the exchange hash with its host key, proving its
identity. The client verifies this signature against the known host key
(stored in `~/.ssh/known_hosts`).

## Phase 5: Encrypted Channel

From this point on, all communication is encrypted with the negotiated
cipher. An eavesdropper sees only encrypted bytes with no discernible
structure.

## Phase 6: User Authentication

Within the encrypted channel, the client authenticates using one of:

- **Public key authentication**: The client proves it holds the private key
  corresponding to an authorized public key. The server sends a challenge,
  the client signs it with the private key, and the server verifies the
  signature. The private key never leaves the client.

- **Password authentication**: The password is sent encrypted within the SSH
  channel (never in plaintext over the network).

- **Keyboard-interactive**: A flexible challenge-response mechanism, often
  used for two-factor authentication.

## SSH Security Properties

| Property | Mechanism |
|----------|-----------|
| Confidentiality | Symmetric encryption (AES-GCM, ChaCha20) |
| Integrity | MAC or AEAD mode |
| Server authentication | Host key signature verification |
| Client authentication | Public key / password / keyboard-interactive |
| Forward secrecy | Ephemeral Diffie-Hellman (new keys per session) |

**Forward secrecy** means that even if a server's host key is later
compromised, past recorded sessions cannot be decrypted — because the
ephemeral DH keys used for encryption are discarded after each session.

# How HTTPS / TLS Works

## TLS Overview

TLS (Transport Layer Security) provides encryption, authentication, and
integrity for application-layer protocols. HTTPS is simply HTTP running
inside a TLS tunnel. TLS sits between the transport layer (TCP) and the
application layer (HTTP).

```
┌─────────────┐
│    HTTP      │  Application layer
├─────────────┤
│    TLS       │  Security layer (encryption + authentication)
├─────────────┤
│    TCP       │  Transport layer (reliable delivery)
├─────────────┤
│    IP        │  Network layer (routing)
└─────────────┘
```

## TLS 1.2 Handshake

TLS 1.2 requires **two round trips** before application data can flow:

```
Client                                Server
  |                                     |
  |  ---- ClientHello --------->        |  Round trip 1
  |    (TLS version, cipher suites,     |
  |     random bytes, SNI extension)    |
  |                                     |
  |  <--- ServerHello ----------        |  Server picks cipher suite
  |  <--- Certificate ----------        |  Server's X.509 cert chain
  |  <--- ServerKeyExchange ----        |  Server's DH public key
  |  <--- ServerHelloDone ------        |
  |                                     |
  |  ---- ClientKeyExchange --->        |  Round trip 2
  |    (Client's DH public key)         |
  |  ---- ChangeCipherSpec ---->        |  "Switching to encryption"
  |  ---- Finished (encrypted)->        |
  |                                     |
  |  <--- ChangeCipherSpec -----        |
  |  <--- Finished (encrypted) -        |
  |                                     |
  |  ==== Encrypted HTTP data ==        |  Application data flows
```

## TLS 1.3 Handshake

TLS 1.3 reduces the handshake to **one round trip** by combining steps:

```
Client                                Server
  |                                     |
  |  ---- ClientHello --------->        |  Single round trip
  |    (TLS version, cipher suites,     |
  |     key_share extension with        |
  |     client's DH public key)         |
  |                                     |
  |  <--- ServerHello ----------        |  Server's DH public key
  |  <--- EncryptedExtensions --        |  (encrypted from here)
  |  <--- Certificate ----------        |
  |  <--- CertificateVerify ---        |
  |  <--- Finished -------------        |
  |                                     |
  |  ---- Finished ------------->       |
  |                                     |
  |  ==== Encrypted HTTP data ==        |  Application data flows
```

Key TLS 1.3 improvements:

- **1-RTT handshake** (down from 2-RTT in TLS 1.2)
- **0-RTT resumption**: returning clients can send data in the first message
  (at a small replay risk)
- **Removed insecure algorithms**: no RSA key exchange, no CBC ciphers,
  no SHA-1 — only AEAD ciphers with forward secrecy
- **Encrypted certificate**: the server certificate is encrypted (in TLS 1.2
  it was plaintext, leaking which site you're visiting)

## Key Concepts

### SNI (Server Name Indication)

SNI is a TLS extension in the ClientHello that tells the server which
hostname the client wants to reach. This is necessary because multiple HTTPS
sites can share a single IP address — the server needs to know which
certificate to present.

```
ClientHello:
  server_name: www.example.com    ← SNI (plaintext in TLS 1.2 and 1.3)
```

**Security implication**: SNI is sent in plaintext (even in TLS 1.3), which
means anyone observing the connection can see which domain you're connecting
to, even though they can't see the content. This is exploited by DPI systems
for selective blocking. ECH (Encrypted Client Hello) is an emerging extension
that encrypts the SNI, but it's not yet widely deployed.

### Certificate Chain Verification

When the server sends its certificate, the client verifies:

1. **Chain of trust**: The certificate is signed by a Certificate Authority
   (CA) that the client trusts (in its CA bundle)
2. **Domain match**: The certificate's Subject Alternative Name (SAN) matches
   the requested hostname
3. **Validity period**: The certificate hasn't expired
4. **Revocation status**: The certificate hasn't been revoked (via OCSP or CRL)

```
Root CA (trusted, pre-installed)
  └── signs Intermediate CA certificate
        └── signs Server certificate (for example.com)
```

### Forward Secrecy

Like SSH, modern TLS uses ephemeral Diffie-Hellman (ECDHE) key exchange.
The server's long-term private key is only used to **sign** the handshake
(proving server identity), not to encrypt data. Even if the server's private
key is later compromised, past recorded TLS sessions remain secure because
the ephemeral keys are discarded after each session.

### Session Resumption

TLS supports session resumption to avoid repeating the full handshake for
returning clients:

- **TLS 1.2**: Session IDs or session tickets (server sends an encrypted
  blob to the client, who presents it on the next connection)
- **TLS 1.3**: PSK (Pre-Shared Key) based resumption, supporting 0-RTT
  early data

## What's Visible to an Observer

| Data | Visible? | Notes |
|------|----------|-------|
| Destination IP | Yes | Always visible at the IP layer |
| Destination port | Yes | Usually 443 for HTTPS |
| SNI (hostname) | Yes | Plaintext in ClientHello (unless ECH) |
| HTTP URL path | No | Encrypted within TLS |
| HTTP headers | No | Encrypted within TLS |
| HTTP body | No | Encrypted within TLS |
| Certificate | TLS 1.2: Yes, TLS 1.3: No | 1.3 encrypts the cert |
| Data volume | Yes | Packet sizes are visible |
| Timing patterns | Yes | Can fingerprint application behavior |

# How DPI (Deep Packet Inspection) Works

## Overview

Deep Packet Inspection (DPI) is a network technology that examines the
**content** of packets beyond just the IP headers. While a simple firewall
only looks at source/destination IP and port (layer 3-4), DPI inspects the
application-layer payload (layer 7) to classify, filter, or modify traffic.

```
Simple firewall:    IP header → Port → Allow/Deny
DPI:                IP header → Port → Payload content → Classify → Action
```

DPI systems are deployed by ISPs, enterprises, and nation-state censorship
infrastructure. They sit inline on the network path and can inspect every
packet in real-time.

## DPI Techniques

### 1. Protocol Fingerprinting

DPI identifies protocols by their distinctive byte patterns, regardless of
which port they use:

| Protocol | Fingerprint |
|----------|------------|
| HTTP | `GET / HTTP/1.1`, `POST`, `Host:` header |
| TLS | Byte `0x16` (handshake) followed by version `0x0303` (TLS 1.2) |
| SSH | `SSH-2.0-` banner in first packet |
| BitTorrent | `0x13BitTorrent protocol` |
| DNS | Standard query format on any port |

This means running SSH on port 443 doesn't hide it — DPI can tell it's SSH
by the protocol banner, not the port number.

### 2. SNI Inspection

For TLS connections, DPI reads the SNI extension from the ClientHello to
determine which domain the user is visiting:

```
ClientHello:
  server_name: blocked-site.com   ← DPI reads this
```

This enables **domain-based blocking** without decrypting the traffic. The
DPI system can:

- Drop the connection (timeout)
- Send a TCP RST to both sides (connection reset)
- Redirect to a block page
- Return a fake DNS response (DNS poisoning)

### 3. Statistical / Behavioral Analysis

Even for encrypted traffic, DPI can analyze:

- **Packet size distribution**: Different protocols produce different
  patterns of packet sizes
- **Timing patterns**: Interactive SSH sessions have different timing than
  bulk file transfers
- **Entropy analysis**: Encrypted traffic has high entropy (~8 bits/byte);
  some proxy protocols (like early Shadowsocks) can be detected by their
  uniformly high entropy without recognizable protocol headers
- **Connection patterns**: Many short-lived connections to the same IP on
  port 443 might indicate proxy usage rather than normal web browsing

### 4. Active Probing

Some DPI systems don't just passively observe — they actively probe
suspicious servers:

```
1. DPI sees a connection to suspicious-ip:443
2. DPI initiates its own TLS connection to suspicious-ip:443
3. If the server responds with a proxy protocol (VLESS, VMess, etc.)
   instead of a normal web page, the IP is flagged and blocked
```

This is why proxy servers use **fallback mechanisms** — when they receive an
unrecognized connection, they serve a normal website (e.g., via nginx) or
proxy the TLS handshake to a legitimate site (REALITY protocol).

### 5. TLS Fingerprinting

Every TLS client produces a slightly different ClientHello based on its
implementation. DPI can fingerprint the TLS library:

- **JA3 fingerprint**: A hash of the cipher suites, extensions, and elliptic
  curves in the ClientHello. Each TLS library (Chrome, Firefox, Go's
  crypto/tls, Python requests) produces a different JA3 hash.
- **JA4 fingerprint**: An improved version of JA3 with better normalization.

If a connection claims to be from Chrome (via User-Agent or ALPN) but has a
Go crypto/tls JA3 fingerprint, DPI can flag it as a proxy. This is why tools
like Xray use **uTLS** to mimic real browser fingerprints (the `"fingerprint":
"chrome"` setting in the config).

## DPI Actions

When DPI identifies traffic it wants to block:

| Action | What the client sees | How to detect |
|--------|---------------------|---------------|
| **Silent drop** | Connection timeout | `nc` reports TIMEOUT; `mtr` shows 100% loss at specific hop |
| **TCP RST injection** | "Connection reset by peer" | `tcpdump` shows RST from unexpected source (wrong TTL) |
| **DNS poisoning** | Wrong IP returned | Compare `dig @local-dns` vs `dig @8.8.8.8` |
| **TLS ClientHello modification** | Handshake fails or hangs | Server logs show auth failure; `tcpdump` comparison between sent and received ClientHello |
| **Throttling** | Very slow connection | `mtr` shows increased latency only on certain ports/protocols |
| **Block page redirect** | HTTP 302 to a block page | `curl -v` shows unexpected redirect |

### Detecting DPI Interference

```bash
# Compare port connectivity (DPI often targets specific ports)
nc -zv server 22 -w 5      # SSH: usually allowed
nc -zv server 443 -w 5     # HTTPS: might be filtered
nc -zv server 2053 -w 5    # Non-standard: usually allowed

# Compare mtr on different ports
mtr -T -r -c 10 -P 22 server
mtr -T -r -c 10 -P 443 server

# Check for DNS poisoning
dig @114.114.114.114 example.com    # local DNS
dig @8.8.8.8 example.com            # Google DNS (may be intercepted too)
dig @1.1.1.1 example.com +tcp       # Cloudflare DNS over TCP

# Look for RST injection with tcpdump
tcpdump -i eth0 -nn 'tcp[tcpflags] & tcp-rst != 0' and host server-ip
```

## Anti-DPI Strategies

Different proxy protocols use different strategies to evade DPI:

| Strategy | Protocol | How it works |
|----------|----------|-------------|
| **Encryption without headers** | Shadowsocks | Encrypted stream with no recognizable protocol markers. Weakness: high-entropy streams without TLS headers are detectable by statistical analysis |
| **Mimicking real TLS** | Trojan | Uses real TLS certificates and standard HTTPS. DPI sees normal HTTPS traffic. Strength: can't block without breaking all HTTPS |
| **Stealing real certificates** | REALITY (Xray) | Server fetches a genuine certificate from a real website and presents it to the client. No domain/cert needed. Weakness: if DPI modifies the ClientHello, the embedded REALITY auth data is corrupted |
| **Browser fingerprint mimicry** | uTLS | Replicates exact TLS ClientHello of real browsers (Chrome, Firefox) to defeat JA3 fingerprinting |
| **CDN fronting** | WebSocket + CDN | Traffic goes through Cloudflare/AWS CloudFront. DPI only sees a connection to a major CDN — can't block without breaking millions of sites |
| **UDP-based protocols** | Hysteria2, TUIC | Uses QUIC (UDP) instead of TCP. Most DPI focuses on TCP analysis; UDP proxy protocols often bypass inspection |
| **Traffic shaping** | Various | Adds padding, fragments packets, or adjusts timing to defeat statistical analysis |

### Why Trojan is resilient against DPI

Trojan's strength comes from being genuinely indistinguishable from normal
HTTPS:

1. It uses a **real domain** with a **real TLS certificate** from Let's Encrypt
2. The TLS handshake is completely standard — nothing to modify or fingerprint
3. After the TLS handshake, Trojan sends a password; if wrong, the server
   serves a normal website (just like nginx would)
4. There is no custom protocol marker — even if DPI decrypts the first few
   bytes (which it can't without the key), it would see standard-looking data

To block Trojan, DPI would have to either:
- Block all HTTPS traffic (breaking the internet)
- Block specific IPs (easy to rotate)
- Somehow identify the server as a proxy (active probing, but Trojan's
  fallback serves a real website)

### Why REALITY can fail under DPI

REALITY is clever but has a specific vulnerability:

1. The client embeds authentication data inside the TLS ClientHello
2. This data is cryptographically derived from the client's key share
3. If a DPI system **modifies any field** in the ClientHello (even adding or
   removing a TLS extension), the authentication data becomes invalid
4. The server can't authenticate the client and treats it as a normal visitor
5. The connection falls back to the dest site instead of establishing a
   proxy tunnel

This is exactly what happens when you see `REALITY: processed invalid
connection: handshake did not complete successfully` in the server log — the
ClientHello was tampered with in transit.

# How the Trojan Protocol Works

## Design Philosophy

Most proxy protocols try to **invent** a new way to hide traffic — custom
encryption, custom headers, custom handshakes. Trojan takes the opposite
approach: instead of inventing anything, it **hides inside** standard HTTPS.
The core insight is simple — if your traffic is genuinely indistinguishable
from normal HTTPS, DPI has no choice but to allow it, because blocking it
would break the entire internet.

## Architecture

```
                           ┌───────────────────────────┐
                           │     Trojan Server          │
                           │                           │
Client ──── TLS ────────►  │  Port 443                 │
                           │    │                      │
                           │    ├─ Password correct?    │
                           │    │   YES → proxy mode ───┼──► internet
                           │    │   NO  → fallback  ────┼──► nginx (real website)
                           │    │                      │
                           └───────────────────────────┘
```

The server listens on port 443, just like any HTTPS website. It holds a
real TLS certificate from a real CA (e.g., Let's Encrypt). When a connection
arrives:

1. Standard TLS handshake completes (identical to any HTTPS site)
2. First encrypted message: client sends a password
3. If correct → connection becomes a proxy tunnel
4. If wrong → connection is silently forwarded to nginx, which serves a
   real website

## Connection Lifecycle

```
Client                              Server (port 443)
  │                                    │
  │  ──── TCP SYN ──────────────────►  │  1. Standard TCP handshake
  │  ◄─── TCP SYN-ACK ─────────────  │
  │  ──── TCP ACK ──────────────────►  │
  │                                    │
  │  ──── TLS ClientHello ──────────►  │  2. Standard TLS handshake
  │  ◄─── TLS ServerHello ─────────  │     (real cert from Let's Encrypt)
  │  ◄─── Certificate ─────────────  │
  │  ◄─── ServerHelloDone ─────────  │
  │  ──── ClientKeyExchange ────────►  │
  │  ──── Finished ─────────────────►  │
  │  ◄─── Finished ────────────────  │
  │                                    │
  │  ═══════ Encrypted Channel ══════  │
  │                                    │
  │  ──── Password + Request ───────►  │  3. First payload (inside TLS)
  │       (56 bytes SHA224 hash)       │
  │       + CRLF                       │     Server checks password:
  │       + target addr + port         │
  │       + CRLF                       │
  │       + payload data               │
  │                                    │
  │  ◄──── Proxied response ────────  │  4. If correct: proxy to target
  │                                    │     If wrong: forward to nginx
```

Steps 1 and 2 are completely standard — identical to visiting any HTTPS
website. There is nothing custom, nothing unusual, nothing for DPI to
detect. The authentication happens at step 3, which is **inside the
encrypted TLS channel** where DPI is blind.

## The Trojan Wire Format

After the TLS handshake, the first encrypted message the client sends has
this structure:

```
+-----------+---------+----------+----------+---------+
| password  |  CRLF   |  target  |  CRLF    | payload |
| (56 bytes)|  (\r\n) |  address |  (\r\n)  | (data)  |
+-----------+---------+----------+----------+---------+
```

| Field | Size | Content |
|-------|------|---------|
| Password | 56 bytes | SHA224 hash of the plaintext password, hex-encoded |
| CRLF | 2 bytes | `\r\n` delimiter |
| Command | 1 byte | `0x01` (CONNECT) or `0x03` (UDP ASSOCIATE) |
| Address type | 1 byte | `0x01` (IPv4), `0x03` (domain), `0x04` (IPv6) |
| Address | variable | The destination to proxy to |
| Port | 2 bytes | Destination port (big-endian) |
| CRLF | 2 bytes | `\r\n` delimiter |
| Payload | variable | Actual application data (e.g., the HTTP request) |

The password is hashed with SHA224, producing exactly 56 hex characters.
This fixed-length prefix makes parsing fast — the server reads exactly 56
bytes, looks up the hash, and decides immediately. The plaintext password
never crosses the wire (it's inside TLS anyway, but this provides
defense-in-depth).

## The Fallback Mechanism

The fallback is what makes Trojan undetectable by active probing. When a
DPI system or scanner connects to the server:

```
Scanner/DPI probe                    Trojan Server
  │                                    │
  │  ── TLS handshake ──────────────►  │  Handshake succeeds (real cert)
  │  ── random data / wrong password ► │
  │                                    │  Password check fails
  │  ◄── Normal website response ────  │  → forwards to nginx
  │                                    │     (serves real HTML page)
  │  "This is just a normal website"   │
```

The scanner sees:

1. A valid TLS certificate issued by Let's Encrypt
2. A real website with HTML, CSS, images
3. Standard HTTP response headers
4. No error messages, no "access denied," no proxy-like behavior

There is **zero distinguishing signal** between a Trojan server and a
regular nginx HTTPS website. The server behaves identically in both cases
from the outside.

## Where Authentication Happens: Trojan vs REALITY

The critical architectural difference between Trojan and REALITY is
**where** the authentication data lives:

```
REALITY:
  ClientHello [auth data embedded here] ──► plaintext, DPI can modify
  ───────── TLS handshake ─────────────
  ═══════ encrypted channel ═══════════

Trojan:
  ClientHello [standard, nothing special] ──► DPI sees normal HTTPS
  ───────── TLS handshake ─────────────
  ═══════ [password + request here] ═══  ──► inside encryption, DPI is blind
```

REALITY embeds authentication in the TLS ClientHello, which is sent
**before** encryption is established. This means DPI can inspect, modify,
or strip the auth data. If a DPI system changes even one field in the
ClientHello, the authentication fails.

Trojan sends authentication **after** the TLS handshake completes, inside
the encrypted channel. DPI cannot see, modify, or even detect the
authentication data. To interfere, DPI would have to break TLS itself.

## Why Trojan Beats Each DPI Technique

| DPI technique | How other protocols fail | How Trojan survives |
|---------------|------------------------|-------------------|
| Protocol fingerprinting | Shadowsocks/VMess have unique byte patterns | Trojan is standard TLS — no custom bytes visible |
| SNI inspection | All protocols expose SNI | Trojan's SNI points to a real domain with a real cert |
| TLS fingerprinting (JA3) | Custom TLS libraries have unique fingerprints | Xray uses uTLS to mimic Chrome/Firefox exactly |
| Active probing | Many proxies return errors on wrong auth | Trojan serves a real website — indistinguishable |
| ClientHello modification | REALITY auth data in ClientHello gets corrupted | Trojan auth is inside encrypted channel — untouchable |
| Statistical analysis | Some protocols have unusual packet patterns | Trojan traffic looks like normal HTTPS browsing |
| Certificate validation | Self-signed certs are suspicious | Trojan uses real Let's Encrypt certificates |

## Security Properties

| Property | Mechanism |
|----------|-----------|
| Confidentiality | Standard TLS encryption (AES-GCM, ChaCha20) |
| Authentication | SHA224 password hash inside TLS channel |
| Forward secrecy | TLS ECDHE — past sessions safe even if key leaks |
| Anti-probing | Wrong password → serve real website via fallback |
| Anti-fingerprinting | uTLS mimics real browser TLS ClientHello |

## Potential Attack Vectors

| Attack | Risk level | Description |
|--------|-----------|-------------|
| Network sniffing | None | Password is inside TLS encryption |
| TLS key compromise | Low | Forward secrecy protects past sessions |
| Fake certificate (MITM) | Low-Medium | A state actor controlling a CA could issue a forged cert and intercept TLS. Mitigated by Certificate Transparency monitoring |
| Server compromise | Medium | Attacker reads config file with password directly |
| IP-based blocking | Medium | The server IP can be blocked, but easily rotated |

The most realistic threat for Trojan is **IP-based blocking** — a censor
may not be able to identify Trojan traffic, but can block specific VPS IP
ranges. This is countered by using CDN-fronted setups (WebSocket + CDN) or
rotating server IPs.
