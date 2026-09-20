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
*   **Buffered Disk Write**: In this test, `dd` writes the test file without immediately forcing the data to the physical disk. The operating system can temporarily store the data in the page cache, so the measured speed mainly shows how quickly the system can handle buffered writes.
*   **Flush Disk Write**:In this test, `conv=fdatasync` makes `dd` wait until the written data is synchronized with the storage device. Because the operation has to wait for the disk, the result also includes the actual cost of writing the data to storage.
*   **Warm Disk Read**: The file is read using `4K` blocks while still allowing the page cache to be used. If the data is already stored in the cache, the operating system can read it directly from memory instead of accessing the disk, making the read significantly faster.
*   **Cold Disk Read**: The `iflag=direct` option bypasses the page cache, so the data has to be read directly from the storage device. This gives a better view of the disk's read performance without relying on previously cached data.
*   **Random 4K Read**: This benchmark reads `4K` blocks from randomly selected locations in the file and measures the result in IOPS (Input/Output Operations Per Second). Random access is slower than sequential access because the storage system cannot process the data in one continuous stream. In this implementation, each read also starts a new dd process, adding process-creation overhead to the measurement.

