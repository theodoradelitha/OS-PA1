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

    # -- 1. CPU Integer Throughput --
    local int_iters=1000000
    start=$(date +%s.%N)
    local i=0
    while (( i++ < int_iters )); do :; done
    end=$(date +%s.%N)

    elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN {print e-s}')
    #converted to Mops/s
    local int_ops=$(awk -v i="$int_iters" -v e="$elapsed" 'BEGIN {printf "%.0f", (i / e) / 1000000}')
    CPU_INT_RESULTS+=("$int_ops")

    # -- 2. Fork Cost --
    local fork_iters=1000
    start=$(date +%s.%N)
    local j=0
    while (( j++ < fork_iters )); do _=$(date +%s > /dev/null); done
    end=$(date +%s.%N)

    elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN {print e - s}')
    local fork_ops=$(awk -v i="$fork_iters" -v e="$elapsed" 'BEGIN {printf "%.0f", i/e}')
    CPU_FORK_RESULTS+=("$fork_ops")

    # -- 3. Awk Throughput --
    local awk_file="awk_test_data.txt"
    seq 1 5000000 > "$awk_file"

    start=$(date +%s.%N)
    awk '{s+=$1} END {print s}' "$awk_file" > /dev/null
    end=$(date +%s.%N)

    elapsed=$(awk -v s="$start" -v e="$end" 'BEGIN {print e-s}')
    #converted to Mops/s
    local awk_ops=$(awk -v i="5000000" -v e="$elapsed" 'BEGIN {printf "%.0f", (i / e) / 1000000}')
    CPU_AWK_RESULTS+=("$awk_ops")

    rm -f "$awk_file"
}

benchmark_memory() {
    local in_cache_result
    local in_cache_speed
    local out_cache_result
    local out_cache_speed
    local l3_cache="Unknown"

    if [[ -f /sys/devices/system/cpu/cpu0/cache/index3/size ]]; then
        l3_cache=$(cat /sys/devices/system/cpu/cpu0/cache/index3/size)
    fi
    echo "  (Detected L3 Cache size: $l3_cache)"

    # -- 1. In-cache memory --
    in_cache_result=$(dd if=/dev/zero of=/dev/shm/memtest.bin bs=1M count=10 2>&1)
    in_cache_speed=$(echo "$in_cache_result" | awk '/copied/ { for(i=1;i<=NF;i++) if($i=="s,") printf "%.2f", ($1 / 1073741824) / $(i-1) }')
    MEM_IN_CACHE_RESULTS+=("$in_cache_speed")

    # -- 2. Out-of-cache memory --
    out_cache_result=$(dd if=/dev/zero of=/dev/shm/memtest.bin bs=1M count=500 2>&1)
    out_cache_speed=$(echo "$out_cache_result" | awk '/copied/ { for(i=1;i<=NF;i++) if($i=="s,") printf "%.2f", ($1 / 1073741824) / $(i-1) }')
    MEM_OUT_CACHE_RESULTS+=("$out_cache_speed")
}

benchmark_timing_floor(){
    echo "Establishing timing floor..."
    local iterations=1000
    local start_time
    local end_time
    local elapsed
    local i

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
    # Buffered write (convert bytes/time to GiB/s)
    buffered_result=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count="${TEST_SIZE_MB}" 2>&1)
    buffered_speed=$(echo "$buffered_result" | awk '/copied/ { for(i=1;i<=NF;i++) if($i=="s,") printf "%.2f", ($1 / 1073741824) / $(i-1) }')

    # Flush write (convert bytes/time to GiB/s)
    flush_result=$(dd if=/dev/zero of="$TEST_FILE" bs=1M count="${TEST_SIZE_MB}" conv=fdatasync 2>&1)
    flush_speed=$(echo "$flush_result" | awk '/copied/ { for(i=1;i<=NF;i++) if($i=="s,") printf "%.2f", ($1 / 1073741824) / $(i-1) }')

    BUFFERED_RESULTS+=("$buffered_speed")
    FLUSH_RESULTS+=("$flush_speed")
}

benchmark_disk_read() {
    local read_count=$((TEST_SIZE_MB * 1024 / 4))

    # Warm read (convert bytes/time to GiB/s)
    warm_read_result=$(dd if="$TEST_FILE" of=/dev/null bs=4K count="$read_count" 2>&1)
    warm_speed=$(echo "$warm_read_result" | awk '/copied/ { for(i=1;i<=NF;i++) if($i=="s,") printf "%.2f", ($1 / 1073741824) / $(i-1) }')

    # Cold read (convert bytes/time to GiB/s)
    cold_read_result=$(dd if="$TEST_FILE" of=/dev/null bs=4K count="$read_count" iflag=direct 2>&1)
    cold_speed=$(echo "$cold_read_result" | awk '/copied/ { for(i=1;i<=NF;i++) if($i=="s,") printf "%.2f", ($1 / 1073741824) / $(i-1) }')

    WARMREAD_RESULTS+=("$warm_speed")
    COLDREAD_RESULTS+=("$cold_speed")
}

