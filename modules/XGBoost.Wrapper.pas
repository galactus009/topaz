{
  XGBoost.Wrapper — Object-oriented Free Pascal wrapper for XGBoost.

  Dynamic linking via dynlibs — loads libxgboost at runtime.
  No compile-time dependency on XGBoost.

  Usage:
    var
      DM: TDMatrix;
      Booster: TBooster;
      Preds: TSingleArray;
    begin
      DM := TDMatrix.Create(Data, 100, 5);
      DM.SetLabels(Labels);
      try
        Booster := TBooster.Create([DM]);
        Booster.SetParam('max_depth', '6');
        Booster.SetParam('eta', '0.3');
        Booster.SetParam('objective', 'reg:squarederror');
        Booster.Train(DM, 100);
        Preds := Booster.Predict(DM);
        Booster.SaveModel('model.json');
        Booster.Free;
      finally
        DM.Free;
      end;
    end;

  Requirements:
    - libxgboost.dylib (macOS) / libxgboost.so (Linux) / xgboost.dll (Windows)
    - Install via: brew install xgboost (macOS) or pip install xgboost
}
unit XGBoost.Wrapper;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  SysUtils, {$IFDEF FPC}DynLibs{$ELSE}Winapi.Windows{$ENDIF};

type
  TSingleArray = array of Single;

  EXGBoostError = class(Exception);

  { TDMatrix — Feature matrix + labels/weights }
  TDMatrix = class
  private
    FHandle: Pointer;
    procedure Check(AResult: Integer);
  public
    constructor Create(const AData: array of Single; ARows, ACols: Integer;
      AMissing: Single = 0);
    destructor Destroy; override;
    procedure SetLabels(const ALabels: array of Single);
    procedure SetWeights(const AWeights: array of Single);
    procedure SetFloatInfo(const AField: AnsiString; const AValues: array of Single);
    function RowCount: Int64;
    function ColCount: Int64;
    property Handle: Pointer read FHandle;
  end;

  { TBooster — Gradient boosted tree model }
  TBooster = class
  private
    FHandle: Pointer;
    procedure Check(AResult: Integer);
  public
    constructor Create(const AMatrices: array of TDMatrix);
    destructor Destroy; override;
    procedure SetParam(const AName, AValue: AnsiString);
    procedure UpdateOneIter(AIter: Integer; ATrain: TDMatrix);
    procedure Train(ATrain: TDMatrix; ARounds: Integer);
    function Predict(AData: TDMatrix; AOptionMask: Integer = 0;
      ANTreeLimit: Cardinal = 0): TSingleArray;
    procedure SaveModel(const APath: AnsiString);
    procedure LoadModel(const APath: AnsiString);
    property Handle: Pointer read FHandle;
  end;

  { Library management }
  function XGBoostLoaded: Boolean;
  procedure LoadXGBoost(const APath: AnsiString = '');
  procedure UnloadXGBoost;

implementation

type
  TBstULong = UInt64;

  TFnGetLastError        = function: PAnsiChar; cdecl;
  TFnDMatrixCreateFromMat = function(Data: PSingle; NRow, NCol: TBstULong;
    Missing: Single; out OutHandle: Pointer): Integer; cdecl;
  TFnDMatrixFree         = function(Handle: Pointer): Integer; cdecl;
  TFnDMatrixSetFloatInfo = function(Handle: Pointer; Field: PAnsiChar;
    Arr: PSingle; Len: TBstULong): Integer; cdecl;
  TFnDMatrixNumRow       = function(Handle: Pointer; out OutLen: TBstULong): Integer; cdecl;
  TFnDMatrixNumCol       = function(Handle: Pointer; out OutLen: TBstULong): Integer; cdecl;
  TFnBoosterCreate       = function(DMats: Pointer; Len: TBstULong;
    out OutHandle: Pointer): Integer; cdecl;
  TFnBoosterFree         = function(Handle: Pointer): Integer; cdecl;
  TFnBoosterSetParam     = function(Handle: Pointer;
    Name, Value: PAnsiChar): Integer; cdecl;
  TFnBoosterUpdateOneIter = function(Handle: Pointer; Iter: Integer;
    DTrain: Pointer): Integer; cdecl;
  TFnBoosterPredict      = function(Handle: Pointer; DMat: Pointer;
    OptionMask: Integer; NTreeLimit: Cardinal; Training: Integer;
    out OutLen: TBstULong; out OutResult: PSingle): Integer; cdecl;
  TFnBoosterSaveModel    = function(Handle: Pointer; FName: PAnsiChar): Integer; cdecl;
  TFnBoosterLoadModel    = function(Handle: Pointer; FName: PAnsiChar): Integer; cdecl;

