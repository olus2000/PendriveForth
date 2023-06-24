;;;;; System design ;;;;;
;
; Data stack:
;   - Growing up from d_stack_base
;   - NoS pointed to by ebp
;   - ToS in eax
;   - Macros `pushd` and `popd` push and pop *below ToS*
;
; Return stack:
;   - Hardware stack
;   - Growing down from 0x80000
;   - Pointed to by esp
;   - Commands `push` and `pop` perform `>r` and `r>`
;
; Stacks share space, grow towards each other.


; Less/Greater -> signed
; Above/Below -> unsigned


;;;;; Macros ;;;;;

%macro pushd 0-1 eax
    add ebp, 4
    mov dword [ebp], %1
%endmacro

%macro popd 0-1 eax
    mov dword %1, [ebp]
    sub ebp, 4
%endmacro

%assign DICT_START 0x100000

%macro comma 0-2 eax, 4 ; Expects [here] in edx, leaves [here] in edx
    %ifn %2 - 1
        mov byte [edx], %1
    %elifn %2 - 2
        mov word [edx], %1
    %elifn %2 - 4
        mov dword [edx], %1
    %else
        %error %2 is not a valid word size for comma
    %endif
    add edx, %2
%endmacro


;;;;; Bootloader ;;;;;

section .bootloader vstart=0x7c00

BITS 16

    jmp start
times 0x3e - ($ - $$) db 0


start:
    ; 1. Load the boot?
    cld
    mov ax, 0       ; Reset segment registers
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0       ; setup hardware stack
    mov ah, 0x02    ; Function: Read Sectors From Drive
    mov al, 0x10    ; !! sector count !!
    mov ch, 0       ; cylinder (actually top 8 bits)
    mov cl, 2       ; sector (actually bottom 4 bits of cylinder
                    ; && 6 bits of sector)
    mov dh, 0       ; head
    mov bx, 0x500   ; destination addess
    int 0x13
    mov ax, 0x0003  ; video mode 80x25
    int 0x10

    ; 2. Disable interrupts
    cli

    ; 3. Enable A20 line :dread:
    ; QEMU does that for me probably, so leave it for later

    ; 4. Make the GDT
    lgdt [gdtr]

    ; 5. Switch to 32b

    mov eax,cr0
    or al,1
    mov cr0,eax
    jmp 8:protected_start

BITS 32
protected_start:
    mov ax, 16
    mov ds, ax
    mov es, ax
    mov ss, ax


    ; 6. Make the IDT
    lidt [idtr]

    ; 7. Initialise the PICs

%assign PIC1_COMMAND    0x20
%assign PIC1_DATA       0x21
%assign PIC1_OFFSET     0x20
%assign PIC2_COMMAND    0xa0
%assign PIC2_DATA       0xa1
%assign PIC2_OFFSET     0x28

%assign ICW1_INIT   0x10
%assign ICW1_ICW4   0x01
%assign ICW4_8086   0x01

    ; Potentially do some waiting between requests maybe???

    mov al, ICW1_INIT | ICW1_ICW4   ; Initialise setup
    out PIC1_COMMAND, al
    out PIC2_COMMAND, al
    mov al, PIC1_OFFSET             ; Set offsets
    out PIC1_DATA, al
    mov al, PIC2_OFFSET
    out PIC2_DATA, al
    mov al, 4                       ; PIC1 has a slave on line 2
    out PIC1_DATA, al
    mov al, 2                       ; PIC2 is a slave on line 2
    out PIC2_DATA, al
    mov al, ICW4_8086               ; Set both to 8086 mode
    out PIC1_DATA, al
    out PIC2_DATA, al

    mov al, 0b11111101  ; Only enable the keyboard interrupt
    out PIC1_DATA, al
    mov al, 0b11111111
    out PIC2_DATA, al


    ; 9. Profit
    sti
    mov [disk_id_something], dl ; Save the disk id something
    mov esp, 0x80000            ; Setup return stack
    push body_quit              ; Initialisation script will return to quit
    mov ebp, d_stack_base - 4   ; Setup data stack with two values on top
    jmp test
    jmp body_parse_eval

times 510 - ($ - $$) db 0
db 0x55, 0xaa


;;;;; Payload ;;;;;

section .payload vstart=0x500
payload_data_start:


;;;;; Descriptor tables ;;;;;

; Global Descriptor Table

%assign GDT_PRESENT     0b10000000
%assign GDT_MEMORY      0b00010000
%assign GDT_CODE        0b00001000
%assign GDT_READABLE    0b00000010
%assign GDT_WRITABLE    0b00000010

%assign GDT_32BIT   0b0100
%assign GDT_PAGE    0b1000