benchmark_random() {
    local count=$(( TEST_SIZE_MB * 1024 / 4 ))
    local start
    local end
    local elapsed
    local random_block
    local iops
    local i

    start=$(date +%s%N)

    for ((i=0; i<count; i++))
    do
        random_block=$(( ((RANDOM << 15) | RANDOM) % count ))

        dd if="$TEST_FILE" of=/dev/null bs=4K count=1 skip="$random_block" 2>/dev/null
    done

    end=$(date +%s%N)

    elapsed=$((end - start))

    iops=$(( count * 1000000000 / elapsed ))

    RANDOM_RESULTS+=("$iops")
}

calculate_stats() {
    local array_name="$1"
    local count

    #safely check the exact length of the array first
    eval "count=\${#${array_name}[@]}"

    #if the array is empty (because it was skipped), exit immediately
    if (( count == 0 )); then
        echo "0 0 0"
        return
    fi

    local -a values
    eval "values=(\"\${${array_name}[@]}\")"

    IFS=$'\n' sorted=($(printf '%s\n' "${values[@]}" | sort -n))
    unset IFS

    local min="${sorted[0]}"
    local max="${sorted[$((count - 1))]}"
    local median

    if (( count % 2 == 1 )); then
        median="${sorted[$((count / 2))]}"
    else
        local mid1="${sorted[$((count / 2 - 1))]}"
        local mid2="${sorted[$((count / 2))]}"

        median=$(awk -v a="$mid1" -v b="$mid2" \
            'BEGIN { printf "%.2f", (a+b)/2 }')
    fi

    echo "$median $min $max"
}

print_result() {
    local name="$1"
    local array_name="$2"
    local unit="$3"

    read -r median min max <<< "$(calculate_stats "$array_name")"

    printf "%-30s %10s %10s %10s   %s\n" \
        "$name" "$median" "$min" "$max" "$unit"
}

print_benchmark_results() {

    echo
    echo "=== Benchmarks (${REPEAT_COUNT} runs, median, first discarded) ==="
    printf "%-30s %10s %10s %10s   %s\n" \
        "BENCHMARK" "MEDIAN" "MIN" "MAX" "UNIT"

    print_result "CPU integer" \
        CPU_INT_RESULTS "Mops/s"

    print_result "CPU fork" \
        CPU_FORK_RESULTS "ops/s"

    print_result "CPU awk" \
        CPU_AWK_RESULTS "Mops/s"

    print_result "Memory read (in cache, 256K)" \
        MEM_IN_CACHE_RESULTS "GiB/s"

    print_result "Memory read (out of cache, 1G)" \
        MEM_OUT_CACHE_RESULTS "GiB/s"

    print_result "Disk write (buffered)" \
        BUFFERED_RESULTS "GiB/s"

    print_result "Disk write (fsync)" \
        FLUSH_RESULTS "GiB/s"

    print_result "Disk read (warm, page cache)" \
        WARMREAD_RESULTS "GiB/s"

    print_result "Disk read (cold, fadvise)" \
        COLDREAD_RESULTS "GiB/s"

    print_result "Disk random 4K read" \
        RANDOM_RESULTS "IOPS"
}