var
  GLib: TLibHandle = NilHandle;
  GGetLastError:        TFnGetLastError;
  GDMatrixCreateFromMat: TFnDMatrixCreateFromMat;
  GDMatrixFree:         TFnDMatrixFree;
  GDMatrixSetFloatInfo: TFnDMatrixSetFloatInfo;
  GDMatrixNumRow:       TFnDMatrixNumRow;
  GDMatrixNumCol:       TFnDMatrixNumCol;
  GBoosterCreate:       TFnBoosterCreate;
  GBoosterFree:         TFnBoosterFree;
  GBoosterSetParam:     TFnBoosterSetParam;
  GBoosterUpdateOneIter: TFnBoosterUpdateOneIter;
  GBoosterPredict:      TFnBoosterPredict;
  GBoosterSaveModel:    TFnBoosterSaveModel;
  GBoosterLoadModel:    TFnBoosterLoadModel;

const
{$IFDEF DARWIN}
  DEFAULT_LIB = 'libxgboost.dylib';
{$ENDIF}
{$IFDEF LINUX}
  DEFAULT_LIB = 'libxgboost.so';
{$ENDIF}
{$IFDEF WINDOWS}
  DEFAULT_LIB = 'xgboost.dll';
{$ENDIF}

function XGBoostLoaded: Boolean;
begin
  Result := GLib <> NilHandle;
end;

procedure LoadXGBoost(const APath: AnsiString);
var
  Lib: AnsiString;

  function Resolve(const AName: AnsiString): Pointer;
  begin
    Result := GetProcAddress(GLib, AName);
    if Result = nil then
      raise EXGBoostError.CreateFmt('XGBoost symbol not found: %s', [AName]);
  end;

begin
  if GLib <> NilHandle then Exit;

  if APath <> '' then Lib := APath
  else Lib := DEFAULT_LIB;

  GLib := LoadLibrary(Lib);
  if GLib = NilHandle then
    raise EXGBoostError.CreateFmt('Failed to load %s', [Lib]);

  GGetLastError        := TFnGetLastError(Resolve('XGBGetLastError'));
  GDMatrixCreateFromMat := TFnDMatrixCreateFromMat(Resolve('XGDMatrixCreateFromMat'));
  GDMatrixFree         := TFnDMatrixFree(Resolve('XGDMatrixFree'));
  GDMatrixSetFloatInfo := TFnDMatrixSetFloatInfo(Resolve('XGDMatrixSetFloatInfo'));
  GDMatrixNumRow       := TFnDMatrixNumRow(Resolve('XGDMatrixNumRow'));
  GDMatrixNumCol       := TFnDMatrixNumCol(Resolve('XGDMatrixNumCol'));
  GBoosterCreate       := TFnBoosterCreate(Resolve('XGBoosterCreate'));
  GBoosterFree         := TFnBoosterFree(Resolve('XGBoosterFree'));
  GBoosterSetParam     := TFnBoosterSetParam(Resolve('XGBoosterSetParam'));
  GBoosterUpdateOneIter := TFnBoosterUpdateOneIter(Resolve('XGBoosterUpdateOneIter'));
  GBoosterPredict      := TFnBoosterPredict(Resolve('XGBoosterPredict'));
  GBoosterSaveModel    := TFnBoosterSaveModel(Resolve('XGBoosterSaveModel'));
  GBoosterLoadModel    := TFnBoosterLoadModel(Resolve('XGBoosterLoadModel'));
end;

procedure UnloadXGBoost;
begin
  if GLib <> NilHandle then
  begin
    FreeLibrary(GLib);
    GLib := NilHandle;
  end;
