program SeagateXBigFrontPanel;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, ctypes, gpiod_min;

{
  seagate-xbig-frontpanel
  ----------------------

  This program is deliberately a small hardware service.  It owns the front
  panel GPIO lines for its entire lifetime and accepts simple text commands on
  stdin (LINE, BACKLIGHT, MODE, ...).  Replies and button events are written to
  stdout.  The shell menu is a separate policy/UI layer.

  There are three important layers:

      shell menu / other client
              |  line-oriented text protocol
              v
      this FreePascal program
              |  libgpiod 2.x
              v
      Linux gpio-f7188x driver -> Fintek F71889ED GPIO pins

  This file contains the board-specific logic only.  The small gpiod_min unit
  contains the dynamic libgpiod declarations.

  HOW ONE LCD BYTE REACHES THE SCREEN
  ------------------------------------
  The LCD is an HD44780-compatible 16x2 module wired in 8-bit parallel mode.
  For every command or character this program does the following:

      1. choose command/data with RS (GPIO70)
      2. keep R/W low (GPIO71), because this implementation is write-only
      3. put all 8 data bits on GPIO40..GPIO47 at once
      4. pulse E (GPIO72) high then low so the LCD latches that byte
      5. wait 1 ms, matching Seagate's original implementation

  For example, displaying ASCII 'A' sends $41 = 0100 0001b with RS=1.
  Initializing the controller sends command bytes such as $38 with RS=0.

  BUTTONS
  -------
  GPIO74 and GPIO75 are inputs and are electrically active-low: 0 means the
  switch is pressed.  The Pascal layer converts that electrical state into
  logical UP/DOWN/BOTH events, performs debounce, and reports PRESS, RELEASE
  and INTERRUPT.  Long-press meaning remains entirely in the shell/UI.
}

const
  PROGRAM_VERSION = '1.0';

{ Recovered MSS0731 front-panel map, accessed only through Linux gpio-f7188x:
    GPIO40..47 -> LCD D0..D7 (8-bit parallel)
    GPIO70     -> RS
    GPIO71     -> R/W (always 0 here)
    GPIO72     -> E
    GPIO73     -> backlight A
    GPIO74     -> UP button, input, active-low
    GPIO75     -> DOWN button, input, active-low
    GPIO76     -> backlight B

  GPIO70..73 and GPIO76 are open-drain outputs.  This program never performs
  raw Super-I/O port I/O and never touches the unrelated/mystery 0x600 range.

  libgpiod 2.x declarations and dynamic loading live in the small gpiod_min
  unit so this file contains only MSS0731/front-panel logic. }

  { gpio-f7188x exposes each Fintek GPIO bank as a separate gpiochip.
    We find the chips by these kernel labels instead of assuming gpiochipN
    numbers, which can vary with boot order and kernel configuration. }
  GPIO4_LABEL = 'gpio-f7188x-4';
  GPIO7_LABEL = 'gpio-f7188x-7';

  { Offsets inside Fintek GPIO bank 7. }
  LCD_RS    = 0;
  LCD_RW    = 1;
  LCD_E     = 2;
  LCD_BL_A  = 3;
  BUTTON_UP = 4;
  BUTTON_DOWN = 5;
  LCD_BL_B  = 6;

  { Public backlight levels recovered from Seagate's Windows implementation.

      level 1 -> GPIO73=0, GPIO76=0 -> off
      level 2 -> GPIO73=0, GPIO76=1 -> dim/light
      level 3 -> GPIO73=1, GPIO76=1 -> bright/strong

    The unused 1,0 combination is intentionally never generated. }
  BACKLIGHT_OFF    = 1;
  BACKLIGHT_DIM    = 2;
  BACKLIGHT_BRIGHT = 3;

  { HD44780 command bytes used by Seagate's original Windows routine.

    The display controller treats a byte differently when RS=0: the byte is a
    command rather than a printable character.  These are the five command
    bytes sent by LCDInit, written as named constants so there are no unexplained
    magic numbers in the initialization code.

      $38 = 0011 1000b  Function Set
            --------
            DL=1 : use the full 8-bit D0..D7 data bus
            N =1 : use the controller's two-line display mode
            F =0 : use the normal 5x8-dot character font

      $0C = 0000 1100b  Display Control
            D=1 : display pixels enabled
            C=0 : cursor hidden
            B=0 : cursor blink disabled

      $01 = 0000 0001b  Clear Display
            clears DDRAM and returns the cursor to address 0

      $06 = 0000 0110b  Entry Mode Set
            I/D=1 : cursor address increments after each character
            S  =0 : do not shift the whole display after a write

    The first $38 is intentionally repeated by the vendor, so the actual
    sequence is $38,$38,$0C,$01,$06.  We preserve that known-good sequence. }
  LCD_CMD_FUNCTION_SET_8BIT_2LINE = $38;
  LCD_CMD_DISPLAY_ON_CURSOR_OFF   = $0C;
  LCD_CMD_CLEAR_DISPLAY           = $01;
  LCD_CMD_ENTRY_MODE_INCREMENT    = $06;

  { HD44780 visible rows start at DDRAM addresses $00 and $40.  The command
    'Set DDRAM Address' is bit 7 ORed with that address, therefore:

      row 0: $80 OR $00 = $80
      row 1: $80 OR $40 = $C0

    LCDWriteLine sends one of these before sending the 16 character bytes. }
  LCD_LINE0_DDRAM_ADDR = $80;
  LCD_LINE1_DDRAM_ADDR = $C0;

  { Timing policy.

    Seagate waits 1 ms after every LCD byte.  We reproduce that fixed delay
    instead of switching D0..D7 to inputs and reading the HD44780 busy flag.

    Button sampling is slower while the UI is idle and faster while it is
    active.  ACTIVE requires two matching samples, so 10 ms polling gives a
    roughly 10-20 ms press qualification window depending on when the physical
    transition occurs relative to the sampling ticks. }
  LCD_BYTE_DELAY_US = 1000;
  IDLE_POLL_MS      = 150;
  ACTIVE_POLL_MS    = 10;
  ACTIVE_DEBOUNCE_POLLS = 2;

  { Internal button-state bitmask returned by ReadRawButtons. }
  BUTTON_STATE_NONE = 0;
  BUTTON_STATE_UP   = 1;
  BUTTON_STATE_DOWN = 2;
  BUTTON_STATE_BOTH = 3;

  { poll(2) event flags used by EventLoop. }
  POLLIN  = $0001;
  POLLHUP = $0010;
  POLLERR = $0008;
  POLLNVAL = $0020;