%macro gdt_entry 4  ; Base, limit, access, flags
    dw (%2) & 0xffff
    dw (%1) & 0xffff
    db ((%1) & 0xff0000) >> 16
    db (%3)
    db (((%2) & 0xf0000) >> 16) | ((%4) << 4)
    db ((%1) & 0xff000000) >> 24
%endmacro


gdt:
    gdt_entry 0, 0, 0, 0
    gdt_entry 0, 0xfffff, GDT_PRESENT | GDT_MEMORY | GDT_CODE | GDT_READABLE, \
              GDT_32BIT | GDT_PAGE
    gdt_entry 0, 0xfffff, GDT_PRESENT | GDT_MEMORY            | GDT_WRITABLE, \
              GDT_32BIT | GDT_PAGE

gdtr:
    dw $ - gdt - 1
    dd gdt


disk_id_something:
    db 0


; Interrupt Descriptor Table

%assign IDT_TRAP32      0xf
%assign IDT_INTERRUPT32 0xe

%assign IDT_PRESENT 0b1000

%macro idt_entry 4 ; Offset, selector, type, flags
    dw (%1 - payload_data_start + 0x500) & 0xffff
    dw (%2)
    db 0
    db (%3) | ((%4) << 4)
    dw ((%1 - payload_data_start + 0x500) & 0xffff0000) >> 16
%endmacro

idt:
    ; Exception """handling"""
    %assign i 0
    %rep 0x20
        idt_entry exception_handler_%+i, 8, IDT_TRAP32, IDT_PRESENT
        %assign i i+1
    %endrep
    ; IRQ """handling"""
    idt_entry die, 8, IDT_INTERRUPT32, IDT_PRESENT
    idt_entry keyboard_interrupt, 8, IDT_INTERRUPT32, IDT_PRESENT
    %rep 0xe
        idt_entry die, 8, IDT_INTERRUPT32, IDT_PRESENT
    %endrep

idtr:
    dw $ - idt - 1
    dd idt


;;;;; Interrupt processing ;;;;;

%assign PIC_EOI 0x20

%macro end_of_master_interrupt 0
    mov al, PIC_EOI
    out PIC1_COMMAND, al
%endmacro

%macro end_of_slave_interrupt 0
    mov al, PIC_EOI
    out PIC1_COMMAND, al
    out PIC1_COMMAND, al
%endmacro


%macro exc_handler 1
    exception_handler_%1:
        mov ax, %1
        call print_number
        call update_cursor
        pop eax
        add eax, 2
        push eax
        iret
%endmacro


; exception "handlers"

%assign i 0
%rep 0x20
    exc_handler i
    %assign i i + 1
%endrep


; Key mapping:
; 0X:  INV ESC  1   2   3   4   5   6   7   8   9   0   -   =  BSP TAB
; 1X:   q   w   e   r   t   y   u   i   o   p   [   ]  RET CTL  a   s
; 2X:   d   f   g   h   j   k   l   ;   '   `  SHL  \   z   x   c   v
; 3X:   b   n   m   ,   .   /  SHR NM* ALL ' ' CPS F1  F2  F3  F4  F5
; 4X:  F6  F7  F8  F9  F10 NML SCL NM7 NM8 NM9 NM- NM4 NM5 NM6 NM+ NM1
; 5X:  NM2 NM3 NM0 NM.  X   X   X  F11 F12  X   X   X   X   X   X   X
; 6X:   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X
; 7X:   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X

keyboard_interrupt:
    pushad
;   mov dx, 0x3f8
;   mov al, 'K'
;   out dx, al
    mov eax, 0
    in al, 0x60
    movzx ebx, byte [.state]
    jmp [ebx+.jump_table]

.default:
    cmp al, 0xe0
    je .double
    cmp al, 0xe1
    je .triple
    mov [last_ekey], al
    cmp al, 0x80
    jae .release

.press:
    mov byte [eax+keys], -1
    mov byte [eax+pressed], -1
    jmp .ret

.release:
    and eax, 0x7f
    mov byte [eax+keys], 0
    jmp .ret

.double:
    mov byte [.state], 4
    jmp .ret

.triple:
    mov byte [.state], 8
    jmp .ret

.two_of_two:
    mov byte [.state], 0
    jmp .ret

.two_of_three:
    mov byte [.state], 12
    jmp .ret

.three_of_three:
    mov byte [.state], 0

.ret:
    end_of_master_interrupt
    popad
    iret

.state: db 0
.jump_table:
    dd .default         ; 0
    dd .two_of_two      ; 4
    dd .two_of_three    ; 8
    dd .three_of_three  ; 12


;;;;; Actual kernel ;;;;;

%assign VGA_START   0x0B8000
%assign VGA_WIDTH   80
%assign VGA_HEIGHT  25
%assign VGA_SIZE    VGA_WIDTH * VGA_HEIGHT

cursor:
    dd 0x00


