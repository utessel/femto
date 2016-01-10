/*
  femto bootloader, usable at least for tiny2313
  (c) 2016 Uli Tessel (utessel@gmx.de)

  Permission is hereby granted, free of charge, to any person 
  obtaining a copy of this software and associated documentation 
  files (the "Software"), to deal in the Software without restriction, 
  including without limitation the rights to use, copy, modify, merge, 
  publish, distribute, sublicense, and/or sell copies of the Software, 
  and to permit persons to whom the Software is furnished to do so,
  subject to the following conditions:

  The above copyright notice and this permission notice shall be included 
  in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS 
  OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY 
  CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
  TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

/*
  Special thanks:
  ideas found everywhere, but especially to picoboot from 
  Ralph Duncaster.

  Features:
  - requires hardware USART
  - uses Watchdog 
  - still smaller than 128 bytes
  - allows to read the flash and fuses
  - allows to read and write the EEPROM
  and, of course: 
  - allows to flash new code (and set fuses)

  How does it work:
  The main idea is to keep the code stupid:
  it does not know why and what it does, it simply forwards
  requests it receives to the chip.

  Protocol: 
  All request are stored in a 4 Byte block: 
  Two byte data, checksum and the command code.

  A request will generate an Ack or Error byte and up to one
  byte response.
  
  For details: Check the data sheet and the source
*/


#define __SFR_OFFSET 0 
#include <avr/io.h>

#define F_CPU 8000000
#define BAUD 38400

#define UBRR_VAL (((F_CPU+BAUD*8)/(BAUD*16))-1) 
#define BAUD_REAL (F_CPU/(16*(UBRR_VAL+1)))  
#define BAUD_ERROR ((BAUD_REAL*1000)/BAUD)

#if ((BAUD_ERROR<990) || (BAUD_ERROR>1010))
  #error baud rate error larger than 1% 
#endif

#define CHECK R2
#define DATA R16
#define TEMP        R17
#define WAITING     R18
#define ACK         R19
#define FAIL        R20
#define RESETREASON R21


.org 0
.text
    rjmp preboot

.org 0x780-2

preboot:
.byte 0xFF,0xFF   ; if appl is avail, a jump should be stored here
                  ; if not, this is a kind of "NOP"
.global bootMain  
bootMain:
    in RESETREASON, MCUSR  ; keep for later
    out MCUSR, TEMP        ; and clear it (temp is 0)
    ori RESETREASON, 0x20  ; make value a readable character

#if (UBRR_VAL>>8)!=0
    ldi TEMP, hi8(UBRR_VAL)
    out UBRRH,TEMP
#endif

    ldi TEMP, lo8(UBRR_VAL)
    out UBRRL,TEMP
    ldi TEMP, (1 << RXEN) | (1 << TXEN)
    out UCSRB,TEMP

#if 0
   ; 2 stop bits
    ldi TEMP, (1<<USBS)|(3<<UCSZ0)
    out UCSRC,TEMP
#endif

#if WATCHDOG > 0
    wdr
    in TEMP, WDTCSR
    ori TEMP, (1<<WDCE) | (1<<WDE)
    out WDTCSR, TEMP
    ldi r16, (1<<WDE) | (WATCHDOG-1)
    out WDTCSR, TEMP
#elif WATCHDOG < 0
    ; todo: disable watchdog?
#endif

    ldi ACK,    'A'
    ldi WAITING,'W'

    ; write (once) the reset reason:
    out UDR, RESETREASON

checksumfail:
#if WATCHDOG > 0
    ; do not handle watchdog here, so we get a restart
    ; if nothing comes in
#else
    ; todo
#endif

bootWait:
    sbis UCSRA,UDRE
    rjmp bootWait
    out UDR, WAITING   ; tell loader we are waiting

bootLoop:
    clr CHECK
rxLoop:
#if WATCHDOG>0
    wdr
#endif
    ; main protocol idea:
    ; proudly found elsewhere (thanks to Ralph Doncaster)
    rcall rxByte  
    mov ZL,DATA    ; 1st byte 
    rcall rxByte
    mov ZH,DATA    ; 2nd byte
    rcall rxByte   ; 3rd byte is checksum
    rcall rxByte   ; 4th byte is command
    brne checksumfail 
    out UDR, ACK   ; if this is not received by the loader (within a time)
                   ; it should send zero bytes to get out of the rx loops 
                   ; (without the watchdog). Zero will likely generate 
                   ; a checksum error, and if not, a NOP command
    sbrc DATA,7    ; bit 7 set of command: see below
    rjmp other
    sbrc DATA,6    ; bit 6 set: read memory/fuses
    rjmp readlpm
    out SPMCSR, DATA 
    spm           ; NOP if bit 0 wasn't set in DATA
    movw r0,ZL    ; transfer Z to r0 (for next command)
    rjmp rxLoop

readlpm:
    ; eor DATA,ACK   ; clear bit 6
    out SPMCSR, DATA ; what kind of read (the command)
    lpm TEMP,Z       ; perform the read
sendbyte:
    out UDR, TEMP    ; and send result
    rjmp rxLoop

other:
    sbrc DATA,6      ; bit 6 set = start application
    rjmp preboot
    sbrc DATA,5      ; bit 5: write or read eeprom
    rjmp writeeeprom

readeeprom:
#ifdef EEARH 
    ; does not exist on small tiny
    out EEARH,ZH     
#endif
    out EEARL,ZL
doreadeeprom:
    sbi EECR,EERE    ; trigger read
    in TEMP,EEDR     
    rjmp sendbyte    ; and send

writeeeprom:         
    ; to write: first read an address!
    out EEDR,ZL      ; the data to be written
    out EECR,ZH      ; what kind of write (and program enable)
    sbi EECR,EEPE    ; start write
waitforeeprom:
    sbic EECR,EEPE   
    rjmp waitforeeprom 
    rjmp doreadeeprom ; as ack: read byte

rxByte:
    sbis UCSRA, RXC
    rjmp rxByte
    in DATA, UDR
    inc CHECK       ; a bit better than simple eor
    eor CHECK,DATA
    ret

.org 0x7fC
magic: ; can be read via the lpm path
.byte 0x1e,0x91,0x0a,0x00
