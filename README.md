# CacheTrace - Cycle-Accurate Cache Simulator

A cycle-accurate CPU cache hierarchy simulator using real, reverse-engineered Intel replacement policies from uops.info research.


CacheTrace simulates the full L1-> L2 -> L3 cache hierarchy with actual Intel cache replacement policies (QLRU, PLRU, MRU), showing you exactly what happens for each memory access:
- Hit or miss at each cache level
- Which blocks get evicted and why
- Precise cycle costs per access
- Total execution time estimate

Unlike existing tools that assume all cache hits or only give aggregate stats, CacheTrace provides deterministic, per-access simulation.

## Features

- **Runtime CPU Selection** - `--cpu=nehalem|snb|ivb|hsw|skl|cfl`
- **6 Intel CPUs Supported** - Nehalem (2008) through Coffee Lake (2017)
- **Accurate Replacement Policies** - Tree-PLRU (L1), QLRU variants (L2/L3), MRU/MRU_N (older L3)
- **Detailed Output** - CSV format with per-access results
- **Statistics Summary** - Hit rates, total cycles, average latency
- **Pure Assembly** - No external dependencies, static binary (~8KB)
- **Fast** - Buffered I/O for 100x+ speedup

## Supported CPUs

| CPU | Short | Full | Year | L3 Policy |
|-----|-------|------|------|-----------|
| Nehalem | `nhm` | `nehalem` | 2008 | MRU |
| Sandy Bridge | `snb` | `sandybridge` | 2011 | MRU_N |
| Ivy Bridge | `ivb` | `ivybridge` | 2012 | QLRU_H11_M1_R1_U2 |
| Haswell | `hsw` | `haswell` | 2013 | QLRU_H11_M1_R1_U2 |
| Skylake | `skl` | `skylake` | 2015 | QLRU_H11_M1_R1_U2 |
| Coffee Lake | `cfl` | `coffeelake` | 2017 | QLRU_H11_M1_R0_U0 (default) |

**Note:** Invalid `--cpu` arguments silently fall back to Coffee Lake.

## Building

### Prerequisites
- NASM 
- Linux x86-64 system
- GNU ld 

### Build Steps

```bash

nasm -f elf64 cachetrace.asm -o cachetrace.o && ld cachetrace.o -o cachetrace
```

## Usage

### Input Format

CacheTrace reads memory access traces from stdin:
```
R 0xADDRESS    # Read access
W 0xADDRESS    # Write access
```

Example trace file:
```
R 0x1000
R 0x2000
R 0x1000
W 0x3000
```

### Basic Usage

```bash
# Default (Coffee Lake)
./cachetrace < trace.txt

# Select CPU
./cachetrace --cpu=nehalem < trace.txt
./cachetrace --cpu=ivb < trace.txt
./cachetrace --cpu=cfl < trace.txt

# Save output to CSV
./cachetrace --cpu=skylake < trace.txt > results.csv

# Quick test
echo "R 0x1000" | ./cachetrace --cpu=cfl
```

### Compare CPUs

```bash
for cpu in nhm snb ivb cfl; do
  echo "=== $cpu ==="
  ./cachetrace --cpu=$cpu < trace.txt | tail -3
done
```

## Output Format

CacheTrace outputs a banner, CSV data, and statistics summary. The CSV portion has this format:
```
address,L1_result,L1_cycles,L2_result,L2_cycles,L3_result,L3_cycles,total_cycles
```

Full output example:
```
CacheTrace - Cycle-Accurate Cache Simulator
 CPU: Coffee Lake
L1: 64 sets x 8-way, 4 cycles
L2: 512 sets x 8-way, 12 cycles
L3: 2048 sets x 16-way, 42 cycles
address,L1_result,L1_cycles,L2_result,L2_cycles,L3_result,L3_cycles,total_cycles
0x0000000000001000,MISS,0,MISS,0,MISS,0,200
0x0000000000002000,MISS,0,MISS,0,MISS,0,200
0x0000000000001000,HIT,4,-,0,-,0,4

=== Statistics Summary ===
Total accesses:     3
L1 hits:            1
L1 misses:          2
L1 hit rate:        33%
L2 hits:            0
L2 misses:          2
L2 hit rate:        0%
L3 hits:            0
L3 misses:          2
L3 hit rate:        0%
Total cycles:       404
Avg cycles/access:  134
```

Output includes banner/stats lines and some lines may be prefixed with NUL bytes. For CSV processing, filter lines starting with `0x`.

### Understanding the Output

- `HIT` = Cache hit at this level
- `MISS` = Cache miss, had to go to next level
- `-` = Not accessed (hit at higher level)

### Cycle Counting Model

Total cycles = effective latency at the level that satisfies the request:
- L1 HIT: 4 cycles
- L2 HIT: 12 cycles (includes L1 miss overhead)
- L3 HIT: 42 cycles (includes L1+L2 miss overhead)
- Memory: 200 cycles (includes all cache miss overhead)

Misses contribute 0 cycles (lookup overhead is absorbed into the hit level latency).

**Example:**
- L1 miss -> L2 hit: `MISS,0,HIT,12,-,0,12` (12 total)
- L1 hit: `HIT,4,-,0,-,0,4` (4 total)
- All miss -> memory: `MISS,0,MISS,0,MISS,0,200` (200 total)

## Cache Configuration

**Default: Coffee Lake**

