ASM = nasm
EMU = qemu-system-i386
EMU_FLAGS = -hda


pdf.img : pendriveforth.asm
	$(ASM) -o $@ $<


.PHONY = run

run : pdf.img
	$(EMU) $(EMU_FLAGS) $<
