.align 0
.p2align 0
// .globl	decompress_src
.globl	decompress_dest
.extern entry
.globl _start

_start: 
decompress: 
    // x17 src
    // w18 bb
    // x19 dest
    // w21 constant 1
    // w22 constant 3
    adr x17, decompress_dest
    ldr x19, [x17], #0x8
    mov x29, x19

    mov	w21, #0x1               // =1
    mov	w22, #0x3               // =3
    mov	w23, #0x1               // =1
decompress_28:
    bl	getbit
    tbz	w0, #0x0, decompress_4c
    ldrb	w8, [x17], #0x1
    strb	w8, [x19], #0x1
    b	decompress_28
decompress_4c:
    mov	w24, #0x1               // =1
decompress_50:
    bl	getbit
    bl	OUTLINED_FUNCTION_1
    tbnz	w0, #0x0, decompress_6c
    bl	getbit
    bfi	w0, w20, #1, #31
    sub	w24, w0, #0x2
    b	decompress_50
decompress_6c:
    cmp	w20, #0x2
    b.ne	decompress_8c
    bl	getbit
    tbz	w0, #0x0, decompress_b4
decompress_7c:
    bl	getbit
    tst	w0, #0x1
    cinc	w8, w21, ne
    b	decompress_e4
decompress_8c:
    ldrb	w8, [x17], #0x1
    orr	w9, w8, w20, lsl #8
    sub	w9, w9, #0x300
    cmn	w9, #0x1
    b.eq	decompress_114
    lsr	w9, w9, #1
    add	w23, w9, #0x1
    tbz	w8, #0x0, decompress_7c
decompress_b4:
    bl	getbit
    tbz	w0, #0x0, decompress_cc
    bl	getbit
    tst	w0, #0x1
    cinc	w8, w22, ne
    b	decompress_e4
decompress_cc:
    mov	w24, #0x1               // =1
decompress_d0:
    bl	getbit
    bl	OUTLINED_FUNCTION_1
    mov	w24, w20
    tbz	w0, #0x0, decompress_d0
    add	w8, w20, #0x3
decompress_e4:
    sub	x10, x19, w23, uxtw
    mov	x9, xzr
    cmp	w23, #0x500
    sub	x9, x9, w23, uxtw
    cinc	w8, w8, hi
    ldrb	w10, [x10]
    strb	w10, [x19], #0x1
decompress_100:
    ldrb	w10, [x19, x9]
    subs	w8, w8, #0x1
    strb	w10, [x19], #0x1
    b.ne	decompress_100
    b	decompress_28
decompress_114:
    b   entry

OUTLINED_FUNCTION_1:
    mov	w20, w0
    bfi	w20, w24, #1, #31

getbit:
    lsl	w18, w18, #1
    tst	w18, #0xff
    b.ne	gotbit
    ldrb	w18, [x17], #0x1
    orr	w18, w21, w18, lsl #1
gotbit:
    ubfx	w0, w18, #8, #1
    ret


decompress_dest:
    .8byte 0
compressed_start:   