emit_raw:   ; Input ax = color | character, modifies ax, ebx, cx, esi, edi
    call scroll_to_cursor
    mov [VGA_START+ebx*2], ax
    inc ebx
    mov [cursor], ebx
    ret


scroll_to_cursor:   ; Modifies ebx, cx, esi, edi. Leaves cursor in ebx.
    mov ebx, [cursor]


.keep_scrolling:
    cmp ebx, VGA_SIZE
    jl .return
    call scroll_up
    sub ebx, VGA_WIDTH
    jmp .keep_scrolling


.return:
    mov [cursor], ebx
    ret


scroll_up:  ; Modfies cx, esi, edi
    mov cx, VGA_SIZE
    mov esi, VGA_START + VGA_WIDTH * 2
    mov edi, VGA_START
    rep movsw
    ret


update_cursor:  ; Modifies ax, bx, dx
    mov bx, [cursor]

    mov dx, 0x03D4  ; Send lower cursor byte
    mov al, 0x0F
    out dx, al

    inc dl
    mov al, bl
    out dx, al

    dec dl          ; Send upper cursor byte
    mov al, 0x0E
    out dx, al

    inc dl
    mov al, bh
    out dx, al
    ret


; TODO: make it use base
print_number:   ; Takes number in eax, modifies eax, ebx, ecx, esi, edi
    push eax
    shr eax, 4
    cmp eax, 0
    je .no_recurse
    call print_number

.no_recurse:
    pop eax
    and eax, 0xf
    cmp eax, 0xa
    jl .just_decimal
    add eax, 7
.just_decimal:
    add eax, 0xf30
    jmp emit_raw

get_eip:
    pop eax
    jmp eax

 
die:
    mov dx, 0x3f8
    mov al, 'D'
    out dx, al
die_loop:
    hlt
    jmp die_loop


;;;;; Forth assembly ;;;;;

%define last_word 0 ; link

%macro def_word 3
    entry_%1:
        dd last_word
        db %strlen(%2) | (%3 << 7) , %2
    body_%1:
    %define last_word entry_%1
%endmacro


def_word abort, "abort", 0  ; ( i*x -- ) r:( j*x -- )
    mov ebp, d_stack_base - 4   ; Reset data stack
    jmp body_quit


def_word quit, "quit", 0        ; ( -- ) r:( i*x -- )
    mov esp, 0x80000            ; Reset return stack
    mov dword [state], 0
    jmp body_repl


def_word repl, "repl", 0 ; ( -- )
    jmp die

times body_repl - $ + 5 db 0


not_found_str:
    db "Undefined word: "
    %assign not_found_str_len %strlen("Undefined word: ")


def_word undefined_error, "undefined-error", 0 ; ( addr u -- quit )
    call body_nl
    pushd
    pushd not_found_str
    mov eax, not_found_str_len
    call body_type
    call body_type
    call body_nl
    jmp body_quit


def_word parse_eval, "parse-eval", 0 ; ( i*x -- j*x ) consumes parse area
    pushd
    mov eax, 0x20
    call body_consume
    mov ebx, [source_ptr]
    cmp ebx, [source_len]
    jb .no_return
    ret

.no_return:         ; nothing
    pushd
    mov eax, 0x20
    call body_parse_until
    call body_find
    cmp eax, 0
    jg .immediate
    jl .non_immediate

.not_found:         ; addr u 0
    popd
    call body_to_number
    cmp eax, 0
    je .invalid_token
    
.a_number:          ; n true
    popd
    cmp dword [state], 0
    je body_parse_eval

.compile_number:    ; n
    call body_literal
    jmp body_parse_eval

.invalid_token:     ; addr u 0
    popd
    jmp body_undefined_error

.non_immediate:     ; xt -1
    cmp dword [state], 0
    je .immediate

.compile_xt:        ; xt -1
    popd
    call body_compile
    jmp body_parse_eval

.immediate:         ; xt 1|-1
    popd
    mov ebx, eax
    popd
    call ebx
    jmp body_parse_eval


def_word execute, "execute", 0 ; ( i*x xt -- j*x )
    mov ebx, eax
    popd
    jmp ebx


def_word consume, "consume", 0 ; ( c -- )
    mov ecx, [source_len]
    sub ecx, [source_ptr]
    jecxz .return
    mov ebx, [source]
    add ebx, [source_ptr]

.loop:
    mov dl, [ebx]
    inc ebx
    cmp dl, al
    jne .found
    loop .loop
    inc ebx

.found:
    dec ebx
    sub ebx, [source]
    mov [source_ptr], ebx

.return:
    popd
    ret


def_word parse_until, "parse-until", 0 ; ( c -- addr u )
    mov ecx, [source_len]
    sub ecx, [source_ptr]
    mov ebx, [source]
    add ebx, [source_ptr]
    pushd ebx
    jecxz .out_of_source

