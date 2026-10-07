# Running RSKj experiments on a Boton instance

**Boton instance** = one of the rented Hetzner Cloud VMs used for RSKj measurements,
reached as `ubuntu@<ip>`. They do **not** run Docker. Each has the packaged RSKj Debian
layout — a systemd unit running a fat jar — and an experiment is deployed by replacing
that jar and its config.

Everything below was executed end to end on 2026-09-18, deploying two builds to two boxes
and running the k6 mainnet-simulation load against each.

## The boxes

| | boton-01 | boton-02 |
|---|---|---|
| Host / instance | `patogallaiovlabs-01` / `163813218` | `patogallaiovlabs-02` / `163820448` |
| IP | `5.161.112.81` | `91.107.194.5` |
| Region | us-east (ash-dc1) | eu-central (fsn1-dc8) |
| CPU / RAM | AMD EPYC-Milan, 2 cores @2196 MHz, 8 GB | identical |
| Disks | `/` 75 G, `/var/lib/rsk` 196 G (separate volume) | identical |
| Java | OpenJDK 17 at `/usr/bin/java` | identical |

Identical hardware is what makes a two-box A/B comparison meaningful. Confirm it with
`grep -m1 "model name" /proc/cpuinfo` before trusting any cross-box number.

## The packaged layout

```
/lib/systemd/system/rsk.service   ExecStart=/usr/bin/java $JAVA_OPTS -cp /usr/share/rsk/rsk.jar $RSKJ_CLASS $RSKJ_OPTS
                                  User=rsk   LimitNOFILE=500000   EnvironmentFile=-/etc/sysconfig/rsk
/etc/sysconfig/rsk                JAVA_OPTS, RSKJ_CLASS=co.rsk.Start, RSKJ_OPTS (--main | --regtest)
/etc/rsk/*.conf                   config overlay, selected with -Drsk.conf.file
/usr/share/rsk/rsk.jar            the jar (~90 MB fat jar)
/var/lib/rsk/database             database
/var/log/rsk/                     logs
```

**The unit file is never edited.** Every change goes through `/etc/sysconfig/rsk` and the
`.conf` overlay. Deploys keep timestamped `.bak-<stamp>` copies of the jar and sysconfig,
so rolling back is a copy and a restart.

## Access

```bash
ssh -i ~/.ssh/rskj-automation -o IdentitiesOnly=yes -o BatchMode=yes ubuntu@<ip>
```

Passwordless key, so unattended runs work; revoke by deleting its line from the box's
`~/.ssh/authorized_keys`. `BatchMode=yes` everywhere in automation — a prompt on a headless
run is a hang. Put the current IPs in `docs/boton/hosts.env` (gitignored;
see `hosts.env.example`) and use `scripts/boton/boton-ssh.sh`.

> **zsh gotcha.** `O="-i key -o BatchMode=yes"; ssh $O host` does **not** word-split in zsh —
> the whole string becomes one argument and ssh reports a missing identity file. Inside the
> `scripts/boton/*.sh` files this is a non-issue (they are `#!/usr/bin/env bash` and use
> arrays), but it will bite you when typing ad-hoc commands in the terminal.

## The network constraint — read before planning anything

A **Hetzner Cloud Firewall** fronts these boxes and allows **only port 22, only from your
network**. There is no host firewall to blame or fix: `ufw` is inactive, iptables `INPUT`
policy is ACCEPT with zero rules, nftables is empty. Outbound is unrestricted. Consequences:

- The two boxes **cannot reach each other on any port** — not even 22. There is no private
  network either; each box is a bare public `/32`.
- **k6 cannot reach a node's RPC from your laptop**, so the load generator runs *on the box*.
- Peering the two nodes requires opening the firewall (see the last section).

Running the load on-box is not merely a workaround — it is better. From a laptop the RTT to
these boxes is ~175 ms, which caps per-VU throughput (10 VUs ≈ 57 tx/s against the ~119 tx/s
needed to fill a 25 M-gas block every 10 s) and makes the numbers incomparable to a local
docker run. On-box the RPC hop is loopback.

The cost is that k6 competes with the node for 2 cores. That is acceptable **because it is
identical on both boxes**, but it means Boton numbers compare to other Boton numbers, never
to laptop runs.

## 1. Build the jar locally — no Docker

