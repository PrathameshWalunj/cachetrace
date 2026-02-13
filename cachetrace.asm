; ============================================================================
; CacheTrace - Cycle-Accurate Cache Hierarchy Simulator
; ============================================================================
; Uses real, reverse-engineered Intel cache replacement policies
; Based on research from uops.info and nanoBench
;
; Input:  Memory trace (stdin) - "R 0xADDRESS" or "W 0xADDRESS"
; Output: Per-access cache behavior and cycle costs
;
; ============================================================================

bits 64
default rel

; ============================================================================
; CONSTANTS
; ============================================================================

; System call numbers
%define SYS_READ    0
%define SYS_WRITE   1
%define SYS_EXIT    60

; File descriptors
%define STDIN       0
%define STDOUT      1
%define STDERR      2

; Cache result codes
%define CACHE_HIT   0
%define CACHE_MISS  1

; Output modes
%define OUTPUT_SIMPLE   0
%define OUTPUT_DETAILED 1
%define OUTPUT_FULL     2

; ============================================================================
; CPU SELECTION
; ============================================================================
; Change this constant to select CPU configuration
; 0=Nehalem, 1=SandyBridge, 2=IvyBridge, 3=Haswell, 4=Skylake, 5=CoffeeLake
%define SELECTED_CPU 5              ; Default: Coffee Lake

; ============================================================================
; CPU CONFIGURATIONS
; ============================================================================
; Each CPU has different cache sizes, associativities, and policies

; ============================================================================
; ACTIVE CPU CONFIGURATION (based on SELECTED_CPU)
; ============================================================================

%if SELECTED_CPU == 0
    ; Nehalem
    %define CPU_NAME        "Nehalem"
    %define L1_NUM_SETS     64
    %define L1_ASSOC        8
    %define L1_LATENCY      4
    %define L2_NUM_SETS     512
    %define L2_ASSOC        8
    %define L2_LATENCY      12
    %define L3_NUM_SETS     4096
    %define L3_ASSOC        16
    %define L3_LATENCY      40
    %define L3_POLICY       4           ; MRU
%elif SELECTED_CPU == 1
    ; Sandy Bridge
    %define CPU_NAME        "Sandy Bridge"
    %define L1_NUM_SETS     64
    %define L1_ASSOC        8
    %define L1_LATENCY      4
    %define L2_NUM_SETS     512
    %define L2_ASSOC        8
    %define L2_LATENCY      12
    %define L3_NUM_SETS     2048
    %define L3_ASSOC        16
    %define L3_LATENCY      36
    %define L3_POLICY       5           ; MRU_N
%elif SELECTED_CPU == 2
    ; Ivy Bridge
    %define CPU_NAME        "Ivy Bridge"
    %define L1_NUM_SETS     64
    %define L1_ASSOC        8
    %define L1_LATENCY      4
    %define L2_NUM_SETS     512
    %define L2_ASSOC        8
    %define L2_LATENCY      12
    %define L3_NUM_SETS     2048
    %define L3_ASSOC        16
    %define L3_LATENCY      36
    %define L3_POLICY       3           ; QLRU_H11_M1_R1_U2
%elif SELECTED_CPU == 3
    ; Haswell
    %define CPU_NAME        "Haswell"
    %define L1_NUM_SETS     64
    %define L1_ASSOC        8
    %define L1_LATENCY      4
    %define L2_NUM_SETS     512
    %define L2_ASSOC        8
    %define L2_LATENCY      12
    %define L3_NUM_SETS     2048
    %define L3_ASSOC        16
    %define L3_LATENCY      36
    %define L3_POLICY       3           ; QLRU_H11_M1_R1_U2
%elif SELECTED_CPU == 4
    ; Skylake
    %define CPU_NAME        "Skylake"
    %define L1_NUM_SETS     64
    %define L1_ASSOC        8
    %define L1_LATENCY      4
    %define L2_NUM_SETS     1024
    %define L2_ASSOC        4
    %define L2_LATENCY      12
    %define L3_NUM_SETS     2048
    %define L3_ASSOC        16
    %define L3_LATENCY      42
    %define L3_POLICY       3           ; QLRU_H11_M1_R1_U2
%elif SELECTED_CPU == 5
    ; Coffee Lake (default)
    %define CPU_NAME        "Coffee Lake"
    %define L1_NUM_SETS     64
    %define L1_ASSOC        8
    %define L1_LATENCY      4
    %define L2_NUM_SETS     512
    %define L2_ASSOC        8
    %define L2_LATENCY      12
    %define L3_NUM_SETS     2048
    %define L3_ASSOC        16
    %define L3_LATENCY      42
    %define L3_POLICY       1           ; QLRU_H11_M1_R0_U0
%else
    %error "Invalid SELECTED_CPU value"
%endif

; Common constants
%define L1_LINE_SIZE    64
%define L2_LINE_SIZE    64
%define L3_LINE_SIZE    64

; Calculate sizes
%define L1_SIZE         (L1_NUM_SETS * L1_ASSOC * L1_LINE_SIZE)
%define L2_SIZE         (L2_NUM_SETS * L2_ASSOC * L2_LINE_SIZE)
%define L3_SIZE         (L3_NUM_SETS * L3_ASSOC * L3_LINE_SIZE)

; ============================================================================
; DATA STRUCTURES
; ============================================================================

section .bss

; Input buffer for reading trace lines
input_buffer:   resb 4096           ; Larger buffer for batch reading
buffer_pos:     resq 1              ; Current position in buffer
buffer_end:     resq 1              ; End of valid data in buffer
current_line:   resb 256            ; Current line being processed

; Runtime CPU configuration
runtime_cpu_id:     resb 1          ; Selected CPU ID (0-5)
runtime_l1_sets:    resw 1
runtime_l1_assoc:   resb 1
runtime_l1_lat:     resb 1
runtime_l2_sets:    resw 1
runtime_l2_assoc:   resb 1
runtime_l2_lat:     resb 1
runtime_l3_sets:    resw 1
runtime_l3_assoc:   resb 1
runtime_l3_lat:     resb 1
runtime_l3_policy:  resb 1
runtime_l3_set_mask: resw 1     ; L3 sets - 1 (for AND masking)
runtime_l3_tag_shift: resb 1    ; Bits to shift for tag (6 + log2(sets))

; L1 Cache State (sized for max: 64 sets, 8-way)
alignb 16
l1_cache_tags:  resq (64 * 8)       ; Max config
l1_cache_ages:  resb (64 * 8)

; L2 Cache State (sized for max: 1024 sets, 8-way - Skylake)
alignb 16
l2_cache_tags:  resq (1024 * 8)     ; Max config
l2_cache_ages:  resb (1024 * 8)

; L3 Cache State (sized for max: 4096 sets, 16-way - Nehalem)
alignb 16
l3_cache_tags:  resq (4096 * 16)    ; Max config
l3_cache_ages:  resb (4096 * 16)

; Statistics
total_accesses:     resq 1
l1_hits:            resq 1
l1_misses:          resq 1
l2_hits:            resq 1
l2_misses:          resq 1
l3_hits:            resq 1
l3_misses:          resq 1
total_cycles:       resq 1

; Current access info
current_address:    resq 1
current_is_write:   resb 1

; Output mode (default: detailed)
output_mode:        resb 1

; Current access results (for output)
result_l1:          resb 1      ; HIT or MISS
result_l2:          resb 1
result_l3:          resb 1
cycles_l1:          resd 1
cycles_l2:          resd 1
cycles_l3:          resd 1
cycles_total:       resd 1
evicted_l1:         resq 1      ; Evicted tag (or 0xFFFFFFFFFFFFFFFF)
evicted_l2:         resq 1
evicted_l3:         resq 1

; Output buffer
output_buffer:      resb 512

section .data

; ============================================================================
; CPU CONFIGURATION TABLE
; ============================================================================
; Structure: name(16), l1_sets(2), l1_assoc(1), l1_lat(1), l1_policy(1),
;            l2_sets(2), l2_assoc(1), l2_lat(1), l2_policy(1),
;            l3_sets(2), l3_assoc(1), l3_lat(1), l3_policy(1)

; Policy IDs:
; 0 = PLRU, 1 = QLRU_H11_M1_R0_U0, 2 = QLRU_H00_M1_R2_U1,
; 3 = QLRU_H11_M1_R1_U2, 4 = MRU, 5 = MRU_N

cpu_configs:
; Nehalem (NHM)
    db "Nehalem         ", 0       ; Name (16 bytes)
    dw 64                           ; L1 sets
    db 8, 4, 0                      ; L1: 8-way, 4cyc, PLRU
    dw 512                          ; L2 sets
    db 8, 12, 0                     ; L2: 8-way, 12cyc, PLRU
    dw 4096                         ; L3 sets
    db 16, 40, 4                    ; L3: 16-way, 40cyc, MRU

; Sandy Bridge (SNB)
    db "Sandy Bridge    ", 0
    dw 64
    db 8, 4, 0                      ; L1: PLRU
    dw 512
    db 8, 12, 0                     ; L2: PLRU
    dw 2048
    db 16, 36, 5                    ; L3: 16-way, 36cyc, MRU_N

