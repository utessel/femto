#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

/*
   this is just a quick hack to test a few things of the bootloader.
*/

int serialFile;

void Usage(const char * name)
{
  printf("%s <option> <serial device>\n", name );
  printf("option:\n");

  printf(" r: read flash\n");
  printf(" w: write a page\n");
  printf(" f: read fuses\n");
  printf(" e: read eeprom\n");
  printf(" x: write some eeprom bytes\n");
}

unsigned char calcChecksum( unsigned char a,unsigned char b,unsigned char cmd)
{
#define xor ^
  unsigned char result = ((((1 xor a)+1) xor b)+1) xor (cmd-1);
}

void SendCommand( unsigned char a,unsigned char b,unsigned char cmd)
{
    unsigned char buffer[4] = { 
      a,
      b, 
      calcChecksum(a,b,cmd),
      cmd 
    };

    int bytes = write( serialFile, buffer, 4 );
    if (bytes<4)
    {
      perror("write to serial port");
    }
}

void DumpMemory(unsigned char memory[], int size)
{
  int i;
  for (i=0; i<size; i++)
  {
    printf("%02x ", memory[i] );
    if (i%16==15) printf("\n");
  }
  if (i%16!=15) printf("\n");
}

void ExecuteCommand( unsigned char a, unsigned char b, unsigned char cmd )
{
    unsigned char ack;
    int retry=3;
    while (retry>0)
    {
      SendCommand(a,b,cmd);

      int bytes = read(serialFile, &ack, 1 );
      if (bytes<=0) 
      {
         perror("read ack from serial port");
         exit(-1);
      }
      if (ack == 'A') break;

      if (ack == 'W')
      {
        printf("checksum err\n");
      } else
        printf("No ack: %x\n", ack);
      retry--;
    }
}

void ReadMem(unsigned char mem[], int size, unsigned char cmd)
{
  int i;
  for (i=0;i<size;i++)
  {
    int bytes;
    if (i%32==0) { printf("%04x\r",i); fflush(stdout); }

    ExecuteCommand( i,i>>8, cmd );

    unsigned char data;
    bytes = read(serialFile, &data, 1 );
    if (bytes<=0) 
    {
       perror("read data from serial port");
       exit(-1);
    }

    mem[i] = data; 
  }
}


void ReadFlash(unsigned char flash[2048])
{
  ReadMem( flash, 2048, 0x40 );
}

void ReadFuses(unsigned char mem[4])
{
  ReadMem( mem, 4, 0x40 | 0x08 | 0x01 );
}

void ReadEEPROM(unsigned char mem[])
{
  ReadMem( mem, 128, 0x80 );
}

void WriteEEPROMByte(unsigned char addr, unsigned char byte)
{
  ExecuteCommand( addr, 0, 0x80 ); // read eeprom

  unsigned char datapre;
  int  bytes = read(serialFile, &datapre, 1 );
  if (bytes<=0) 
  {
     perror("read data from serial port");
     exit(-1);
  }

  if (datapre==byte) return;

  ExecuteCommand( byte, 4, 0x80 | 0x20 ); // write eeprom

  unsigned char datapost;
  bytes = read(serialFile, &datapost, 1 );
  if (bytes<=0) 
  {
     perror("read data from serial port");
     exit(-1);
  }

  printf("tried to write %x to EEPROM address %x: %x -> %x\n", 
      byte, addr, datapre, datapost );
  
}

void FillTemp(unsigned char mem[])
{
  int i;
  for (i=0; i<16; i++)
  {
    // use nop to load r1:r0
    ExecuteCommand( mem[i*2], mem[i*2+1], 0x0 );
    // and then load that to the temp buffer address i
    ExecuteCommand( i*2, 0, 0x01 );
  }
}

void ErasePage(unsigned char addr)
{
  ExecuteCommand( addr, 0, 0x03 );
  usleep(10000);
}

void PageWrite(unsigned char addr)
{
  ExecuteCommand( addr, 0, 0x05 );
  usleep(10000);
}


int main(int argc, char**argv)
{
  if (argc<3)
  {
    Usage(argv[0]);
    return -1;
  }

  serialFile = open( argv[argc-1], O_RDWR);
  if (serialFile<0)
  {
    perror("open serial port");
    return -1;
  }

  for (;;)
  {
    unsigned char reason;
    unsigned char wait;

    printf("Waiting for reset:\n");
    int bytes = read( serialFile, &reason, 1 );
    if (bytes<=0)
    {
       perror("read reason from serial port");
       return -1;
    }
    if (reason == 'W') continue;
      
    bytes = read( serialFile, &wait, 1 );
    if (bytes<=0)
    {
       perror("read wait from serial port");
       return -1;
    }

    if (wait == 'W')
    {
      if ((reason&0xF0)!=0x20) 
      {
         printf("strange reset\n");
         continue;
      }
      if (reason&1) printf("Power On Reset\n");
      if (reason&2) printf("External Reset\n");
      if (reason&4) printf("Brown-out Reset\n");
      if (reason&8) printf("Watchdog Reset\n");
      break;
    }
  }   

  unsigned char flash[2048];
  unsigned char eeprom[128];
  unsigned char fuses[4];

  if (argv[1][0]=='r')
  {
    printf("reading Flash:\n");
    ReadFlash(flash);
    DumpMemory(flash, sizeof(flash));
  }

  if (argv[1][0]=='w')
  {
    unsigned char dummy[] = "Hello World: this is just a test if write flash works";
    printf("fill temp\n");
    FillTemp( dummy ); 
    printf("erase page\n");
    ErasePage( 0x20 );
    printf("page write\n");
    PageWrite( 0x20 );
  }

  if (argv[1][0]=='f')
  {
    ReadFuses(fuses);

    printf("LFuse: %02x\n", fuses[0] );
    printf("HFuse: %02x\n", fuses[3] );
    printf("EFuse: %02x\n", fuses[2] );
    printf("LockBits: %02x\n", fuses[1] );
  }

  if (argv[1][0]=='e')
  {
    printf("Reading EEPROM:\n");
    ReadEEPROM(eeprom);
    DumpMemory(eeprom, sizeof(eeprom));
  }

  if (argv[1][0]=='x')
  {
    WriteEEPROMByte( 0x4, 0x55 );
    WriteEEPROMByte( 0x9, 0xAA );
    WriteEEPROMByte( 0x52, 'X' );

    printf("Reading EEPROM:\n");
    ReadEEPROM(eeprom);
    DumpMemory(eeprom, sizeof(eeprom));
  }

  close( serialFile );

  return 0;
}
