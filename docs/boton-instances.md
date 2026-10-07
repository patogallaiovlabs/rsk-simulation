# Boton instances — specification

Captured 2026-09-22. Both are Hetzner Cloud KVM guests.

| | **boton-01 (box A)** | **boton-02 (box B)** |
|---|---|---|
| IP | `5.161.112.81` | `91.107.194.5` |
| Hostname | `patogallaiovlabs-01` | `patogallaiovlabs-02` |
| Instance ID | `163813218` | `163820448` |
| Region / AZ | us-east / `ash-dc1` | eu-central / `fsn1-dc8` |
| **Architecture** | **x86_64** | **x86_64** |
| CPU model | AMD EPYC-Milan Processor | AMD EPYC-Milan Processor |
| CPU family / model / stepping | 25 / 1 / 1 | 25 / 1 / 1 |
| Microcode | `0x1000065` | `0x1000065` |
| vCPUs / sockets / NUMA nodes | 2 / 1 / 1 | 2 / 1 / 1 |
| Nominal clock | 2196.7 MHz | 2196.9 MHz |
| BogoMIPS | 4393.39 | 4393.79 |
| L1d / L1i | 32 KiB / 32 KiB | 32 KiB / 32 KiB |
| L2 / L3 | 512 KiB / **32 MiB** | 512 KiB / **32 MiB** |
| RAM | 7743 MB | 7743 MB |
| Virtualization | KVM, full | KVM, full |
| Kernel | 5.15.0-187-generic | 5.15.0-187-generic |
| OS | Ubuntu 22.04.5 LTS | Ubuntu 22.04.5 LTS |
| Root disk (`/`) | `sda` 76.3 G, SSD, sched `none` | `sda` 76.3 G, SSD, sched `none` |
| Data disk (`/var/lib/rsk`) | `sdb` 200 G, SSD, sched `none` | `sdb` 200 G, SSD, sched `none` |
| **JDK** | **`17.0.20+8-1~22.04`** (2026-07-21) | **`17.0.20.1+1-1~22.04`** (2026-08-18) |
| JVM | OpenJDK 64-Bit Server VM, mixed mode, sharing | same VM, newer build |

## The one difference that matters

Every hardware and OS attribute is identical — same CPU stepping, same microcode, same
32 MiB L3, same kernel, same disks, same memory. **The JDK builds differ**: box A runs
`17.0.20+8`, box B runs the later `17.0.20.1+1`.

That is a strong candidate for the box asymmetry measured in
`AA-CONTROL-INVALIDATES-RUNS.md`, where identical RSKj jars produced `txExecutionMs`
p50 of 23 ms on box A and 45 ms on box B. A JDK patch build can change JIT compilation
of hot loops substantially, and the keccak workload is exactly that — one long-running,
trie-and-hash-heavy transaction per block.

It also reframes every earlier cross-box comparison: they were partly measuring
**JVM version**, not only hardware or the RSKj build.

Note the direction is counter-intuitive — the *newer* JDK is the slower one here — so
this is a hypothesis with a good motive, not a proven cause. It is testable directly:
align the JDKs and re-run the A/A. If the 23 vs 45 ms gap collapses, it is confirmed,
and parallel (non-counterbalanced) A/B becomes usable again, which halves the cost of
every future comparison.

## Configuration differences imposed by the harness

These are ours, not the provider's, and they also differ per box:

| | box A | box B |
|---|---|---|
| `MINER_ID` | 1 | 2 |
| Coinbase secret | `miner1` | `miner2` |
| `peer.privateKey` | `…DFFFFF91` | `…DFFFFF92` |
| `peer.port` | 50501 | 50502 |

An A/A control cannot separate these from the hardware/JVM difference. If aligning the
JDKs does not close the gap, swapping the miner IDs between boxes is the next test.

## Other measured characteristics

| | box A | box B |
|---|---|---|
| Peak integer loop (best of 4) | 0.44 s | 0.44 s |
| Integer loop variance | 0.44–0.47 s | 0.44–0.57 s |
| sha256 (openssl, 16 KB) | 1,744,557 k | 1,771,951 k |
| Memory random-walk (64 MB) | 0.88 s | **0.65 s** |
| RTT from the laptop | ~175 ms | ~175 ms |

Peak CPU is identical and box B is *faster* on memory latency, so raw hardware does not
explain a stable 2× in RSKj — which is what points at the JVM rather than the silicon.
Note also that a single unrepeated sample of the integer loop suggested box B was 46 %
slower; four repetitions showed equal peaks and merely higher variance. Micro-benchmarks
here need repetition before they mean anything.