; Ivy Bridge (IVB)
    db "Ivy Bridge      ", 0
    dw 64
    db 8, 4, 0                      ; L1: PLRU
    dw 512
    db 8, 12, 0                     ; L2: PLRU
    dw 2048
    db 16, 36, 3                    ; L3: 16-way, 36cyc, QLRU_H11_M1_R1_U2

; Haswell (HSW)
    db "Haswell         ", 0
    dw 64
    db 8, 4, 0
    dw 512
    db 8, 12, 2                     ; L2: QLRU_H00_M1_R2_U1
    dw 2048
    db 16, 36, 3                    ; L3: QLRU_H11_M1_R1_U2

; Skylake (SKL)
    db "Skylake         ", 0
    dw 64
    db 8, 4, 0
    dw 1024
    db 4, 12, 2                     ; L2: 4-way, QLRU_H00_M1_R2_U1
    dw 2048
    db 16, 42, 3                    ; L3: QLRU_H11_M1_R1_U2

; Coffee Lake (CFL)
    db "Coffee Lake     ", 0
    dw 64
    db 8, 4, 0                      ; L1: 8-way, 4cyc, PLRU
    dw 512
    db 8, 12, 2                     ; L2: 8-way, 12cyc, QLRU_H00_M1_R2_U1
    dw 2048
    db 16, 42, 1                    ; L3: 16-way, 42cyc, QLRU_H11_M1_R0_U0

cpu_config_size equ 32              ; Size of each config entry

; ============================================================================
; LOOKUP TABLES FOR QLRU POLICIES
; ============================================================================

; QLRU Hit Functions
; H00: All ages -> 0
qlru_h00_table:     db 0, 0, 0, 0

; H10: 3->1, 2->0, 1->0, 0->0
qlru_h10_table:     db 0, 0, 0, 1

; H11: 3->1, 2->1, 1->0, 0->0
qlru_h11_table:     db 0, 0, 1, 1

; H20: 3->2, 2->0, 1->0, 0->0
qlru_h20_table:     db 0, 0, 0, 2

; H21: 3->2, 2->1, 1->0, 0->0 (decrement by 1, floor at 0)
qlru_h21_table:     db 0, 0, 1, 2

; QLRU Miss Functions (initial age for new blocks)
%define QLRU_M0     0
%define QLRU_M1     1
%define QLRU_M2     2
%define QLRU_M3     3

; String constants
banner_msg:         db "CacheTrace - Cycle-Accurate Cache Simulator", 10
banner_len          equ $ - banner_msg

cpu_name_msg:       db "CPU: ", CPU_NAME, 10, 0
cpu_name_len        equ $ - cpu_name_msg

; Note: Dynamic cache config string - will update after implementing runtime config
cache_config_msg:   db "See CPU config above", 10, 0
cache_config_len    equ $ - cache_config_msg

csv_header_simple:  db "address,total_cycles", 10
csv_header_simple_len equ $ - csv_header_simple

csv_header_detailed: db "address,L1_result,L1_cycles,L2_result,L2_cycles,L3_result,L3_cycles,total_cycles", 10
csv_header_detailed_len equ $ - csv_header_detailed

csv_header_full:    db "address,L1_result,L1_cycles,L1_evicted,L2_result,L2_cycles,L2_evicted,L3_result,L3_cycles,L3_evicted,total_cycles", 10
csv_header_full_len equ $ - csv_header_full

str_hit:            db "HIT", 0
str_miss:           db "MISS", 0

; CPU name strings for argument parsing
cpu_arg_nhm:        db "--cpu=nhm", 0
cpu_arg_nehalem:    db "--cpu=nehalem", 0
cpu_arg_snb:        db "--cpu=snb", 0
cpu_arg_sandybridge: db "--cpu=sandybridge", 0
cpu_arg_ivb:        db "--cpu=ivb", 0
cpu_arg_ivybridge:  db "--cpu=ivybridge", 0
cpu_arg_hsw:        db "--cpu=hsw", 0
cpu_arg_haswell:    db "--cpu=haswell", 0
cpu_arg_skl:        db "--cpu=skl", 0
cpu_arg_skylake:    db "--cpu=skylake", 0
cpu_arg_cfl:        db "--cpu=cfl", 0
cpu_arg_coffeelake: db "--cpu=coffeelake", 0

; Statistics strings
newline:            db 10
stats_header:       db 10, "=== Statistics Summary ===", 10
stats_header_len    equ $ - stats_header

stats_total:        db "Total accesses:     ", 0
stats_l1_hits:      db "L1 hits:            ", 0
stats_l1_misses:    db "L1 misses:          ", 0
stats_l1_rate:      db "L1 hit rate:        ", 0
stats_l2_hits:      db "L2 hits:            ", 0
stats_l2_misses:    db "L2 misses:          ", 0
stats_l2_rate:      db "L2 hit rate:        ", 0
stats_l3_hits:      db "L3 hits:            ", 0
stats_l3_misses:    db "L3 misses:          ", 0
stats_l3_rate:      db "L3 hit rate:        ", 0
stats_total_cycles: db "Total cycles:       ", 0
stats_avg_cycles:   db "Avg cycles/access:  ", 0
stats_percent:      db "%", 10, 0

; ============================================================================
; CODE SECTION
; ============================================================================

section .text
global _start

; ============================================================================
; Main Entry Point
; ============================================================================
_start:
    ; Parse command-line arguments
    pop rdi                         ; argc
    pop rsi                         ; argv[0] (program name)

    ; Default CPU
    mov byte [runtime_cpu_id], SELECTED_CPU

    ; Check if we have arguments
    dec rdi
    jz .no_args

.parse_args:
    test rdi, rdi
    jz .no_args

    pop rsi                         ; Next argument
    call parse_argument

    dec rdi
    jmp .parse_args

.no_args:
    ; Load CPU configuration
    call load_cpu_config

    ; Initialize buffer state
    mov qword [buffer_pos], 0
    mov qword [buffer_end], 0

    ; Initialize output mode to detailed
    mov byte [output_mode], OUTPUT_DETAILED

    ; Print banner
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [banner_msg]
    mov rdx, banner_len
    syscall

    ; Print CPU name (runtime)
    call print_cpu_name

    ; Print cache configuration
    call print_cpu_config

    ; Initialize buffer state
    mov qword [buffer_pos], 0
    mov qword [buffer_end], 0

    ; Initialize cache state
    call init_caches

    ; Print CSV header based on output mode
    call print_csv_header

    ; Main simulation loop
.main_loop:
    ; Read one line from stdin
    call read_trace_line
    test rax, rax           ; Check if we read anything
    jz .end_simulation      ; EOF or error

    ; Parse the trace line (sets current_address and current_is_write)
    call parse_trace_line
    test rax, rax
    jz .main_loop           ; Invalid line, skip

    ; Simulate cache access
    call simulate_access

    ; Output results
    call output_results

    jmp .main_loop

.end_simulation:
    ; Print statistics summary
    call print_statistics

    ; Exit program
    mov rax, SYS_EXIT
    xor rdi, rdi
    syscall

; ============================================================================
; Parse Command-Line Argument
; ============================================================================
; Input: RSI = argument string
parse_argument:
    push rdi
    push rsi
    push rcx

    ; Check for --cpu= prefix
    mov rdi, rsi
    lea rsi, [cpu_arg_nhm]
    call strcmp
    test al, al
    jnz .is_nhm

    mov rsi, [rsp + 8]              ; Restore original arg
    lea rdi, [cpu_arg_nehalem]
    call strcmp
    test al, al
    jnz .is_nhm

    mov rsi, [rsp + 8]
    lea rdi, [cpu_arg_snb]
    call strcmp
    test al, al
    jnz .is_snb

    mov rsi, [rsp + 8]
    lea rdi, [cpu_arg_sandybridge]
    call strcmp
    test al, al
    jnz .is_snb

    mov rsi, [rsp + 8]
    lea rdi, [cpu_arg_ivb]
    call strcmp
    test al, al
    jnz .is_ivb

    mov rsi, [rsp + 8]
    lea rdi, [cpu_arg_ivybridge]
    call strcmp
    test al, al
    jnz .is_ivb

    mov rsi, [rsp + 8]
    lea rdi, [cpu_arg_hsw]
    call strcmp
    test al, al
    jnz .is_hsw

    mov rsi, [rsp + 8]
    lea rdi, [cpu_arg_haswell]
    call strcmp
    test al, al
    jnz .is_hsw

    mov rsi, [rsp + 8]
    lea rdi, [cpu_arg_skl]
    call strcmp
    test al, al
    jnz .is_skl

    mov rsi, [rsp + 8]
    lea rdi, [cpu_arg_skylake]
    call strcmp
    test al, al
    jnz .is_skl

    mov rsi, [rsp + 8]
    lea rdi, [cpu_arg_cfl]
    call strcmp
    test al, al
    jnz .is_cfl

    mov rsi, [rsp + 8]
    lea rdi, [cpu_arg_coffeelake]
    call strcmp
    test al, al
    jnz .is_cfl

    jmp .done

.is_nhm:
    mov byte [runtime_cpu_id], 0
    jmp .done
.is_snb:
    mov byte [runtime_cpu_id], 1
    jmp .done
.is_ivb:
    mov byte [runtime_cpu_id], 2
    jmp .done
.is_hsw:
    mov byte [runtime_cpu_id], 3
    jmp .done
