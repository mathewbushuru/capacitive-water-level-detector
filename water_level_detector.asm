; EFM8_Receiver.asm:  This program implements a simple serial port
; communication protocol to program, verify, and read an SPI flash memory.  Since
; the program was developed to store wav audio files, it also allows 
; for the playback of said audio.  It is assumed that the wav sampling rate is
; 22050Hz, 8-bit, mono.
;
; Connections:
; 
; EFM8 board  SPI_FLASH
; P0.0        Pin 6 (SPI_CLK)
; P0.1        Pin 2 (MISO)
; P0.2        Pin 5 (MOSI)
; P0.3        Pin 1 (CS/)
; GND         Pin 4
; 3.3V        Pins 3, 7, 8  (The MCP1700 3.3V voltage regulator or similar is required)
;
; P3.0 is the DAC output which should be connected to the input of power amplifier (LM386 or similar)
;

$NOLIST
$MODEFM8LB1
$LIST

;Timer2
SYSCLK         EQU 72000000  ; Microcontroller system clock frequency in Hz
TIMER2_RATE    EQU 22050     ; 22050Hz is the sampling rate of the wav file we are playing
TIMER2_RELOAD  EQU 0x10000-(SYSCLK/TIMER2_RATE)
F_SCK_MAX      EQU 20000000
BAUDRATE       EQU 115200

;Timer0
CLK           EQU 2400000 ; Microcontroller system crystal frequency in Hz
TIMER0_RATE   EQU 2000*2    ; The tone we want out is A mayor.  Interrupt rate must be twice as fast.
TIMER0_RELOAD EQU 0x10000-(CLK/TIMER0_RATE)

FLASH_CE EQU P0.3
SPEAKER  EQU P1.3

BOOT_BUTTON   equ P3.7
SOUND_OUT     equ P2.1
SPI_IN        equ P0.2

; Commands supported by the SPI flash memory according to the datasheet
WRITE_ENABLE     EQU 0x06  ; Address:0 Dummy:0 Num:0
WRITE_DISABLE    EQU 0x04  ; Address:0 Dummy:0 Num:0
READ_STATUS      EQU 0x05  ; Address:0 Dummy:0 Num:1 to infinite
READ_BYTES       EQU 0x03  ; Address:3 Dummy:0 Num:1 to infinite
READ_SILICON_ID  EQU 0xab  ; Address:0 Dummy:3 Num:1 to infinite
FAST_READ        EQU 0x0b  ; Address:3 Dummy:1 Num:1 to infinite
WRITE_STATUS     EQU 0x01  ; Address:0 Dummy:0 Num:1
WRITE_BYTES      EQU 0x02  ; Address:3 Dummy:0 Num:1 to 256
ERASE_ALL        EQU 0xc7  ; Address:0 Dummy:0 Num:0
ERASE_BLOCK      EQU 0xd8  ; Address:3 Dummy:0 Num:0
READ_DEVICE_ID   EQU 0x9f  ; Address:0 Dummy:2 Num:1 to infinite

; Variables used in the program:
dseg at 30H
	w:   ds 3 ; 24-bit play counter.  Decremented in Timer 2 ISR.
    x:      ds 4        ;4 bytes for x and y
    y:      ds 4 
    bcd:    ds 5        ;5 bytes for bcd number         
    
bseg
    mf:     dbit 1 

; Interrupt vectors:
cseg

LCD_RS equ P2.0
LCD_RW equ P1.7
LCD_E  equ P1.6
LCD_D4 equ P1.1
LCD_D5 equ P1.0
LCD_D6 equ P0.7
LCD_D7 equ P0.6


org 0x0000 ; Reset vector
    ljmp MainProgram

org 0x0003 ; External interrupt 0 vector (not used in this code)
	reti

org 0x000B ; Timer/Counter 0 overflow interrupt vector (not used in this code)
	ljmp Timer0_ISR
    ;reti

org 0x0013 ; External interrupt 1 vector (not used in this code)
	reti

