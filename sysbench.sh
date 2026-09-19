#!/usr/bin/env bash

set -euo pipefail

cleanup() {
    #clean up temp files on exit or interrupt
    if [[ -n "${TEST_FILE:-}" ]] && [[ -f "$TEST_FILE" ]]; then
        rm -f "$TEST_FILE"
    fi
    if [[ -f "awk_test_data.txt" ]]; then
        rm -f "awk_test_data.txt"
    fi
    if [[ -f "/dev/shm/memtest.bin" ]]; then
        rm -f "/dev/shm/memtest.bin"
    fi
}

benchmark_cpu() {
    local start end elapsed

    # -- 1. CPU Integer Throughput (Bash arithmetic) --
    local int_iters=1000000
    start=$(date +%s.%N)
    local i=0
    while (( i++ < int_iters )); do :; done
    end=$(date +%s.%N)

    elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN {print e-s}')
    local int_ops=$(awk -v i="$int_iters" -v e="$elapsed" 'BEGIN {printf "%d", i / e}')
    CPU_INT_RESULTS+=("$int_ops")

    # -- 2. Fork Cost (Subshell spawn) --
    local fork_iters=1000
    start=$(date +%s.%N)
    local j=0
    while (( j++ < fork_iters )); do _=$(date +%s > /dev/null); done
    end=$(date +%s.%N)

    elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN {print e - s}')
    local fork_ops=$(awk -v i="$fork_iters" -v e="$elapsed" 'BEGIN {printf "%d", i/e}')
    CPU_FORK_RESULTS+=("$fork_ops")

    # -- 3. Awk Throughput --
    local awk_file="awk_test_data.txt"
    seq 1 5000000 > "$awk_file"

    start=$(date +%s.%N)
    awk '{s+=$1} END {print s}' "$awk_file" > /dev/null
    end=$(date +%s.%N)

    elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN {print e-s}')
    local awk_ops=$(awk -v i="5000000" -v e="$elapsed" 'BEGIN {printf "%d", i / e}')
    CPU_AWK_RESULTS+=("$awk_ops")

    rm -f "$awk_file"
}

benchmark_memory() {
    local in_cache_result
    local in_cache_speed
    local out_cache_result
    local out_cache_speed
    local l3_cache="Unknown"

    #read the cache size from sysfs 
    if [[ -f /sys/devices/system/cpu/cpu0/cache/index3/size ]]; then
        l3_cache=$(cat /sys/devices/system/cpu/cpu0/cache/index3/size)
    fi
    echo "  (Detected L3 Cache size: $l3_cache)"

    # -- 1. In-cache memory --
    in_cache_result=$(dd if=/dev/zero of=/dev/shm/memtest.bin bs=256K count=20000 2>&1)
    in_cache_speed=$(echo "$in_cache_result" | tail -1 | awk '{print $(NF-1)}')
    MEM_IN_CACHE_RESULTS+=("$in_cache_speed")

    # -- 2. Out-of-cache memory --
    out_cache_result=$(dd if=/dev/zero of=/dev/shm/memtest.bin bs=1G count=2 2>&1)
    out_cache_speed=$(echo "$out_cache_result" | tail -1 | awk '{print $(NF-1)}')
    MEM_OUT_CACHE_RESULTS+=("$out_cache_speed")
}

benchmark_timing_floor(){
    echo "Establishing timing floor..."
    local iterations=1000
    local start_time
    local end_time
    local elapsed

    #capture the start time using nanosecond resolution wall-clock time
    start_time=$(date +%s.%N)

    #run an empty timed region to measure the cost of the timing calls themselves
    for ((i=1; i<=iterations; i++)); do
        _=$(date +%s.%N)
    done

    #capture the end time
    end_time=$(date +%s.%N)

    #bash can't do floating point math, so use awk to calculate the difference
    elapsed=$(awk -v start="$start_time" -v end="$end_time" 'BEGIN { print end - start }')

    #calculate the average time per call in milliseconds
    TIMING_FLOOR_MS=$(awk -v el="$elapsed" -v iter="$iterations" 'BEGIN { printf "%.3f", (el / iter) * 1000 }')

    echo "Timing floor: ~${TIMING_FLOOR_MS} ms per call."
}

benchmark_disk_write() {
    # Buffered write
    buffered_result=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count="${TEST_SIZE_MB}" 2>&1)
    buffered_speed=$(echo "$buffered_result" | tail -1 | awk '{print $(NF-1)}')

    # Flush write
    flush_result=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count="${TEST_SIZE_MB}" conv=fdatasync 2>&1)
    flush_speed=$(echo "$flush_result" | tail -1 | awk '{print $(NF-1)}')

    # Save the result to the array
    BUFFERED_RESULTS+=("$buffered_speed")
    FLUSH_RESULTS+=("$flush_speed")
}

benchmark_disk_read() {
    # Warm read
    warm_read_result=$(dd if="$TEST_FILE" of=/dev/null bs=4K 2>&1)
    warm_speed=$(echo "$warm_read_result" | tail -1 | awk '{print $(NF-1)}')

    # Cold read (bypass cache)
    cold_read_result=$(dd if="$TEST_FILE" of=/dev/null bs=4K count=256000 iflag=direct 2>&1)
    cold_speed=$(echo "$cold_read_result" | tail -1 | awk '{print $(NF-1)}')

    WARMREAD_RESULTS+=($warm_speed)
    COLDREAD_RESULTS+=($cold_speed)
}

benchmark_random() {
    # masih blm random, bacanya seq
    random_result=$(dd if=$TEST_FILE of=/dev/null bs=4K 2>&1)
    random_speed=$(echo "$random_result" | tail -1 | awk '{print $(NF-1)}')

    RANDOM_RESULTS+=($random_speed)
}

run_repeated() {
    for ((i=1; i<=REPEAT_COUNT; i++))
    do
        echo "Run $i"

        # FUNCTIONS
        benchmark_cpu
        benchmark_memory
        benchmark_disk_write
        benchmark_disk_read
        benchmark_random
    done
}

main() {
    #bind the cleanup function to EXIT and interrupt signals
    trap cleanup EXIT INT TERM

    #declare variables globally from within main to keep the top-level clean
    declare -g TIMING_FLOOR_MS="0"
    declare -g TEST_FILE="testfile.bin"
    declare -g TEST_SIZE_MB=1000
    declare -g REPEAT_COUNT=5 # harusnya 6, soalnya run pertama di discard tp blm i sesuaiin

    #declare global arrays safely
    declare -g -a CPU_INT_RESULTS=()
    declare -g -a CPU_FORK_RESULTS=()
    declare -g -a CPU_AWK_RESULTS=()
    declare -g -a MEM_IN_CACHE_RESULTS=()
    declare -g -a MEM_OUT_CACH_RESULTS=()
    declare -g -a BUFFERED_RESULTS=()
    declare -g -a FLUSH_RESULTS=()
    declare -g -a WARMREAD_RESULTS=()
    declare -g -a COLDREAD_RESULTS=()
    declare -g -a RANDOM_RESULTS=()

    #establish the timing resolution
    benchmark_timing_floor

    #execute the core logic
    run_repeated
}

main "$@"

