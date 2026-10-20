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
.global pixel, selected_tint, _start, frame, key_read, march, shade, end_code
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
.equ PREV,20
.equ MATERIAL,22

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
    mov ds,ax
    push 0xa000-48
    pop es
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
    xchg ax,dx
    imul al
    add ax,dx
    shr ax,4
    cmp al,5
    jb height_add
    mov al,5
height_add:
    add al,7
    mov dl,bh
    shr dl,2
    # block value doubles as its color: 0 air, 143 grass, 139 dirt
    sub al,dl
    jbe ground
    cmp al,5
    ja air
    mov cx,bx
    and cl,0xe7
    cmp al,4
    jb trunk
    sub cl,0x42
    test cl,0x84
    mov al,144
    jz terrain_store
air:
    xor al,al
    jmp terrain_store
trunk:
    cmp cl,0x63
    mov al,137
    je terrain_store
    jmp air
ground:
    mov al,143
    je terrain_store
    sbb al,al
    and al,139
terrain_store:
    mov byte ptr [bx],al
    inc bx
    # BX hits 8000h after all 32768 blocks, sign bit ends the loop
    jns terrain
    push 40-100
    push bx
    mov ax,0x2200
    push ax
    push 0x1600
    push ax
    mov bp,sp
    mov byte ptr [bp+MATERIAL],143
# check the center ray first so the highlight matches the block being edited
frame:
    or dword ptr [bp+TARGET],-1
    mov di,0x8000
    xor dx,dx
    mov ax,word ptr [bp+PITCH]
    add ax,100
# columns go right to left, one horizontal rotation per column
column:
    mov word ptr [bp+VY],ax
    call turn_column
    mov word ptr [bp+VX],dx
    mov word ptr [bp+VZ],ax
# SP = BP here, pop/push the camera coords to save 3 bytes
pixel:
    pop ax
    pop dx
    pop si
    push si
    push dx
    push ax
    # start with the camera's cell so close-up hits have a previous voxel
    mov cl,96
    call sample_voxel
# fixed-size steps, keep the last empty cell
march:
    mov word ptr [bp+PREV],bx
    call step
    loope march
    jnc sky
    # find the face crossed: check Y, then Z, then X
    # previous cell was air, so at least one axis has to differ
    mov si,word ptr [bp+PREV]
    xor si,bx
    mov dx,0x800f
face_mask_loop:
    ror dx,5
    test si,dx
    jz face_mask_loop
# only the center ray sets the remove/place targets
face_selected:
    test di,di
    jns shade
    mov word ptr [bp+TARGET],bx
    and si,dx
    xor si,bx
    # skip the first 8 samples for placement, too close to the camera
    cmp cl,87
    ja shade
    mov word ptr [bp+EMPTY],si
shade:
    test dl,dl
    mov al,byte ptr [bx]
    jz colored
    jns side_tint
    add al,96
side_tint:
    sub al,24
# shift to another palette band for distant blocks
colored:
    cmp cl,71
    jae selected_tint
    add al,24
# brighten the selected block, keep the face shading
selected_tint:
    cmp bx,word ptr [bp+TARGET]
    jne draw
    sub al,72
    .byte 0xa9
sky:
    mov al,102
draw:
    add word ptr [bp+VY],2
    stosb
    stosb
    add di,318
    jns pixel
    mov ax,word ptr [bp+PITCH]
    sub di,0x8002
    lea di,[di+768]
    lea dx,[di-768-160]
    jnc column
    mov di,768+98*320+4
    mov al,byte ptr [bp+MATERIAL]
    sub al,72
    mov cl,8
    rep stosb
key_read:
    xor ax,ax
    int 0x16
    sub al,49
    cmp al,5
    ja key_dispatch
    cbw
    xchg ax,bx
    ss mov al,byte ptr [bx+materials]
    mov byte ptr [bp+MATERIAL],al
    jmp redraw
key_dispatch:
    xchg ax,dx
    mov si,offset keys
    mov cl,12
# each key comes with a signed movement amount or block material
# table order matches the state offsets so the controls can share code
find_key:
    ss lodsw
    cmp ah,dh
    loopne find_key
    jne redraw
    cbw
    xchg ax,dx
    cmp cl,10
    jae edit
    xor ax,ax
    xor si,si
    and cl,-2
    jz rotate_move
    cmp cl,4
    ja parameter
    jb vertical
    xchg ax,dx
rotate_move:
    call turn_vector
    xchg ax,si
    xchg ax,dx
    xor dx,dx
vertical:
    push bp
    sub bp,VX-PX
    call step
    pop bp
    jne redraw
    add sp,6
    push si
    push dx
    push ax
    jmp redraw
parameter:
    mov si,cx
    add word ptr [bp+si],dx
    jmp redraw
edit:
    and dl,byte ptr [bp+MATERIAL]
    mov bx,word ptr [bp+si+TARGET-2-0x7c00-(keys-_start)]
    test byte ptr [bx],dl
    jne redraw
    mov byte ptr [bx],dl
redraw:
    jmp frame
# in: AX=X, DX=Y, SI=Z, CH=0; coords and CX stay intact
# out: BX=index if valid; CF=solid, ZF=air, neither=out of bounds
step:
    add ax,word ptr [bp+VX]
    add dx,word ptr [bp+VY]
    add si,word ptr [bp+VZ]
# valid coords fit in 15 bits, OR catches anything outside
sample_voxel:
    mov bx,si
    or bx,ax
    or bx,dx
    js sampled
    push ax
    mov bx,si
    shr bx,5
    and bl,0xe0
    shr ax,10
    mov ah,dh
    and ah,0x7c
    or bx,ax
    pop ax
    # compare 0 to the block value, get both flags in one go
    cmp ch,byte ptr [bx]
sampled:
    ret
# 64 yaw positions: small rounded Q8 rotations, then exact quarter turns
# used for both movement and rays
turn_column:
    mov ax,192
turn_vector:
    mov cx,word ptr [bp+YAW]
    push cx
    and cx,15
    jcxz quarter_setup
micro_rotate:
    imul bx,ax,25
    imul si,dx,-25
    sub si,ax
    sub bx,dx
    sar si,8
    adc ax,si
    sar bx,8
    adc dx,bx
    loop micro_rotate
quarter_setup:
    pop cx
    shr cx,4
    and cl,3
    jcxz rotated_vector
rotate:
    xchg ax,dx
    neg ax
    loop rotate
rotated_vector:
    ret
keys:
    .byte 0,0x0e, 255,0x39
    .byte 2,0x50, -2,0x48, 1,0x12, -1,0x10
    .byte 96,0x11, -96,0x1f, 96,0x21, -96,0x13, 96,0x20, -96,0x1e
materials:
    .byte 143,137,136,140,131,148
end_code:
    .fill 510-(.-_start),1,0
    .word 0xaa55
