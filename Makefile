.PHONY: all
all: femto.hex femtoreset.hex blink.bin mydude

femto: femto.S
	avr-gcc -nostartfiles -mmcu=attiny2313 -T femto.x femto.S -o femto

femto.hex : femto
	 avr-objcopy -j bootload -O ihex $< $@

femtoreset.hex : femto
	 avr-objcopy -j intvect -O ihex $< $@

load: femto.hex
	avrdude -V -p t2313 -c usbtiny -U flash:w:femto.hex 

mydude: mydude.c
	gcc -Wall mydude.c -o mydude

blink.bin: blink
	 avr-objcopy -j .data -j .text -O binary $< $@

blink: blink.cpp
	avr-gcc -O2 -o blink blink.cpp -DF_CPU=8000000 -mmcu=attiny2313

.PHONY: clean
clean:
	rm -f *.o  *.hex *.bin femto blink mydude
