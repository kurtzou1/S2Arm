// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Synthetic shared object: adjacent executable bytes permit exact range tests.
// Its name has no guest-carrier prefix; ownership comes only from g_mod.
    .section .text.fixture,"ax",%progbits
    .p2align 4
    .global s2a_fixture_before
    .type s2a_fixture_before,%function
s2a_fixture_before:
    ret
    .size s2a_fixture_before, .-s2a_fixture_before
    .p2align 4
    .global s2a_fixture_begin
    .global s2a_fixture_entry
    .type s2a_fixture_entry,%function
s2a_fixture_begin:
s2a_fixture_entry:
    mov w0, #73
    ret
    .size s2a_fixture_entry, .-s2a_fixture_entry
    .p2align 4
    .global s2a_fixture_patch
    .type s2a_fixture_patch,%function
s2a_fixture_patch:
    mov w0, #19
    ret
    .size s2a_fixture_patch, .-s2a_fixture_patch
    .global s2a_fixture_end
    .type s2a_fixture_end,%function
s2a_fixture_end:
    nop
    ret
    .size s2a_fixture_end, .-s2a_fixture_end

    .section .data.fixture,"aw",%progbits
    .p2align 3
    .global s2a_fixture_data
    .type s2a_fixture_data,%object
s2a_fixture_data:
    .quad 0x1234
    .size s2a_fixture_data, .-s2a_fixture_data

    .section .rodata.fixture,"a",%progbits
    .p2align 3
    .global s2a_fixture_rodata
    .type s2a_fixture_rodata,%object
s2a_fixture_rodata:
    .quad 0x5678
    .size s2a_fixture_rodata, .-s2a_fixture_rodata
    .section .note.GNU-stack,"",%progbits
