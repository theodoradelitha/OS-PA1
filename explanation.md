Jadi flownya: 
1. System specification
2. Testing & Collecting the data
3. Process the data
4. Print out the benchmark 

19 Sept 15.26
Yg baru i bikin:
Testing -> all funct. except the disk random read
collecting the data -> udah i bikin run repeated, dimasukkin ke array

# CPU Benchmarks & Overhead Analysis
- **Bash Integer Throughput**: Bash is an interpreted language, meaning our arithmetic loop (`(( i++ ))`) must be parsed and evaluated line-by-line in real-time rather than executing as compiled machine code. This results in significantly lower operations per second compared to a compiled C benchmark.
- **Fork Cost**: The lowest throughput number is the fork cost. Every time we call `$(date)`, the system must execute a fork/exec routine. This requires an expensive context switch from user mode to kernel mode, allocating new memory space, spinning up a new process, and passing the result back.
- **Awk Throughput**: `awk` operates orders of magnitude faster than Bash loops or forks because the `awk` binary is pre-compiled C code optimised for stream processing. While Bash forks a new process for every external command, `awk` reads millions of lines within a single process space, entirely avoiding the kernel-mode context switching penalty.