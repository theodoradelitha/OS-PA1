Jadi flownya: 
1. System specification
2. Testing & Collecting the data
3. Process the data
4. Print out the benchmark 

19 Sept 15.26
Yg baru i bikin:
Testing -> all funct. except the disk random read
collecting the data -> udah i bikin run repeated, dimasukkin ke array

# Hardware Inventory & System Benchmark Reporter

## How to Run the Tool
The script requires no external dependencies and runs natively in Bash. Ensure it is executable before running:
`chmod +x sysbench.sh`

**Profiles & Arguments:**
*   `./sysbench.sh --quick` : Runs a fast benchmark (50MB test file, 2 repetitions) for rapid testing.
*   `./sysbench.sh --full` : Runs the complete benchmark suite (1000MB test file, 5 repetitions).
*   `./sysbench.sh --size 100M` : Overrides the default test file size. (Will refuse to run if it exceeds free disk space).

## Work Division
*   **Member 1 (Delitha Theodora/2506553585):** Script architecture, argument parser, CPU benchmark implementation, memory bandwidth implementation, and CPU/Memory documentation.
*   **Member 2 (Gavrila Sarah Kartika Suoth/2506559071):** Disk read/write/random benchmarks, hardware inventory (`collect_inventory`), median calculation/scorecard formatting, CSV export, and Disk documentation.

## CPU Benchmarks & Overhead Analysis
*   **Bash Integer Throughput**: Bash is an interpreted language, meaning our arithmetic loop (`(( i++ ))`) must be parsed and evaluated line-by-line in real-time rather than executing as compiled machine code. This results in significantly lower operations per second compared to a compiled C benchmark.
*   **Fork Cost**: The lowest throughput number is the fork cost. Every time we call `$(date)`, the system must execute a fork/exec routine. This requires an expensive context switch from user mode to kernel mode, allocating new memory space, spinning up a new process, and passing the result back.
*   **Awk Throughput**: `awk` operates orders of magnitude faster than Bash loops or forks because the `awk` binary is pre-compiled C code optimised for stream processing. While Bash forks a new process for every external command, `awk` reads millions of lines within a single process space, entirely avoiding the kernel-mode context switching penalty.

## Memory Bandwidth Analysis
*   **Targeting tmpfs**: To measure memory throughput, we wrote to `/dev/shm/memtest.bin`. Because `/dev/shm` is a `tmpfs` mount (a RAM disk), writing to it accurately measures physical RAM allocation and transfer speeds. If we had simply used `dd if=/dev/zero of=/dev/null`, we would only be measuring the speed of the Linux pipe and the `dd` copy loop.
*   **In-Cache vs. Out-of-Cache**: The CPU pulls data from the storage hierarchy in chunks. When our working set size (256K) fits entirely within the L2/L3 CPU cache, the processor can execute the read/write operations instantly using ultra-fast on-die SRAM. When we force a working set size of 1GB, it heavily exceeds the cache capacity read from `/sys/devices/system/cpu/cpu0/cache/`. This forces the CPU to constantly fetch and flush data to the physical RAM sticks on the motherboard, drastically lowering the measured bandwidth.

## Disk & Storage Analysis
[Member 2 to insert disk flush, page cache, and sequential vs random theory here]