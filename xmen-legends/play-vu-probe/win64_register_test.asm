; Probe the Windows nonvolatile SIMD registers without corrupting the test caller.
; RCX=function, RDX=context, R8=aligned sentinel, R9=ten-vector output buffer.
.code
playVuCheckRegisters PROC FRAME
    sub rsp, 216
    .allocstack 216
    movaps [rsp+32], xmm6
    .savexmm128 xmm6, 32
    movaps [rsp+48], xmm7
    .savexmm128 xmm7, 48
    movaps [rsp+64], xmm8
    .savexmm128 xmm8, 64
    movaps [rsp+80], xmm9
    .savexmm128 xmm9, 80
    movaps [rsp+96], xmm10
    .savexmm128 xmm10, 96
    movaps [rsp+112], xmm11
    .savexmm128 xmm11, 112
    movaps [rsp+128], xmm12
    .savexmm128 xmm12, 128
    movaps [rsp+144], xmm13
    .savexmm128 xmm13, 144
    movaps [rsp+160], xmm14
    .savexmm128 xmm14, 160
    movaps [rsp+176], xmm15
    .savexmm128 xmm15, 176
    .endprolog
    mov [rsp+192], r9
    mov rax, rcx
    mov rcx, rdx
    movaps xmm0, [r8]
    movaps xmm6, xmm0
    movaps xmm7, xmm0
    movaps xmm8, xmm0
    movaps xmm9, xmm0
    movaps xmm10, xmm0
    movaps xmm11, xmm0
    movaps xmm12, xmm0
    movaps xmm13, xmm0
    movaps xmm14, xmm0
    movaps xmm15, xmm0
    call rax
    mov r9, [rsp+192]
    movups [r9], xmm6
    movups [r9+16], xmm7
    movups [r9+32], xmm8
    movups [r9+48], xmm9
    movups [r9+64], xmm10
    movups [r9+80], xmm11
    movups [r9+96], xmm12
    movups [r9+112], xmm13
    movups [r9+128], xmm14
    movups [r9+144], xmm15
    movaps xmm6, [rsp+32]
    movaps xmm7, [rsp+48]
    movaps xmm8, [rsp+64]
    movaps xmm9, [rsp+80]
    movaps xmm10, [rsp+96]
    movaps xmm11, [rsp+112]
    movaps xmm12, [rsp+128]
    movaps xmm13, [rsp+144]
    movaps xmm14, [rsp+160]
    movaps xmm15, [rsp+176]
    add rsp, 216
    ret
playVuCheckRegisters ENDP
END