type
  { Pascal equivalent of the small part of C struct pollfd that we need. }
  TPollFD = packed record
    fd: cint;
    events: cshort;
    revents: cshort;
  end;
  PPollFD = ^TPollFD;

var
  { Persistent libgpiod requests.  Keeping them open means this process owns
    the front-panel GPIO lines continuously; no subprocess is spawned for each
    LCD byte or button sample. }
  Req4: TGpiodLineRequest = nil;
  Req7: TGpiodLineRequest = nil;
  LCDInitialized: Boolean = False;
  Running: Boolean = True;
  ActiveMode: Boolean = False;

  { Button debounce state.

    StableButtonState    = the logical press already reported to the client
    CandidateButtonState = raw state currently being qualified by debounce
    CandidateButtonCount = number of consecutive samples of that candidate
    InterruptSent        = prevents duplicate INTERRUPT events for one gesture

    Long-press timing is NOT done here.  This layer only reports physical
    PRESS / RELEASE / INTERRUPT events; the shell menu assigns their meaning. }
  StableButtonState: Integer = BUTTON_STATE_NONE;
  CandidateButtonState: Integer = BUTTON_STATE_NONE;
  CandidateButtonCount: Integer = 0;
  InterruptSent: Boolean = False;
  NextPollAt: QWord = 0;

