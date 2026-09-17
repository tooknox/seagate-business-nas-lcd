unit gpiod_min;

{$mode objfpc}{$H+}

{ Minimal dynamic libgpiod 2.x binding used by seagate-xbig-frontpanel.

  WHY THIS UNIT EXISTS
  --------------------
  FreePascal does not need to know anything about the Fintek chip here.  The
  Linux gpio-f7188x driver already exposes the chip through the standard GPIO
  character-device API, and libgpiod is the userspace library for that API.

  This unit is intentionally NOT a general Pascal GPIO framework.  It exposes
  only the small subset of libgpiod 2.x that the front-panel program uses.
  Keeping the binding tiny makes it easy to audit and easy to replace later.

  WHY DYNAMIC LOADING
  -------------------
  The executable resolves the required symbols at runtime instead of linking a
  Pascal import library at build time.  Debian 13 provides libgpiod.so.3.  A
  generic libgpiod.so fallback is also accepted when it exposes the same 2.x ABI.

  Nothing in this unit performs raw port I/O. }

interface

uses
  ctypes;

const
  { These numbers are not board-specific magic values; they are the exact enum
    values defined by the libgpiod 2.x C ABI.  We reproduce them here because
    this deliberately tiny binding does not import the full C header.

    LINE_VALUE_INACTIVE/ACTIVE are libgpiod logical values supplied to GPIO
    requests.  On an ordinary push-pull output they correspond to low/high.  On
    an open-drain line, ACTIVE/INACTIVE are still logical libgpiod values while
    the kernel handles the actual drive/release behavior requested below.

    DIRECTION_INPUT/OUTPUT select whether the kernel samples or drives a line.
    OPEN_DRAIN asks the kernel to configure the Fintek output with open-drain
    semantics, matching Seagate's configuration for GPIO70..73 and GPIO76. }
  GPIOD_LINE_VALUE_INACTIVE = 0;
  GPIOD_LINE_VALUE_ACTIVE   = 1;

  GPIOD_LINE_DIRECTION_INPUT  = 2;
  GPIOD_LINE_DIRECTION_OUTPUT = 3;

  GPIOD_LINE_DRIVE_OPEN_DRAIN = 2;

type
  { libgpiod objects are opaque C structures.  Pascal never dereferences them;
    it simply stores the pointers returned by libgpiod and passes them back. }
  TGpiodChip          = Pointer;
  TGpiodChipInfo      = Pointer;
  TGpiodLineSettings  = Pointer;
  TGpiodLineConfig    = Pointer;
  TGpiodRequestConfig = Pointer;
  TGpiodLineRequest   = Pointer;

  PCUInt = ^cuint;
  PCInt  = ^cint;

  { Function-pointer types below mirror only the libgpiod calls used by the
    front-panel program.  There are four conceptual groups:

      chip_*          open a /dev/gpiochip and inspect its label
      line_settings_* describe input/output/open-drain behavior
      line_config_*   attach those settings to chosen line offsets
      line_request_*  own the configured lines and read/write their values

    cdecl is required because libgpiod is a C library.  The opaque Pointer
    handles above are passed back unchanged; Pascal never looks inside them. }
  TGpiodChipOpen = function(path: PChar): TGpiodChip; cdecl;
  TGpiodChipClose = procedure(chip: TGpiodChip); cdecl;
  TGpiodChipGetInfo = function(chip: TGpiodChip): TGpiodChipInfo; cdecl;
  TGpiodChipInfoFree = procedure(info: TGpiodChipInfo); cdecl;
  TGpiodChipInfoGetLabel = function(info: TGpiodChipInfo): PChar; cdecl;

  TGpiodLineSettingsNew = function: TGpiodLineSettings; cdecl;
  TGpiodLineSettingsFree = procedure(settings: TGpiodLineSettings); cdecl;
  TGpiodLineSettingsSetDirection = function(settings: TGpiodLineSettings;
    direction: cint): cint; cdecl;
  TGpiodLineSettingsSetDrive = function(settings: TGpiodLineSettings;
    drive: cint): cint; cdecl;
  TGpiodLineSettingsSetOutputValue = function(settings: TGpiodLineSettings;
    value: cint): cint; cdecl;

  TGpiodLineConfigNew = function: TGpiodLineConfig; cdecl;
  TGpiodLineConfigFree = procedure(config: TGpiodLineConfig); cdecl;
  TGpiodLineConfigAddLineSettings = function(config: TGpiodLineConfig;
    offsets: PCUInt; numOffsets: csize_t; settings: TGpiodLineSettings): cint; cdecl;

  TGpiodRequestConfigNew = function: TGpiodRequestConfig; cdecl;
  TGpiodRequestConfigFree = procedure(config: TGpiodRequestConfig); cdecl;
  TGpiodRequestConfigSetConsumer = procedure(config: TGpiodRequestConfig;
    consumer: PChar); cdecl;

  TGpiodChipRequestLines = function(chip: TGpiodChip;
    reqCfg: TGpiodRequestConfig; lineCfg: TGpiodLineConfig): TGpiodLineRequest; cdecl;
  TGpiodLineRequestRelease = procedure(request: TGpiodLineRequest); cdecl;
  TGpiodLineRequestSetValues = function(request: TGpiodLineRequest;
    values: PCInt): cint; cdecl;
  TGpiodLineRequestSetValuesSubset = function(request: TGpiodLineRequest;
    numValues: csize_t; offsets: PCUInt; values: PCInt): cint; cdecl;
  TGpiodLineRequestGetValuesSubset = function(request: TGpiodLineRequest;
    numValues: csize_t; offsets: PCUInt; values: PCInt): cint; cdecl;

var
  { These start as nil and are filled by gpiod_load after dlopen/LoadLibrary.
    Keeping the original C names makes it easy to compare calls with libgpiod
    documentation. }
  gpiod_chip_open: TGpiodChipOpen = nil;
  gpiod_chip_close: TGpiodChipClose = nil;
  gpiod_chip_get_info: TGpiodChipGetInfo = nil;
  gpiod_chip_info_free: TGpiodChipInfoFree = nil;
  gpiod_chip_info_get_label: TGpiodChipInfoGetLabel = nil;

  gpiod_line_settings_new: TGpiodLineSettingsNew = nil;
  gpiod_line_settings_free: TGpiodLineSettingsFree = nil;
  gpiod_line_settings_set_direction: TGpiodLineSettingsSetDirection = nil;
  gpiod_line_settings_set_drive: TGpiodLineSettingsSetDrive = nil;
  gpiod_line_settings_set_output_value: TGpiodLineSettingsSetOutputValue = nil;

  gpiod_line_config_new: TGpiodLineConfigNew = nil;
  gpiod_line_config_free: TGpiodLineConfigFree = nil;
  gpiod_line_config_add_line_settings: TGpiodLineConfigAddLineSettings = nil;

  gpiod_request_config_new: TGpiodRequestConfigNew = nil;
  gpiod_request_config_free: TGpiodRequestConfigFree = nil;
  gpiod_request_config_set_consumer: TGpiodRequestConfigSetConsumer = nil;

  gpiod_chip_request_lines: TGpiodChipRequestLines = nil;
  gpiod_line_request_release: TGpiodLineRequestRelease = nil;
  gpiod_line_request_set_values: TGpiodLineRequestSetValues = nil;
  gpiod_line_request_set_values_subset: TGpiodLineRequestSetValuesSubset = nil;
  gpiod_line_request_get_values_subset: TGpiodLineRequestGetValuesSubset = nil;

procedure gpiod_load;
procedure gpiod_unload;
function gpiod_loaded: Boolean;
function gpiod_library_name: string;

implementation

uses
  SysUtils, Dynlibs;

var
  LibHandle: TLibHandle = dynlibs.NilHandle;
  LoadedName: string = '';

{ Resolve one mandatory libgpiod symbol.  Missing any symbol means the loaded
  library is not the 2.x ABI this program expects, so fail immediately. }
function NeedSymbol(const Name: string): Pointer;
begin
  Result := GetProcedureAddress(LibHandle, PChar(Name));
  if Result = nil then
    raise Exception.Create('libgpiod 2.x symbol missing: ' + Name);
end;

{ Load libgpiod once, then resolve every API entry point used by the project.
  Repeated calls are harmless. }
procedure gpiod_load;
begin
  if LibHandle <> dynlibs.NilHandle then
    Exit;

  LibHandle := LoadLibrary('libgpiod.so.3');
  if LibHandle <> dynlibs.NilHandle then
    LoadedName := 'libgpiod.so.3'
  else
  begin
    LibHandle := LoadLibrary('libgpiod.so');
    if LibHandle <> dynlibs.NilHandle then
      LoadedName := 'libgpiod.so';
  end;

  if LibHandle = dynlibs.NilHandle then
    raise Exception.Create('cannot load libgpiod.so.3 (libgpiod 2.x required)');

  try
    { Assigning the resolved addresses to typed procedure variables gives the
      board-specific unit normal Pascal-call syntax with C-compatible types. }
    Pointer(gpiod_chip_open) := NeedSymbol('gpiod_chip_open');
    Pointer(gpiod_chip_close) := NeedSymbol('gpiod_chip_close');
    Pointer(gpiod_chip_get_info) := NeedSymbol('gpiod_chip_get_info');
    Pointer(gpiod_chip_info_free) := NeedSymbol('gpiod_chip_info_free');
    Pointer(gpiod_chip_info_get_label) := NeedSymbol('gpiod_chip_info_get_label');

    Pointer(gpiod_line_settings_new) := NeedSymbol('gpiod_line_settings_new');
    Pointer(gpiod_line_settings_free) := NeedSymbol('gpiod_line_settings_free');
    Pointer(gpiod_line_settings_set_direction) := NeedSymbol('gpiod_line_settings_set_direction');
    Pointer(gpiod_line_settings_set_drive) := NeedSymbol('gpiod_line_settings_set_drive');
    Pointer(gpiod_line_settings_set_output_value) := NeedSymbol('gpiod_line_settings_set_output_value');

    Pointer(gpiod_line_config_new) := NeedSymbol('gpiod_line_config_new');
    Pointer(gpiod_line_config_free) := NeedSymbol('gpiod_line_config_free');
    Pointer(gpiod_line_config_add_line_settings) := NeedSymbol('gpiod_line_config_add_line_settings');

    Pointer(gpiod_request_config_new) := NeedSymbol('gpiod_request_config_new');
    Pointer(gpiod_request_config_free) := NeedSymbol('gpiod_request_config_free');
    Pointer(gpiod_request_config_set_consumer) := NeedSymbol('gpiod_request_config_set_consumer');

    Pointer(gpiod_chip_request_lines) := NeedSymbol('gpiod_chip_request_lines');
    Pointer(gpiod_line_request_release) := NeedSymbol('gpiod_line_request_release');
    Pointer(gpiod_line_request_set_values) := NeedSymbol('gpiod_line_request_set_values');
    Pointer(gpiod_line_request_set_values_subset) := NeedSymbol('gpiod_line_request_set_values_subset');
    Pointer(gpiod_line_request_get_values_subset) := NeedSymbol('gpiod_line_request_get_values_subset');
  except
    gpiod_unload;
    raise;
  end;
end;

{ Release the shared library handle.  Procedure variables are not used after
  this point because the front-panel program unloads only after releasing GPIOs. }
procedure gpiod_unload;
begin
  if LibHandle <> dynlibs.NilHandle then
  begin
    FreeLibrary(LibHandle);
    LibHandle := dynlibs.NilHandle;
  end;
  LoadedName := '';
end;

function gpiod_loaded: Boolean;
begin
  Result := LibHandle <> dynlibs.NilHandle;
end;

function gpiod_library_name: string;
begin
  Result := LoadedName;
end;

{ Safety net for abnormal Pascal unit teardown; gpiod_unload itself checks
  whether a library is still loaded, so this can follow an explicit unload. }
finalization
  gpiod_unload;

end.
