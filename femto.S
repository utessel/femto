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
  Ralph Doncaster.

  Features:
  - requires hardware USART
  - uses, configures and handles Watchdog 
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

  A request will generate an Ack or Error byte after
  receiving the four bytes and one "result" byte after the
  command was executed.
  
  For details: Check the data sheet (SPM/LPM) and the source
  below.
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

#define CHECK       R2
#define DATA        R16
#define TEMP        R17
#define WAITING     R18
#define ACK         R19

#ifndef WATCHDOG
#define WATCHDOG 7
#endif

.org 0
.text
    rjmp bootMain

.org 0x780-2,0xff

preboot:
.byte 0xFF,0xFF   // if appl is avail, a rcall should be stored here
                  // if not, this is a kind of "NOP"
.global bootMain  
bootMain:
  //--------------------------------------------------
  // read and clear the reset reason
    ldi ACK,        '@'
    in DATA, MCUSR  // keep for later
    out MCUSR, ACK  // and clear it  
                    // (for this ACK must have lowest bits clear)

  //--------------------------------------------------
  // setup the watchdog
     // a wdr not required here, because one is done by reset
    in TEMP, WDTCSR
    ori TEMP, (1<<WDCE) | (1<<WDE)
    out WDTCSR, TEMP
    ldi TEMP, (1<<WDE) | ((WATCHDOG-1) &0x7) | (((WATCHDOG-1)&8)<<2)
    out WDTCSR, TEMP


  // --------------------------------------------------
  // check the reset reason to know when to start the app
    in r30,SP  // load Z with SP

    // read top of stack (old values)
    ld TEMP,Z   
    cpi TEMP, pm_lo8( afterFirstRx )   
    ld CHECK,-Z 
    ldi TEMP, pm_hi8( afterFirstRx )   
    cpc CHECK, TEMP
    ldi TEMP, 8
    cpc DATA, TEMP
    breq preboot   

    /*
      So how does starting the app work:

      The app is started when the watchdog has reset this
      code while it was waiting for the first character:

      For this the top of stack is checked together with the
      Reset-Reason:
      The app should be started via rcall, as this will write 
      a different value to the stack. With that we can detect
      the application was started and the watchdog happened
      there, not here.
      
      (would also allow to "ret" into the bootloader if the 
      app wants?) Of course this will not work if the app writes 
      the right value, but that might be done intentionally.
    */

bootCont:
 // --------------------------------------------------
 // setup the USART:

#if (UBRR_VAL>>8)!=0
    ldi TEMP, hi8(UBRR_VAL)
    out UBRRH,TEMP
#endif
    ldi TEMP, lo8(UBRR_VAL)
    out UBRRL,TEMP
    ldi TEMP, (1 << RXEN) | (1 << TXEN)
    out UCSRB,TEMP

#if 0
   // 2 stop bits? 
    ldi TEMP, (1<<USBS)|(3<<UCSZ0)
    out UCSRC,TEMP
#endif

   // --------------------------------------------------
   // send RESET reason
   out UDR,DATA

   // --------------------------------------------------
   // Main of bootloader

   ldi WAITING,    'W'
checksumfail:
    /* 
       Optimization:
       why not wait for the send buffer to be flushed? 
       Because max 2 chars are sent!
       The first will immediately start to sent, the second 
       is prepared in UDR to be sent next

       This will work as we will receive 4 chars before 
       sending the next bytes.
    */

    out UDR, WAITING   // tell loader we are waiting
    // (also sent when checksum was wrong)

rxLoop:
    wdr

    /* main protocol idea from picobootserial.S:

       all is done using 4 bytes blocks:
       The checksum is calculated while receiving. 
       It must be 0 at the end, so the value of the 3rd 
       byte itself is only used for the checksum 
       calculation.
    */
    mov CHECK,ACK
    rcall rxByte  
afterFirstRx:      // this address is found on the stack in
                   // case of watchdog reset
    mov ZL,DATA    // 1st byte is parameter, stored in ZL
    rcall rxByte
    mov ZH,DATA    // 2nd byte is parameter, stored in ZH
    rcall rxByte   // 3rd byte is checksum
    rcall rxByte   // 4th byte is command, stored in DATA
    brne checksumfail 

    out UDR, ACK   
    /*
      if this ACK is not received by the loader control
      application (within a time, depends on the baud rate) 
      it should send bytes with zero to get out of the rx 
      loops. Otherwise the watchdog will reset the chip!
      Zeroes will likely generate a checksum error, 
      and if not, a NOP command. In both cases we can
      continue without leaving the bootloader, for example
      by repeating the last command.
    */

    bst DATA,6     // copy bit 6 to T flag: checked later
#ifndef NO_EEPROM
    sbrc DATA,7    // bit 7 set = not a SPM/LPM command
    rjmp other
#endif
    // so we have either a SPM or LPM command:
    // both want SPMCSR to be set:
    out SPMCSR, DATA 
    brtc writespm  // bit 6 (via T) set = LPM (read memory/fuses)

    // --------------------------------------------------
    // a "LPM" Command: 0x40..0x7F  (read memory or fuses)
    lpm DATA,Z     // perform the read
    rjmp sendByte  // and send result

    // --------------------------------------------------
    // a "SPM" Command: 0x00..0x3F  (write memory or fuses)
writespm:
    spm           // NOP if bit 0 wasn't set in DATA
    movw r0,ZL    // transfer Z to r0:1 (for next command)
    rjmp sendByte // and send a 2nd byte as ack

    // --------------------------------------------------
    // other commands:
other:
    brtc readeeprom// bit 6 (in T): write or read eeprom?

#if 0
    // sorry, no space left in 128 bytes
    sbrs DATA,5
    rjmp writeeeprom
    // --------------------------------------------------
    // read SRAM Memory
    // can be used to dump the memory after a watchdog 
    // reset of the application: SRAM has not changed.
    // obviously some registers are lost
    ld DATA,Z
    rjmp sendByte
#endif

    // --------------------------------------------------
    // Write EEPROM: 0x80
writeeeprom:         
    // to write: first read an address!
    out EEDR,ZL      // the data to be written
    out EECR,ZH      // what kind of write (and program enable)
    sbi EECR,EEPE    // start write
waitforeeprom:
    sbic EECR,EEPE   
    rjmp waitforeeprom 
    sbis EECR,EEPE  // skip next, so same address is read
                    // and a read is executed

    // --------------------------------------------------
    // Read EEPROM: 0xC0
readeeprom:
    out EEARL,ZL
    sbi EECR,EERE    // trigger read
    in DATA,EEDR     

    // --------------------------------------------------
    // all commands send a 2nd byte as ack when it was
    // executed
sendByte:
    out UDR, DATA
    rjmp rxLoop

    // --------------------------------------------------
    // to receive a byte
    // todo: this might be useful for the app, too
    // so check the register assignment. 
rxByte:
    sbis UCSRA, RXC
    rjmp rxByte
    in DATA, UDR
    eor CHECK,DATA
    inc CHECK       // a bit better than simple eor
    /* 
    the main idea for this inc and starting with 0x40
    is to avoid a valid checksum when four indentical
    bytes are received, which might happen, especially
    if someone is using a terminal: That should _not_
    destroy the flash or anything.
    */
    ret

#if 1
.org 0x7fC,0xFF
magic: // can be read via the lpm path
.byte 0x1e,0x91,0x0a,0x00
#endif