| Level | Size   | Associativity | Sets | Latency | Policy            |
|-------|--------|---------------|------|---------|-------------------|
| L1    | 32 KB  | 8-way         | 64   | 4 cyc   | Tree-PLRU         |
| L2    | 256 KB | 8-way         | 512  | 12 cyc  | QLRU_H00_M1_R2_U1 |
| L3    | 2 MB   | 16-way        | 2048 | 42 cyc  | QLRU_H11_M1_R0_U0 |

### Understanding Tree-PLRU (L1)

PLRU (Pseudo-LRU) uses a binary tree of bits to approximate LRU without tracking full ordering.

For 8-way cache:
- Tree has 7 bits (1 root + 2 internal + 4 leaf)
- Each bit points to "not recently used" subtree
- Much faster than true LRU (no shifting required)

### Understanding QLRU Policies

QLRU (Quad-age LRU) gives each cache block a 2-bit age (0-3). Configured by:

**QLRU_H11_M1_R0_U0** (Coffee Lake L3):
- **H11**: On hit, ages 3→1, 2→1, 1→0, 0→0
- **M1**: New blocks get age 1
- **R0**: Replace first block with age 3
- **U0**: Add (3 - max_age) to all blocks after access

**QLRU_H00_M1_R2_U1** (Coffee Lake L2):
- **H00**: On hit, reset age to 0
- **M1**: New blocks get age 1
- **R2**: Replace last block with age 3
- **U1**: Add (3 - max_age_except_replaced) to all except replaced block

## Testing

### Test 1: Basic Functionality

```bash
cat > test1.txt << 'EOF'
R 0x1000
R 0x2000
R 0x1000
EOF

./cachetrace < test1.txt
```

Expected output:
```
0x0000000000001000,MISS,0,MISS,0,MISS,0,200  # Cold miss - all levels
0x0000000000002000,MISS,0,MISS,0,MISS,0,200  # Cold miss
0x0000000000001000,HIT,4,-,0,-,0,4           # Hit in L1!
```

### Test 2: Cache Thrashing

```bash
cat > thrash_test.txt << 'EOF'
R 0x1000
R 0x2000
R 0x3000
R 0x4000
R 0x5000
R 0x6000
R 0x7000
R 0x8000
R 0x9000
R 0x1000
EOF

./cachetrace < thrash_test.txt
```

Expected behavior:
- First 8 accesses: Fill L1 (8-way cache)
- 9th access (0x9000): Evicts oldest block from L1
- 10th access (0x1000): MISS at L1, HIT at L2

## Validation

CacheTrace has been validated against hardware performance counters on Intel Coffee Lake:

**Synthetic Benchmarks:**
- 8KB workload: 98% L1 hits (matches hardware trend)
- 128KB workload: 95% L2 hits (matches hardware trend)
- 1MB workload: 88% L3 hits (matches hardware trend)

**Real Applications:**
- xxHash (128KB): 94% L1 hits
- jq JSON parser (2KB input): 99% L1 hits

**Key Result:** CacheTrace correctly predicts which cache level serves accesses as working set size increases, validating the replacement policy implementations.

See **[BENCHMARKS.md](BENCHMARKS.md)** for detailed validation results, methodology, and comparison with perf counters.

## CSV Analysis

Process output with standard tools. Strip NUL bytes with `tr -d '\0'` first, then use `grep` to extract only CSV data lines (starting with `0x`):

```bash
# Count hits vs misses at L1
./cachetrace < trace.txt | tr -d '\0' | grep '^0x' | awk -F, '{print $2}' | sort | uniq -c

# Average cycles per access
./cachetrace < trace.txt | tr -d '\0' | grep '^0x' | awk -F, '{sum+=$8; n++} END {print sum/n}'

# Total simulated time
./cachetrace < trace.txt | tr -d '\0' | grep '^0x' | awk -F, '{sum+=$8} END {print sum " cycles"}'

# Extract pure CSV (no banner or stats)
./cachetrace < trace.txt | tr -d '\0' | grep '^0x' > results.csv
```

## Architecture

Written in pure x86-64 assembly (NASM) for:
- **Speed**: Simulate billions of accesses efficiently
- **Precision**: Exact behavior, no interpreter overhead
- **Portability**: Single binary, no libc or shared library dependencies

Uses direct Linux syscalls (`read`, `write`, `exit`) with no external userspace libraries.

## Troubleshooting

### Build Errors

**"nasm: not found"**
```bash
sudo apt install nasm
```

**"ld: unrecognized option"**
- Make sure you're using GNU ld, not LLVM's lld
- On Ubuntu/Debian: `sudo apt install binutils`

### Runtime Issues

**No output or crashes:**
- Check trace format: must be `R 0xADDRESS` or `W 0xADDRESS`
- Addresses must be hex (with or without 0x prefix)

**CSV processing fails or shows unexpected data:**
- Output includes banner and statistics lines, not pure CSV
- Some lines have NUL byte prefixes that cause `grep` to treat output as binary
- Solution: Strip NUL bytes first with `tr -d '\0'`, then filter with `grep '^0x'`
- Example: `./cachetrace < trace.txt | tr -d '\0' | grep '^0x' > clean.csv`

**Unexpected results:**
- Verify addresses map to same cache set (use lower bits)
- Remember: different addresses can map to different cache sets

## Implementation Details

For detailed technical documentation on cache replacement policies, cycle counting models, and development history, see the source code comments in `cachetrace.asm`.

## References

- [uops.info](https://uops.info/cache.html) - Cache configurations and policies
- [nanoBench](https://github.com/andreas-abel/nanoBench) - Reference implementation
- [nanoBench Paper](https://arxiv.org/pdf/1911.03282) - Reverse-engineering methodology