end;

function LastError: AnsiString;
var
  P: PAnsiChar;
begin
  if Assigned(GGetLastError) then
  begin
    P := GGetLastError();
    if P <> nil then Exit(AnsiString(P));
  end;
  Result := 'unknown error';
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  TDMatrix                                                          }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TDMatrix.Check(AResult: Integer);
begin
  if AResult <> 0 then
    raise EXGBoostError.Create(LastError);
end;

constructor TDMatrix.Create(const AData: array of Single; ARows, ACols: Integer;
  AMissing: Single);
begin
  inherited Create;
  if not XGBoostLoaded then LoadXGBoost;
  Check(GDMatrixCreateFromMat(@AData[0], TBstULong(ARows), TBstULong(ACols),
    AMissing, FHandle));
end;

destructor TDMatrix.Destroy;
begin
  if FHandle <> nil then
    GDMatrixFree(FHandle);
  inherited;
end;

procedure TDMatrix.SetLabels(const ALabels: array of Single);
begin
  SetFloatInfo('label', ALabels);
end;

procedure TDMatrix.SetWeights(const AWeights: array of Single);
begin
  SetFloatInfo('weight', AWeights);
end;

procedure TDMatrix.SetFloatInfo(const AField: AnsiString;
  const AValues: array of Single);
begin
  Check(GDMatrixSetFloatInfo(FHandle, PAnsiChar(AField), @AValues[0],
    TBstULong(Length(AValues))));
end;

function TDMatrix.RowCount: Int64;
var
  N: TBstULong;
begin
  Check(GDMatrixNumRow(FHandle, N));
  Result := Int64(N);
end;

function TDMatrix.ColCount: Int64;
var
  N: TBstULong;
begin
  Check(GDMatrixNumCol(FHandle, N));
  Result := Int64(N);
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  TBooster                                                          }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TBooster.Check(AResult: Integer);
begin
  if AResult <> 0 then
    raise EXGBoostError.Create(LastError);
end;

constructor TBooster.Create(const AMatrices: array of TDMatrix);
var
  Handles: array of Pointer;
  I: Integer;
begin
  inherited Create;
  if not XGBoostLoaded then LoadXGBoost;

  SetLength(Handles, Length(AMatrices));
  for I := 0 to High(AMatrices) do
    Handles[I] := AMatrices[I].Handle;

  Check(GBoosterCreate(@Handles[0], TBstULong(Length(Handles)), FHandle));
end;

destructor TBooster.Destroy;
begin
  if FHandle <> nil then
    GBoosterFree(FHandle);
  inherited;
end;

procedure TBooster.SetParam(const AName, AValue: AnsiString);
begin
  Check(GBoosterSetParam(FHandle, PAnsiChar(AName), PAnsiChar(AValue)));
end;

procedure TBooster.UpdateOneIter(AIter: Integer; ATrain: TDMatrix);
begin
  Check(GBoosterUpdateOneIter(FHandle, AIter, ATrain.Handle));
end;

procedure TBooster.Train(ATrain: TDMatrix; ARounds: Integer);
var
  I: Integer;
begin
  for I := 0 to ARounds - 1 do
    UpdateOneIter(I, ATrain);
end;

function TBooster.Predict(AData: TDMatrix; AOptionMask: Integer;
  ANTreeLimit: Cardinal): TSingleArray;
var
  OutLen: TBstULong;
  OutPtr: PSingle;
  I: Integer;
begin
  Check(GBoosterPredict(FHandle, AData.Handle, AOptionMask, ANTreeLimit,
    0, OutLen, OutPtr));

  SetLength(Result, OutLen);
  for I := 0 to Int64(OutLen) - 1 do
    Result[I] := PSingle(PByte(OutPtr) + I * SizeOf(Single))^;
end;

procedure TBooster.SaveModel(const APath: AnsiString);
begin
  Check(GBoosterSaveModel(FHandle, PAnsiChar(APath)));
end;

procedure TBooster.LoadModel(const APath: AnsiString);
begin
  Check(GBoosterLoadModel(FHandle, PAnsiChar(APath)));
end;

finalization
  UnloadXGBoost;

end.
