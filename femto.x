SECTIONS
{
  intvect 0x0 : { *(.intvect) }
  preboot  0x780-2 : { *(.bootpre.bootload) }
  bootload 0x780 : { *(.bootmain.bootload) *(.magic.bootload) }
}