`CLAUDE.md` used to say there is no local JVM and changes must be compiled via the Docker
image. That is no longer true: this machine has JDK 17, rskj targets Java 17, and
`:rskj-core:fatJar` produces exactly the artifact the box needs in **~20 seconds**.

```bash
scripts/boton/build-jar.sh ri_fixleak /tmp/rsk-tip.jar
scripts/boton/build-jar.sh 47a2eb63a  /tmp/rsk-baseline.jar
```

The script picks JDK 17 via `/usr/libexec/java_home -v 17`, builds the current checkout in
place when the ref is already HEAD, and otherwise uses a throwaway git worktree so your
working copy and its uncommitted changes are untouched. Two things it handles that will
break a hand-rolled build:

- **`gradle-wrapper.jar` is untracked**, so a fresh worktree has no wrapper and gradle dies
  with `ClassNotFoundException: GradleWrapperMain`. It copies the wrapper in.
- **The `mavenLocal()` content filter in `rskj-core/build.gradle` is an uncommitted local
  fix.** Without it, dependency verification fails on unrelated `~/.m2` artifacts served as
  bare `.pom` files. It applies the same patch to the worktree.

It then asserts the jar carries `linux/amd64/libbn128.so` and `librocksdbjni-linux64.so`.
If those are missing the box silently falls back to Bouncy Castle / `JavaAltBN128`, which
changes throughput without any error. (`Main-Class` in the manifest is malformed — harmless,
because the unit launches with `-cp` plus an explicit `co.rsk.Start`.)

Verify two builds really differ before trusting an A/B — same version string, different code:

```bash
unzip -p /tmp/rsk-tip.jar co/rsk/metrics/BlockProcessingStatsMBean.class | strings | grep -c getPreambleMs
```

## 2. Deploy a node

```bash
scripts/boton/deploy-node.sh 5.161.112.81 1 /tmp/rsk-baseline.jar
scripts/boton/deploy-node.sh 91.107.194.5 2 /tmp/rsk-tip.jar
```

`<miner-id>` selects the deterministic peer key, coinbase and peer port (`5050<id>`) used by
the local docker miners, so a Boton node is configured like `rskj-miner<id>`. The script
stages the config, pushes jar + config, and runs `remote/install.sh`, which stops the
service, backs up the old jar and sysconfig, **wipes the database**, installs, and starts.

Config comes from `rsk/rsk.conf` via `scripts/boton/make-node-conf.sh`, so consensus rules
and caches match the local sim — `rskip144 = -1`, `rskip97 = 0`, the cache sizes. Only what
must differ on a cloud box is rewritten: database path, RPC `hosts = ["*"]`, 25 M gas, and
the peer list. JVM flags in `templates/sysconfig-rsk.tmpl` mirror `rsk/Dockerfile`'s
entrypoint (`medianBlockTime=10s`, `skipPowValidation`, `flushNumberOfBlocks=10`,
`-Xms4G -Xmx4G` on the 8 GB box).

By default the node is **isolated** (`peer.active = []`, discovery off) — the right shape for
independent per-box experiments. Pass an `enode://` URL as a 4th argument to dial a peer.

Confirm the intended build is live (never assume — the unit could have failed and left the
old jar running):

```bash
scripts/boton/boton-ssh.sh --host 5.161.112.81 'systemctl is-active rsk; sudo grep -m1 git.hash /var/log/rsk/stress/rsk.log'
```

## 3. Run the load

```bash
scripts/boton/run-load.sh 5.161.112.81 14      # 14 = Real-World Mainnet Simulation
scripts/boton/run-load.sh 91.107.194.5 14
```

Ships the k6 suite (~250 KB without `node_modules`), runs `npm install` on the box, and
starts `infinite.sh` detached with `setsid nohup` so it survives the SSH session. The suite's
`resolve-rpc-urls.js` probes and finds only `http://localhost:4444`, so no config change is
needed for a single-node box.

`infinite.sh` **never terminates** — it loops the scenario until killed. Option 14's stage is
1 hour, which makes a convenient fixed comparison window.

Scenarios worth knowing for A/B work:

- **14 — mainnet simulation.** Mixed ERC20/storage/calldata write load. The general-purpose default.
- **2 — keccak random writes.** Random-key SSTORE defeats trie locality; the load that actually
  pressures the trie write path when `statePersistMs` barely moves under 14.
