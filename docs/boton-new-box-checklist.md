# Provisioning a replacement Boton box

Written after box B (`boton-02`) was found to be ~2× slower than box A on the
trie-write-heavy keccak workload with **identical** jars, JVM, kernel, OS, CPU stepping,
microcode, cache sizes and disks — see `boton-instances.md` and
`../results/boton/AA-CONTROL-INVALIDATES-RUNS.md`.

## Match these, or the boxes are not comparable

| | value on box A (`boton-01`) |
|---|---|
| Type | 2 vCPU, 8 GB RAM (AMD EPYC-Milan, family 25 model 1 stepping 1) |
| Root disk | 76 G SSD |
| Data volume | 200 G SSD, mounted at `/var/lib/rsk` |
| OS | Ubuntu 22.04.5 LTS, kernel 5.15.0-187-generic |
| **JDK** | **`17.0.20.1+1-1~22.04`** — pin it; a mismatch here was a real confound |
| RSKj layout | packaged: `/lib/systemd/system/rsk.service`, `/etc/sysconfig/rsk`, `/etc/rsk/`, `/usr/share/rsk/rsk.jar`, `/var/log/rsk`, service user `rsk` |
| Access | `~/.ssh/rskj-automation.pub` in `ubuntu`'s `authorized_keys`; passwordless sudo |
| **k6** | **pin to match the other box** — a fresh install pulled 2.3.0 while the existing box had 2.2.0. k6 *generates* the workload, so a version gap changes what the node is asked to do |
| **node** | match (v20.20.2) |
| Kernel | match if you can; box A 5.15.0-187 vs box C 5.15.0-190 was left unaligned deliberately, since box A could only move to 191 and create a new gap |
| Firewall | inbound 22 from your network (nothing else is needed — k6 runs on the box) |

**Consider placing it in the same region/AZ as box A (us-east / `ash-dc1`).** Box B was
eu-central; co-locating removes one more uncontrolled variable, since whatever differs
between these hosts is not visible from inside the guest.

## Wire it in

```bash
cp docs/boton/hosts.env.example docs/boton/hosts.env   # if not already present
$EDITOR docs/boton/hosts.env                           # set BOTON_HOST_B=<new ip>
scripts/boton/boton-ssh.sh --host <new ip> 'uptime; nproc; java -version'
```

`run-experiment.sh` and `collect-experiment.sh` read `BOTON_HOST_A`/`BOTON_HOST_B` from
that file, so nothing else needs editing.

Then push the helper scripts the box needs:

```bash
scripts/boton/boton-ssh.sh --host <new ip> --push scripts/boton/remote/k6-setup.sh /tmp/
scripts/boton/boton-ssh.sh --host <new ip> 'bash /tmp/k6-setup.sh'     # node 20 + k6
scripts/boton/boton-ssh.sh --host <new ip> --push scripts/boton/remote/sample-resources.sh /tmp/
scripts/boton/boton-ssh.sh --host <new ip> --push nmt/analyze_block_breakdown.py /tmp/
```

## THE FIRST RUN MUST BE AN A/A — do not skip this

```bash
BOTON_JAR_TIP=rsk-baseline.jar \
  scripts/boton/run-experiment.sh AA-newbox 2 40m "RATE=1 TIME_UNIT=12s PRE_VUS=5" --lean
scripts/boton/collect-experiment.sh AA-newbox 0.85 20
```

Identical jar on both boxes. Read `txExecutionMs` p50:

- **Within a few percent** → the boxes are interchangeable for this workload and plain
  parallel A/B is valid again (~1 slot per comparison instead of 2).
- **Still a large gap** → the boxes remain non-interchangeable. Counterbalance
  everything (`CROSSOVER-keccak-CORRECTED.md` has the design), and run one more A/A with
  the `MINER_ID`s swapped between boxes to find out whether the cause is our own
  configuration rather than the host.

Reference figures from box A, JDK-aligned, this exact configuration:
**`txExecutionMs` p50 ≈ 24 ms, mean ≈ 29 ms.** Box B measured 43 ms.

An A/A is ~55 minutes and it decides whether every subsequent comparison costs one slot
or two. It is the cheapest hour in this whole setup — a day of work was lost to not
having run one.

## Replacing the box did NOT fix the asymmetry

Box B was destroyed and replaced by box C — different kernel, different disk size,
different host — with JDK, k6, node, CPU stepping, microcode, cache and RAM all verified
identical to box A. Box C measured `txExecutionMs` p50 **44 ms** against box A's
**24 ms**: the same figure the box it replaced produced.

So the cause is not the instance. The only thing that travelled across the rebuild is the
harness's own role assignment — box B/C runs `MINER_ID=2` (different coinbase secret,
peer private key, peer port). That is now the prime suspect, and it is testable:

```bash
BOTON_MINER_A=2 BOTON_MINER_B=1 BOTON_JAR_TIP=rsk-baseline.jar \
  scripts/boton/run-experiment.sh AA-minerswap 2 40m "RATE=1 TIME_UNIT=12s PRE_VUS=5" --lean
```

If the ~44 ms follows `MINER_ID=2` over to box A, the asymmetry is ours and fixable.

## Don't assume a fresh box is "clean"

Everything measurable said these two boxes were identical, and they were not. Treat the
A/A result as the only evidence that matters, and re-run it if a box is ever rebuilt,
resized or migrated.