{ libc calls used directly because we need only two tiny facilities:
  poll() lets one loop wait for either stdin activity or the next button-poll
  deadline, while usleep() reproduces Seagate's 1 ms LCD-byte delay. }
function c_poll(fds: PPollFD; nfds: culong; timeout: cint): cint; cdecl; external 'c' name 'poll';
function c_usleep(usec: cuint): cint; cdecl; external 'c' name 'usleep';

{ Protocol output.  Flush immediately because the shell menu is waiting on a
  pipe and button events should be visible without stdio buffering delay. }
procedure Emit(const S: string);
begin
  WriteLn(Output, S);
  Flush(Output);
end;

{ Diagnostic output is kept on stderr so stdout remains a clean protocol
  stream that another program can parse. }
procedure Log(const S: string);
begin
  WriteLn(StdErr, S);
  Flush(StdErr);
end;

{ Protocol records are one line each.  Replace embedded CR/LF in exception
  messages so an error can never accidentally create extra protocol records. }
function CleanMessage(const S: string): string;
begin
  Result := StringReplace(StringReplace(S, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]);
end;

{ Locate a gpiochip by its kernel label.  The numeric /dev/gpiochipN name is
  intentionally treated as dynamic.  Each candidate is opened only long enough
  to read its label, then closed again. }
function FindChipPathByLabel(const WantedLabel: string): string;
var
  I: Integer;
  Path: string;
  Chip: TGpiodChip;
  Info: TGpiodChipInfo;
  LabelPtr: PChar;
begin
  Result := '';
  for I := 0 to 63 do
  begin
    Path := '/dev/gpiochip' + IntToStr(I);
    Chip := gpiod_chip_open(PChar(Path));
    if Chip = nil then
      Continue;
    try
      Info := gpiod_chip_get_info(Chip);
      if Info = nil then
        Continue;
      try
        LabelPtr := gpiod_chip_info_get_label(Info);
        if (LabelPtr <> nil) and (string(LabelPtr) = WantedLabel) then
        begin
          Result := Path;
          Exit;
        end;
      finally
        gpiod_chip_info_free(Info);
      end;
    finally
      gpiod_chip_close(Chip);
    end;
  end;
end;

{ libgpiod setter/configuration calls return 0 on success and -1 on error.
  Convert that C convention into Pascal exceptions at one central point. }
procedure CheckZero(Ret: cint; const What: string);
begin
  if Ret <> 0 then
    raise Exception.Create(What + ' failed');
end;

{ Build one reusable libgpiod line-settings object for outputs.

  OpenDrain=False is used for GPIO40..47, the LCD's 8-bit data bus.
  OpenDrain=True is required for the recovered GPIO70..73/76 wiring. }
function NewOutputSettings(OpenDrain: Boolean; InitialValue: cint): TGpiodLineSettings;
begin
  Result := gpiod_line_settings_new();
  if Result = nil then
    raise Exception.Create('cannot allocate GPIO output settings');
  try
    CheckZero(gpiod_line_settings_set_direction(Result, GPIOD_LINE_DIRECTION_OUTPUT),
      'set GPIO output direction');
    if OpenDrain then
      CheckZero(gpiod_line_settings_set_drive(Result, GPIOD_LINE_DRIVE_OPEN_DRAIN),
        'set GPIO open-drain drive');
    CheckZero(gpiod_line_settings_set_output_value(Result, InitialValue),
      'set GPIO initial output value');
  except
    gpiod_line_settings_free(Result);
    Result := nil;
    raise;
  end;
end;

{ GPIO74 and GPIO75 are button inputs, so their request uses input settings. }
function NewInputSettings: TGpiodLineSettings;
begin
  Result := gpiod_line_settings_new();
  if Result = nil then
    raise Exception.Create('cannot allocate GPIO input settings');
  try
    CheckZero(gpiod_line_settings_set_direction(Result, GPIOD_LINE_DIRECTION_INPUT),
      'set GPIO input direction');
  except
    gpiod_line_settings_free(Result);
    Result := nil;
    raise;
  end;
end;

{ Request all eight lines of Fintek GPIO bank 4 as one persistent output
  request.  Their offsets map directly to LCD D0..D7, so SetGPIO4Byte can write
  a complete LCD data byte in one libgpiod operation. }
function RequestGPIO4(const ChipPath: string): TGpiodLineRequest;
const
  Offsets: array[0..7] of cuint = (0,1,2,3,4,5,6,7);
var
  Chip: TGpiodChip;
  Settings: TGpiodLineSettings;
  LineCfg: TGpiodLineConfig;
  ReqCfg: TGpiodRequestConfig;
begin
  Result := nil;
  Chip := gpiod_chip_open(PChar(ChipPath));
  if Chip = nil then
    raise Exception.Create('cannot open ' + ChipPath);
  Settings := nil;
  LineCfg := nil;
  ReqCfg := nil;
  try
    Settings := NewOutputSettings(False, GPIOD_LINE_VALUE_INACTIVE);
    LineCfg := gpiod_line_config_new();
    if LineCfg = nil then
      raise Exception.Create('cannot allocate GPIO4 line config');
    CheckZero(gpiod_line_config_add_line_settings(LineCfg, @Offsets[0], Length(Offsets), Settings),
      'configure GPIO4');

    ReqCfg := gpiod_request_config_new();
    if ReqCfg = nil then
      raise Exception.Create('cannot allocate GPIO4 request config');
    gpiod_request_config_set_consumer(ReqCfg, PChar('seagate-xbig-frontpanel'));

    Result := gpiod_chip_request_lines(Chip, ReqCfg, LineCfg);
    if Result = nil then
      raise Exception.Create('cannot request GPIO4 lines 0..7');
  finally
    if ReqCfg <> nil then gpiod_request_config_free(ReqCfg);
    if LineCfg <> nil then gpiod_line_config_free(LineCfg);
    if Settings <> nil then gpiod_line_settings_free(Settings);
    gpiod_chip_close(Chip);
  end;
end;

{ Request the bank-7 front-panel lines as one persistent mixed request.

  Outputs (open-drain):
    GPIO70 RS, GPIO71 R/W, GPIO72 E, GPIO73 backlight A, GPIO76 backlight B

  Inputs:
    GPIO74 UP button, GPIO75 DOWN button

  Initial output values are chosen to be a quiet, safe state.  The arrays below
  are worth spelling out because they describe the electrical state established
  the instant the persistent GPIO7 request is created:

      ZeroOffsets = RS, R/W, E, backlight A -> initial logical 0
      OneOffsets  = backlight B             -> initial logical 1
      InputOffsets= UP, DOWN                -> inputs, never driven

  Therefore startup begins with RS=0, R/W=0, E=0 and A=0/B=1.  A=0/B=1 is
  Seagate backlight level 2 (Light/dim), our normal idle level. }
function RequestGPIO7(const ChipPath: string): TGpiodLineRequest;
const
  ZeroOffsets: array[0..3] of cuint = (LCD_RS, LCD_RW, LCD_E, LCD_BL_A);
  OneOffsets: array[0..0] of cuint = (LCD_BL_B);
  InputOffsets: array[0..1] of cuint = (BUTTON_UP, BUTTON_DOWN);
var
  Chip: TGpiodChip;
  ZeroOut, OneOut, InputSet: TGpiodLineSettings;
  LineCfg: TGpiodLineConfig;
  ReqCfg: TGpiodRequestConfig;
begin
  Result := nil;
  Chip := gpiod_chip_open(PChar(ChipPath));
  if Chip = nil then
    raise Exception.Create('cannot open ' + ChipPath);

  ZeroOut := nil;
  OneOut := nil;
  InputSet := nil;
  LineCfg := nil;
  ReqCfg := nil;
  try
    ZeroOut := NewOutputSettings(True, GPIOD_LINE_VALUE_INACTIVE);
    OneOut := NewOutputSettings(True, GPIOD_LINE_VALUE_ACTIVE);
    InputSet := NewInputSettings;

    LineCfg := gpiod_line_config_new();
    if LineCfg = nil then
      raise Exception.Create('cannot allocate GPIO7 line config');

    CheckZero(gpiod_line_config_add_line_settings(LineCfg, @ZeroOffsets[0], Length(ZeroOffsets), ZeroOut),
      'configure GPIO70..73');
    CheckZero(gpiod_line_config_add_line_settings(LineCfg, @OneOffsets[0], Length(OneOffsets), OneOut),
      'configure GPIO76');
    CheckZero(gpiod_line_config_add_line_settings(LineCfg, @InputOffsets[0], Length(InputOffsets), InputSet),
      'configure GPIO74/75');

    ReqCfg := gpiod_request_config_new();
    if ReqCfg = nil then
      raise Exception.Create('cannot allocate GPIO7 request config');
    gpiod_request_config_set_consumer(ReqCfg, PChar('seagate-xbig-frontpanel'));

    Result := gpiod_chip_request_lines(Chip, ReqCfg, LineCfg);
    if Result = nil then
      raise Exception.Create('cannot request GPIO7 front-panel lines');
  finally
    if ReqCfg <> nil then gpiod_request_config_free(ReqCfg);
    if LineCfg <> nil then gpiod_line_config_free(LineCfg);
    if InputSet <> nil then gpiod_line_settings_free(InputSet);
    if OneOut <> nil then gpiod_line_settings_free(OneOut);
    if ZeroOut <> nil then gpiod_line_settings_free(ZeroOut);
    gpiod_chip_close(Chip);
  end;
end;

{ Discover both gpiochips and take ownership of the lines.  If the second
  request fails, release the first so startup either succeeds completely or
  leaves no GPIO request behind. }
procedure InitHardware;
var
  Chip4Path, Chip7Path: string;
begin
  Chip4Path := FindChipPathByLabel(GPIO4_LABEL);
  Chip7Path := FindChipPathByLabel(GPIO7_LABEL);

  if Chip4Path = '' then
    raise Exception.Create('cannot find ' + GPIO4_LABEL + ' (load gpio-f7188x)');
  if Chip7Path = '' then
    raise Exception.Create('cannot find ' + GPIO7_LABEL + ' (load gpio-f7188x)');

  Req4 := RequestGPIO4(Chip4Path);
  try
    Req7 := RequestGPIO7(Chip7Path);
  except
    gpiod_line_request_release(Req4);
    Req4 := nil;
    raise;
  end;

  Log('frontpanel ' + PROGRAM_VERSION + ': GPIO4=' + Chip4Path + ' GPIO7=' + Chip7Path);
end;

{ Release both persistent line requests.  This is called from a finally block
  so normal QUIT and exceptional exits follow the same cleanup path. }
procedure ReleaseHardware;
begin
  if Req7 <> nil then
  begin
    gpiod_line_request_release(Req7);
    Req7 := nil;
  end;
  if Req4 <> nil then
  begin
    gpiod_line_request_release(Req4);
    Req4 := nil;
  end;
end;

{ Put one byte on the LCD D0..D7 bus.

  GPIO4 offset 0 is D0, offset 1 is D1, ... offset 7 is D7.  Therefore bit I
  of Value goes directly to libgpiod value I.  This only presents the byte on
  the wires; the LCD does not latch it until LCDWriteByte pulses E. }
procedure SetGPIO4Byte(Value: Byte);
var
  Values: array[0..7] of cint;
  I: Integer;
begin
  for I := 0 to 7 do
    if (Value and (1 shl I)) <> 0 then
      Values[I] := GPIOD_LINE_VALUE_ACTIVE
    else
      Values[I] := GPIOD_LINE_VALUE_INACTIVE;
  CheckZero(gpiod_line_request_set_values(Req4, @Values[0]), 'write GPIO4 data bus');
end;

{ Set the HD44780 control pins together:

      RS=0 -> Value is a command
      RS=1 -> Value is character data
      R/W=0 -> write to LCD
      E      -> enable/strobe

  R/W=1 is deliberately rejected.  GPIO40..47 remain outputs at all times, so
  asking the LCD to drive that same bus could electrically contend with the
  Fintek outputs. }
procedure SetLCDControl(RS, RW, Enable: cint);
const
  Offsets: array[0..2] of cuint = (LCD_RS, LCD_RW, LCD_E);
var
  Values: array[0..2] of cint;
begin
  if RW <> 0 then
    raise Exception.Create('LCD R/W=1 is disabled: data bus is write-only');
  Values[0] := RS;
  Values[1] := RW;
  Values[2] := Enable;
  CheckZero(gpiod_line_request_set_values_subset(Req7, 3, @Offsets[0], @Values[0]),
    'write LCD control GPIOs');
end;

{ Send one byte to the HD44780 exactly in the order recovered from Seagate.

  Nothing is clocked into the display merely by changing D0..D7.  The E pin is
  the strobe: the controller samples RS/RW and the eight data wires during the
  E pulse.  Keeping E low while changing the bus prevents an accidental write.

    1. set RS to 0 for a command or 1 for character data
       set R/W=0 because this implementation only writes
       keep E=0 while preparing the transaction
    2. present the entire byte on GPIO40..GPIO47 / LCD D0..D7
    3. drive E=1
    4. drive E=0; the high-to-low transition completes the write strobe
    5. wait 1000 us (1 ms), matching the vendor code

  Example: LCDData($41) ultimately places binary 0100 0001 on D7..D0 and
  pulses E with RS=1, which displays ASCII 'A'.  LCDCommand($01) uses the same
  bus transaction with RS=0, so the LCD interprets $01 as Clear Display. }
procedure LCDWriteByte(RS: cint; Value: Byte);
begin
  SetLCDControl(RS, 0, 0);
  SetGPIO4Byte(Value);
  SetLCDControl(RS, 0, 1);
  SetLCDControl(RS, 0, 0);
  c_usleep(LCD_BYTE_DELAY_US);
end;

{ Convenience wrappers make call sites self-documenting. }
procedure LCDCommand(Value: Byte);
begin
  LCDWriteByte(0, Value);
end;

procedure LCDData(Value: Byte);
begin
  LCDWriteByte(1, Value);
end;

{ Initialize the HD44780 using the exact command stream emitted by the original
  Seagate Windows program.  LCDCommand means RS=0, so every value below is sent
  as a controller command rather than as a character to display.

    1. $38  Function Set
             0011 1000b -> 8-bit bus, two-line mode, 5x8 font

    2. $38  Function Set again
             Seagate deliberately sends the same command twice.  The second
             write simply reasserts the same mode; we keep it because the
             recovered sequence is known to work on this exact hardware.

    3. $0C  Display Control
             0000 1100b -> display ON, cursor OFF, blink OFF

    4. $01  Clear Display
             clears visible DDRAM and returns the address/cursor to home

    5. $06  Entry Mode Set
             0000 0110b -> advance to the next character after each write,
             without shifting the entire display

  LCDWriteByte waits 1 ms after every one of these commands, exactly as it does
  for ordinary character bytes.  No state cache is created here; the Boolean
  below only records whether INIT has been performed, so LINE/CLEAR can reject
  use of an uninitialized controller. }
procedure LCDInit;
begin
  LCDCommand(LCD_CMD_FUNCTION_SET_8BIT_2LINE);
  LCDCommand(LCD_CMD_FUNCTION_SET_8BIT_2LINE);
  LCDCommand(LCD_CMD_DISPLAY_ON_CURSOR_OFF);
  LCDCommand(LCD_CMD_CLEAR_DISPLAY);
  LCDCommand(LCD_CMD_ENTRY_MODE_INCREMENT);
  LCDInitialized := True;
end;

{ Convert one caller-provided byte into the character byte actually sent to
  the LCD.

  The recovered Seagate translation table passes normal printable ASCII
  unchanged:

      $20 = space, $21 = '!', ... $41 = 'A', ... $7E = '~'

  Bytes outside $20..$7E are not part of the supported UI character set, so
  Seagate maps them to a space ($20).  Keeping that rule here avoids sending
  arbitrary controller-specific character codes for UTF-8 or control bytes. }
function LCDMapChar(C: Byte): Byte;
begin
  if (C >= $20) and (C <= $7E) then
    Result := C
  else
    Result := $20;
end;

{ A physical LCD row is exactly 16 character cells.  Normalize client text
  before writing it:

    - truncate anything beyond column 16
    - pad shorter text with spaces so stale characters are erased
    - apply the Seagate ASCII mapping to every resulting byte

  RawByteString is intentional: the protocol is byte-oriented and the LCD does
  not understand UTF-8 text. }
function NormalizeLCDLine(const Text: RawByteString): RawByteString;
var
  I: Integer;
begin
  Result := Copy(Text, 1, 16);
  while Length(Result) < 16 do
    Result := Result + ' ';

  { At this point Result is exactly 16 bytes long.  Convert each one to the
    exact byte that the LCD will receive. }
  for I := 1 to 16 do
    Result[I] := AnsiChar(LCDMapChar(Byte(Result[I])));
end;

{ Rewrite one complete visible LCD row.

  HD44780 display RAM uses address $00 for row 0 and $40 for row 1.  Setting bit
  7 turns that address into the 'Set DDRAM Address' command, hence $80 and $C0.

  This hardware layer deliberately does NOT cache text.  Every LINE command is
  executed.  A menu/UI that wants duplicate suppression can make that policy
  decision itself. }
procedure LCDWriteLine(LineNo: Integer; const Text: RawByteString);
var
  S: RawByteString;
  I: Integer;
  Addr: Byte;
begin
  if not LCDInitialized then
    raise Exception.Create('LCD is not initialized; send INIT first');
  if (LineNo < 0) or (LineNo > 1) then
    raise Exception.Create('LINE number must be 0 or 1');

  S := NormalizeLCDLine(Text);

  { Deliberately unconditional: the hardware layer performs every LINE command.
    Duplicate-write suppression is UI policy and belongs in the caller. }
  if LineNo = 0 then
    Addr := LCD_LINE0_DDRAM_ADDR
  else
    Addr := LCD_LINE1_DDRAM_ADDR;
  LCDCommand(Addr);
  for I := 1 to 16 do
    LCDData(Byte(S[I]));
end;

{ Clear both rows and return the HD44780 cursor to its home position. }
procedure LCDClear;
begin
  if not LCDInitialized then
    raise Exception.Create('LCD is not initialized; send INIT first');
  LCDCommand(LCD_CMD_CLEAR_DISPLAY);
end;

{ Translate the public Seagate level 1/2/3 API into the two physical backlight
  GPIOs.  We only emit the three combinations observed in the vendor code; the
  unobserved A=1/B=0 combination is never exposed. }
procedure SetBacklight(Level: Integer);
const
  Offsets: array[0..1] of cuint = (LCD_BL_A, LCD_BL_B);
var
  Values: array[0..1] of cint;
begin
  case Level of
    BACKLIGHT_OFF:
      begin Values[0] := 0; Values[1] := 0; end;
    BACKLIGHT_DIM:
      begin Values[0] := 0; Values[1] := 1; end;
    BACKLIGHT_BRIGHT:
      begin Values[0] := 1; Values[1] := 1; end;
  else
    raise Exception.Create('BACKLIGHT level must be 1, 2 or 3');
  end;

  CheckZero(gpiod_line_request_set_values_subset(Req7, 2, @Offsets[0], @Values[0]),
    'set LCD backlight');
end;

{ Sample both physical buttons once and return a compact logical bitmask:

      0 = neither button
      1 = UP
      2 = DOWN
      3 = both

  The board wiring is active-low: an electrical 0 means pressed.  Converting
  that here keeps the debounce state machine independent of electrical polarity. }
function ReadRawButtons: Integer;
const
  Offsets: array[0..1] of cuint = (BUTTON_UP, BUTTON_DOWN);
var
  Values: array[0..1] of cint;
  UpPressed, DownPressed: Integer;
begin
  CheckZero(gpiod_line_request_get_values_subset(Req7, 2, @Offsets[0], @Values[0]),
    'read buttons');

  { GPIO74/75 are active-low. }
  if Values[0] = GPIOD_LINE_VALUE_INACTIVE then UpPressed := 1 else UpPressed := 0;
  if Values[1] = GPIOD_LINE_VALUE_INACTIVE then DownPressed := 1 else DownPressed := 0;
  Result := UpPressed or (DownPressed shl 1);
end;

{ Human-readable protocol name for the internal button bitmask. }
function ButtonName(State: Integer): string;
begin
  case State of
    BUTTON_STATE_UP:   Result := 'UP';
    BUTTON_STATE_DOWN: Result := 'DOWN';
    BUTTON_STATE_BOTH: Result := 'BOTH';
  else
    Result := 'UNKNOWN';
  end;
end;

{ Emit one protocol event, for example 'BUTTON UP PRESS'. }
procedure EmitButtonEvent(State: Integer; const EventName: string);
begin
  Emit('BUTTON ' + ButtonName(State) + ' ' + EventName);
end;

{ Forget any not-yet-qualified debounce candidate. }
procedure ResetCandidate;
begin
  CandidateButtonState := BUTTON_STATE_NONE;
  CandidateButtonCount := 0;
end;

{ Sample and debounce the buttons, producing only protocol-level events.

  There are two modes:

    IDLE   (150 ms): a first observed press is accepted immediately.  The panel
                     is asleep/dim here, and requiring two 150 ms samples could
                     miss a short wake tap.

    ACTIVE (10 ms): a new press needs two consecutive matching samples.
                    Depending on where the physical transition falls between
                    poll ticks, qualification takes roughly 10-20 ms.

  RELEASE also requires two clean 'none pressed' samples.

  INTERRUPT is different from RELEASE.  As soon as a reported press stops being
  continuously present for even one sample, INTERRUPT is emitted.  The shell UI
  uses that to invalidate its 0.95 s long-hold timer.  A later clean RELEASE then
  ends the gesture.  If the raw state changes from UP to BOTH (or DOWN to BOTH),
  we do not turn the in-progress gesture into a new chord; we wait for release. }
procedure PollButtons;
var
  Raw: Integer;
begin
  Raw := ReadRawButtons;

  { UP, DOWN and BOTH are all valid physical protocol states.  The reference
    UI ignores BOTH, while another UI may assign a chord action to it. }
  if StableButtonState = BUTTON_STATE_NONE then
  begin
    if (Raw < BUTTON_STATE_UP) or (Raw > BUTTON_STATE_BOTH) then
    begin
      ResetCandidate;
      Exit;
    end;

    { Idle wake is deliberately one-sample so a short wake tap is not lost. }
    if not ActiveMode then
    begin
      StableButtonState := Raw;
      InterruptSent := False;
      ResetCandidate;
      EmitButtonEvent(StableButtonState, 'PRESS');
      Exit;
    end;

    if Raw = CandidateButtonState then
      Inc(CandidateButtonCount)
    else
    begin
      CandidateButtonState := Raw;
      CandidateButtonCount := 1;
    end;

    if CandidateButtonCount >= ACTIVE_DEBOUNCE_POLLS then
    begin
      StableButtonState := Raw;
      InterruptSent := False;
      ResetCandidate;
      EmitButtonEvent(StableButtonState, 'PRESS');
    end;
    Exit;
  end;

  { While a logical press is held, a single raw break is enough to tell the UI
    that the hold was not continuous.  This prevents a brief release/repress
    from bridging the UI's long-press timer. }
  if Raw <> StableButtonState then
  begin
    if not InterruptSent then
    begin
      InterruptSent := True;
      EmitButtonEvent(StableButtonState, 'INTERRUPT');
    end;

    if Raw = BUTTON_STATE_NONE then
    begin
      if CandidateButtonState = BUTTON_STATE_NONE then
        Inc(CandidateButtonCount)
      else
      begin
        CandidateButtonState := BUTTON_STATE_NONE;
        CandidateButtonCount := 1;
      end;

      if CandidateButtonCount >= ACTIVE_DEBOUNCE_POLLS then
      begin
        EmitButtonEvent(StableButtonState, 'RELEASE');
        StableButtonState := BUTTON_STATE_NONE;
        InterruptSent := False;
        ResetCandidate;
      end;
    end
    else
      ResetCandidate; { changed chord/state: wait for a clean release }
  end
  else
    ResetCandidate;
end;

{ Return the physical button sampling interval selected by MODE.

  IDLE   -> 150 ms, because the only purpose is detecting a wake press
  ACTIVE -> 10 ms, so menu navigation feels immediate and two-sample debounce
            still finishes in roughly 10-20 ms. }
function PollIntervalMs: Integer;
begin
  if ActiveMode then
    Result := ACTIVE_POLL_MS
  else
    Result := IDLE_POLL_MS;
end;

{ MODE changes only how frequently this hardware process samples GPIO74/75.

    MODE IDLE   -> 150 ms sampling
    MODE ACTIVE -> 10 ms sampling

  It does NOT change LCD contents, brightness, menu state, long-press meaning or
  inactivity policy.  Those decisions remain entirely in the caller/UI. }
procedure SetMode(const ModeName: string);
begin
  if SameText(ModeName, 'ACTIVE') then
    ActiveMode := True
  else if SameText(ModeName, 'IDLE') then
    ActiveMode := False
  else
    raise Exception.Create('MODE must be IDLE or ACTIVE');

  NextPollAt := GetTickCount64 + QWord(PollIntervalMs);
end;

{ Convert a caught command error into one parseable protocol record. }
procedure ReplyError(const Msg: string);
begin
  Emit('ERROR ' + CleanMessage(Msg));
end;

{ Parse one complete line from stdin.

  The protocol intentionally stays boring and human-readable.  Successful
  commands receive an OK reply; malformed commands become ERROR replies instead
  of terminating the hardware service.  Hardware/startup failures outside this
  handler are fatal and are handled by the program-level exception block. }
procedure HandleCommand(const CmdLine: RawByteString);
var
  S, Rest, Text: RawByteString;
  P, LineNo, Level: Integer;
begin
  S := CmdLine;
  if S = '' then Exit;

  try
    if S = 'PING' then
      Emit('OK PONG')
    else if S = 'INIT' then
    begin
      LCDInit;
      Emit('OK INIT');
    end
    else if S = 'CLEAR' then
    begin
      LCDClear;
      Emit('OK CLEAR');
    end
    else if S = 'QUIT' then
    begin
      Emit('OK QUIT');
      Running := False;
    end
    else if Copy(S, 1, 10) = 'BACKLIGHT ' then
    begin
      Rest := Copy(S, 11, MaxInt);
      Level := StrToInt(Rest);
      SetBacklight(Level);
      Emit('OK BACKLIGHT ' + IntToStr(Level));
    end
    else if Copy(S, 1, 5) = 'MODE ' then
    begin
      Rest := Copy(S, 6, MaxInt);
      SetMode(Rest);
      Emit('OK MODE ' + UpperCase(Rest));
    end
    else if S = 'GETBUTTONS' then
    begin
      { Diagnostic/immediate read: unlike asynchronous PRESS/RELEASE events,
        this command samples GPIO74/75 right now and reports their state. }
      Level := ReadRawButtons;
      Emit('BUTTONS UP=' + IntToStr(Ord((Level and 1) <> 0)) +
        ' DOWN=' + IntToStr(Ord((Level and 2) <> 0)));
    end
    else if Copy(S, 1, 5) = 'LINE ' then
    begin
      Rest := Copy(S, 6, MaxInt);
      P := Pos(' ', Rest);
      if P = 0 then
        raise Exception.Create('usage: LINE <0|1> <text>');
      LineNo := StrToInt(Copy(Rest, 1, P - 1));
      Text := Copy(Rest, P + 1, MaxInt); { preserve any leading space in text }
      LCDWriteLine(LineNo, Text);
      Emit('OK LINE ' + IntToStr(LineNo));
    end
    else
      raise Exception.Create('unknown command: ' + string(S));
  except
    on E: Exception do
      ReplyError(E.Message);
  end;
end;

{ Main service loop.

  One process has two independent jobs:
    1. accept protocol commands from stdin
    2. sample buttons at the current MODE interval

  libc poll() lets us sleep until whichever happens first.  The timeout is the
  number of milliseconds until the next button sample, so there is no busy loop
  and no shell-side GPIO polling. }
procedure EventLoop;
var
  PFD: TPollFD;
  TimeoutMs, PollRet: cint;
  NowMs: QWord;
  Cmd: RawByteString;
begin
  ActiveMode := False;
  NextPollAt := GetTickCount64 + QWord(PollIntervalMs);

  while Running do
  begin
    NowMs := GetTickCount64;
    if NowMs >= NextPollAt then
    begin
      PollButtons;
      NextPollAt := GetTickCount64 + QWord(PollIntervalMs);
      Continue;
    end;

    TimeoutMs := cint(NextPollAt - NowMs);
    PFD.fd := 0;
    PFD.events := POLLIN;
    PFD.revents := 0;
    PollRet := c_poll(@PFD, 1, TimeoutMs);

    if PollRet < 0 then
      raise Exception.Create('poll(stdin) failed');

    if PollRet = 0 then
      Continue;

    if (PFD.revents and (POLLERR or POLLNVAL)) <> 0 then
      raise Exception.Create('stdin pipe error');

    if (PFD.revents and POLLIN) <> 0 then
    begin
      if Eof(Input) then
      begin
        Running := False;
        Continue;
      end;
      ReadLn(Input, Cmd);
      HandleCommand(Cmd);
    end
    else if (PFD.revents and POLLHUP) <> 0 then
      Running := False;
  end;
end;

{ Best-effort cosmetic shutdown: return the backlight to the normal dim level
  before releasing GPIO ownership.  Failure here must not prevent cleanup. }
procedure SafeShutdown;
begin
  if Req7 <> nil then
  begin
    try
      SetBacklight(BACKLIGHT_DIM);
    except
      { Best effort only during shutdown. }
    end;
  end;
end;

{ Program lifetime is deliberately nested so every acquired resource has a
  matching finally block:

      load libgpiod
        -> request GPIOs
          -> run protocol loop
          -> dim + release GPIOs
        -> unload libgpiod

  A fatal error is reported on both stdout (for protocol clients) and stderr
  (for administrators/logs). }
begin
  try
    gpiod_load;
    try
      InitHardware;
      try
        Emit('READY ' + PROGRAM_VERSION);
        EventLoop;
      finally
        SafeShutdown;
        ReleaseHardware;
      end;
    finally
      gpiod_unload;
    end;
  except
    on E: Exception do
    begin
      Emit('ERROR FATAL ' + CleanMessage(E.Message));
      Log('frontpanel: ' + CleanMessage(E.Message));
      Halt(1);
    end;
  end;
end.
