# PocketCraft 512 - Kieran Schmitt
#
# editable voxel world in a 512-byte x86 boot sector
# 160 x 100 rays, up to 96 steps each
#
# WASD move, QE turn, arrows look, RF up/down
# space places, backspace removes
#
# build with GNU binutils:
#   as --32 PocketCraft512.S -o PocketCraft512.o
#   ld -m elf_i386 -Ttext 0x7c00 -e _start PocketCraft512.o -o PocketCraft512.elf
#   objcopy -O binary -j .text PocketCraft512.elf PocketCraft512.img
# 512 bytes total, boot signature included
#
.intel_syntax noprefix
.code16
.global pixel, selected_tint, prepass_done, _start, frame, ready, key_read, march, shade, end_code
# offsets from BP, 1024 units per block
# camera on the stack; targets and rays reuse the startup code's memory
.equ PX,0
.equ PY,2
.equ PZ,4
.equ YAW,6
.equ PITCH,8
.equ TARGET,10
.equ EMPTY,12
.equ VX,14
.equ VY,16
.equ VZ,18

# set up the stack and clear the direction flag
_start:
    xor ax,ax
    mov ss,ax
    mov sp,0x7c00
    cld
    mov al,0x13
    int 0x10
    # reuse the BIOS palette, repeat each row over 4 scanlines
    # gives a 320 x 100 framebuffer without extra drawing code
    mov dx,0x3d4
    mov ax,0x4309
    out dx,ax
    # ES = video memory, DS = 32 x 32 x 32 blocks
    push 0xa000
    pop es
    push 0x8000
    pop ds
    xor bx,bx
# squared X/Z coords make the hills, capped so they don't get too tall
# index = (Y << 10) | (Z << 5) | X, positive Y points down
terrain:
    mov ax,bx
    shr ax,1
    aam 16
    sub ax,0x0708
    mov dl,ah
    imul al
    xchg si,ax
    mov al,dl
    imul al
    add ax,si
    shr ax,4
    cmp al,5
    jb height_add
    mov al,5
height_add:
    add al,7
    mov dl,bh
    shr dl,2
    cmp dl,al
    # block value doubles as its color: 0 air, 143 grass, 139 dirt
    mov al,139
    ja terrain_store
    sbb al,al
    not al
    and al,143
terrain_store:
    mov byte ptr [bx],al
    inc bx
    # BX hits 8000h after all 32768 blocks, sign bit ends the loop
    jns terrain
    # push pitch, yaw, Z, Y, X; spawn at (8.5, 5.5, 8.5)
    push 40
    push 0
    mov ax,0x2200
    push ax
    push 0x1600
    push ax
    mov bp,sp
# check the center ray first so the highlight matches the block being edited
# DI's sign bit marks this pass, nothing drawn yet
frame:
    and word ptr [bp+YAW],63
    or dword ptr [bp+TARGET],-1
    mov di,0x80a0
# columns go right to left, one horizontal rotation per column
column:
    mov dx,di
    and dh,0x7f
    sub dx,160
    mov ax,192
    call turn_vector
rotated:
    mov word ptr [bp+VX],dx
    mov word ptr [bp+VZ],ax
    mov ax,word ptr [bp+PITCH]
    test di,di
    js vertical_ready
    # start 50 rows above center
    sub ax,100
vertical_ready:
    mov word ptr [bp+VY],ax
# SP = BP here, pop/push the camera coords to save 3 bytes
pixel:
    pop ax
    pop dx
    pop si
    push si
    push dx
    push ax
    # start with the camera's cell so close-up hits have a previous voxel
    mov cx,96
    call sample_voxel
# fixed-size steps, keep the last empty cell
march:
    push bx
    add ax,word ptr [bp+VX]
    add dx,word ptr [bp+VY]
    add si,word ptr [bp+VZ]
    call sample_voxel
    jc hit
    jne sky
    add sp,2
    loop march
    jmp empty_sky
# steps left tell us how far the hit was (fog + placement distance)
hit:
    mov ah,cl
    pop cx
    mov si,cx
    xor si,bx
    # find the face crossed: check Y, then Z, then X
    # previous cell was air, so at least one axis has to differ
    mov dx,0x7c00
face_mask_loop:
    test si,dx
    jnz face_selected
    shr dx,5
    jmp face_mask_loop
# only the center ray sets the remove/place targets
face_selected:
    test di,di
    jns shade
    mov word ptr [bp+TARGET],bx
    and si,dx
    xor si,bx
    # skip the first 8 samples for placement, too close to the camera
    cmp ah,88
    ja shade
    mov word ptr [bp+EMPTY],si