.is_skl:
    mov byte [runtime_cpu_id], 4
    jmp .done
.is_cfl:
    mov byte [runtime_cpu_id], 5

.done:
    pop rcx
    pop rsi
    pop rdi
    ret

; ============================================================================
; String Compare
; ============================================================================
; Input: RDI = string1, RSI = string2
; Output: AL = 1 if equal, 0 otherwise
strcmp:
    push rcx
    push rsi
    push rdi

.loop:
    lodsb                           ; Load from RSI
    mov cl, [rdi]
    inc rdi

    cmp al, cl
    jne .not_equal

    test al, al                     ; Check for null terminator
    jz .equal

    jmp .loop

.equal:
    mov al, 1
    jmp .strcmp_done

.not_equal:
    xor al, al

.strcmp_done:
    pop rdi
    pop rsi
    pop rcx
    ret

; ============================================================================
; Load CPU Configuration
; ============================================================================
; Loads config based on runtime_cpu_id
load_cpu_config:
    push rax
    push rbx
    push rcx

    movzx rax, byte [runtime_cpu_id]

    ; Load from cpu_configs table
    ; Each entry is 32 bytes
    imul rax, 32
    lea rbx, [cpu_configs]
    add rbx, rax

    ; Skip name (16 bytes + NUL = 17 bytes)
    add rbx, 17

    ; Load L1 config
    mov ax, [rbx]
    mov [runtime_l1_sets], ax
    add rbx, 2
    mov al, [rbx]
    mov [runtime_l1_assoc], al
    inc rbx
    mov al, [rbx]
    mov [runtime_l1_lat], al
    inc rbx
    inc rbx                         ; Skip policy byte

    ; Load L2 config
    mov ax, [rbx]
    mov [runtime_l2_sets], ax
    add rbx, 2
    mov al, [rbx]
    mov [runtime_l2_assoc], al
    inc rbx
    mov al, [rbx]
    mov [runtime_l2_lat], al
    inc rbx
    inc rbx                         ; Skip policy byte

    ; Load L3 config
    mov ax, [rbx]
    mov [runtime_l3_sets], ax
    add rbx, 2
    mov al, [rbx]
    mov [runtime_l3_assoc], al
    inc rbx
    mov al, [rbx]
    mov [runtime_l3_lat], al
    inc rbx
    mov al, [rbx]
    mov [runtime_l3_policy], al

    ; Calculate L3 set mask (sets - 1)
    movzx rax, word [runtime_l3_sets]
    dec rax
    mov [runtime_l3_set_mask], ax

    ; Calculate L3 tag shift (6 + log2(sets))
    movzx rax, word [runtime_l3_sets]
    bsr rax, rax                ; Find highest bit position (log2)
    add rax, 6                  ; Add line offset bits
    mov [runtime_l3_tag_shift], al

    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; Initialize Cache State
; ============================================================================
; Sets all tags to invalid (0xFFFFFFFFFFFFFFFF)
; Sets all ages to 0
init_caches:
    push rdi
    push rcx
    push rax

    ; Initialize L1 (use compile-time max for safety)
    lea rdi, [l1_cache_tags]
    mov rcx, 64 * 8                 ; Max L1: 64 sets * 8 ways
    mov rax, 0xFFFFFFFFFFFFFFFF     ; Invalid tag marker
    rep stosq

    lea rdi, [l1_cache_ages]
    mov rcx, 64 * 8
    xor rax, rax
    rep stosb

    ; Initialize L2 (use compile-time max for safety)
    lea rdi, [l2_cache_tags]
    mov rcx, 1024 * 8               ; Max L2: 1024 sets (Skylake) * 8 ways
    mov rax, 0xFFFFFFFFFFFFFFFF
    rep stosq

    lea rdi, [l2_cache_ages]
    mov rcx, 1024 * 8
    mov al, 3                       ; QLRU: Initialize ages to 3 (empty = max age)
    rep stosb

    ; Initialize L3 (use compile-time max for safety)
    lea rdi, [l3_cache_tags]
    mov rcx, 4096 * 16              ; Max L3: 4096 sets (Nehalem) * 16 ways
    mov rax, 0xFFFFFFFFFFFFFFFF
    rep stosq

    lea rdi, [l3_cache_ages]
    mov rcx, 4096 * 16
    mov al, 3                       ; QLRU: Initialize ages to 3 (empty = max age)
    rep stosb

    pop rax
    pop rcx
    pop rdi
    ret

; ============================================================================
; Read Trace Line from stdin (Buffered)
; ============================================================================
; Reads one line at a time into current_line using buffered input
; Returns: RAX = number of bytes in line (0 = EOF)
read_trace_line:
    push rbx
    push rcx
    push rdi
    push rsi
    push rdx
    push r8
    push r9

    lea r8, [current_line]          ; r8 = output buffer
    xor rbx, rbx                    ; rbx = line length

.next_char:
    ; Check if we need to refill buffer
    mov rax, [buffer_pos]
    cmp rax, [buffer_end]
    jl .have_data

    ; Refill buffer
    mov rax, SYS_READ
    mov rdi, STDIN
    lea rsi, [input_buffer]
    mov rdx, 4096                   ; Read full buffer
    syscall

    ; Check for EOF
    test rax, rax
    jz .eof

    ; Update buffer state
    mov [buffer_end], rax
    xor rax, rax
    mov [buffer_pos], rax

.have_data:
    ; Get next character from buffer
    mov r9, [buffer_pos]
    lea rdi, [input_buffer]
    mov al, [rdi + r9]
    inc r9
    mov [buffer_pos], r9

    ; Check for newline
    cmp al, 10                      ; \n
    je .got_line

    ; Check for carriage return (ignore it)
    cmp al, 13
    je .next_char

    ; Add to line buffer
    mov [r8 + rbx], al
    inc rbx
    cmp rbx, 255                    ; Max line length
    jl .next_char

.got_line:
    ; Null-terminate the line
    mov byte [r8 + rbx], 0
    mov rax, rbx                    ; Return line length
    jmp .done

.eof:
    ; If we have partial line, return it
    test rbx, rbx
    jz .really_eof
    mov byte [r8 + rbx], 0
    mov rax, rbx
    jmp .done

.really_eof:
    xor rax, rax

.done:
    pop r9
    pop r8
    pop rdx
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; ============================================================================
; Parse Trace Line
; ============================================================================
; Input: current_line contains line like "R 0x7fffffffd8a0" or "W 0x400000"
; Output: RAX = 1 if valid, 0 if invalid
;         Sets current_address and current_is_write
parse_trace_line:
    push rbx
    push rcx
    push rdx

    lea rsi, [current_line]

    ; Check first character (R or W)
    lodsb
    cmp al, 'R'
    je .is_read
    cmp al, 'W'
    je .is_write

    ; Invalid operation
    xor rax, rax
    jmp .done

.is_read:
    mov byte [current_is_write], 0
    jmp .parse_address

.is_write:
    mov byte [current_is_write], 1

.parse_address:
    ; Skip space
    lodsb
    cmp al, ' '
    jne .invalid

    ; Parse hex address (skip "0x" if present)
    lodsb
    cmp al, '0'
    jne .parse_hex_start
    lodsb
    cmp al, 'x'
    je .parse_hex_digits

.parse_hex_start:
    dec rsi  ; Back up one character

.parse_hex_digits:
    xor rbx, rbx  ; Accumulator for address
    xor rcx, rcx  ; Digit counter

