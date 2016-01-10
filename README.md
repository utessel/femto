femto is a serial, full featured generic bootloader
(usable at least for tiny2313)

Features:
  - requires hardware USART
  - uses Watchdog 
  - still smaller than 128 bytes
  - allows to read the flash and fuses
  - allows to read and write the EEPROM
  and, of course: 
  - allows to flash new code (and set fuses)

Special thanks:
ideas found everywhere, but especially to Ralph Duncaster for his picoboot.


The file mydude.c is just a quick hack to test
the different aspects of the bootloader.
it is far from perfect, as it doesn't handle timeouts
etc, and it is not usable for anything real.

to compile it: (Linux!)
  cc -o mydude mydude.c