.loop:
    mov dl, [ebx]
    inc ebx
    cmp dl, al
    je .delimiter
    loop .loop

.out_of_source:
    sub ebx, [source]
    mov eax, ebx
    sub eax, [source_ptr]
    mov [source_ptr], ebx
    ret

.delimiter:
    sub ebx, [source]
    mov eax, ebx
    sub eax, [source_ptr]
    dec eax
    mov [source_ptr], ebx
    ret


def_word parse_name, "parse-name", 0 ; ( -- addr u )
    pushd
    mov eax, 0x20
    call body_consume
    pushd
    mov eax, 0x20
    jmp body_parse_until


def_word source, "source", 0 ; ( -- addr u )
    mov [ebp+4], eax
    mov eax, [source]
    mov [ebp+8], eax
    add ebp, 8
    mov eax, [source_len]
    ret


def_word source_addr, "source-addr", 0 ; ( -- addr )
    call variable

source:     dd forth_kernel


def_word source_len, "source-len", 0 ; ( -- addr )
    call variable

source_len: dd forth_kernel_end - forth_kernel


def_word source_ptr, ">in", 0 ; ( -- addr )
    call variable

source_ptr: dd 0


def_word source_id, "source-id", 0 ; ( -- addr )
    call variable

source_id: dd -1


def_word literal, "literal", 0 ; ( x -- ) compiles: ( -- x )
    mov edx, [here]
    comma 0xe8, 1
    mov ebx, literal
    sub ebx, edx
    sub ebx, 4
    comma ebx
    comma
    mov [here], edx
    popd
    ret

literal:
    pushd
    pop ebx
    mov eax, [ebx]
    add ebx, 4
    jmp ebx

    
def_word find, "find", 0 ; ( addr u -- addr u 0 | xt 1 | xt -1 )
    popd ebx
    mov edx, [latest]
    
.loop:
    mov cl, [edx+4]
    and ecx, 0x7f
    cmp eax, ecx            ; Compare lengths
    jne .skip

    mov esi, edx
    mov edi, ebx
    add esi, 5
    repz cmpsb
    jz .found

.skip:
    mov edx, [edx]
    cmp edx, 0
    jne .loop

.not_found:
    pushd ebx
    pushd
    mov eax, 0
    ret

.found:
    pushd esi
    mov eax, [edx+4]
    and eax, 0x80
    shr eax, 6
    dec eax
    ret


def_word nl, "nl", 0 ; ( -- )
    pushd
    mov eax, [cursor]
    mov cl, VGA_WIDTH
    div cl
    inc al
    mul cl
    mov [cursor], eax
    call scroll_to_cursor
    call update_cursor
    popd
    ret


def_word sp, "sp", 0 ; ( -- )
    pushd
    mov eax, 32
    call emit_raw
    call update_cursor
    popd
    ret


def_word bsp, "bsp", 0 ; ( -- )
    mov ebx, [cursor]
    dec ebx
    mov ecx, [color]
    or ecx, 0x20
    mov [VGA_START+ebx*2], cx
    mov [cursor], ebx
    pushd
    call update_cursor
    popd
    ret


def_word color, "color", 0 ; ( -- addr )
    call variable

color: dd 0xf00


def_word emit, "emit", 0 ; ( c -- )
    or eax, [color]
    call emit_raw
    call update_cursor
    popd
    ret


def_word type, "type", 0 ; ( addr u -- )
    mov ecx, eax
    popd ebx
    mov edx, [color]
    cmp ecx, 0
    je .no_type_loop

.type_loop:
    mov al, [ebx]
    mov ah, dh
    push ebx
    push ecx
    call emit_raw
    pop ecx
    pop ebx
    inc ebx
    loop .type_loop

.no_type_loop:
    call update_cursor
    popd
    ret
    

def_word compile, "compile,", 0 ; ( xt -- ) compiles: execution of xt
    mov edx, [here]
    comma 0xe8, 1
    sub eax, edx
    sub eax, 4
    comma
    mov [here], edx
    popd
    ret


def_word allot, "allot", 0 ; ( n -- )
    add [here], eax
    popd
    ret


def_word to_r, ">r", 0 ; ( x -- ) r:( -- x )
    pop ebx
    push eax
    popd
    jmp ebx


def_word from_r, "r>", 0 ; ( -- x ) r:( x -- )
    pop ebx
    pushd
    pop eax
    jmp ebx


def_word at_r, "r@", 0 ; ( -- x ) r:( x -- x )
    pushd
    mov eax, [esp+4]
    ret


def_word depth, "depth", 0 ; ( -- u )
    pushd
    mov eax, ebp
    sub eax, d_stack_base
    sar eax, 2
    ret


def_word dup, "dup", 0 ; ( x -- x x )
    pushd
    ret


