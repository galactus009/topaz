(**
 * Topaz.State — Position State Persistence
 *
 * Saves and restores trading session state (positions, P&L, trade count)
 * to survive crashes. State is serialized as JSON to config/state.json.
 *
 * On load, if trading_date doesn't match today, positions are cleared
 * (new session). Auto-save runs every FSaveInterval seconds when dirty.
 *)
unit Topaz.State;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, DateUtils,
  {$IFDEF FPC}fpjson, jsonparser{$ELSE}System.JSON{$ENDIF};

type
  TPositionState = record
    Symbol: AnsiString;
    Exchange: Integer;      // TExchange ordinal
    Qty: Integer;           // positive=long, negative=short
    AvgPrice: Double;
    UnrealizedPnL: Double;
    RealizedPnL: Double;
    Strategy: AnsiString;   // which strategy owns this
  end;

  TSessionState = record
    TradingDate: AnsiString;    // YYYY-MM-DD
    DailyPnL: Double;
    TotalTrades: Integer;
    Positions: array of TPositionState;
    LastSaveTime: TDateTime;
  end;

  TStateManager = class
  private
    FStatePath: AnsiString;
    FState: TSessionState;
    FSaveInterval: Integer;    // seconds between auto-saves
    FLastSaveTime: TDateTime;
    FDirty: Boolean;

    function FindPositionIndex(const AStrategy, ASymbol: AnsiString): Integer;
    procedure EnsureDirectory;
  public
    constructor Create(const APath: AnsiString = '');
    destructor Destroy; override;

    // Position tracking
    procedure UpdatePosition(const AStrategy, ASymbol: AnsiString;
      AExchange: Integer; AQty: Integer; AAvgPrice, AUnrealizedPnL, ARealizedPnL: Double);
    procedure RemovePosition(const AStrategy, ASymbol: AnsiString);
    procedure ClearPositions;

    // P&L
    procedure SetDailyPnL(APnL: Double);
    procedure IncrementTrades;

    // Persistence
    procedure Save;
    procedure Load;
    procedure CheckAutoSave;  // call periodically (e.g. from timer)

    // Query
    function GetPositions: TArray<TPositionState>;
    function HasPositions: Boolean;
    function PositionCount: Integer;

    property TradingDate: AnsiString read FState.TradingDate write FState.TradingDate;
    property DailyPnL: Double read FState.DailyPnL;
    property TotalTrades: Integer read FState.TotalTrades;
    property SaveInterval: Integer read FSaveInterval write FSaveInterval;
  end;

implementation

{ TStateManager }

constructor TStateManager.Create(const APath: AnsiString);
begin
  inherited Create;
  if APath <> '' then
    FStatePath := APath
  else
    FStatePath := ExtractFilePath(ParamStr(0)) + 'config' + PathDelim + 'state.json';
  FSaveInterval := 30;
  FLastSaveTime := 0;
  FDirty := False;
  FState.TradingDate := FormatDateTime('yyyy-mm-dd', Now);
  FState.DailyPnL := 0;
  FState.TotalTrades := 0;
  SetLength(FState.Positions, 0);
  FState.LastSaveTime := Now;
end;

destructor TStateManager.Destroy;
begin
  if FDirty then
    Save;
  inherited;
end;

function TStateManager.FindPositionIndex(const AStrategy, ASymbol: AnsiString): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FState.Positions) do
    if (FState.Positions[I].Strategy = AStrategy) and
       (FState.Positions[I].Symbol = ASymbol) then
      Exit(I);
  Result := -1;
end;

procedure TStateManager.EnsureDirectory;
var
  Dir: AnsiString;
begin
  Dir := ExtractFilePath(FStatePath);
  if (Dir <> '') and not DirectoryExists(Dir) then
    ForceDirectories(Dir);
end;

procedure TStateManager.UpdatePosition(const AStrategy, ASymbol: AnsiString;
  AExchange: Integer; AQty: Integer; AAvgPrice, AUnrealizedPnL, ARealizedPnL: Double);
var
  Idx, Len: Integer;
begin
  Idx := FindPositionIndex(AStrategy, ASymbol);
  if Idx < 0 then
  begin
    Len := Length(FState.Positions);
    SetLength(FState.Positions, Len + 1);
    Idx := Len;
    FState.Positions[Idx].Symbol := ASymbol;
    FState.Positions[Idx].Strategy := AStrategy;
  end;
  FState.Positions[Idx].Exchange := AExchange;
  FState.Positions[Idx].Qty := AQty;
  FState.Positions[Idx].AvgPrice := AAvgPrice;
  FState.Positions[Idx].UnrealizedPnL := AUnrealizedPnL;
  FState.Positions[Idx].RealizedPnL := ARealizedPnL;
  FDirty := True;
end;

procedure TStateManager.RemovePosition(const AStrategy, ASymbol: AnsiString);
var
  Idx, Last: Integer;
