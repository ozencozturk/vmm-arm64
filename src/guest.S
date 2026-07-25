.text
.global _start
_start:
    movz x0, #0x1000, lsl #16     // UART base  0x1000_0000
    movz x3, #0x0010, lsl #16     // poweroff   0x0010_0000
    adr  x1, msg                  // PC-relative -> message (load-address independent)

loop:
    ldrb w2, [x1]                 // next char (RAM read, no fault)
    cbz  w2, done                 // NUL terminator -> finish

wait_thre:
    ldrb w4, [x0, #5]             // read LSR  (UART unmapped -> MMIO READ exit)
    tbz  w4, #5, wait_thre        // THRE = bit 5; spin until transmitter ready
    strb w2, [x0]                 // write THR (UART unmapped -> MMIO WRITE exit)
    add  x1, x1, #1               // advance (plain add, NOT a writeback form)
    b    loop

done:
    str  wzr, [x3]                // any store to poweroff (SRT=31/XZR) -> exit signal
halt:
    b    halt                     // safety net: never fall off the end

msg:
    .asciz "Hello from EL1\n"     // 15 chars + NUL = 16 bytes