- **7 — cpu:ecdsa.** ECRECOVER-bound and untouched by the storage/receipt optimizations, so it
  works as a **negative control**: a build that also "wins" here is a sign the measurement is
  contaminated (asymmetric log I/O, noisy neighbour) rather than genuinely faster.
- **16 — indexer read.** `eth_getLogs` over historical ranges plus cold receipt and
  block-by-hash lookups, run concurrently with writes. The only scenario exercising the
  *read* path — bloom filters, true-negative block lookups, cache-populate-on-load. Note its
  results are measured client-side: `block-breakdown.log` only covers block connect, so a read
  workload does not appear there at all.

Verify the run is real, not just started. Both of these matter:

```bash
# blocks are actually full -- gasUsed/gasLimit should be ~98-99%
scripts/boton/boton-ssh.sh --host <ip> 'curl -s -X POST http://127.0.0.1:4444 \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"latest\",false],\"id\":1}" \
  | jq -r "\"gasUsed=\(.result.gasUsed) gasLimit=\(.result.gasLimit)\""'
```

> **A slow node looks exactly like a stuck k6.** The scenario's `setup()` deploys contracts
> and waits on receipts, so if the node mines slowly, k6 sits in `setup()` with near-zero
> load for minutes. Check the node's block height before concluding k6 is broken.

## 4. Collect and compare

The metrics come from the logs, not JMX. `rsk/logback.xml` already wires a dedicated
`BLOCK-BREAKDOWN` appender (`blockexecutor.breakdown`, `blockchain`, `state`, `triestore` at
DEBUG) writing `/var/log/rsk/stress/block-breakdown.log`, and those lines are exactly what
`nmt/analyze_block_breakdown.py` parses:

```
block execute breakdown pre-RSKIP144: block=42 hash=... totalMs=3 txExecutionMs=3 statePersistMs=0 ...
block persistence step: block=42 ... action=commit durationMs=0 txCount=1 gasUsed=0
```

(`pre-RSKIP144` in that marker is also a free confirmation that `rskip144 = -1` took effect.)

```bash
scripts/boton/collect.sh 5.161.112.81 baseline
scripts/boton/collect.sh 91.107.194.5 tip

python3 nmt/analyze_block_breakdown.py --label tip \
  --baseline results/boton/baseline_summary.json results/boton/tip/block-breakdown.log*
```

Compare only metrics both builds emit. Commit 18 (`b4a13038d`) added `preambleMs`,
`postExecuteValidationMs` and `processBestMs`, so a pre-commit-18 baseline has no
counterpart for them.

## 5. Restore the box

```bash
scripts/boton/boton-ssh.sh --host <ip> '
  sudo systemctl stop rsk
  sudo cp -a /usr/share/rsk/rsk.jar.bak-<stamp> /usr/share/rsk/rsk.jar
  sudo cp -a /etc/sysconfig/rsk.bak-<stamp>     /etc/sysconfig/rsk
  sudo systemctl start rsk'
```

A mainnet node restored this way resyncs from whatever database is left. If the mainnet
database was wiped for the experiment, it resyncs from scratch — days of work. Check what
the box was doing before you take it.

## Optional: peering two Boton nodes

Only worth it if you want both builds validating the *same* blocks rather than running
independent chains. It needs firewall rules, which live in the Hetzner console/API — nothing
on the box can grant them.

| On | Protocol | Port | Source |
|---|---|---|---|
| boton-01 | TCP + UDP | 50501 | `91.107.194.5/32` |
| boton-02 | TCP + UDP | 50502 | `5.161.112.81/32` |
| both | TCP | 4444 | your laptop IP, only if driving k6 remotely |

Console → project → server → **Firewalls** tab → the attached firewall → **Rules** →
**Inbound** → add each row with **Source IPs** set to the `/32`, not "Any IPv4". Applies in
seconds, no reboot. **Leave the existing SSH rule alone** — it is source-restricted, which is
why the boxes cannot SSH to each other, and it is the only way in.

Or: `brew install hcloud`, then

```bash
hcloud firewall add-rule <name> --direction in --protocol tcp --port 50501 --source-ips 91.107.194.5/32
```

Then redeploy each node with the other's enode as the 4th argument to `deploy-node.sh`. The
node IDs for miner-ids 1 and 2 are the ones already in `rsk/rsk.conf`'s `peer.active`. One
dialled direction is enough — RLPx carries blocks both ways. Wipe both databases first so
they build one chain from a common genesis instead of reconciling two forks.
