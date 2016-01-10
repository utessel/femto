TARGET = femto

.PHONY: $(TARGET)
$(TARGET): 
	avr-gcc -nostartfiles -mmcu=attiny2313 femto.S -DWATCHDOG=7 -o femto

$(TARGET).hex : $(TARGET)
	 avr-objcopy -j .data -j .text -O ihex $< $@

load: $(TARGET).hex
	avrdude -V -p t2313 -c usbtiny -U flash:w:$(TARGET).hex 

clean:
	rm -f *.o  *.hex $(TARGET)
