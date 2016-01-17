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

  Features/Drawbacks of this bootloader:
  - requires hardware USART
  - uses, configures and handles the Watchdog 
  - still smaller than 128 bytes
  - allows to read the flash 
  - allows to flash new code 
  - allows to read the fuses
  - allows to read and write the data "RAM"
  - via this "RAM" access you can access everything:
  - allo kind of external IO or internal IO:
  - including read and write of the EEPROM

  How does it work:
  The main idea is to keep the code stupid:
  it does not know why and what it does, it simply forwards
  requests it receives to the chip: SPM, LPM, read from address,
  write to address. 

  Protocol: 
  6 Bytes:
     Byte 0: R0
     Byte 1: R1
     Byte 2: ZL
     Byte 3: ZH
     Byte 4: DATA    // the command
     Byte 5: checksum
 
  A request will generate an Ack or Error byte after
  receiving the six bytes and one "result" byte after the
  command was executed. The last is important when you use
  "waitfor".
  
  For details: 
  Check the data sheet (SPM/LPM !) and the source below.
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
/* take care: DATA and TEMP are used as pair */
#define DATA        R16
#define TEMP        R17
#define WAITING     R18
#define ACK         R19

#ifndef WATCHDOG
#define WATCHDOG 7
#endif

.section .intvect,"ax",@progbits
    rjmp bootMain

.section .pre.bootload,"ax",@progbits
preboot:
.byte 0xFF,0xFF   // if appl is avail, a rcall should be stored here
 // if not, this is a kind of "NOP"
                 
.section .code.bootload,"ax",@progbits
.global bootMain  
bootMain:
  //--------------------------------------------------
  // read and clear the reset reason
    clr r1
    in DATA, MCUSR  // keep for later
    out MCUSR, r1   // and clear it  


  //--------------------------------------------------
  // setup the watchdog
    // a wdr not required here, because one was done by reset
    in TEMP, WDTCSR
    ori TEMP, (1<<WDCE) | (1<<WDE)
    out WDTCSR, TEMP
    ldi TEMP, (1<<WDE) | ((WATCHDOG-1) &0x7) | (((WATCHDOG-1)&8)<<2)
    out WDTCSR, TEMP


  // --------------------------------------------------
  // check the reset reason to know when to start the app
    in r31,(SP+1)   // for chips with more RAM
    in r30,SP       // = load Z with SP

#if 0
    ld TEMP,-Z // skips top of stack 
    out SP,r30 // = dec SP (low byte is enough here)
#else
    ld TEMP,Z 
#endif
    cpi TEMP, pm_lo8( afterRx )   
    ld CHECK,-Z 
    ldi TEMP, pm_hi8( afterRx )   
    cpc CHECK, TEMP
    ldi TEMP, 8
    cpc DATA, TEMP
    breq preboot // the call below and a watchdog reset?
                 // then no bytes were received while in bootloader:
                 // call the app!

#if 0
    pop TEMP     // = inc SP
    push DATA    // store new reset reason at end of RAM
#endif
    
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
   ldi ACK,     '@'
   ldi WAITING, 'W'
checksumfail:

    out UDR, WAITING   // tell loader we are waiting
    // (is also sent when checksum was wrong)

rxLoop:
    wdr

    // start checksum
    mov CHECK,ACK

    rcall rx6Bytes
afterRx:
    brne checksumfail

    out UDR, ACK   
    /*
      if this ACK is not received by the loader control
      application (within a time, depends on the baud rate) 
      it should send bytes with 0x80 to get out of the rx 
      loops. Otherwise the watchdog will reset the chip!
      0x80 will likely generate a checksum error, 
      and if not, a lpm command: Reading some random address of
      program flash. In both cases we can continue without 
      leaving the bootloader, for example by repeating the last 
      command.
    */

    // set some flags
    cpi DATA,0xC0
    /*
           SVNZC
    00..3F=00001
    40..7F=01101
    80..BF=10101
    C0..  =00010
    C1..FF=00000
    */
    brpl other  // N=0 

    // so DATA is 40..BF
    // we have either a SPM or LPM command:
    // both want SPMCSR to be set. After that we have
    // only the cycles for one branch:
    out SPMCSR, DATA 
    brvs writespm 

    // --------------------------------------------------
    // a "LPM" Command:  80..BF
readlpm:
    lpm DATA,Z     // perform the read
    rjmp sendByte  // and send result

    // --------------------------------------------------
    // a "SPM" Command:  40..7F
writespm:
    spm           
    rjmp sendByte 

    // --------------------------------------------------
    // other commands: 00..3F, C0..FF
    /*     SVNZC
    00..3F=00001
    C0..  =00010
    C1..FF=00000
    */
other:
    brcc readram  // C0..FF?
writeram:         // write ram: 00..3F
    st Z,r0
    sbrc DATA,0   // don't read if Bit 0 is set
readram:         
    ld DATA,Z
    brne sendByte // not equal -> not C0 
    and DATA,r0   // C0 is waitfor:
    cp DATA,r1    // poll one io for change
    rjmp readram  
sendByte:
    out UDR, DATA
    rjmp rxLoop

rx6Bytes:
    rcall rx2Bytes
    movw r0,DATA
rx4Bytes:
    rcall rx2Bytes
    movw ZL,DATA
rx2Bytes:
    rcall rx1Byte
    mov DATA,TEMP
rx1Byte:
    sbis UCSRA, RXC
    rjmp rx1Byte
    in  TEMP, UDR
    eor CHECK,TEMP
    inc CHECK
    ret

.section .magic.bootload,"ax",@progbits
magic: // can be read via the lpm path
.byte 0x1e,0x91,0x0a,0x00