def_word drop, "drop", 0 ; ( x -- )
    popd
    ret


def_word nip, "nip", 0 ; ( x2 x1 -- x1 )
    sub ebp, 4
    ret


def_word swap, "swap", 0 ; ( x2 x1 -- x1 x2 )
    mov ebx, [ebp]
    mov [ebp], eax
    mov eax, ebx
    ret


def_word over, "over", 0 ; ( x2 x1 -- x2 x1 x2 )
    pushd
    mov eax, [ebp-4]
    ret


def_word rot, "rot", 0 ; ( x3 x2 x1 -- x2 x1 x3 )
    mov ebx, [ebp]
    mov [ebp], eax
    mov eax, [ebp-4]
    mov [ebp-4], ebx
    ret


def_word unrot, "-rot", 0 ; ( x3 x2 x1 -- x1 x3 x2 )
    mov ebx, [ebp-4]
    mov [ebp-4], eax
    mov eax, [ebp]
    mov [ebp], ebx
    ret


def_word pick, "pick", 0 ; ( xn ... x0 n -- xn ... x0 xn )
    shl eax, 2
    mov ebx, ebp
    sub ebx, eax
    mov eax, [ebx]
    ret


def_word immediate, "immediate", 0 ; ( -- )
    mov ebx, [latest]
    or byte [ebx+4], 0x80
    ret


def_word to_number, ">number", 0 ; ( addr u -- addr u 0 | n -1 )
    pushd
    mov ecx, eax
    jecxz .fail
    mov ebx, [ebp-4]
    mov eax, 0
    mov esi, [base]

    ; TODO: base prefixes

.char_check:
    mov edx, 0
    mov dl, [ebx]
    cmp dl, "'"
    jne .sign_check

.char:
    dec ecx
    jecxz .fail
    inc ebx
    popd ecx
    mov al, [ebx]
    mov [ebp], eax
    mov eax, -1
    ret

.sign_check:
    mov edi, 0
    mov dl, [ebx]
    cmp dl, '-'
    jne .loop
    mov edi, 0xffffffff
    inc ebx
    dec ecx
    jecxz .fail

.loop:
    mul esi
    mov edx, 0
    mov dl, [ebx]
    inc ebx
    sub dl, 0x30
    cmp dl, 0x11
    jb .adjusted
    sub dl, 0x7
    cmp dl, 0x2a
    jb .adjusted
    sub dl, 0x5

.adjusted:
    cmp edx, esi
    jae .fail
    add eax, edx
    loop .loop

.complete:
    add eax, edi
    xor eax, edi
    sub ebp, 8
    pushd
    mov eax, -1
    ret

.fail:
    mov eax, 0
    ret


def_word variable, "variable:", 0 ; ( "<name>" -- ) defines: ( -- addr )
    call body_create
    add dword [here], 4
    ret

variable:
    pushd
    pop eax
    ret


def_word create, "create:", 0 ; ( "<name>" -- ) defines: ( -- addr )
    call body_create_helper
    pushd
    mov ebx, [shadow]
    mov [latest], ebx
    mov eax, variable
    jmp body_compile


def_word create_helper, "(create)", 0 ; ( "<name>" -- ) creates entry
    call body_parse_name
    cmp eax, 64
    ja .name_too_long
    cmp eax, 0
    je .name_too_short

    mov edx, [here]
    mov [shadow], edx
    mov ebx, [latest]
    comma ebx           ; Link
    comma al, 1         ; Name length
    mov ecx, eax
    popd esi
    mov edi, edx
    rep movsb           ; Name
    mov [current], edi
    mov [here], edi
    popd
    ret
    
.name_too_long_err:
    db "Name longer than 64 characters:"
%assign NAME_TOO_LONG_LEN %strlen("Name longer than 64 characters:")

.name_too_long:
    call body_nl

    pushd
    pushd .name_too_long_err
    mov eax, NAME_TOO_LONG_LEN
    call body_type

    call body_nl
    call body_type
    jmp body_quit

.name_too_short_err:
    db "No name provided to a defining word"
%assign NAME_TOO_SHORT_LEN %strlen("No name provided to a defining word")

.name_too_short:
    call body_nl
    pushd
    pushd .name_too_short_err
    mov eax, NAME_TOO_SHORT_LEN
    call body_type
    jmp body_quit


def_word does, "does>", 1 ; ( -- )
    pushd
    mov eax, .helper_1
    call body_compile
    pushd
    mov eax, .helper_2
    jmp body_compile

.helper_1:
    pushd
    pop eax
    mov ebx, [current]
    mov byte [ebx], 0xe8
    inc ebx
    sub eax, ebx
    sub eax, 4
    mov [ebx], eax
    popd
    ret

.helper_2:
    pushd
    pop ebx
    pop eax
    jmp ebx