print_storage_hierarchy() {

    local cache_stats
    local memory_stats
    local disk_stats
    local random_stats

    cache_stats=$(calculate_stats "MEM_IN_CACHE_RESULTS")
    memory_stats=$(calculate_stats "MEM_OUT_CACHE_RESULTS")
    disk_stats=$(calculate_stats "COLDREAD_RESULTS")
    random_stats=$(calculate_stats "RANDOM_RESULTS")

    local cache_speed
    local memory_speed
    local disk_speed
    local random_iops

    cache_speed=$(echo "$cache_stats" | awk '{print $1}')
    memory_speed=$(echo "$memory_stats" | awk '{print $1}')
    disk_speed=$(echo "$disk_stats" | awk '{print $1}')
    random_iops=$(echo "$random_stats" | awk '{print $1}')

    # Convert random 4K IOPS -> GiB/s
    local random_speed
    random_speed=$(awk -v iops="$random_iops" '
        BEGIN {
            printf "%.6f", (iops * 4096) / 1073741824
        }
    ')

    # Calculate ratios using in-cache memory as baseline
    local memory_ratio
    local disk_ratio
    local random_ratio

    memory_ratio=$(awk -v cache="$cache_speed" -v mem="$memory_speed" '
        BEGIN { if (mem > 0)
                    printf "%.1f", cache / mem
                else
                    print "N/A"
        }
    ')

    disk_ratio=$(awk -v cache="$cache_speed" -v disk="$disk_speed" '
        BEGIN { if (disk > 0)
                    printf "%.1f", cache / disk
                else
                    print "N/A"
        }
    ')

    random_ratio=$(awk -v cache="$cache_speed" -v random="$random_speed" '
        BEGIN { if (random > 0)
                    printf "%.1f", cache / random
                else
                    print "N/A" 
        }
    ')

    echo
    echo "=== The storage hierarchy, measured ==="

    printf "  In-cache memory  %.2f GiB/s   ──  1.0x   (baseline)\n" \
        "$cache_speed"

    printf "  Main memory      %.2f GiB/s   ──  %.1fx slower than cache\n" \
        "$memory_speed" "$memory_ratio"

    printf "  Disk sequential  %.2f GiB/s   ──  %.1fx slower than cache\n" \
        "$disk_speed" "$disk_ratio"

    printf "  Disk random 4K   %.2f GiB/s   ──  %.1fx slower than cache\n" \
        "$random_speed" "$random_ratio"
}


print_system_inventory() {
    echo "=== System Inventory ==="

    echo "CPU            $(lscpu | grep 'Model name:' | sed 's/Model name:[[:space:]]*//'), $(lscpu | grep '^CPU(s):' | awk '{print $2}') cores"

    echo "Cache          $(lscpu | grep 'L1d cache:' | awk '{print $3, $4}')  $(lscpu | grep 'L1i cache:' | awk '{print $3, $4}')  $(lscpu | grep 'L2 cache:' | awk '{print $3, $4}')  $(lscpu | grep 'L3 cache:' | awk '{print $3, $4}')"

    echo "Memory         $(free -h | awk '/^Mem:/ {print $2 " total, " $7 " available"}')  $(free -h | awk '/^Swap:/ {print $2 " swap"}')"

    echo "Storage        $(lsblk -d -o NAME,SIZE,ROTA,MODEL | tail -n +2)"

    echo "Filesystem     $(df -h / | awk 'NR==2 {print $4 " free of " $2}')"

    echo "Kernel         $(uname -r)   $(lsb_release -ds)"

    echo "Virtualised    $(systemd-detect-virt)"
}

export_csv() {

    local output_file="benchmark_results.csv"

    echo "=== System Inventory ===" > "$output_file"
    echo "Metric,Value" >> "$output_file"

    printf 'CPU,"%s"\n' \
        "$(lscpu | grep 'Model name:' | sed 's/Model name:[[:space:]]*//'), $(lscpu | grep '^CPU(s):' | awk '{print $2}') cores" \
        >> "$output_file"

    printf 'Cache,"%s"\n' \
        "$(lscpu | grep 'L1d cache:' | awk '{print $3, $4}')  $(lscpu | grep 'L1i cache:' | awk '{print $3, $4}')  $(lscpu | grep 'L2 cache:' | awk '{print $3, $4}')  $(lscpu | grep 'L3 cache:' | awk '{print $3, $4}')" \
        >> "$output_file"

    printf 'Memory,"%s"\n' \
        "$(free -h | awk '/^Mem:/ {print $2 " total, " $7 " available"}')  $(free -h | awk '/^Swap:/ {print $2 " swap"}')" \
        >> "$output_file"

    printf 'Storage,"%s"\n' \
        "$(lsblk -d -o NAME,SIZE,ROTA,MODEL | tail -n +2 | tr '\n' ' ')" \
        >> "$output_file"

    printf 'Filesystem,"%s"\n' \
        "$(df -h / | awk 'NR==2 {print $4 " free of " $2}')" \
        >> "$output_file"

    printf 'Kernel,"%s"\n' \
        "$(uname -r)   $(lsb_release -ds)" \
        >> "$output_file"

    printf 'Virtualised,"%s"\n' \
        "$(systemd-detect-virt)" \
        >> "$output_file"

    echo >> "$output_file"
    echo "=== Benchmarks (${REPEAT_COUNT} runs, median, first discarded) ===" >> "$output_file"
    echo "Benchmark,Median,Min,Max,Unit" >> "$output_file"

    local median min max

    read -r median min max <<< "$(calculate_stats "CPU_INT_RESULTS")"
    printf "CPU integer,%s,%s,%s,Mops/s\n" \
        "$median" "$min" "$max" >> "$output_file"

    read -r median min max <<< "$(calculate_stats "CPU_FORK_RESULTS")"
    printf "CPU fork,%s,%s,%s,ops/s\n" \
        "$median" "$min" "$max" >> "$output_file"

    read -r median min max <<< "$(calculate_stats "CPU_AWK_RESULTS")"
    printf "CPU awk,%s,%s,%s,Mops/s\n" \
        "$median" "$min" "$max" >> "$output_file"

    read -r median min max <<< "$(calculate_stats "MEM_IN_CACHE_RESULTS")"
    printf "Memory read (in cache),%s,%s,%s,GiB/s\n" \
        "$median" "$min" "$max" >> "$output_file"

    read -r median min max <<< "$(calculate_stats "MEM_OUT_CACHE_RESULTS")"
    printf "Memory read (out of cache),%s,%s,%s,GiB/s\n" \
        "$median" "$min" "$max" >> "$output_file"

    read -r median min max <<< "$(calculate_stats "BUFFERED_RESULTS")"
    printf "Disk write (buffered),%s,%s,%s,GiB/s\n" \
        "$median" "$min" "$max" >> "$output_file"

    read -r median min max <<< "$(calculate_stats "FLUSH_RESULTS")"
    printf "Disk write (fdatasync),%s,%s,%s,GiB/s\n" \
        "$median" "$min" "$max" >> "$output_file"

    read -r median min max <<< "$(calculate_stats "WARMREAD_RESULTS")"
    printf "Disk read (warm),%s,%s,%s,GiB/s\n" \
        "$median" "$min" "$max" >> "$output_file"

    read -r median min max <<< "$(calculate_stats "COLDREAD_RESULTS")"
    printf "Disk read (cold),%s,%s,%s,GiB/s\n" \
        "$median" "$min" "$max" >> "$output_file"

    read -r median min max <<< "$(calculate_stats "RANDOM_RESULTS")"
    printf "Disk random 4K read,%s,%s,%s,IOPS\n" \
        "$median" "$min" "$max" >> "$output_file"

    echo >> "$output_file"
    echo "=== Storage Hierarchy ===" >> "$output_file"
    echo "Metric,Speed,Ratio,Unit" >> "$output_file"

    local cache_stats
    local memory_stats
    local disk_stats
    local random_stats

    cache_stats=$(calculate_stats "MEM_IN_CACHE_RESULTS")
    memory_stats=$(calculate_stats "MEM_OUT_CACHE_RESULTS")
    disk_stats=$(calculate_stats "COLDREAD_RESULTS")
    random_stats=$(calculate_stats "RANDOM_RESULTS")

    local cache_speed
    local memory_speed
    local disk_speed
    local random_iops
    local random_speed

    cache_speed=$(echo "$cache_stats" | awk '{print $1}')
    memory_speed=$(echo "$memory_stats" | awk '{print $1}')
    disk_speed=$(echo "$disk_stats" | awk '{print $1}')
    random_iops=$(echo "$random_stats" | awk '{print $1}')

    # Convert random 4K IOPS to GiB/s
    random_speed=$(awk -v iops="$random_iops" '
        BEGIN {
            printf "%.6f", (iops * 4096) / 1073741824
        }
    ')

    local memory_ratio
    local disk_ratio
    local random_ratio

    memory_ratio=$(awk -v cache="$cache_speed" -v mem="$memory_speed" '
        BEGIN {
            if (mem > 0)
                printf "%.1f", cache / mem
            else
                print "N/A"
        }
    ')

    disk_ratio=$(awk -v cache="$cache_speed" -v disk="$disk_speed" '
        BEGIN {
            if (disk > 0)
                printf "%.1f", cache / disk
            else
                print "N/A"
        }
    ')

    random_ratio=$(awk -v cache="$cache_speed" -v random="$random_speed" '
        BEGIN {
            if (random > 0)
                printf "%.1f", cache / random
            else
                print "N/A"
        }
    ')

    printf "In-cache memory,%.2f,1.0x,GiB/s\n" \
        "$cache_speed" >> "$output_file"

    printf "Main memory,%.2f,%sx slower than cache,GiB/s\n" \
        "$memory_speed" "$memory_ratio" >> "$output_file"

    printf "Disk sequential,%.2f,%sx slower than cache,GiB/s\n" \
        "$disk_speed" "$disk_ratio" >> "$output_file"

    printf "Disk random 4K,%.2f,%sx slower than cache,GiB/s\n" \
        "$random_speed" "$random_ratio" >> "$output_file"


    echo
    echo "CSV exported to: $output_file"
}

run_repeated() {
    local i

    for ((i=1; i<=REPEAT_COUNT; i++))
    do
        echo "Run $i"

        if [[ "$RUN_ONLY" == "all" || "$RUN_ONLY" == *"cpu"* ]]; then
            benchmark_cpu
        fi
        
        if [[ "$RUN_ONLY" == "all" || "$RUN_ONLY" == *"mem"* ]]; then
            benchmark_memory
        fi
        
        if [[ "$RUN_ONLY" == "all" || "$RUN_ONLY" == *"disk"* ]]; then
            benchmark_disk_write
            benchmark_disk_read
            benchmark_random
        fi


        if (( i == 1 )); then
            echo "  First run discarded (warm-up)"

            CPU_INT_RESULTS=()
            CPU_FORK_RESULTS=()
            CPU_AWK_RESULTS=()

            MEM_IN_CACHE_RESULTS=()
            MEM_OUT_CACHE_RESULTS=()

            BUFFERED_RESULTS=()
            FLUSH_RESULTS=()

            WARMREAD_RESULTS=()
            COLDREAD_RESULTS=()

            RANDOM_RESULTS=()
        fi
    done
}

main() {
    #bind the cleanup function to EXIT and interrupt signals
    trap cleanup EXIT INT TERM

    #declare variables globally from within main to keep the top-level clean
    declare -g TIMING_FLOOR_MS="0"
    declare -g TEST_FILE="testfile.bin"

    #default values
    declare -g TEST_SIZE_MB=1000
    declare -g REPEAT_COUNT=6
    declare -g RUN_ONLY="all"

    #parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick)
                TEST_SIZE_MB=50
                REPEAT_COUNT=3
                shift
                ;;
            --full)
                TEST_SIZE_MB=1000
                REPEAT_COUNT=6
                shift
                ;;
            --only)
                if [[ -n "${2:-}" ]]; then
                    RUN_ONLY="$2"
                    shift 2
                else
                    echo "Error: --only requires a value (e.g., cpu,mem)"
                    exit 1
                fi
                ;;
            --repeat)
                if [[ -n "${2:-}" ]]; then
                    REPEAT_COUNT="$2"
                    shift 2
                else
                    echo "Error: --repeat requires a number (e.g., 5)"
                    exit 1
                fi
                ;;
            --size)
                if [[ -n "${2:-}" ]]; then
                    #strip 'G' or 'M' and convert everything to MB for the dd count
                    if [[ "$2" == *G ]]; then
                        TEST_SIZE_MB=$((${2%G} * 1024))
                    elif [[ "$2" == *M ]]; then
                        TEST_SIZE_MB=${2%M}
                    else
                        TEST_SIZE_MB=$2
                    fi
                    shift 2
                else
                    echo "Error: --size requires a value (e.g., 100M or 1G)"
                    exit 1
                fi
                ;;
            *)
                echo "Unknown argument: $1"
                shift
                ;;
        esac
    done

    # -- Safety: Refuse to fill the disk --
    #get available disk space in MB
    local free_space_kb
    free_space_kb=$(df -k . | awk 'NR==2 {print $4}')
    local free_space_mb=$((free_space_kb / 1024))

    if (( TEST_SIZE_MB > free_space_mb )); then
        echo "Error: Requested file size (${TEST_SIZE_MB}MB) exceeds available free space (${free_space_mb}MB). Refusing to run."
        exit 1
    fi

    #declare global arrays safely
    declare -g -a CPU_INT_RESULTS=()
    declare -g -a CPU_FORK_RESULTS=()
    declare -g -a CPU_AWK_RESULTS=()
    declare -g -a MEM_IN_CACHE_RESULTS=()
    declare -g -a MEM_OUT_CACHE_RESULTS=()
    declare -g -a BUFFERED_RESULTS=()
    declare -g -a FLUSH_RESULTS=()
    declare -g -a WARMREAD_RESULTS=()
    declare -g -a COLDREAD_RESULTS=()
    declare -g -a RANDOM_RESULTS=()

    benchmark_timing_floor

    #execute the core logic
    run_repeated

    # print system inventory
    print_system_inventory

    # process and display benchmark results
    print_benchmark_results

    # calculate storage hierarchy ratios
    print_storage_hierarchy

    # export results to CSV
    export_csv
}

main "$@"