.hex_loop:
    lodsb

    ; Check for end of line
    cmp al, 10    ; newline
    je .parsed
    cmp al, 13    ; carriage return
    je .parsed
    cmp al, 0     ; null
    je .parsed
    cmp al, ' '   ; space (in case there's more data)
    je .parsed

    ; Convert hex digit
    cmp al, '0'
    jb .invalid
    cmp al, '9'
    jbe .digit_0_9

    cmp al, 'A'
    jb .invalid
    cmp al, 'F'
    jbe .digit_A_F

    cmp al, 'a'
    jb .invalid
    cmp al, 'f'
    jbe .digit_a_f

    jmp .invalid

.digit_0_9:
    sub al, '0'
    jmp .add_digit

.digit_A_F:
    sub al, 'A' - 10
    jmp .add_digit

.digit_a_f:
    sub al, 'a' - 10

.add_digit:
    shl rbx, 4
    or bl, al
    inc rcx
    cmp rcx, 16  ; Max 16 hex digits for 64-bit address
    jb .hex_loop

.parsed:
    ; Store the parsed address
    mov [current_address], rbx
    mov rax, 1
    jmp .done

.invalid:
    xor rax, rax

.done:
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; Simulate Cache Access
; ============================================================================
; Simulates access through L1 -> L2 -> L3 hierarchy
; Uses current_address
; Stores results in result_l1/l2/l3, cycles_*, and evicted_* variables
simulate_access:
    push rbp
    mov rbp, rsp

    ; Initialize result variables
    mov qword [evicted_l1], 0xFFFFFFFFFFFFFFFF
    mov qword [evicted_l2], 0xFFFFFFFFFFFFFFFF
    mov qword [evicted_l3], 0xFFFFFFFFFFFFFFFF
    mov dword [cycles_total], 0

    ; Try L1
    mov rdi, [current_address]
    call access_l1

    ; Store L1 result and evicted tag
    mov [result_l1], al
    mov [evicted_l1], rbx

    cmp al, CACHE_HIT
    jne .l1_miss

    ; L1 hit - just add latency
    mov eax, L1_LATENCY
    mov [cycles_l1], eax
    add [cycles_total], eax

    ; Update statistics
    inc qword [total_accesses]
    inc qword [l1_hits]

    ; No need to check L2/L3
    mov byte [result_l2], 0xFF      ; Mark as not accessed
    mov byte [result_l3], 0xFF
    mov dword [cycles_l2], 0
    mov dword [cycles_l3], 0
    jmp .done

.l1_miss:
    ; L1 miss - no cycles from L1, but we insert into L1
    mov dword [cycles_l1], 0
    inc qword [l1_misses]

    ; Try L2
    mov rdi, [current_address]
    call access_l2

    ; Store L2 result and evicted tag
    mov [result_l2], al
    mov [evicted_l2], rbx

    cmp al, CACHE_HIT
    jne .l2_miss

    ; L2 hit
    mov eax, L2_LATENCY
    mov [cycles_l2], eax
    add [cycles_total], eax

    ; Update statistics
    inc qword [total_accesses]
    inc qword [l2_hits]

    ; No need to check L3
    mov byte [result_l3], 0xFF      ; Mark as not accessed
    mov dword [cycles_l3], 0
    jmp .done

.l2_miss:
    ; L2 miss
    mov dword [cycles_l2], 0
    inc qword [l2_misses]

    ; Try L3
    mov rdi, [current_address]
    call access_l3

    ; Store L3 result and evicted tag
    mov [result_l3], al
    mov [evicted_l3], rbx

    cmp al, CACHE_HIT
    jne .l3_miss

    ; L3 hit
    mov eax, L3_LATENCY
    mov [cycles_l3], eax
    add [cycles_total], eax

    ; Update statistics
    inc qword [total_accesses]
    inc qword [l3_hits]
    jmp .done

.l3_miss:
    ; L3 miss - memory access (~200 cycles typical)
    mov dword [cycles_l3], 0
    inc qword [l3_misses]

    mov eax, 200
    add [cycles_total], eax

    ; Update statistics
    inc qword [total_accesses]

.done:
    ; Add to cumulative total cycles
    mov eax, [cycles_total]
    add [total_cycles], rax

    pop rbp
    ret

; ============================================================================
; Access L1 Cache (Tree-PLRU)
; ============================================================================
; PLRU uses a binary tree of bits to track replacement
; For 8-way cache: 3 levels (1 + 2 + 4 = 7 bits total)
; ============================================================================
; Input: RDI = address
; Output: RAX = CACHE_HIT or CACHE_MISS
;         RBX = evicted tag (if MISS), 0xFFFFFFFFFFFFFFFF if no eviction
access_l1:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15

    ; Extract set index (bits 11:6 for 64 sets)
    mov rax, rdi
    shr rax, 6
    and rax, (L1_NUM_SETS - 1)
    mov r12, rax                    ; r12 = set index

    ; Extract tag (address >> 12, excluding line offset + set index)
    mov r13, rdi
    shr r13, 12                     ; r13 = tag (bits 12+ for 64 sets * 64 bytes)

    ; Calculate base pointers for this set
    mov rax, r12
    imul rax, L1_ASSOC

    lea r14, [l1_cache_tags]
    lea r14, [r14 + rax * 8]        ; r14 = base of tags for this set

    lea r15, [l1_cache_ages]
    add r15, rax                    ; r15 = base of PLRU tree bits

    ; Search for tag in the set (check all 8 ways)
    xor rcx, rcx                    ; way counter
.search_loop:
    cmp rcx, L1_ASSOC
    jge .not_found

    ; Check if tag matches
    mov rax, [r14 + rcx * 8]
    cmp rax, r13
    je .found_hit

    inc rcx
    jmp .search_loop

.found_hit:
    ; HIT: Update PLRU tree to point away from this way
    ; rcx = hit way index
    call plru_update_tree_l1

    mov rax, CACHE_HIT
    xor rbx, rbx                    ; No eviction
    jmp .done

.not_found:
    ; MISS: Find victim using PLRU tree
    call plru_get_victim_l1         ; Returns victim way in RCX

    ; Check if slot is empty
    mov rax, [r14 + rcx * 8]
    cmp rax, 0xFFFFFFFFFFFFFFFF
    je .empty_slot

    ; Save evicted tag
    mov rbx, rax
    jmp .insert

.empty_slot:
    mov rbx, 0xFFFFFFFFFFFFFFFF     ; No eviction

.insert:
    ; Insert new tag
    mov [r14 + rcx * 8], r13

    ; Update PLRU tree
    call plru_update_tree_l1

    mov rax, CACHE_MISS

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

; ============================================================================
; PLRU Tree Functions for L1
; ============================================================================

; Get victim way using PLRU tree
; Input: R15 = base of tree bits (byte array, 7 bits stored in 1 byte per set)
; Output: RCX = victim way index (0-7)
plru_get_victim_l1:
    push rax
    push rbx

    movzx rax, byte [r15]           ; Load all 7 tree bits

    ; Traverse tree (3 levels for 8-way)
    ; Level 0: bit 0 (root)
    xor rcx, rcx                    ; Start at way 0
    bt ax, 0                        ; Test bit 0
    jnc .level1                     ; If 0, go left
    or rcx, 4                       ; If 1, go right (add 4)

.level1:
    ; Level 1: bits 1-2
    mov rbx, rcx
    shr rbx, 2                      ; Which level-1 node? (0 or 1)
    inc rbx                         ; Offset into tree (bits 1-2)
    bt ax, bx
    jnc .level2
    or rcx, 2                       ; Add 2 to way index

.level2:
    ; Level 2: bits 3-6
    mov rbx, rcx
    shr rbx, 1                      ; Which level-2 node? (0-3)
    add rbx, 3                      ; Offset into tree (bits 3-6)
    bt ax, bx
    jnc .done_victim
    or rcx, 1                       ; Add 1 to way index

.done_victim:
    pop rbx
    pop rax
    ret

; Update PLRU tree after access
; Input: R15 = base of tree bits
;        RCX = accessed way index
plru_update_tree_l1:
    push rax
    push rbx
    push rcx
    push rdx

    movzx rax, byte [r15]           ; Load current tree state

    ; Update level 0 (root): point away from accessed way
    ; If way 0-3 accessed, set bit 0 = 1 (point right)
    ; If way 4-7 accessed, set bit 0 = 0 (point left)
    mov rbx, rcx
    and rbx, 4
    test rbx, rbx
    jz .set_bit0_1
    btr ax, 0                       ; Clear bit 0
    jmp .level1_update
.set_bit0_1:
    bts ax, 0                       ; Set bit 0

.level1_update:
    ; Update level 1: bits 1-2
    mov rbx, rcx
    and rbx, 2                      ; Test bit 1 of way index
    mov rdx, rcx
    shr rdx, 2                      ; Which level-1 node?
    inc rdx                         ; Bit position (1 or 2)

    test rbx, rbx
    jz .set_level1_1
    btr ax, dx
    jmp .level2_update
.set_level1_1:
    bts ax, dx

.level2_update:
    ; Update level 2: bits 3-6
    mov rbx, rcx
    and rbx, 1                      ; Test bit 0 of way index
    mov rdx, rcx
    shr rdx, 1                      ; Which level-2 node? (0-3)
    add rdx, 3                      ; Bit position (3-6)

    test rbx, rbx
    jz .set_level2_1
    btr ax, dx
    jmp .done_update
.set_level2_1:
    bts ax, dx

.done_update:
    ; Store updated tree
    mov [r15], al

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; Access L3 - QLRU_H11_M1_R1_U2 (Ivy Bridge, Haswell, Skylake)
; ============================================================================
access_l3_qlru_ivb:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15

    ; Extract set index (runtime configuration)
    mov rax, rdi
    shr rax, 6
    movzx r10, word [runtime_l3_set_mask]
    and rax, r10
    mov r12, rax

    ; Extract tag (runtime configuration)
    mov r13, rdi
    movzx rcx, byte [runtime_l3_tag_shift]
    shr r13, cl

    ; Calculate base pointers
    mov rax, r12
    movzx r10, byte [runtime_l3_assoc]
    imul rax, r10

    lea r14, [l3_cache_tags]
    lea r14, [r14 + rax * 8]

    lea r15, [l3_cache_ages]
    add r15, rax

    ; Search for tag
    xor rcx, rcx
.search_loop:
    movzx r10, byte [runtime_l3_assoc]
    cmp rcx, r10
    jge .not_found

    mov rax, [r14 + rcx * 8]
    cmp rax, r13
    je .found_hit

    inc rcx
    jmp .search_loop

.found_hit:
    ; Apply H11 hit function
    movzx rax, byte [r15 + rcx]
    lea rbx, [qlru_h11_table]
    movzx rax, byte [rbx + rax]
    mov [r15 + rcx], al

    ; Apply U2 update function
    movzx r8, byte [runtime_l3_assoc]
    call qlru_u2_update

    mov rax, CACHE_HIT
    xor rbx, rbx
    jmp .done

.not_found:
    ; Find victim using R1 (first age-3, else way 0)
    xor rcx, rcx
    mov r8, 0                       ; Default to way 0

.find_victim:
    movzx r10, byte [runtime_l3_assoc]
    cmp rcx, r10
    jge .victim_found

    ; Check if empty
    mov rax, [r14 + rcx * 8]
    cmp rax, 0xFFFFFFFFFFFFFFFF
    je .use_this_victim

    ; Check if age 3
    movzx rax, byte [r15 + rcx]
    cmp al, 3
    je .use_this_victim

    inc rcx
    jmp .find_victim

.use_this_victim:
    mov r8, rcx

.victim_found:
    ; Save evicted tag
    mov rbx, [r14 + r8 * 8]

    ; Insert new tag
    mov [r14 + r8 * 8], r13

    ; Set initial age M1
    mov byte [r15 + r8], QLRU_M1

    ; Apply U2 update function
    push r8
    movzx r8, byte [runtime_l3_assoc]
    call qlru_u2_update
    pop r8

    mov rax, CACHE_MISS

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

; ============================================================================
; Access L2 Cache (QLRU_H00_M1_R2_U1)
; ============================================================================
; Input: RDI = address
; Output: RAX = CACHE_HIT or CACHE_MISS
;         RBX = evicted tag (if MISS), 0xFFFFFFFFFFFFFFFF if no eviction
access_l2:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15

    ; Extract set index (bits 14:6 for 512 sets)
    mov rax, rdi
    shr rax, 6
    and rax, (L2_NUM_SETS - 1)
    mov r12, rax                    ; r12 = set index

    ; Extract tag (address >> 15, excluding line offset + set index)
    mov r13, rdi
    shr r13, 15                     ; r13 = tag (bits 15+ for 512 sets * 64 bytes)

    ; Calculate base pointers for this set
    mov rax, r12
    imul rax, L2_ASSOC

    lea r14, [l2_cache_tags]
    lea r14, [r14 + rax * 8]        ; r14 = base of tags for this set

    lea r15, [l2_cache_ages]
    add r15, rax                    ; r15 = base of ages for this set

    ; Search for tag in the set (check all 8 ways)
    xor rcx, rcx                    ; way counter
.search_loop:
    cmp rcx, L2_ASSOC
    jge .not_found

    ; Check if tag matches
    mov rax, [r14 + rcx * 8]
    cmp rax, r13
    je .found_hit

    inc rcx
    jmp .search_loop

.found_hit:
    ; HIT: Apply H00 hit function (all ages → 0)
    mov byte [r15 + rcx], 0         ; Set age to 0

    ; Apply U1 update function: add (3 - max_age_except_hit) to all except hit block
    mov r8, rcx                     ; r8 = hit way index
    call qlru_u1_update_l2

    mov rax, CACHE_HIT
    xor rbx, rbx                    ; No eviction
    jmp .done

.not_found:
    ; MISS: Find victim using R2 (LAST block with age 3, or last empty)
    ; Search backwards from last way
    mov rcx, L2_ASSOC
    dec rcx                         ; Start at last way
    mov r8, -1                      ; victim way (-1 = not found)

.find_victim:
    cmp rcx, 0
    jl .victim_found

    ; Check if slot is empty (tag = 0xFFFFFFFFFFFFFFFF)
    mov rax, [r14 + rcx * 8]
    cmp rax, 0xFFFFFFFFFFFFFFFF
    je .use_this_victim

    ; Check if age is 3
    movzx rax, byte [r15 + rcx]
    cmp al, 3
    je .use_this_victim

    dec rcx
    jmp .find_victim

.use_this_victim:
    mov r8, rcx                     ; Found victim
    jmp .victim_found

.victim_found:
    ; If no victim found, use last way
    cmp r8, -1
    jne .have_victim
    mov r8, L2_ASSOC - 1

.have_victim:
    ; Save evicted tag
    mov rbx, [r14 + r8 * 8]

    ; Insert new tag
    mov [r14 + r8 * 8], r13

    ; Set initial age to M1 (age = 1)
    mov byte [r15 + r8], QLRU_M1

    ; Apply U1 update function: add (3 - max_age_except_replaced) to all except replaced
    ; r8 already contains replaced way index
    call qlru_u1_update_l2

    mov rax, CACHE_MISS

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

; ============================================================================
; QLRU U2 Update Function (Ivy Bridge variant)
; ============================================================================
; Increment all ages by 1 if no block has age 3
; Input: R15 = base of ages array for current set
;        R8 = associativity (L3_ASSOC or L2_ASSOC)
qlru_u2_update:
    push rax
    push rbx
    push rcx

    ; Check if any block has age 3
    xor rcx, rcx                    ; way counter
    xor bl, bl                      ; found_age_3 flag

.check_for_3:
    cmp rcx, r8
    jge .checked_all

    movzx rax, byte [r15 + rcx]
    cmp al, 3
    je .has_age_3

    inc rcx
    jmp .check_for_3

.has_age_3:
    mov bl, 1                       ; Set flag

.checked_all:
    ; If any block has age 3, don't update
    test bl, bl
    jnz .done

    ; No age 3 found - increment all ages (saturate at 3)
    xor rcx, rcx

.increment_loop:
    cmp rcx, r8
    jge .done

    movzx rax, byte [r15 + rcx]
    inc al
    cmp al, 3
    jle .no_sat
    mov al, 3

.no_sat:
    mov [r15 + rcx], al
    inc rcx
    jmp .increment_loop

.done:
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; QLRU U3 Update Function
; ============================================================================
; Increment all ages except accessed/replaced by 1 if no block has age 3
; Input: R15 = base of ages array
;        R8 = excluded way index
;        R9 = associativity
qlru_u3_update:
    push rax
    push rbx
    push rcx
    push rdx

    ; Check if any block has age 3
    xor rcx, rcx
    xor bl, bl                      ; found_age_3 flag

.check_for_3:
    cmp rcx, r9
    jge .checked_all

    movzx rax, byte [r15 + rcx]
    cmp al, 3
    je .has_age_3

    inc rcx
    jmp .check_for_3

.has_age_3:
    mov bl, 1

.checked_all:
    test bl, bl
    jnz .done

    ; No age 3 - increment all except excluded (saturate at 3)
    xor rcx, rcx

.increment_loop:
    cmp rcx, r9
    jge .done

    ; Skip excluded way
    cmp rcx, r8
    je .skip_way

    movzx rax, byte [r15 + rcx]
    inc al
    cmp al, 3
    jle .no_sat
    mov al, 3

.no_sat:
    mov [r15 + rcx], al

.skip_way:
    inc rcx
    jmp .increment_loop

.done:
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; QLRU U1 Update Function for L2
; ============================================================================
; Add (3 - max_age_except_excluded) to all ages except excluded way
; Input: R15 = base of ages array for current set
;        R8 = excluded way index (hit or replaced block)
qlru_u1_update_l2:
    push rcx
    push rax
    push rbx
    push rdx

    ; Find max age in the set (excluding way R8)
    xor rbx, rbx                    ; max_age = 0
    xor rcx, rcx                    ; way counter

.find_max:
    cmp rcx, L2_ASSOC
    jge .found_max

    ; Skip excluded way
    cmp rcx, r8
    je .skip_way

    movzx rax, byte [r15 + rcx]
    cmp al, bl
    jle .not_greater
    mov bl, al                      ; Update max

.not_greater:
.skip_way:
    inc rcx
    jmp .find_max

.found_max:
    ; Calculate increment = 3 - max_age
    mov al, 3
    sub al, bl                      ; al = 3 - max_age

    ; If increment is 0, nothing to do
    test al, al
    jz .done

    ; Add increment to all ages except excluded (saturate at 3)
    xor rcx, rcx

.update_loop:
    cmp rcx, L2_ASSOC
    jge .done

    ; Skip excluded way
    cmp rcx, r8
    je .skip_update

    movzx rbx, byte [r15 + rcx]
    add bl, al                      ; Add increment

    ; Saturate at 3
    cmp bl, 3
    jle .no_saturate
    mov bl, 3

.no_saturate:
    mov [r15 + rcx], bl

.skip_update:
    inc rcx
    jmp .update_loop

.done:
    pop rdx
    pop rbx
    pop rax
    pop rcx
    ret

; ============================================================================
; Access L3 Cache (Runtime Policy Dispatcher)
; ============================================================================
; Input: RDI = address
; Output: RAX = CACHE_HIT or CACHE_MISS
;         RBX = evicted tag (if MISS), 0xFFFFFFFFFFFFFFFF if no eviction
access_l3:
    push rdi                        ; Save address

    ; Check runtime L3 policy
    movzx rax, byte [runtime_l3_policy]

    cmp al, 4
    je .dispatch_mru

    cmp al, 5
    je .dispatch_mru_n

    cmp al, 3
    je .dispatch_qlru_ivb

    cmp al, 1
    je .dispatch_qlru_cfl

    ; Default: Coffee Lake
    jmp .dispatch_qlru_cfl

.dispatch_mru:
    pop rdi
    lea rsi, [l3_cache_tags]
    lea rdx, [l3_cache_ages]
    movzx rcx, word [runtime_l3_sets]
    movzx r8, byte [runtime_l3_assoc]
    call mru_access
    ret

.dispatch_mru_n:
    pop rdi
    lea rsi, [l3_cache_tags]
    lea rdx, [l3_cache_ages]
    movzx rcx, word [runtime_l3_sets]
    movzx r8, byte [runtime_l3_assoc]
    call mru_n_access
    ret

.dispatch_qlru_ivb:
    pop rdi
    call access_l3_qlru_ivb
    ret

.dispatch_qlru_cfl:
    pop rdi
    call access_l3_qlru_cfl
    ret

; ============================================================================
; Access L3 - QLRU_H11_M1_R0_U0 (Coffee Lake)
; ============================================================================
access_l3_qlru_cfl:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15

    ; Extract set index (runtime configuration)
    mov rax, rdi
    shr rax, 6
    movzx r10, word [runtime_l3_set_mask]
    and rax, r10
    mov r12, rax                    ; r12 = set index

    ; Extract tag (runtime configuration)
    mov r13, rdi
    movzx rcx, byte [runtime_l3_tag_shift]
    shr r13, cl                     ; r13 = tag

    ; Calculate base pointers for this set
    mov rax, r12
    movzx r10, byte [runtime_l3_assoc]
    imul rax, r10

    lea r14, [l3_cache_tags]
    lea r14, [r14 + rax * 8]        ; r14 = base of tags for this set

    lea r15, [l3_cache_ages]
    add r15, rax                    ; r15 = base of ages for this set

    ; Search for tag in the set
    xor rcx, rcx                    ; way counter
.search_loop:
    movzx r10, byte [runtime_l3_assoc]
    cmp rcx, r10
    jge .not_found

    ; Check if tag matches
    mov rax, [r14 + rcx * 8]
    cmp rax, r13
    je .found_hit

    inc rcx
    jmp .search_loop

.found_hit:
    ; HIT: Apply H11 hit function and update
    ; H11: 3→1, 2→1, 1→0, 0→0
    movzx rax, byte [r15 + rcx]     ; Get current age
    lea rbx, [qlru_h11_table]
    movzx rax, byte [rbx + rax]     ; Apply hit function
    mov [r15 + rcx], al             ; Update age

    ; Apply U0 update function: add (3 - max_age) to all ages
    call qlru_u0_update_l3

    mov rax, CACHE_HIT
    xor rbx, rbx                    ; No eviction
    jmp .done

.not_found:
    ; MISS: Find victim using R0 (first block with age 3, or first empty)
    xor rcx, rcx                    ; way counter
    mov r8, -1                      ; victim way (-1 = not found)

.find_victim:
    movzx r10, byte [runtime_l3_assoc]
    cmp rcx, r10
    jge .victim_found

    ; Check if slot is empty (tag = 0xFFFFFFFFFFFFFFFF)
    mov rax, [r14 + rcx * 8]
    cmp rax, 0xFFFFFFFFFFFFFFFF
    je .use_this_victim

    ; Check if age is 3
    movzx rax, byte [r15 + rcx]
    cmp al, 3
    je .use_this_victim

    inc rcx
    jmp .find_victim

.use_this_victim:
    mov r8, rcx                     ; Found victim
    jmp .victim_found

.victim_found:
    ; If no victim found with age 3, use way 0 (shouldn't happen with proper QLRU)
    cmp r8, -1
    jne .have_victim
    xor r8, r8

.have_victim:
    ; Save evicted tag
    mov rbx, [r14 + r8 * 8]

    ; Insert new tag
    mov [r14 + r8 * 8], r13

    ; Set initial age to M1 (age = 1)
    mov byte [r15 + r8], QLRU_M1

    ; Apply U0 update function: add (3 - max_age) to all ages
    call qlru_u0_update_l3

    mov rax, CACHE_MISS

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

; ============================================================================
; QLRU U0 Update Function for L3
; ============================================================================
; Add (3 - max_age) to all ages in the set
; Input: R15 = base of ages array for current set
qlru_u0_update_l3:
    push rcx
    push rax
    push rbx

    ; Find max age in the set
    xor rbx, rbx                    ; max_age = 0
    xor rcx, rcx                    ; way counter

.find_max:
    movzx r10, byte [runtime_l3_assoc]
    cmp rcx, r10
    jge .found_max

    movzx rax, byte [r15 + rcx]
    cmp al, bl
    jle .not_greater
    mov bl, al                      ; Update max

.not_greater:
    inc rcx
    jmp .find_max

.found_max:
    ; Calculate increment = 3 - max_age
    mov al, 3
    sub al, bl                      ; al = 3 - max_age

    ; If increment is 0, nothing to do
    test al, al
    jz .done

    ; Add increment to all ages (saturate at 3)
    xor rcx, rcx

.update_loop:
    movzx r10, byte [runtime_l3_assoc]
    cmp rcx, r10
    jge .done

    movzx rbx, byte [r15 + rcx]
    add bl, al                      ; Add increment

    ; Saturate at 3
    cmp bl, 3
    jle .no_saturate
    mov bl, 3

.no_saturate:
    mov [r15 + rcx], bl
    inc rcx
    jmp .update_loop

.done:
    pop rbx
    pop rax
    pop rcx
    ret

; ============================================================================
; Print CPU Name (Runtime)
; ============================================================================
print_cpu_name:
    push rax
    push rdi
    push rsi
    push rdx
    push rbx

    ; Print "CPU: "
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [rel .cpu_prefix]
    mov rdx, 5
    syscall

    ; Get CPU name from table
    movzx rax, byte [runtime_cpu_id]
    imul rax, 32                    ; Each config is 32 bytes
    lea rbx, [cpu_configs]
    add rbx, rax

    ; Print CPU name (first 16 bytes of config, null-terminated)
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    mov rsi, rbx
    mov rdx, 16
    syscall

    ; Print newline
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [newline]
    mov rdx, 1
    syscall

    pop rbx
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

.cpu_prefix: db "CPU: "

; ============================================================================
; Print CPU Configuration
; ============================================================================
; Prints L1, L2, L3 cache configuration from runtime config
print_cpu_config:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi

    ; Print L1 config
    lea rsi, [.l1_prefix]
    call .print_cache_line
    movzx rax, word [runtime_l1_sets]
    movzx rbx, byte [runtime_l1_assoc]
    movzx rcx, byte [runtime_l1_lat]
    call .print_cache_params

    ; Print L2 config
    lea rsi, [.l2_prefix]
    call .print_cache_line
    movzx rax, word [runtime_l2_sets]
    movzx rbx, byte [runtime_l2_assoc]
    movzx rcx, byte [runtime_l2_lat]
    call .print_cache_params

    ; Print L3 config
    lea rsi, [.l3_prefix]
    call .print_cache_line
    movzx rax, word [runtime_l3_sets]
    movzx rbx, byte [runtime_l3_assoc]
    movzx rcx, byte [runtime_l3_lat]
    call .print_cache_params

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Helper: Print cache line prefix (e.g., "L1: ")
.print_cache_line:
    push rax
    push rdi
    push rdx
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    ; rsi already contains prefix address
    mov rdx, 4
    syscall
    pop rdx
    pop rdi
    pop rax
    ret

; Helper: Print cache parameters (sets × ways, latency)
; Input: RAX = sets, RBX = ways, RCX = latency
.print_cache_params:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12
    push r13
    push r14

    mov r12, rax                    ; Save sets
    mov r13, rbx                    ; Save ways
    mov r14, rcx                    ; Save latency

    ; Build string in output_buffer
    lea rdi, [output_buffer]
    xor rsi, rsi

    ; Print sets number
    mov eax, r12d
    call append_decimal

    ; Append " sets x "
    mov byte [rdi + rsi], ' '
    inc rsi
    mov byte [rdi + rsi], 's'
    inc rsi
    mov byte [rdi + rsi], 'e'
    inc rsi
    mov byte [rdi + rsi], 't'
    inc rsi
    mov byte [rdi + rsi], 's'
    inc rsi
    mov byte [rdi + rsi], ' '
    inc rsi
    mov byte [rdi + rsi], 'x'
    inc rsi
    mov byte [rdi + rsi], ' '
    inc rsi

    ; Print ways number
    mov eax, r13d
    call append_decimal

    ; Append "-way, "
    mov byte [rdi + rsi], '-'
    inc rsi
    mov byte [rdi + rsi], 'w'
    inc rsi
    mov byte [rdi + rsi], 'a'
    inc rsi
    mov byte [rdi + rsi], 'y'
    inc rsi
    mov byte [rdi + rsi], ','
    inc rsi
    mov byte [rdi + rsi], ' '
    inc rsi

    ; Print latency
    mov eax, r14d
    call append_decimal

    ; Append " cycles\n"
    mov byte [rdi + rsi], ' '
    inc rsi
    mov byte [rdi + rsi], 'c'
    inc rsi
    mov byte [rdi + rsi], 'y'
    inc rsi
    mov byte [rdi + rsi], 'c'
    inc rsi
    mov byte [rdi + rsi], 'l'
    inc rsi
    mov byte [rdi + rsi], 'e'
    inc rsi
    mov byte [rdi + rsi], 's'
    inc rsi
    mov byte [rdi + rsi], 10        ; newline
    inc rsi

    ; Write the buffer
    mov rdx, rsi                    ; Length
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [output_buffer]
    syscall

    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

.l1_prefix: db "L1: "
.l2_prefix: db "L2: "
.l3_prefix: db "L3: "

; ============================================================================
; Print CSV Header
; ============================================================================
print_csv_header:
    push rax
    push rdi
    push rsi
    push rdx

    movzx rax, byte [output_mode]

    cmp rax, OUTPUT_SIMPLE
    je .simple
    cmp rax, OUTPUT_DETAILED
    je .detailed
    cmp rax, OUTPUT_FULL
    je .full

.detailed:
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [csv_header_detailed]
    mov rdx, csv_header_detailed_len
    syscall
    jmp .done

.simple:
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [csv_header_simple]
    mov rdx, csv_header_simple_len
    syscall
    jmp .done

.full:
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [csv_header_full]
    mov rdx, csv_header_full_len
    syscall

.done:
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

; ============================================================================
; Output Results
; ============================================================================
; Format and output based on output_mode
output_results:
    push rbp
    mov rbp, rsp

    lea rdi, [output_buffer]
    xor rsi, rsi                    ; rsi = buffer position

    movzx rax, byte [output_mode]
    cmp rax, OUTPUT_SIMPLE
    je .output_simple
    cmp rax, OUTPUT_FULL
    je .output_full
    ; else OUTPUT_DETAILED (fall through)

.output_detailed:
    ; Format: address,L1_result,L1_cycles,L2_result,L2_cycles,L3_result,L3_cycles,total_cycles

    ; Write address in hex
    mov rax, [current_address]
    call append_hex
    mov byte [rdi + rsi], ','
    inc rsi

    ; L1 result
    movzx rax, byte [result_l1]
    cmp al, 0xFF
    je .l1_skip
    call append_hit_miss
    mov byte [rdi + rsi], ','
    inc rsi

    ; L1 cycles
    mov eax, [cycles_l1]
    call append_decimal
    mov byte [rdi + rsi], ','
    inc rsi

    ; L2 result
    movzx rax, byte [result_l2]
    cmp al, 0xFF
    je .l2_skip
    call append_hit_miss
    mov byte [rdi + rsi], ','
    inc rsi

    ; L2 cycles
    mov eax, [cycles_l2]
    call append_decimal
    mov byte [rdi + rsi], ','
    inc rsi

    ; L3 result
    movzx rax, byte [result_l3]
    cmp al, 0xFF
    je .l3_skip
    call append_hit_miss
    mov byte [rdi + rsi], ','
    inc rsi

    ; L3 cycles
    mov eax, [cycles_l3]
    call append_decimal
    mov byte [rdi + rsi], ','
    inc rsi

    jmp .write_total

.l1_skip:
    mov byte [rdi + rsi], '-'
    inc rsi
    mov byte [rdi + rsi], ','
    inc rsi
    mov byte [rdi + rsi], '0'
    inc rsi
    mov byte [rdi + rsi], ','
    inc rsi
.l2_skip:
    mov byte [rdi + rsi], '-'
    inc rsi
    mov byte [rdi + rsi], ','
    inc rsi
    mov byte [rdi + rsi], '0'
    inc rsi
    mov byte [rdi + rsi], ','
    inc rsi
.l3_skip:
    mov byte [rdi + rsi], '-'
    inc rsi
    mov byte [rdi + rsi], ','
    inc rsi
    mov byte [rdi + rsi], '0'
    inc rsi
    mov byte [rdi + rsi], ','
    inc rsi

.write_total:
    ; Total cycles
    mov eax, [cycles_total]
    call append_decimal
    mov byte [rdi + rsi], 10        ; newline
    inc rsi
    jmp .print

.output_simple:
    ; Format: address,total_cycles
    mov rax, [current_address]
    call append_hex
    mov byte [rdi + rsi], ','
    inc rsi
    mov eax, [cycles_total]
    call append_decimal
    mov byte [rdi + rsi], 10
    inc rsi
    jmp .print

.output_full:
    ; Format: address,L1_result,L1_cycles,L1_evicted,L2_result,L2_cycles,L2_evicted,L3_result,L3_cycles,L3_evicted,total_cycles

    ; Write address
    mov rax, [current_address]
    call append_hex
    mov byte [rdi + rsi], ','
    inc rsi

    ; L1 result
    movzx rax, byte [result_l1]
    call append_hit_miss
    mov byte [rdi + rsi], ','
    inc rsi

    ; L1 cycles
    mov eax, [cycles_l1]
    call append_decimal
    mov byte [rdi + rsi], ','
    inc rsi

    ; L1 evicted
    mov rax, [evicted_l1]
    call append_hex
    mov byte [rdi + rsi], ','
    inc rsi

    ; L2 result
    movzx rax, byte [result_l2]
    call append_hit_miss
    mov byte [rdi + rsi], ','
    inc rsi

    ; L2 cycles
    mov eax, [cycles_l2]
    call append_decimal
    mov byte [rdi + rsi], ','
    inc rsi

    ; L2 evicted
    mov rax, [evicted_l2]
    call append_hex
    mov byte [rdi + rsi], ','
    inc rsi

    ; L3 result
    movzx rax, byte [result_l3]
    call append_hit_miss
    mov byte [rdi + rsi], ','
    inc rsi

    ; L3 cycles
    mov eax, [cycles_l3]
    call append_decimal
    mov byte [rdi + rsi], ','
    inc rsi

    ; L3 evicted
    mov rax, [evicted_l3]
    call append_hex
    mov byte [rdi + rsi], ','
    inc rsi

    ; Total cycles
    mov eax, [cycles_total]
    call append_decimal
    mov byte [rdi + rsi], 10
    inc rsi

.print:
    ; Write to stdout
    mov rax, SYS_WRITE
    push rdi
    mov rdi, STDOUT
    lea rdx, [output_buffer]
    mov rcx, rsi                    ; length
    mov rsi, rdx
    mov rdx, rcx
    syscall
    pop rdi

    pop rbp
    ret

; ============================================================================
; Print Statistics Summary
; ============================================================================
print_statistics:
    push rbp
    mov rbp, rsp

    ; Print header
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [stats_header]
    mov rdx, stats_header_len
    syscall

    ; Total accesses
    lea rsi, [stats_total]
    mov rax, [total_accesses]
    call print_stat_line

    ; L1 hits
    lea rsi, [stats_l1_hits]
    mov rax, [l1_hits]
    call print_stat_line

    ; L1 misses
    lea rsi, [stats_l1_misses]
    mov rax, [l1_misses]
    call print_stat_line

    ; L1 hit rate
    lea rsi, [stats_l1_rate]
    mov rax, [l1_hits]
    mov rbx, [total_accesses]
    call print_percentage

    ; L2 hits
    lea rsi, [stats_l2_hits]
    mov rax, [l2_hits]
    call print_stat_line

    ; L2 misses
    lea rsi, [stats_l2_misses]
    mov rax, [l2_misses]
    call print_stat_line

    ; L2 hit rate (of L1 misses)
    lea rsi, [stats_l2_rate]
    mov rax, [l2_hits]
    mov rbx, [l1_misses]
    call print_percentage

    ; L3 hits
    lea rsi, [stats_l3_hits]
    mov rax, [l3_hits]
    call print_stat_line

    ; L3 misses
    lea rsi, [stats_l3_misses]
    mov rax, [l3_misses]
    call print_stat_line

    ; L3 hit rate (of L2 misses)
    lea rsi, [stats_l3_rate]
    mov rax, [l3_hits]
    mov rbx, [l2_misses]
    call print_percentage

    ; Total cycles
    lea rsi, [stats_total_cycles]
    mov rax, [total_cycles]
    call print_stat_line

    ; Average cycles per access
    lea rsi, [stats_avg_cycles]
    mov rax, [total_cycles]
    mov rbx, [total_accesses]
    call print_average

    pop rbp
    ret

; ============================================================================
; Helper: Print statistic line (label + number)
; ============================================================================
; Input: RSI = label string (null-terminated)
;        RAX = number
print_stat_line:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov rbx, rax                    ; Save number

    ; Print label
    mov rdi, rsi
    call strlen
    mov rdx, rax                    ; length
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    ; rsi already set
    syscall

    ; Print number
    lea rdi, [output_buffer]
    xor rsi, rsi
    mov rax, rbx
    call append_decimal

    ; Add newline
    mov byte [rdi + rsi], 10
    inc rsi

    ; Write
    mov rax, SYS_WRITE
    push rdi
    mov rdi, STDOUT
    lea rdx, [output_buffer]
    mov rcx, rsi
    mov rsi, rdx
    mov rdx, rcx
    syscall
    pop rdi

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; Helper: Print percentage (numerator/denominator * 100)
; ============================================================================
; Input: RSI = label string
;        RAX = numerator
;        RBX = denominator
print_percentage:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Save values
    mov r12, rax                    ; numerator
    mov r13, rbx                    ; denominator

    ; Print label
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    ; rsi already set
    syscall

    ; Calculate percentage: (numerator * 100) / denominator
    test r13, r13                   ; Check for divide by zero
    jz .zero_percent

    mov rax, r12
    imul rax, 100
    xor rdx, rdx
    div r13                         ; rax = percentage

    jmp .print_it

.zero_percent:
    xor rax, rax

.print_it:
    ; Print percentage
    lea rdi, [output_buffer]
    xor rsi, rsi
    call append_decimal

    ; Add %
    lea rbx, [stats_percent]
    mov ax, [rbx]
    mov [rdi + rsi], ax
    add rsi, 2

    ; Write
    mov rax, SYS_WRITE
    push rdi
    mov rdi, STDOUT
    lea rdx, [output_buffer]
    mov rcx, rsi
    mov rsi, rdx
    mov rdx, rcx
    syscall
    pop rdi

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; Helper: Print average (total/count)
; ============================================================================
; Input: RSI = label string
;        RAX = total
;        RBX = count
print_average:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    mov r12, rax                    ; total
    mov r13, rbx                    ; count

    ; Print label
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rax, SYS_WRITE
    mov rdi, STDOUT
    ; rsi already set
    syscall

    ; Calculate average
    test r13, r13
    jz .zero_avg

    mov rax, r12
    xor rdx, rdx
    div r13

    jmp .print_avg

.zero_avg:
    xor rax, rax

.print_avg:
    ; Print average
    lea rdi, [output_buffer]
    xor rsi, rsi
    call append_decimal

    ; Add newline
    mov byte [rdi + rsi], 10
    inc rsi

    ; Write
    mov rax, SYS_WRITE
    push rdi
    mov rdi, STDOUT
    lea rdx, [output_buffer]
    mov rcx, rsi
    mov rsi, rdx
    mov rdx, rcx
    syscall
    pop rdi

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; Helper: String length
; ============================================================================
; Input: RDI = string pointer
; Output: RAX = length
strlen:
    push rcx
    push rdi
    xor rax, rax
    xor rcx, rcx
    not rcx
    xor al, al
    cld
    repne scasb
    not rcx
    dec rcx
    mov rax, rcx
    pop rdi
    pop rcx
    ret

; ============================================================================
; MRU (Most Recently Used) Policy - Nehalem
; ============================================================================
; Each way has 1 bit: 0=MRU, 1=not-MRU
; On access: set bit to 0, leave others unchanged
; When all bits are 0: reset all except current to 1
; Evict: first block with bit=1
;
; Input: RDI = address, RSI = tags ptr, RDX = ages ptr (stores MRU bits)
;        RCX = num_sets, R8 = assoc
; Output: RAX = HIT(0) or MISS(1), RBX = evicted tag
mru_access:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15

    ; Extract set and tag (runtime configuration)
    mov rax, rdi
    shr rax, 6
    movzx r10, word [runtime_l3_set_mask]
    and rax, r10                    ; Use runtime mask
    mov r12, rax                    ; r12 = set index

    mov r13, rdi
    movzx rcx, byte [runtime_l3_tag_shift]
    shr r13, cl                     ; Use runtime shift

    ; Calculate base pointers
    mov rax, r12
    imul rax, r8                    ; r8 = assoc

    mov r14, rsi
    lea r14, [r14 + rax * 8]        ; r14 = tags base

    mov r15, rdx
    add r15, rax                    ; r15 = MRU bits base

    ; Search for tag
    xor rcx, rcx
.search:
    cmp rcx, r8
    jge .not_found

    mov rax, [r14 + rcx * 8]
    cmp rax, r13
    je .found_hit

    inc rcx
    jmp .search

.found_hit:
    ; Set this way's bit to 0 (MRU)
    mov byte [r15 + rcx], 0

    ; Check if all bits are 0
    call mru_check_all_zero
    test al, al
    jz .hit_done

    ; All zero - reset all except current to 1
    xor rdx, rdx
.reset_loop:
    cmp rdx, r8
    jge .hit_done

    cmp rdx, rcx                    ; Skip current way
    je .skip_reset

    mov byte [r15 + rdx], 1

.skip_reset:
    inc rdx
    jmp .reset_loop

.hit_done:
    mov rax, CACHE_HIT
    xor rbx, rbx
    jmp .done

.not_found:
    ; Find victim: first block with bit=1 (not-MRU)
    xor rcx, rcx
    mov r9, -1                      ; victim index

.find_victim:
    cmp rcx, r8
    jge .victim_found

    ; Check if slot empty
    mov rax, [r14 + rcx * 8]
    cmp rax, 0xFFFFFFFFFFFFFFFF
    je .use_victim

    ; Check if bit=1 (not-MRU)
    movzx rax, byte [r15 + rcx]
    test al, al
    jnz .use_victim

    inc rcx
    jmp .find_victim

.use_victim:
    mov r9, rcx
    jmp .victim_found

.victim_found:
    ; If no victim found, use first way
    cmp r9, -1
    jne .have_victim
    xor r9, r9

.have_victim:
    mov rbx, [r14 + r9 * 8]         ; Evicted tag
    mov [r14 + r9 * 8], r13         ; Insert new tag
    mov byte [r15 + r9], 0          ; Set to MRU

    ; Check and reset if needed
    call mru_check_all_zero
    test al, al
    jz .miss_done

    xor rdx, rdx
.reset_loop2:
    cmp rdx, r8
    jge .miss_done

    cmp rdx, r9
    je .skip_reset2

    mov byte [r15 + rdx], 1

.skip_reset2:
    inc rdx
    jmp .reset_loop2

.miss_done:
    mov rax, CACHE_MISS

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

; Helper: Check if all MRU bits are 0
; Input: R15 = MRU bits base, R8 = assoc
; Output: AL = 1 if all zero, 0 otherwise
mru_check_all_zero:
    push rcx
    xor rcx, rcx
    xor al, al

.check_loop:
    cmp rcx, r8
    jge .all_zero

    movzx rax, byte [r15 + rcx]
    test al, al
    jnz .not_all_zero

    inc rcx
    jmp .check_loop

.all_zero:
    mov al, 1
    jmp .check_done

.not_all_zero:
    xor al, al

.check_done:
    pop rcx
    ret

; ============================================================================
; MRU_N (Sandy Bridge) - Only updates when cache is full
; ============================================================================
; Same as MRU but only updates bits when all ways are filled
mru_n_access:
    ; For now, identical to MRU (would need full/not-full detection)
    ; This is a simplification - full implementation would check if cache full(wp)
    jmp mru_access

; ============================================================================
; Helper: Append HIT or MISS to buffer
; ============================================================================
; Input: AL = result code (0=HIT, 1=MISS, 0xFF=skip)
;        RDI = buffer pointer
;        RSI = current position
; Output: RSI updated
append_hit_miss:
    cmp al, CACHE_HIT
    je .hit
    cmp al, CACHE_MISS
    je .miss
    ; Unknown/skip
    mov byte [rdi + rsi], '-'
    inc rsi
    ret

.hit:
    mov byte [rdi + rsi], 'H'
    inc rsi
    mov byte [rdi + rsi], 'I'
    inc rsi
    mov byte [rdi + rsi], 'T'
    inc rsi
    ret

.miss:
    mov byte [rdi + rsi], 'M'
    inc rsi
    mov byte [rdi + rsi], 'I'
    inc rsi
    mov byte [rdi + rsi], 'S'
    inc rsi
    mov byte [rdi + rsi], 'S'
    inc rsi
    ret

; ============================================================================
; Helper: Append decimal number to buffer
; ============================================================================
; Input: EAX = number
;        RDI = buffer pointer
;        RSI = current position
; Output: RSI updated
append_decimal:
    push rbx
    push rcx
    push rdx
    push r8

    ; Handle zero specially
    test eax, eax
    jnz .non_zero
    mov byte [rdi + rsi], '0'
    inc rsi
    jmp .done

.non_zero:
    ; Convert to decimal digits (reversed)
    mov ebx, 10
    xor rcx, rcx                    ; digit count
    mov r8, rsi                     ; save start position

.divide_loop:
    xor edx, edx
    div ebx                         ; eax = quotient, edx = remainder
    add dl, '0'
    mov [rdi + rsi], dl
    inc rsi
    inc rcx
    test eax, eax
    jnz .divide_loop

    ; Reverse the digits
    mov rax, r8                     ; start
    mov rbx, rsi
    dec rbx                         ; end

.reverse_loop:
    cmp rax, rbx
    jge .done

    ; Swap [rax] and [rbx]
    mov cl, [rdi + rax]
    mov dl, [rdi + rbx]
    mov [rdi + rax], dl
    mov [rdi + rbx], cl

    inc rax
    dec rbx
    jmp .reverse_loop

.done:
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================================
; Helper: Append hex number to buffer
; ============================================================================
; Input: RAX = number
;        RDI = buffer pointer
;        RSI = current position
; Output: RSI updated
append_hex:
    push rbx
    push rcx
    push rdx

    ; Write "0x" prefix
    mov byte [rdi + rsi], '0'
    inc rsi
    mov byte [rdi + rsi], 'x'
    inc rsi

    ; Convert to hex (16 digits for 64-bit)
    mov rcx, 16
    mov rbx, rax

.hex_loop:
    rol rbx, 4                      ; Rotate left by 4 bits
    mov rax, rbx
    and rax, 0xF                    ; Get lowest 4 bits

    cmp al, 10
    jl .digit
    add al, 'a' - 10
    jmp .write
.digit:
    add al, '0'

.write:
    mov [rdi + rsi], al
    inc rsi
    dec rcx
    jnz .hex_loop

    pop rdx
    pop rcx
    pop rbx
    ret