def_word constant, "constant:", 0 ; ( x "<name>" -- ) defines: ( -- x )
    call body_create_helper
    mov ebx, [shadow]
    mov [latest], ebx
    pushd
    mov eax, constant
    call body_compile
    jmp body_append


constant:
    pushd
    pop eax
    mov eax, [eax]
    ret


def_word semicolon, ";", 1 ; ( -- ) compiles: r:( ret -- )
    mov edx, [here]
    comma 0xc3, 1
    mov [here], edx
    mov ebx, [shadow]
    mov [latest], ebx
    mov dword [state], 0
    ret


    ; TODO: make it work in reverse when appropriate
def_word move, "move", 0 ; ( addr2 addr1 u -- ) moves u bytes from 2 to 1
    mov ecx, eax
    mov edi, [ebp]
    mov esi, [ebp-4]
    mov eax, [ebp-8]
    sub ebp, 12
    rep movsb
    ret


def_word append, ",", 0 ; ( x -- ) compiles x at here
    mov edx, [here]
    comma
    mov [here], edx
    popd
    ret


def_word char_append, "c,", 0 ; ( c -- ) compiles c at here
    mov edx, [here]
    comma al, 1
    mov [here], edx
    popd
    ret


def_word at, "@", 0 ; ( addr -- x )
    mov eax, [eax]
    ret


def_word char_at, "c@", 0 ; ( addr -- c )
    movzx eax, byte [eax]
    ret


def_word flag_at, "f@", 0 ; ( addr -- ? ) Actually just sign extends
    movsx eax, byte [eax]
    ret


def_word bang, "!", 0 ; ( x addr -- )
    popd ebx
    mov [eax], ebx
    popd
    ret


def_word char_bang, "c!", 0 ; ( c addr -- )
    popd ebx
    mov [eax], bl
    popd
    ret


def_word print_number, ".", 0 ; ( n -- )
    call body_sp
    call print_number
    call update_cursor
    popd
    ret


def_word add, "+", 0 ; ( n2 n1 -- n2+n1 )
    add eax, [ebp]
    sub ebp, 4
    ret


def_word sub, "-", 0 ; ( n2 n1 -- n2-n1 )
    mov ebx, eax
    popd
    sub eax, ebx
    ret


def_word udmul, "um*", 0 ; ( u2 u1 -- ud )
    mul dword [ebp]
    mov [ebp], eax
    mov eax, edx
    ret


def_word dmul, "m*", 0 ; ( n2 n1 -- d )
    imul dword [ebp]
    mov [ebp], eax
    mov eax, edx
    ret


def_word mul, "*", 0 ; ( n2 n1 -- n3 )
    imul eax, [ebp]
    sub ebp, 4
    ret


def_word eq, "=", 0 ; ( x2 x1 -- x2==x1 )
    popd ecx
    sub ecx, eax
    jecxz .true
    mov ecx, 1
.true:
    mov eax, ecx
    dec eax
    ret


def_word neq, "<>", 0 ; ( x2 x1 -- x2<>x1 )
    popd ecx
    sub ecx, eax
    jecxz .false
    mov ecx, -1
.false:
    mov eax, ecx
    ret


def_word word_gt, ">", 0 ; ( x2 x1 -- x2==x1 )
    cmp [ebp], eax
    jg .true
    mov ecx, 1
    mov eax, 0
    sub ebp, 4
    ret

.true:
    mov eax, -1
    sub ebp, 4
    ret


def_word word_lt, "<", 0 ; ( x2 x1 -- x2==x1 )
    cmp [ebp], eax
    jl .true
    mov ecx, 1
    mov eax, 0
    sub ebp, 4
    ret

.true:
    mov eax, -1
    sub ebp, 4
    ret


def_word word_ugt, "u>", 0 ; ( x2 x1 -- x2==x1 )
    cmp [ebp], eax
    ja .true
    mov ecx, 1
    mov eax, 0
    sub ebp, 4
    ret

.true:
    mov eax, -1
    sub ebp, 4
    ret


def_word word_ult, "u<", 0 ; ( x2 x1 -- x2==x1 )
    cmp [ebp], eax
    jb .true
    mov ecx, 1
    mov eax, 0
    sub ebp, 4
    ret

.true:
    mov eax, -1
    sub ebp, 4
    ret


def_word and, "and", 0 ; ( x2 x1 -- x2&x1 )
    and eax, [ebp]
    sub ebp, 4
    ret


def_word or, "or", 0 ; ( x2 x1 -- x2&x1 )
    or eax, [ebp]
    sub ebp, 4
    ret


def_word jez, "(if)", 0 ; ( ? -- )
    pop ebx
    mov ecx, eax
    popd
    jecxz .skip
    add ebx, 4
    jmp ebx

.skip:
    jmp [ebx]


