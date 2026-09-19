#!/usr/bin/env bash

set -euo pipefail

# the variables
TEST_FILE="testfile.bin"
TEST_SIZE_MB=1000
REPEAT_COUNT=5 # harusnya 6, soalnya run pertama di discard tp blm i sesuaiin

# array result idk bru
BUFFERED_RESULTS=()
FLUSH_RESULTS=()
WARMREAD_RESULTS=()
COLDREAD_RESULTS=()
RANDOM_RESULTS=()

benchmark_disk_write() {
    # Buffered write
    buffered_result=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count=1000 2>&1)
    buffered_speed=$(echo "$buffered_result" | tail -1 | awk '{print $(NF-1)}')

    # Flush write
    flush_result=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count=1000 conv=fdatasync 2>&1)
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
        benchmark_disk_write
        benchmark_disk_read
        benchmark_random

    done
}

run_repeated