org 0x001B ; Timer/Counter 1 overflow interrupt vector (not used in this code
	reti

org 0x0023 ; Serial port receive/transmit interrupt vector (not used in this code)
	reti

org 0x005b ; Timer 2 interrupt vector.  Used in this code to replay the wave file.
	ljmp Timer2_ISR

$NOLIST
$include(LCD_4bit72Hz.inc) ; A library of LCD related functions and utility macros
$LIST

;include math32 library
$NOLIST 
$include(math32.inc)
$LIST

Msg1:  db 'Water Level (%):', 0 

; This 'wait' must be as precise as possible. Sadly the 24.5MHz clock in the EFM8LB1 has an accuracy of just 2%.
Wait_one_second:	
    ;For a 24.5MHz clock one machine cycle takes 1/24.5MHz=40.81633ns
    mov R2, #198 ; Calibrate using this number to account for overhead delays
X3: mov R1, #245
X2: mov R0, #167
X1: djnz R0, X1 ; 3 machine cycles ->3*13.89ns*167=20.44898us (see table 10.2 in reference manual)
    djnz R1, X2 ; 20.44898us*245=5.01ms
    djnz R2, X3 ; 5.01ms*198=0.991s + overhead
    ret

; This 'wait' must be as precise as possible. Sadly the 24.5MHz clock in the EFM8LB1 has an accuracy of just 2%.
Wait_one_second2:	
    ;For a 72MHz clock one machine cycle takes 1/72MHz=13.89ns
    mov R2, #30 ; Calibrate using this number to account for overhead delays
X3_1: mov R1, #30
X2_1: mov R0, #30
X1_1: 
	lcall                                                                                                                                                                Wait40uSec
	djnz R0, X1_1 ; 3 machine cycles -> 3*40.81633ns*501=20.875us  (see table 10.2 in reference manual)
    djnz R1, X2_1 ; 20.875us*240=5.01ms 
    djnz R2, X3_1 ; 5.01ms*198=0.991s + overhead
    ret

;This part removes leading zeros
Left_blank mac
	mov a, %0
	anl a, #0xf0
	swap a
	jz Left_blank_%M_a
	ljmp %1
Left_blank_%M_a:
	Display_char(#' ')
	mov a, %0
	anl a, #0x0f
	jz Left_blank_%M_b
	ljmp %1
Left_blank_%M_b:
	Display_char(#' ')
endmac

; Sends 10-digit BCD number in bcd to the LCD
Display_10_digit_BCD:
	Set_Cursor(2, 7)
	Display_BCD(bcd+4)
	Display_BCD(bcd+3)
	Display_BCD(bcd+2)
	Display_BCD(bcd+1)
	Display_BCD(bcd+0)
	; Replace all the zeros to the left with blanks
	Set_Cursor(2, 7)
	Left_blank(bcd+4, skip_blank)
	Left_blank(bcd+3, skip_blank)
	Left_blank(bcd+2, skip_blank)
	Left_blank(bcd+1, skip_blank)
	mov a, bcd+0
	anl a, #0f0h
	swap a
	jnz skip_blank
	Display_char(#' ')
skip_blank:
	ret

 ; We can display a number any way we want.  In this case with
; four decimal places.
Display_formated_BCD:
	Set_Cursor(2, 7)
	Display_char(#' ')
	Display_BCD(bcd+3)
	Display_BCD(bcd+2)
	Display_char(#'.')
	Display_BCD(bcd+1)
	Display_BCD(bcd+0)
	ret



;-----------------------------------;
; Routine to initialize the timer 0 ;
;-----------------------------------;
Timer0_Init:
	orl CKCON0, #00000100B ; Timer 0 uses the system clock
	mov a, TMOD
	anl a, #0xf0 ; Clear the bits for timer 0
	orl a, #0x01 ; Configure timer 0 as 16-timer
	mov TMOD, a
	mov TH0, #high(TIMER0_RELOAD)
	mov TL0, #low(TIMER0_RELOAD)
	; Enable the timer and interrupts
    setb ET0  ; Enable timer 0 interrupt
    setb TR0  ; Start timer 0
	ret

;---------------------------------;
; ISR for timer 0.                ;
;---------------------------------;
Timer0_ISR:
	;clr TF0  ; According to the data sheet this is done for us already.
	; Timer 0 can not autoreload so we need to reload it in the ISR:
	clr TR0
	mov TH0, #high(TIMER0_RELOAD)
	mov TL0, #low(TIMER0_RELOAD)
	setb TR0
	cpl SOUND_OUT ; Toggle the pin connected to the speaker
	reti


;-------------------------------------;
; ISR for Timer 2.  Used to playback  ;
; the WAV file stored in the SPI      ;
; flash memory.                       ;
;-------------------------------------;
Timer2_ISR:
	mov	SFRPAGE, #0x00
	clr	TF2H ; Clear Timer2 interrupt flag

	; The registers used in the ISR must be saved in the stack
	push acc
	push psw
	
	; Check if the play counter is zero.  If so, stop playing sound.
	mov a, w+0
	orl a, w+1
	orl a, w+2
	jz stop_playing
	
	; Decrement play counter 'w'.  In this implementation 'w' is a 24-bit counter.
	mov a, #0xff
	dec w+0
	cjne a, w+0, keep_playing
	dec w+1
	cjne a, w+1, keep_playing
	dec w+2
	
keep_playing:

	setb SPEAKER
	lcall Send_SPI ; Read the next byte from the SPI Flash...
	
	; It gets a bit complicated here because we read 8 bits from the flash but we need to write 12 bits to DAC:
	mov SFRPAGE, #0x30 ; DAC registers are in page 0x30
	push acc ; Save the value we got from flash
	swap a
	anl a, #0xf0
	mov DAC0L, a
	pop acc
	swap a
	anl a, #0x0f
	mov DAC0H, a
	mov SFRPAGE, #0x00
	
	sjmp Timer2_ISR_Done

stop_playing:
	clr TR2 ; Stop timer 2
	setb FLASH_CE  ; Disable SPI Flash
	clr SPEAKER ; Turn off speaker.  Removes hissing noise when not playing sound.

Timer2_ISR_Done:	
	pop psw
	pop acc
	reti

;---------------------------------;
; Sends a byte via serial port    ;
;---------------------------------;
putchar:
	jbc	TI,putchar_L1
	sjmp putchar
putchar_L1:
	mov	SBUF,a
	ret

;---------------------------------;
; Receive a byte from serial port ;
;---------------------------------;
getchar:
	jbc	RI,getchar_L1
	sjmp getchar
getchar_L1:
	mov	a,SBUF
	ret

;---------------------------------;
; Sends AND receives a byte via   ;
; SPI.                            ;
;---------------------------------;
Send_SPI:
	mov	SPI0DAT, a
Send_SPI_L1:
	jnb	SPIF, Send_SPI_L1 ; Wait for SPI transfer complete
	clr SPIF ; Clear SPI complete flag 
	mov	a, SPI0DAT
	ret

;---------------------------------;
; SPI flash 'write enable'        ;
; instruction.                    ;
;---------------------------------;
Enable_Write:
	clr FLASH_CE
	mov a, #WRITE_ENABLE
	lcall Send_SPI
	setb FLASH_CE
	ret

;---------------------------------;
; This function checks the 'write ;
; in progress' bit of the SPI     ;
; flash memory.                   ;
;---------------------------------;
Check_WIP:
	clr FLASH_CE
	mov a, #READ_STATUS
	lcall Send_SPI
	mov a, #0x55
	lcall Send_SPI
	setb FLASH_CE
	jb acc.0, Check_WIP ;  Check the Write in Progress bit
	ret
	
Init_all:
	; Disable WDT:
	mov	WDTCN, #0xDE
	mov	WDTCN, #0xAD
	
	mov	VDM0CN, #0x80
	mov	RSTSRC, #0x06
	
	; Switch SYSCLK to 72 MHz.  First switch to 24MHz:
	mov	SFRPAGE, #0x10
	mov	PFE0CN, #0x20
	mov	SFRPAGE, #0x00
	mov	CLKSEL, #0x00
	mov	CLKSEL, #0x00 ; Second write to CLKSEL is required according to datasheet
	
	; Wait for clock to settle at 24 MHz by checking the most significant bit of CLKSEL:
Init_L1:
	mov	a, CLKSEL
	jnb	acc.7, Init_L1
	
	; Now switch to 72MHz:
	mov	CLKSEL, #0x03
	mov	CLKSEL, #0x03  ; Second write to CLKSEL is required according to datasheet
	
	; Wait for clock to settle at 72 MHz by checking the most significant bit of CLKSEL:
Init_L2:
	mov	a, CLKSEL
	jnb	acc.7, Init_L2

	mov	SFRPAGE, #0x00
	
	; Configure P3.0 as analog output.  P3.0 pin is the output of DAC0.
	anl	P3MDIN, #0xFE
	orl	P3, #0x01
	
	; Configure the pins used for SPI (P0.0 to P0.3)
	mov	P0MDOUT, #0x1D ; SCK, MOSI, P0.3, TX0 are push-pull, all others open-drain

	mov	XBR0, #0x03 ; Enable SPI and UART0: SPI0E=1, URT0E=1
	mov	XBR1, #0x00
	mov	XBR2, #0x40 ; Enable crossbar and weak pull-ups

	; Enable serial communication and set up baud rate using timer 1
	mov	SCON0, #0x10	
	mov	TH1, #(0x100-((SYSCLK/BAUDRATE)/(12*2)))
	mov	TL1, TH1
	anl	TMOD, #0x0F ; Clear the bits of timer 1 in TMOD
	orl	TMOD, #0x20 ; Set timer 1 in 8-bit auto-reload mode.  Don't change the bits of timer 0
	setb TR1 ; START Timer 1
	setb TI ; Indicate TX0 ready
	
	; Configure DAC 0
	mov	SFRPAGE, #0x30 ; To access DAC 0 we use register page 0x30
	mov	DACGCF0, #0b_1000_1000 ; 1:D23REFSL(VCC) 1:D3AMEN(NORMAL) 2:D3SRC(DAC3H:DAC3L) 1:D01REFSL(VCC) 1:D1AMEN(NORMAL) 1:D1SRC(DAC1H:DAC1L)
	mov	DACGCF1, #0b_0000_0000
	mov	DACGCF2, #0b_0010_0010 ; Reference buffer gain 1/3 for all channels
	mov	DAC0CF0, #0b_1000_0000 ; Enable DAC 0
	mov	DAC0CF1, #0b_0000_0010 ; DAC gain is 3.  Therefore the overall gain is 1.
	; Initial value of DAC 0 is mid scale:
	mov	DAC0L, #0x00
	mov	DAC0H, #0x08
	mov	SFRPAGE, #0x00
	
	; Configure SPI
	mov	SPI0CKR, #((SYSCLK/(2*F_SCK_MAX))-1)
	mov	SPI0CFG, #0b_0100_0000 ; SPI in master mode
	mov	SPI0CN0, #0b_0000_0001 ; SPI enabled and in three wire mode
	setb FLASH_CE ; CS=1 for SPI flash memory
	clr SPEAKER ; Turn off speaker.
	
	; Configure Timer 2 and its interrupt
	mov	TMR2CN0,#0x00 ; Stop Timer2; Clear TF2
	orl	CKCON0,#0b_0001_0000 ; Timer 2 uses the system clock
	; Initialize reload value:
	mov	TMR2RLL, #low(TIMER2_RELOAD)
	mov	TMR2RLH, #high(TIMER2_RELOAD)
	; Set timer to reload immediately
	mov	TMR2H,#0xFF
	mov	TMR2L,#0xFF
	setb ET2 ; Enable Timer 2 interrupts
    ;setb TR2 ; Timer 2 is only enabled to play stored sound
	
	setb EA ; Enable interrupts
	
	ret 

;---------------------------------;
; Sends a string to serial port   ;
;---------------------------------;
puts:
	clr a
	movc a, @a+dptr
	jz puts_done
	lcall putchar
	inc dptr
	sjmp puts
puts_done:
	ret	

Hello: db 'Hello, world!\r\n', 0

;-----------------------------------
;Capacitance Calc
;------------------------------------
capacitance_calc:
    ; Configure LCD and display initial message
    lcall LCD_4BIT
	Set_Cursor(1, 1)
    Send_Constant_String(#Msg1)

    ; Measure the frequency applied to pin T0 (T0 is routed to pin P1.2 using the 'crossbar')
    clr TR0 ; Stop counter 0
    mov TL0, #0 ;reset timer 0 - reset counter to 0
    mov TH0, #0
    setb TR0 ; Start counter 0
    lcall Wait_one_second2
    clr TR0 ; Stop counter 0, TH0-TL0 has the frequency in Hz 

    ;Set_Cursor(2, 1) 

    ;----------------------------------------------------------------------------------------
    ;Added my capacitance calculation here
    ; C = (1.44) / (Ra+2Rb)*f
    ;Ra=1966,Rb=2947;f=currently in THO-TL0
    ;C= (1.44) / 8000*f
    ;C= (144) / (100*7860*f)
    ;measure in nF instead of F
    ;C= (144,000,000) / (786 * f )
    ;----------------------------------------------------------------------------------------
    ;mov freq to x
    mov x+0,TL0 
    mov x+1,TH0 
    mov x+2,#0
    mov x+3,#0
    ;mov 100 to y
    Load_y(100)
    ;x=x/y  x=freq/100
    lcall div32 
    ;mov 8 to y 
    Load_y(786) 
    ;x = x*y  x=(freq/100) * 8
    lcall mul32 
    ; mov result of denonimator,x to y
    mov a,x+0
    mov R0,a
    mov	y+0,R0
    mov a,x+1
    mov R1,a
    mov	y+1,r1
    mov a,x+2
    mov R2,a
    mov	y+2,R2
    mov a,x+3
    mov R3,a
    mov	y+3,R3
    ;x = 14400_0000 / (8*(freq))
    Load_x(144000000)
    lcall div32
    Load_y(100)
    lcall mul32

    ;----------------------------------------------------------------------------------------

	; Convert the result to BCD and display on LCD
    lcall hex2bcd2
    ;lcall Display_10_digit_BCD
    lcall Display_formated_BCD

	ret


;40%

ten_percent:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	;cjne x, #0x5, fifteen_percent
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x00
	lcall Send_SPI
	mov a, #0x00
	lcall Send_SPI
	mov a, #0x00
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0x4a
	mov w+0, #0x64

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret


twenty_percent:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	;cjne x, #0x5, twentyfive_percent
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x00
	lcall Send_SPI
	mov a, #0x4a
	lcall Send_SPI
	mov a, #0x91
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0x75
	mov w+0, #0x91

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret

thirty_percent:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	;cjne x, #0x5, thirtyfive_percent
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x00
	lcall Send_SPI
	mov a, #0xc0
	lcall Send_SPI
	mov a, #0x22
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0x6f
	mov w+0, #0x78

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret

forty_percent:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	;cjne x, #0x5, fortyfive_percent
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x01
	lcall Send_SPI
	mov a, #0x2f
	lcall Send_SPI
	mov a, #0x9a
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0x72
	mov w+0, #0x3b

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret

fifty_percent:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	;cjne x, #0x5, fiftyfive_percent
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x01
	lcall Send_SPI
	mov a, #0xa1
	lcall Send_SPI
	mov a, #0xd5
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0x42
	mov w+0, #0x7e

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret

sixty_percent:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	;cjne x, #0x5, sixtyfive_percent
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x01
	lcall Send_SPI
	mov a, #0xe4
	lcall Send_SPI
	mov a, #0x53
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0x7a
	mov w+0, #0xff

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret

seventy_percent:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	;cjne x, #0x5, seventyfive_percent
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x02
	lcall Send_SPI
	mov a, #0x5f
	lcall Send_SPI
	mov a, #0xf9
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0xac
	mov w+0, #0xff

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret

eighty_percent:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	;cjne x, #0x5, eightyfive_percent
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x03
	lcall Send_SPI
	mov a, #0x0d
	lcall Send_SPI
	mov a, #0xb2
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0x6c
	mov w+0, #0xa8

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret

ninety_percent:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	;cjne x, #0x5, ninetyfive_percent
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x03
	lcall Send_SPI
	mov a, #0x7a
	lcall Send_SPI
	mov a, #0x5a
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0xd6
	mov w+0, #0x89

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret

	

hundred_percent:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x04
	lcall Send_SPI
	mov a, #0x50
	lcall Send_SPI
	mov a, #0xe3
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0x5f
	mov w+0, #0xff

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret

cupisfull:
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	clr SPEAKER ; Turn off speaker.

	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory where to start playing
	mov a, #0x04
	lcall Send_SPI
	mov a, #0xb0
	lcall Send_SPI
	mov a, #0xeb
	lcall Send_SPI
	
	; How many bytes to play?
	mov w+2, #0x00
	mov w+1, #0x78
	mov w+0, #0x5b

	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb SPEAKER ; Turn on speaker.
	setb TR2 ; Start playback by enabling Timer 2

	ret


;---------------------------------;
; Main program. Includes hardware ;
; initialization and 'forever'    ;
; loop.                           ;
;---------------------------------;
MainProgram:
    mov SP, #0x7f ; Setup stack pointer to the start of indirectly accessable data memory minus one
    lcall Init_all ; Initialize the hardware

     ; DISABLE WDT: provide Watchdog disable keys
	mov	WDTCN,#0xDE ; First key
	mov	WDTCN,#0xAD ; Second key

    orl P0SKIP, #0b_1100_1000 ; P0.7 and P0.6 used by LCD.  P0.3 used as CS/ for SPI memory.
	orl P1SKIP, #0b_0000_0011 ; P1.1 and P1.2 used by LCD

    ; Enable crossbar and weak pull-ups
	mov	XBR0,#0x03 ; Enable SPI0 and UART0
	mov	XBR1,#0x10 ; Enable T0 on P1.2.  T0 is the external clock input to Timer/Counter 0
	mov	XBR2,#0x40

    ; Enable serial communication and set up baud rate using timer 1
	mov	SCON0, #0x10	
	mov	TH1, #(0x100-((SYSCLK/BAUDRATE)/(12*2)))
	mov	TL1, TH1
	anl	TMOD, #0x0F ; Clear the bits of timer 1 in TMOD
	orl	TMOD, #0x20 ; Set timer 1 in 8-bit auto-reload mode.  Don't change the bits of timer 0
	setb TR1 ; START Timer 1
	setb TI ; Indicate TX0 ready

    ;-----
	
	;Initializes timer/counter 0 as a 16-bit counter
    clr TR0 ; Stop timer 0
    mov a, TMOD
    anl a, #0b_1111_0000 ; Clear the bits of timer/counter 0
    orl a, #0b_0000_0101 ; Sets the bits of timer/counter 0 for a 16-bit counter
    mov TMOD, a

	; Configure SPI
	mov	SPI0CKR, #((SYSCLK/(2*F_SCK_MAX))-1)
	mov	SPI0CFG, #0b_0100_0000 ; SPI in master mode
	mov	SPI0CN0, #0b_0000_0001 ; SPI enabled and in three wire mode

	; Send string to serial port
	mov dptr, #Hello
	lcall puts

forever_loop:


	lcall capacitance_calc

	
ten:
		Load_y(51300)
		lcall x_lteq_y
		jnb mf, twenty
		setb TR2
		lcall ten_percent
		ljmp done

	twenty:
		Load_y(51350)
		lcall x_lteq_y
		jnb mf, thirty
		setb TR2
		lcall twenty_percent
		ljmp done
	
	thirty:
		Load_y(51400)
		lcall x_lteq_y
		jnb mf, forty
		setb TR2
		lcall thirty_percent
		ljmp done

	forty:
		Load_y(51450)
		lcall x_lteq_y
		jnb mf, fifty
		setb TR2
		lcall forty_percent
		ljmp done

	fifty:
		Load_y(51500)
		lcall x_lteq_y
		jnb mf, sixty
		setb TR2
		lcall fifty_percent
		ljmp done

	sixty:
		Load_y(51550)
		lcall x_lteq_y
		jnb mf, seventy
		setb TR2
		lcall sixty_percent
		ljmp done

	seventy:
		Load_y(51600)
		lcall x_lteq_y
		jnb mf, eighty
		setb TR2
		lcall seventy_percent
		ljmp done

	eighty:
		Load_y(51650)
		lcall x_lteq_y
		jnb mf, ninety
		setb TR2
		lcall eighty_percent
		ljmp done

	ninety:
		Load_y(51700)
		lcall x_lteq_y
		jnb mf, hundred
		setb TR2
		lcall ninety_percent
		ljmp done

	hundred:
		Load_y(51750)
		lcall x_lteq_y
		jnb mf, full
		setb TR2
		lcall hundred_percent
		ljmp done

	full:
		Load_y(51800)
		lcall x_lteq_y
		jnb mf, forever_loop2
		setb TR2
		lcall cupisfull
		ljmp done
	

	done: 
		ljmp forever_loop

forever_loop2:
	ljmp forever_loop
	
serial_get:
	lcall getchar ; Wait for data to arrive
	cjne a, #'#', forever_loop2 ; Message format is #n[data] where 'n' is '0' to '9'
	clr TR2 ; Stop Timer 2 from playing previous request
	setb FLASH_CE ; Disable SPI Flash	
	clr SPEAKER ; Turn off speaker.
	lcall getchar

;---------------------------------------------------------	
	cjne a, #'0' , Command_0_skip
Command_0_start: ; Identify command
	clr FLASH_CE ; Enable SPI Flash	
	mov a, #READ_DEVICE_ID
	lcall Send_SPI	
	mov a, #0x55
	lcall Send_SPI
	lcall putchar
	mov a, #0x55
	lcall Send_SPI
	lcall putchar
	mov a, #0x55
	lcall Send_SPI
	lcall putchar
	setb FLASH_CE ; Disable SPI Flash
	ljmp forever_loop	
Command_0_skip:

;---------------------------------------------------------	
	cjne a, #'1' , Command_1_skip 
Command_1_start: ; Erase whole flash (takes a long time)
	lcall Enable_Write
	clr FLASH_CE
	mov a, #ERASE_ALL
	lcall Send_SPI
	setb FLASH_CE
	lcall Check_WIP
	mov a, #0x01 ; Send 'I am done' reply
	lcall putchar		
	ljmp forever_loop	
Command_1_skip:

;---------------------------------------------------------	
	cjne a, #'2' , Command_2_skip 
Command_2_start: ; Load flash page (256 bytes or less)
	lcall Enable_Write
	clr FLASH_CE
	mov a, #WRITE_BYTES
	lcall Send_SPI
	lcall getchar ; Address bits 16 to 23
	lcall Send_SPI
	lcall getchar ; Address bits 8 to 15
	lcall Send_SPI
	lcall getchar ; Address bits 0 to 7
	lcall Send_SPI
	lcall getchar ; Number of bytes to write (0 means 256 bytes)
	mov r0, a
Command_2_loop:
	lcall getchar
	lcall Send_SPI
	djnz r0, Command_2_loop
	setb FLASH_CE
	lcall Check_WIP
	mov a, #0x01 ; Send 'I am done' reply
	lcall putchar		
	ljmp forever_loop	
Command_2_skip:

;---------------------------------------------------------	
	cjne a, #'3' , Command_3_skip 
Command_3_start: ; Read flash bytes (256 bytes or less)
	clr FLASH_CE
	mov a, #READ_BYTES
	lcall Send_SPI
	lcall getchar ; Address bits 16 to 23
	lcall Send_SPI
	lcall getchar ; Address bits 8 to 15
	lcall Send_SPI
	lcall getchar ; Address bits 0 to 7
	lcall Send_SPI
	lcall getchar ; Number of bytes to read and send back (0 means 256 bytes)
	mov r0, a

Command_3_loop:
	mov a, #0x55
	lcall Send_SPI
	lcall putchar
	djnz r0, Command_3_loop
	setb FLASH_CE	
	ljmp forever_loop	
Command_3_skip:

;---------------------------------------------------------	
	cjne a, #'4' , Command_4_skip 
Command_4_start: ; Playback a portion of the stored wav file
	clr TR2 ; Stop Timer 2 ISR from playing previous request
	setb FLASH_CE
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Get the initial position in memory where to start playing
	lcall getchar
	lcall Send_SPI
	lcall getchar
	lcall Send_SPI
	lcall getchar
	lcall Send_SPI
	; Get how many bytes to play
	lcall getchar
	mov w+2, a
	lcall getchar
	mov w+1, a
	lcall getchar
	mov w+0, a
	
	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb TR2 ; Start playback by enabling timer 2
	ljmp forever_loop	
Command_4_skip:

;---------------------------------------------------------	
	cjne a, #'5' , Command_5_skip 
Command_5_start: ; Calculate and send CRC-16 of ISP flash memory from zero to the 24-bit passed value.
	; Get how many bytes to use to calculate the CRC.  Store in [r5,r4,r3]
	lcall getchar
	mov r5, a
	lcall getchar
	mov r4, a
	lcall getchar
	mov r3, a
	
	; Since we are using the 'djnz' instruction to check, we need to add one to each byte of the counter.
	; A side effect is that the down counter becomes efectively a 23-bit counter, but that is ok
	; because the max size of the 25Q32 SPI flash memory is 400000H.
	inc r3
	inc r4
	inc r5
	
	; Initial CRC must be zero.
	mov	SFRPAGE, #0x20 ; UART0, CRC, and SPI can work on this page
	mov	CRC0CN0, #0b_0000_1000 ; // Initialize hardware CRC result to zero;

	clr FLASH_CE
	mov a, #READ_BYTES
	lcall Send_SPI
	clr a ; Address bits 16 to 23
	lcall Send_SPI
	clr a ; Address bits 8 to 15
	lcall Send_SPI
	clr a ; Address bits 0 to 7
	lcall Send_SPI
	mov	SPI0DAT, a ; Request first byte from SPI flash
	sjmp Command_5_loop_start

Command_5_loop:
	jnb SPIF, Command_5_loop 	; Check SPI Transfer Completion Flag
	clr SPIF				    ; Clear SPI Transfer Completion Flag	
	mov a, SPI0DAT				; Save received SPI byte to accumulator
	mov SPI0DAT, a				; Request next byte from SPI flash; while it arrives we calculate the CRC:
	mov	CRC0IN, a               ; Feed new byte to hardware CRC calculator

Command_5_loop_start:
	; Drecrement counter:
	djnz r3, Command_5_loop
	djnz r4, Command_5_loop
	djnz r5, Command_5_loop
Command_5_loop2:	
	jnb SPIF, Command_5_loop2 	; Check SPI Transfer Completion Flag
	clr SPIF			    	; Clear SPI Transfer Completion Flag
	mov a, SPI0DAT	            ; This dummy read is needed otherwise next transfer fails (why?)
	setb FLASH_CE 				; Done reading from SPI flash
	
	; Computation of CRC is complete.  Send 16-bit result using the serial port
	mov	CRC0CN0, #0x01 ; Set bit to read hardware CRC high byte
	mov	a, CRC0DAT
	lcall putchar

	mov	CRC0CN0, #0x00 ; Clear bit to read hardware CRC low byte
	mov	a, CRC0DAT
	lcall putchar
	
	mov	SFRPAGE, #0x00

	ljmp forever_loop	
Command_5_skip:

;---------------------------------------------------------	
	cjne a, #'6' , Command_6_skip 
Command_6_start: ; Fill flash page (256 bytes)
	lcall Enable_Write
	clr FLASH_CE
	mov a, #WRITE_BYTES
	lcall Send_SPI
	lcall getchar ; Address bits 16 to 23
	lcall Send_SPI
	lcall getchar ; Address bits 8 to 15
	lcall Send_SPI
	lcall getchar ; Address bits 0 to 7
	lcall Send_SPI
	lcall getchar ; Byte to write
	mov r1, a
	mov r0, #0 ; 256 bytes
Command_6_loop:
	mov a, r1
	lcall Send_SPI
	djnz r0, Command_6_loop
	setb FLASH_CE
	lcall Check_WIP
	mov a, #0x01 ; Send 'I am done' reply
	lcall putchar		
	ljmp forever_loop	
Command_6_skip:

	ljmp forever_loop

END