begin
  Idx := FindPositionIndex(AStrategy, ASymbol);
  if Idx < 0 then Exit;
  Last := High(FState.Positions);
  if Idx < Last then
    FState.Positions[Idx] := FState.Positions[Last];
  SetLength(FState.Positions, Last);
  FDirty := True;
end;

procedure TStateManager.ClearPositions;
begin
  SetLength(FState.Positions, 0);
  FDirty := True;
end;

procedure TStateManager.SetDailyPnL(APnL: Double);
begin
  FState.DailyPnL := APnL;
  FDirty := True;
end;

procedure TStateManager.IncrementTrades;
begin
  Inc(FState.TotalTrades);
  FDirty := True;
end;

procedure TStateManager.Save;
var
  Root, PosArr, PosObj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  SL: TStringList;
begin
  EnsureDirectory;
  FState.LastSaveTime := Now;

  Root := TJSONObject.Create;
  try
    Root.Add('trading_date', FState.TradingDate);
    Root.Add('daily_pnl', FState.DailyPnL);
    Root.Add('total_trades', FState.TotalTrades);
    Root.Add('last_save', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', FState.LastSaveTime));

    Arr := TJSONArray.Create;
    for I := 0 to High(FState.Positions) do
    begin
      PosObj := TJSONObject.Create;
      PosObj.Add('symbol', FState.Positions[I].Symbol);
      PosObj.Add('exchange', FState.Positions[I].Exchange);
      PosObj.Add('qty', FState.Positions[I].Qty);
      PosObj.Add('avg_price', FState.Positions[I].AvgPrice);
      PosObj.Add('unrealized_pnl', FState.Positions[I].UnrealizedPnL);
      PosObj.Add('realized_pnl', FState.Positions[I].RealizedPnL);
      PosObj.Add('strategy', FState.Positions[I].Strategy);
      Arr.Add(PosObj);
    end;
    Root.Add('positions', Arr);

    SL := TStringList.Create;
    try
      SL.Text := Root.FormatJSON;
      SL.SaveToFile(FStatePath);
    finally
      SL.Free;
    end;

    FLastSaveTime := Now;
    FDirty := False;
  finally
    Root.Free;
  end;
end;

procedure TStateManager.Load;
var
  SL: TStringList;
  Root: TJSONData;
  Obj, PosObj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Today: AnsiString;
begin
  if not FileExists(FStatePath) then Exit;

  SL := TStringList.Create;
  try
    SL.LoadFromFile(FStatePath);
    if SL.Text = '' then Exit;

    Root := GetJSON(SL.Text);
    try
      if not (Root is TJSONObject) then Exit;
      Obj := TJSONObject(Root);

      FState.TradingDate := Obj.Get('trading_date', '');
      FState.DailyPnL := Obj.Get('daily_pnl', Double(0));
      FState.TotalTrades := Obj.Get('total_trades', 0);

      // If trading date doesn't match today, start a fresh session
      Today := FormatDateTime('yyyy-mm-dd', Now);
      if FState.TradingDate <> Today then
      begin
        FState.TradingDate := Today;
        FState.DailyPnL := 0;
        FState.TotalTrades := 0;
        SetLength(FState.Positions, 0);
        FState.LastSaveTime := Now;
        FDirty := True;
        Exit;
      end;

      // Parse positions
      Arr := Obj.Get('positions', TJSONArray(nil));
      if Arr <> nil then
      begin
        SetLength(FState.Positions, Arr.Count);
        for I := 0 to Arr.Count - 1 do
        begin
          PosObj := Arr.Objects[I];
          FState.Positions[I].Symbol := PosObj.Get('symbol', '');
          FState.Positions[I].Exchange := PosObj.Get('exchange', 0);
          FState.Positions[I].Qty := PosObj.Get('qty', 0);
          FState.Positions[I].AvgPrice := PosObj.Get('avg_price', Double(0));
          FState.Positions[I].UnrealizedPnL := PosObj.Get('unrealized_pnl', Double(0));
          FState.Positions[I].RealizedPnL := PosObj.Get('realized_pnl', Double(0));
          FState.Positions[I].Strategy := PosObj.Get('strategy', '');
        end;
      end
      else
        SetLength(FState.Positions, 0);

      FState.LastSaveTime := Now;
      FLastSaveTime := Now;
      FDirty := False;
    finally
      Root.Free;
    end;
  finally
    SL.Free;
  end;
end;

procedure TStateManager.CheckAutoSave;
begin
  if FDirty and (SecondsBetween(Now, FLastSaveTime) >= FSaveInterval) then
    Save;
end;

function TStateManager.GetPositions: TArray<TPositionState>;
var
  I: Integer;
begin
  SetLength(Result, Length(FState.Positions));
  for I := 0 to High(FState.Positions) do
    Result[I] := FState.Positions[I];
end;

function TStateManager.HasPositions: Boolean;
begin
  Result := Length(FState.Positions) > 0;
end;

function TStateManager.PositionCount: Integer;
begin
  Result := Length(FState.Positions);
end;

end.