def_word jmp, "(else)", 0 ; ( -- )
    pop ebx
    jmp [ebx]


def_word jnz, "(until)", 0 ; ( ? -- )
    pop ebx
    mov ecx, eax
    popd
    jecxz .no_skip
    add ebx, 4
    jmp ebx

.no_skip:
    jmp [ebx]


def_word halt, "halt", 0 ; ( -- )
    hlt
    ret


def_word last_ekey, "last-ekey", 0 ; ( -- addr )
    call variable

last_ekey: dd 0


def_word keymaps, "keymaps", 0 ; ( -- addr )
    call variable

keymaps:
    ; No modifiers
    db  0,  0, '1','2','3','4','5','6','7','8','9','0','-','=', 0,  0
    db 'q','w','e','r','t','y','u','i','o','p','[',']', 0,  0, 'a','s'
    db 'd','f','g','h','j','k','l',';',"'",'`', 0, '\','z','x','c','v'
    db 'b','n','m',',','.','/', 0, '*', 0, ' ', 0,  0,  0,  0,  0,  0
    db  0,  0,  0,  0,  0,  0,  0, '7','8','9','-','4','5','6','+','1'
    db '2','3','0','.', 0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0
    db  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0
    db  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0
    ; Shift
    db  0,  0, '!','@','#','$','%','^','&','*','(',')','_','+', 0,  0
    db 'Q','W','E','R','T','Y','U','I','O','P','{','}', 0,  0, 'A','S'
    db 'D','F','G','H','J','K','L',':','"','~', 0, '|','Z','X','C','V'
    db 'B','N','M','<','>','?', 0,  0,  0, ' ', 0,  0,  0,  0,  0,  0
    db  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0
    db  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0
    db  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0
    db  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0
    ; Left Alt
    ; TODO?

; 0X:  INV ESC  1   2   3   4   5   6   7   8   9   0   -   =  BSP TAB
; 1X:   q   w   e   r   t   y   u   i   o   p   [   ]  RET CTL  a   s
; 2X:   d   f   g   h   j   k   l   ;   '   `  SHL  \   z   x   c   v
; 3X:   b   n   m   ,   .   /  SHR NM* ALL ' ' CPS F1  F2  F3  F4  F5
; 4X:  F6  F7  F8  F9  F10 NML SCL NM7 NM8 NM9 NM- NM4 NM5 NM6 NM+ NM1
; 5X:  NM2 NM3 NM0 NM.  X   X   X  F11 F12  X   X   X   X   X   X   X
; 6X:   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X
; 7X:   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X
; 0X:  INV ESC  1   2   3   4   5   6   7   8   9   0   -   =  BSP TAB
; 1X:   q   w   e   r   t   y   u   i   o   p   [   ]  RET CTL  a   s
; 2X:   d   f   g   h   j   k   l   ;   '   `  SHL  \   z   x   c   v
; 3X:   b   n   m   ,   .   /  SHR NM* ALL ' ' CPS F1  F2  F3  F4  F5
; 4X:  F6  F7  F8  F9  F10 NML SCL NM7 NM8 NM9 NM- NM4 NM5 NM6 NM+ NM1
; 5X:  NM2 NM3 NM0 NM.  X   X   X  F11 F12  X   X   X   X   X   X   X
; 6X:   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X
; 7X:   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X   X


def_word pressed, "pressed", 0 ; ( -- addr )
    call variable

pressed:
times 128 db 0


def_word keys, "keys", 0 ; ( -- addr )
    call variable

keys:
times 128 db 0


def_word here, "here", 0 ; ( -- addr ) addr is free space, not variable.
    call constant

here:   dd DICT_START


def_word state, "state", 0 ; ( -- addr )
    call variable

state:  dd 0


def_word base, "base", 0 ; ( -- addr )
    call variable

base:   dd 16


def_word shadow, "shadow", 0 ; ( -- addr )
    call variable

shadow: dd entry_latest


def_word current, "current", 0 ; ( -- addr )
    call variable

current: dd body_latest


def_word latest, "latest", 0 ; ( -- addr )
    call variable

latest: dd entry_latest


print_charset:
    mov eax, 0

.loop:
    pushd
    mov ebx, eax
    shl ebx, 2
    add ebx, eax
    mov [cursor], ebx

    call print_number

    mov eax, ':' | 0xf00
    call emit_raw

    mov eax, [ebp]
    or eax, 0xf00
    call emit_raw

    popd
    inc al
    cmp al, 0
    jne .loop

    ret


test:

;   call print_charset
;   jmp die

    call body_parse_eval

    call body_sp
    mov eax, 'D' | 0xf00
    call body_emit

    jmp die


;;;;; Forth forth ;;;;;

