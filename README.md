femto
-----

a serial, full featured/generic bootloader

Features:
  - usable at least for tiny2313
  - requires/uses hardware USART 
  - uses the Watchdog
  - fits into 128 bytes
  - allows to read the flash and fuses
  - allows to read and write the EEPROM
  and, of course: 
  - allows to flash new code (and set fuses)

The usage of the watchdog is making this loader hopefully very useful:

If your application stops to work, the watchdog will reset
and now you have the option to exchange your app via the
serial interface. Standard, only bytes to send.  No RTS/CTS/DTR things.
If this does not happen, the app is started again.

As this loader is meant for environments where the serial
interface is in use, you might add a command to your protocol
that should activate the bootloader: then you get a cheap
(just 128 Bytes)  update path to your chip.

Of course you can still use a reset button or a reset line
from your serial interface or use a power cycle:
The important thing is: You don't need that.

I expect you can also use this nice on breadboards:
Just two pins from a serial interface to (re-)program your
chip...

Special thanks:
ideas found everywhere, but especially to Ralph Doncaster for 
his picoboot:

  https://github.com/nerdralph/picoboot/blob/master/picobootSerial.S


How to use it:

You need an application that speaks the protocol.

Currently there is only "mydude": 

It implements most/all of the protocol, but lacks some timeout handling etc.
so it is far from perfect: It might be useful to understand how the protocol works?

To compile mydude:

  cc -Wall -o mydude mydude.c

At least it supports to upload a binary:
You can generate a binary from a normal compile with

  avr-objcopy -j .data -j .text -O binary blink blink.bin

with blink being the elf-File and blink.bin the result that
can be uploaded:

  mydude w /dev/ttyUSB0 blink.bin


