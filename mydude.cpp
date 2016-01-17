#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <termios.h>

void Usage(const char * name)
{
  printf("%s <option> <serial device> [filename]\n", name );
  printf("option:\n");

  printf(" r: read flash\n");
  printf(" w: write a binary\n");
  printf(" f: read fuses\n");
  printf(" e: read eeprom\n");
  printf(" k: kill app\n");
  printf(" x: write some eeprom bytes\n");
}
// ------------------------------------------------------------------

class FemtoLoader
{
public:
  struct Command
  {
    unsigned char bytes[6];

    void SetR0( unsigned char v ) { bytes[0] = v; }
    void SetR1( unsigned char v ) { bytes[1] = v; }
    void SetZL( unsigned char v ) { bytes[2] = v; }
    void SetZH( unsigned char v ) { bytes[3] = v; }
    void SetCommand( unsigned char v ) { bytes[4] = v; }

    void SetChecksum();

    void SetZ( unsigned short v ) 
    {
      SetZL( v & 0xFF );
      SetZH( v>>8 );
    }

    void SetR01( unsigned short v ) 
    {
      SetR0( v & 0xFF );
      SetR1( v>>8 );
    }
  };

private:
  enum {
    ACK_CHAR = '@',
    WAIT_CHAR = 'W'
  };

  int serialFile;
  bool ok;
  void Error( const char * msg );

  bool RxByte( unsigned char * byte, unsigned int maxusec );
  void SendCommand( const struct Command & );

  bool ReadMem( unsigned char * mem, unsigned short start, size_t len, unsigned char cmd );
public:

  FemtoLoader( const char * filename );
  ~FemtoLoader();

  bool Ok() const { return ok && (serialFile>=0); }

  unsigned char WaitForReset( );
  void DecodeResetReason( unsigned char );

  unsigned char ExecuteCommand( Command & );

  bool ReadFlash( unsigned char * mem, unsigned short start, 
    size_t len )
  {
    return ReadMem( mem, start, len, 0x80 );
  }

  bool ReadFuses( unsigned char * mem, size_t len )
  {
    return ReadMem( mem, 0, len, 0x89 );
  }

  unsigned char ReadData( unsigned short addr )
  {
    unsigned char result;
    ReadMem( &result, addr, 1, 0xD0 );

    return result;
  }

  unsigned char WriteData( unsigned short addr, unsigned char value );

  bool ReadRegisters( unsigned char * mem, size_t len )
  {
    return ReadMem( mem, 0, len, 0xD0 );
  }

  bool ReadRAM( unsigned char * mem, size_t len )
  {
    return ReadMem( mem, 0x60, len, 0xD0 );
  }

  bool ReadEEPROM( unsigned char * mem, unsigned short addr, size_t len );

  bool WriteEEPROM( const unsigned char * mem, unsigned short addr, size_t len );

  bool ErasePage( unsigned short addr );
  bool LoadTemp( unsigned char mem[], size_t size );
  bool WritePage( unsigned short addr );
};
// ------------------------------------------------------------------

FemtoLoader::FemtoLoader(const char * filename)
: serialFile {-1 }
, ok { false }
{
  serialFile = open( filename, O_RDWR);
  if (serialFile<0)
  {
    Error("open serial port");
    return;
  }

  struct termios serset;
  tcgetattr(serialFile, &serset);
  cfsetospeed(&serset, B38400); 
  cfmakeraw(&serset);
  tcsetattr(serialFile, TCSANOW, &serset); 

  ok = true;
}
// ------------------------------------------------------------------

FemtoLoader::~FemtoLoader()
{
  if (serialFile >= 0) close( serialFile );
  serialFile = -1;
}
// ------------------------------------------------------------------

void FemtoLoader::Error( const char * msg )
{
  ok = false;
  perror( msg );
}
// ------------------------------------------------------------------

bool FemtoLoader::RxByte( unsigned char * byte, unsigned int maxusec )
{
  if (!Ok()) return false;

  fd_set rfds;
  struct timeval tv;
  int retval;

  FD_ZERO(&rfds);
  FD_SET(serialFile, &rfds);

  tv.tv_sec = 0;
  tv.tv_usec = maxusec;

  retval = select(serialFile+1, &rfds, NULL, NULL, &tv);

  if (retval==-1) { Error("select in RxByte"); return false; }

  if (retval==0) return false;
  retval = read( serialFile, byte, 1 );

  if (retval < 0)
  {
    Error( "read in RxByte" );
  }

  return retval == 1;
}
// ------------------------------------------------------------------

unsigned char FemtoLoader::WaitForReset()
{
  if (!Ok()) return 0xFF;

  for (;;)
  {
    unsigned char reason;
    unsigned char wait;

    if (RxByte( &reason, 200000)!=1)
    {
       printf("."); fflush(stdout);
       continue;
    }

    if (RxByte( &wait, 10000)!=1)
    {
       printf("?"); fflush(stdout);
       continue;
    }

    if (wait == 'W') 
        return reason;
  }
}
// ------------------------------------------------------------------

void FemtoLoader::DecodeResetReason(unsigned char reason)
{
    printf("Reset detected\n");
    if (reason & 0xf0)
    {
      printf("strange reset: %02x\n", reason);
      return;
    }
   
    if (reason==0) printf("no app to be started\n");
    if (reason&1) printf("Power On\n");
    if (reason&2) printf("External\n");
    if (reason&4) printf("Brown-out\n");
    if (reason&8) printf("Watchdog\n");
}
// ------------------------------------------------------------------

void FemtoLoader::SendCommand( const Command & command )
{
    if (!Ok()) return;

    size_t bytes = write( serialFile, command.bytes, sizeof(command.bytes) );
    if (bytes<sizeof(command.bytes))
    {
      Error("write in SendCommand");
    }
}
// ------------------------------------------------------------------

unsigned char FemtoLoader::ExecuteCommand( Command & command )
{
    if (!Ok()) return 0;

    command.SetChecksum();

    unsigned char ack;
    int retry=3;
    while (retry>0)
    {
      int err = 0;
      SendCommand(command);

     /*
        38400 baud = 3840 chars per second 
        = 960  4-byte commands peer second
        ~= 1ms timeout

        so if longer than 20ms, something went wrong
     */

      while (!RxByte( &ack, 20000 ))
      {
         if (!Ok()) return 0;

         err++;
         unsigned char nullbyte = 0;
         write( serialFile, &nullbyte, 1 );
      }

      if ((err == 0) && (ack == ACK_CHAR))
      {
        break; 
      }

      printf("%02x received\n", ack );

      // checksum error
      retry--;
      if (err==0)
      {
        fprintf(stderr,"checksum error: Retry required\n"); fflush(stderr);
      }
      else
      {
        fprintf(stderr,"timeout occured: Retry required\n"); fflush(stderr);
      }
    }

    unsigned char result;

    // so now the command is running:
    // some, like WaitFor, might take a while
    // but not 100ms?
    if (!RxByte( &result, 100000))
    {
       ok = false;
       fprintf(stderr, "communication timout\n"); fflush(stderr);
    }

    return result;
}
// ------------------------------------------------------------------

void FemtoLoader::Command::SetChecksum()
{
  bytes[5] = 0;

  unsigned char sum = ACK_CHAR;
  for (auto b : bytes)
  {
    sum ^= b;
    sum++;
  }
  bytes[5] = (sum-1)^0xFF;

}
// ------------------------------------------------------------------

unsigned char FemtoLoader::WriteData( unsigned short addr, unsigned char value )
{
  Command cmd;

  cmd.SetR0(value);
  cmd.SetR1(value);
  cmd.SetZ(addr);
  cmd.SetCommand( 0 );
 
  return ExecuteCommand( cmd );
}
// ------------------------------------------------------------------
 
bool FemtoLoader::ReadMem( unsigned char * mem, unsigned short start, size_t len, unsigned char cmdValue )
{
  Command cmd;

  cmd.SetR01(0);
  cmd.SetCommand( cmdValue );
 
  unsigned short addr = start;
  unsigned short end = start+len;

  while (addr < end)
  {
    if (!Ok()) return false;

    fprintf(stdout, "%04x\r", addr); fflush(stdout);
    cmd.SetZ( addr );

    *mem = ExecuteCommand( cmd );

    addr++;
    mem++;
  }

  return true;
}
// ------------------------------------------------------------------

bool FemtoLoader::ReadEEPROM( unsigned char * mem, unsigned short addr, 
 size_t len )
{
  // todo
  // set EEPROM IO Register and then read from IO
  return false;
}
// ------------------------------------------------------------------

bool FemtoLoader::WriteEEPROM( const unsigned char * mem, 
  unsigned short addr, size_t len )
{
  // todo
  // set EEPROM IO Register, write to IO, ...
  return false;
}
// ------------------------------------------------------------------

bool FemtoLoader::ErasePage( unsigned short addr )
{
  Command cmd;
  cmd.SetR01(0);
  cmd.SetZ(addr);
  cmd.SetCommand( 0x43 );
  return ExecuteCommand( cmd );
}
// ------------------------------------------------------------------

bool FemtoLoader::LoadTemp( unsigned char mem[], size_t size )
{
  Command cmd;
 
  if (size>0x20) return false;

  unsigned int i = 0;
  while (i<size)
  {
    cmd.SetZ(i);
    cmd.SetR0(mem[i++]);
    cmd.SetR1(mem[i++]);
    cmd.SetCommand( 0x41 );

    if (!ExecuteCommand( cmd )) return false;
  }

  return true;
}
// ------------------------------------------------------------------

bool FemtoLoader::WritePage( unsigned short addr )
{
  Command cmd;
  cmd.SetR01(0);
  cmd.SetZ(addr);
  cmd.SetCommand( 0x45 );

  return ExecuteCommand(cmd);
}
// ------------------------------------------------------------------

static void DumpMemory(unsigned char memory[], size_t size)
{
  unsigned int i;
  for (i=0; i<size; i++)
  {
    printf("%02x ", memory[i] );
    if (i%16==15) printf("\n");
  }
  if (i%16!=15) printf("\n");
}
// ------------------------------------------------------------------

static bool AllFF( unsigned char * mem, size_t size)
{
  unsigned int i;
  for (i=0; i<size; i++)
    if (mem[i] != 0xFF) return false;

  return true;
}
// ------------------------------------------------------------------

void UploadFile(FemtoLoader & loader, const char * name)
{
  const unsigned int PAGE_SIZE = 0x20;

  int i;
  unsigned char buffer[2048 - 128];
  unsigned char flashPost[2048];

  memset( buffer, 0xFF, sizeof(buffer) );

  int fd = open( name, O_RDONLY );
  if (fd<0) return;
  int bytes = read( fd, &buffer, sizeof(buffer));
  close(fd);

  // copy rjmp fromreset vector
  // and create rcall of it
  unsigned short appstart = buffer[1]<<8 | buffer[0];
  appstart &= 0x0FFF;
  appstart ++;
  appstart *= 2;
  printf("App starts at 0x%x\n", appstart );

  appstart -= 0x780;
  appstart /= 2;
  appstart &= 0x0FFF;
  appstart |= 0xD000;
  printf("that gives %02x %02x (rcall)\n", appstart&0xff, appstart>>8 );

  buffer[0x780-2] = appstart&0xff;
  buffer[0x780-1] = appstart>>8;

  // and patch jump to bootloader to reset vector
  buffer[0] = 0xBF;
  buffer[1] = 0xC3;

  printf("Uploading data\n");
  for (i=0; i<bytes; i+=PAGE_SIZE)
  {
    printf("Address %x\r", i); fflush(stdout);

    if (AllFF( &buffer[i], PAGE_SIZE))
    {
      loader.ErasePage( i );
    } else
    {
      loader.LoadTemp( &buffer[i], PAGE_SIZE ); 
      loader.ErasePage( i );
      loader.WritePage( i );
    }
  }

  if (i<0x780)
  {
    loader.LoadTemp( &buffer[0x760], PAGE_SIZE ); 
    loader.ErasePage( 0x760 );
    loader.WritePage( 0x760 );
  }
  printf("Reading flash\n");

  loader.ReadFlash( flashPost, 0, sizeof(flashPost) );

  DumpMemory( flashPost, sizeof(flashPost));
}

int main(int argc, char**argv)
{
  if (argc<3)
  {
    Usage(argv[0]);
    return -1;
  }

  FemtoLoader mydude( argv[2] );
  unsigned char reason = mydude.WaitForReset();
  mydude.DecodeResetReason( reason );

  unsigned char flash[2048];
  //unsigned char eeprom[128];
  unsigned char fuses[4];


  if (argv[1][0]=='r')
  {
    if (mydude.ReadFlash( flash, 0, 2048 ))
    {
      DumpMemory(flash, sizeof(flash));
    } else
    {
      printf("Read flash failed\n");
    }
  }

  if (argv[1][0]=='f')
  {
    mydude.ReadFuses(fuses, sizeof(fuses));

    printf("LFuse: %02x\n", fuses[0] );
    printf("HFuse: %02x\n", fuses[3] );
    printf("EFuse: %02x\n", fuses[2] );
    printf("LockBits: %02x\n", fuses[1] );
  }

#if 0
  if (argv[1][0]=='y')
  {
    mydude.ReadRegisters(flash, 32);
    DumpMemory(flash, 32);
  }

  if (argv[1][0]=='z')
  {
    mydude.ReadRAM(flash, 128);
    DumpMemory(flash, 128);
  }

  if (argv[1][0]=='t')
  {
    mydude.WriteData(25, 0x55);
  }
#endif

  if (argv[1][0]=='w')
  {
    if (argc<4) printf("please give me a filename\n");
    UploadFile(mydude, argv[3]);
  }

  if (argv[1][0]=='k')
  {
    printf("erase page\n");
    mydude.ErasePage( 0x760 );
  }

#if 0
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
#endif

  return 0;
}
