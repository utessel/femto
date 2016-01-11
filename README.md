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
ideas found everywhere, but especially to Ralph Doncaster for his picoboot:

  https://github.com/nerdralph/picoboot/blob/master/picobootSerial.S


How to use it:

You need an application that speaks the protocol.
Currently there is only "mydude": It implements most/all
of the protocol, but lacks some timeout handling etc.
so it is far from perfect:
It might be useful to understand how the protocol works?

To compile mydude:
  cc -Wall -o mydude mydude.c

At least it supports to upload a binary:
You can generate a binary from a normal compile with

  avr-objcopy -j .data -j .text -O binary blink blink.bin

with blink being the elf-File and blink.bin the result that
can be uploaded:

  mydude w /dev/ttyUSB0 blink.bin