# top gets the block's color, sides get two different dirt shades
shade:
    test dh,0x7c
    mov al,byte ptr [bx]
    jnz colored
    test dl,31
    mov al,138
    jnz colored
    add al,71
# shift to another palette band for distant blocks
colored:
    cmp ah,72
    jae selected_tint
    add al,24
# brighten the selected block, keep the face shading
selected_tint:
    cmp bx,word ptr [bp+TARGET]
    jne draw
    sub al,72
    jmp draw
sky:
    pop bx
empty_sky:
    mov al,102
# skip drawing the center pass, other rays fill 2 pixels side by side
draw:
    test di,di
    js prepass_done
    mov ah,al
    stosw
    add di,318
    add word ptr [bp+VY],2
    cmp di,32000
    jb pixel
column_finished:
    sub di,32002
    jns column
ready:
# BIOS gives ASCII keys or extended scan codes
key_read:
    xor ax,ax
    int 0x16
turn:
    test al,al
    jnz ascii_key
    mov al,ah
ascii_key:
    xchg ax,dx
    mov si,offset keys
    mov cx,12
# each key comes with a signed movement amount or block material
# table order matches the state offsets so the controls can share code
find_key:
    ss lodsw
    cmp ah,dl
    loopne find_key
    jne redraw
    cbw
    xchg ax,dx
    cmp cl,10
    jb normal_move
    inc cx
    and cl,-2
    mov si,cx
    mov bx,word ptr [bp+si]
    # FFFFh = no target; can't place in an occupied cell either
    test bh,bh
    js redraw
    test byte ptr [bx],dl
    jne redraw
    mov byte ptr [bx],dl
redraw:
    jmp frame
# target found, start drawing at the rightmost column
prepass_done:
    mov di,32320
    jmp column_finished
normal_move:
    and cl,-2
# rotate horizontal movement with the camera, R/F handles height
move:
    mov si,word ptr [bp+PZ]
    test cl,10
    jnz vertical
    xor ax,ax
    test cl,cl
    jz moving
    xchg ax,dx
moving:
    push si
    call turn_vector
    pop si
    add si,ax
    xchg ax,dx
    xor dx,dx
    jmp coordinates
vertical:
    cmp cl,PY
    jne parameter
    xor ax,ax
coordinates:
    add ax,word ptr [bp+PX]
    add dx,word ptr [bp+PY]
# only move if the new cell is empty and in bounds
# put the new camera coords back on the stack
collision:
    call sample_voxel
    jne cancelled
    add sp,6
    push si
    push dx
    push ax
cancelled:
    jmp redraw
parameter:
    mov si,cx
    add word ptr [bp+si],dx
    jmp redraw
# in: AX=X, DX=Y, SI=Z, CH=0; coords and CX stay intact
# out: BX=index if valid; CF=solid, ZF=air, neither=out of bounds
# valid coords fit in 15 bits, OR catches anything outside
sample_voxel:
    mov bx,si
    or bx,ax
    or bx,dx
    js sampled
    push ax
    mov bx,si
    shr bx,5
    and bx,0x3e0
    shr ax,10
    or bx,ax
    mov ax,dx
    and ax,0x7c00
    or bx,ax
    pop ax
    # compare 0 to the block value, get both flags in one go
    cmp ch,byte ptr [bx]
sampled:
    ret
# 64 yaw positions: small rounded Q8 rotations, then exact quarter turns
# used for both movement and rays
turn_vector:
    mov cx,word ptr [bp+YAW]
    push cx
    and cx,15
    jcxz quarter_setup
micro_rotate:
    imul bx,ax,25
    imul si,dx,25
    add si,ax
    add si,127
    sar si,8
    sub ax,si
    sub bx,dx
    sub bx,-128
    sar bx,8
    add dx,bx
    loop micro_rotate
quarter_setup:
    pop cx
    shr cx,4
quarter:
    jcxz rotated_vector
rotate:
    xchg ax,dx
    neg ax
    loop rotate
rotated_vector:
    ret
# place/remove, look down/up, turn right/left, forward/back, down/up, strafe
keys:
    .byte 143,32, 0,8
    .byte 2,0x50, -2,0x48, 1,'e', -1,'q'
    .byte 96,'w', -96,'s', 96,'f', -96,'r', 96,'d', -96,'a'
# pad to 510, last 2 bytes are the boot signature
end_code:
    .fill 510-(.-_start),1,0
    .word 0xaa55