forth_kernel:

    db "(create) : -1 state ! (create) -1 state ! ; "
    
    db ": recurse current @ compile, ; immediate "
    
    db ": ( ') parse-until drop drop ; immediate "

    db ": [ 0 state ! ; immediate : ] -1 state ! ; "
    
    db ": jump, ( xt -- ) E9 c, here - 4 - , ; "

    db ": 2dup ( x2 x1 -- x2 x1 x2 x1 ) over over ; "

    db ": 2drop ( x2 x1 -- ) drop drop ; "

    db ": ' ( '<name>' -- xt ) parse-name find drop ; "
    
    db ": ['] ( '<name>' -- ) ( compiles: -- xt ) ' literal ; immediate "

    db ": exit ( r: ret -- ) r> drop ; "

    db ": within ( n lbound ubound -- ? ) over - >r - r> u< ; "

    db ": if ( -- orig ) ['] (if) compile, here 0 , ; immediate "

    db ": else ( orig1 -- orig2 ) ['] (else) compile, here 4 allot "
    db   "here rot ! ; immediate "

    db ": then ( orig -- ) here swap ! ; immediate "

    db ": begin ( -- dest ) here ; immediate "

    db ": while ( dest -- orig dest ) ['] (until) compile, "
    db   "here swap 4 allot ; immediate "

    db ": repeat ( orig dest -- ) jump, here swap ! ; immediate "

    db ": until ( dest -- ) ['] (until) compile, , ; immediate "

    db ": again ( dest -- ) jump, ; immediate "

    db ": do ( -- dest ) ['] >r dup compile, 1 literal ['] - compile, "
    db   "compile, here ; immediate "

    db ": (+loop) ( step -- ) ( r: index limit-1 -- index+step limit-1 ) "
    db   "r> r> rot r> 2dup + dup >r rot 0 < if swap then 2 pick >r within "
    db   "if r> r> 2drop 4 + else @ then >r ; "

    db ": loop ( dest -- ) 1 literal ['] (+loop) compile, , ; immediate "

    db ": +loop ( dest -- ) ['] (+loop) compile, , ; immediate "

    db ": i r> r> r@ -rot >r >r ; "

    db `: s" '" parse-until here 17 + literal dup literal `
    db   "dup here + 5 + jump, here swap dup allot move ; immediate "
    
    db ': defer-error ( -- quit ) s" Attempt to call an undefined hook" '
    db   "nl type nl quit ; "
    
    db ": defer: ( '<name>' -- ) (create) ['] defer-error jump, "
    db   "shadow @ latest ! ; "

    db ": defer! ( xt2 xt1 -- ) E9 over ! 1 + swap over - 4 - swap ! ; "

    db ": defer@ ( xt1 -- xt2 ) 1 + dup @ + 4 + ; "

    db ": noname: ( -- xt ) here dup current ! ] ; "

    db "noname: ( '<name>' -- xt ) parse-name find 0 = "
    db "  if undefined-error then ; ' ' defer! "

    db ": cells ( n1 -- n2 ) 4 * ; : cell+ ( n1 -- n2 ) 4 + ; "

    db ": ?dup ( x -- 0 | x x ) dup if dup then ; "

    db "36 constant: k-shr 2A constant: k-shl : shift+ ( c -- c ) 80 + ; "
    db "0E constant: k-bsp 1C constant: k-ret "

    db ": ekey ( -- c ) begin last-ekey @ dup 0 = while drop halt repeat "
    db   "0 last-ekey ! ; "

    db ": e>key ( c -- c ) dup 79 > if drop 0 then keymaps + "
    db   "keys k-shr + f@ keys k-shl + f@ or if shift+ then c@ ; "

    db ": key ( -- c ) begin ekey e>key ?dup until ; "

    db "create: inp-buffer 50 allot "

    db ": accept ( addr +n -- +n ) dup >r begin ekey dup k-ret <> while "
    db   "2dup k-bsp = swap r@ < and if drop bsp 1 + swap 1 - swap else "
    db   "e>key 2dup swap 0 > and if dup emit rot dup >r c! r> 1 + swap 1 - "
    db   "else drop then then repeat drop nip r> swap - ; "

    db ": evaluate ( i*x addr u -- j*x ) source >r >r source-id @ >r >in @ >r "
    db   "source-len ! source-addr ! -1 source-id ! 0 >in ! parse-eval "
    db   "r> >in ! r> source-id ! r> source-addr ! r> source-len ! ; "

    db 'noname: s" PendriveForth v0.1.1 by olus2000" type nl ; execute '

    db "noname: begin inp-buffer inp-buffer 50 accept evaluate "
    db   `state @ 0 = if s"  ok." type then nl again ; ' repl defer! quit `


forth_kernel_end:


align 4
d_stack_base:


;;;;; User dictionary label ;;;;;

section .dict vstart=DICT_START

user_dictionary:
