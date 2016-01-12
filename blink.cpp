#include <avr/io.h>
#include <util/delay.h>
#include <avr/wdt.h>

int main()
{
  DDRB  = 0xFF;
  int i;

  // handle the watchdog for some time
  for (i=0; i<20; i++)
  {
    wdt_reset();
    PORTB |= (1<<PB0);
    _delay_ms(200);
    wdt_reset();
    PORTB &= ~(1<<PB0);
    _delay_ms(200);
  }

  // but then stop doing so
  for(;;)
  {
    PORTB |= (1<<PB0);
    _delay_ms(200);
    PORTB &= ~(1<<PB0);
    _delay_ms(200);
   }
}
