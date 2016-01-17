SECTIONS
{
  intvect 0x0 : { *(.intvect) }
  preboot  0x780-2 : { *(.pre.bootload) }
  bootload 0x780 : { *(.code.bootload) }
  magic 0x7FC : { *(.magic.bootload) }
}
