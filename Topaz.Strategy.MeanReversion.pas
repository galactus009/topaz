{
  MeanReversion — Z-score + RSI mean reversion strategy.

  Computes a rolling Z-score = (price - SMA) / StdDev over a lookback
  window. Combines with RSI for confirmation: only enters when both
  Z-score AND RSI agree the market is stretched.

  Entry (long):  Z <= -EntryZ AND RSI <= oversold
  Entry (short): Z >= +EntryZ AND RSI >= overbought
  Exit:  Z reverts to +/-ExitZ, or Z extends beyond +/-StopZ (stop loss).
  Cooldown prevents re-entry for N ticks after exit.
}
unit Topaz.Strategy.MeanReversion;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math, Apollo.Broker, Topaz.EventTypes, Topaz.Strategy,
  Topaz.Indicators;

type
  TMeanReversionStrategy = class(TStrategy)
  private
    { Parameters }
    FLookback: Integer;
    FEntryZ: Double;
    FExitZ: Double;
    FStopZ: Double;
    FRSIOversold: Double;
    FRSIOverbought: Double;
    FCooldownTicks: Integer;

    { Indicators }
    FSMA: TSMA;
    FRSI: TRSI;

    { Rolling buffer for StdDev }
    FBuf: array[0..MAX_PERIOD-1] of Double;
    FBufPos: Integer;
    FBufCount: Integer;

    { State }
    FInPosition: Boolean;
    FPositionSide: Integer;     // +1 = long, -1 = short
    FEntryPrice: Double;
    FTicksSinceExit: Integer;

    function CalcZScore(APrice: Double): Double;
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  public
    constructor Create;
    function DeclareParams: TArray<TStrategyParam>; override;
    procedure ApplyParam(const AName, AValue: AnsiString); override;
    function GetParamValue(const AName: AnsiString): AnsiString; override;
    property Lookback: Integer read FLookback write FLookback;
    property EntryZ: Double read FEntryZ write FEntryZ;
    property ExitZ: Double read FExitZ write FExitZ;
    property StopZ: Double read FStopZ write FStopZ;
    property RSIOversold: Double read FRSIOversold write FRSIOversold;
    property RSIOverbought: Double read FRSIOverbought write FRSIOverbought;
    property CooldownTicks: Integer read FCooldownTicks write FCooldownTicks;
  end;

implementation

function MkParam(const AName, ADisplay: AnsiString; AKind: TParamKind; const AValue: AnsiString): TStrategyParam;
begin
  Result.Name := AName;
  Result.Display := ADisplay;
  Result.Kind := AKind;
  Result.Value := AValue;
end;

{ ── Constructor ── }

constructor TMeanReversionStrategy.Create;
begin
  inherited Create;
  FLookback := 20;
  FEntryZ := 2.0;
  FExitZ := 0.5;
  FStopZ := 3.5;
  FRSIOversold := 30.0;
  FRSIOverbought := 70.0;
  FCooldownTicks := 50;
  FInPosition := False;
end;

function TMeanReversionStrategy.DeclareParams: TArray<TStrategyParam>;
begin
  SetLength(Result, 5);
  Result[0] := MkParam('lookback', 'Lookback', pkInteger, IntToStr(FLookback));
  Result[1] := MkParam('entry_z', 'Entry Z', pkFloat, FloatToStr(FEntryZ));
  Result[2] := MkParam('exit_z', 'Exit Z', pkFloat, FloatToStr(FExitZ));
  Result[3] := MkParam('stop_z', 'Stop Z', pkFloat, FloatToStr(FStopZ));
  Result[4] := MkParam('cooldown', 'Cooldown', pkInteger, IntToStr(FCooldownTicks));
end;

procedure TMeanReversionStrategy.ApplyParam(const AName, AValue: AnsiString);
begin
  if AName = 'lookback' then FLookback := StrToIntDef(string(AValue), FLookback)
  else if AName = 'entry_z' then FEntryZ := StrToFloatDef(string(AValue), FEntryZ)
  else if AName = 'exit_z' then FExitZ := StrToFloatDef(string(AValue), FExitZ)
  else if AName = 'stop_z' then FStopZ := StrToFloatDef(string(AValue), FStopZ)
  else if AName = 'cooldown' then FCooldownTicks := StrToIntDef(string(AValue), FCooldownTicks);
end;

function TMeanReversionStrategy.GetParamValue(const AName: AnsiString): AnsiString;
begin
  if AName = 'lookback' then Result := IntToStr(FLookback)
  else if AName = 'entry_z' then Result := FloatToStr(FEntryZ)
  else if AName = 'exit_z' then Result := FloatToStr(FExitZ)
  else if AName = 'stop_z' then Result := FloatToStr(FStopZ)
  else if AName = 'cooldown' then Result := IntToStr(FCooldownTicks)
  else Result := '';
end;

{ ── Z-score from rolling buffer ── }

function TMeanReversionStrategy.CalcZScore(APrice: Double): Double;
var
  Mean, Variance, StdDev: Double;
  I, N: Integer;
begin
  { Push into circular buffer }
  FBuf[FBufPos] := APrice;
  FBufPos := (FBufPos + 1) mod FLookback;
  if FBufCount < FLookback then
    Inc(FBufCount);

  if FBufCount < FLookback then
    Exit(0.0);

  { SMA gives us the mean; compute variance from buffer }
  Mean := FSMA.Value;
  N := FBufCount;
  Variance := 0;
  for I := 0 to N - 1 do
    Variance := Variance + Sqr(FBuf[I] - Mean);
  Variance := Variance / N;
  StdDev := Sqrt(Variance);

  if StdDev > 1e-12 then
    Result := (APrice - Mean) / StdDev
  else
    Result := 0.0;
end;

{ ── Lifecycle ── }

procedure TMeanReversionStrategy.OnStart;
begin
  inherited;
  FSMA.Init(FLookback);
  FRSI.Init(14);

  FBufPos := 0;
  FBufCount := 0;
  FillChar(FBuf, SizeOf(FBuf), 0);

  FInPosition := False;
  FTicksSinceExit := FCooldownTicks; // allow immediate first entry
end;

procedure TMeanReversionStrategy.OnTick(const ATick: TTickEvent);
var
  Z, RSIVal: Double;
begin
  { Update indicators }
  FSMA.Update(ATick.LTP);
  RSIVal := FRSI.Update(ATick.LTP);
  Z := CalcZScore(ATick.LTP);

  if not WarmedUp then Exit;

  { Wait for indicators to be ready }
  if not (FSMA.Ready and FRSI.Ready) then Exit;

  { ── Exit logic ── }
  if FInPosition then
  begin
    if FPositionSide = 1 then
    begin
      { Long exit: Z reverts above -ExitZ (profit) or extends below -StopZ (stop) }
      if Z >= -FExitZ then
      begin
        Sell(Underlying, Lots, 0, Exchange);
        PnL := PnL + (ATick.LTP - FEntryPrice) * Lots;
        FInPosition := False;
        FTicksSinceExit := 0;
        Exit;
      end;
      if Z <= -FStopZ then
      begin
        Sell(Underlying, Lots, 0, Exchange);
        PnL := PnL + (ATick.LTP - FEntryPrice) * Lots;
        FInPosition := False;
        FTicksSinceExit := 0;
        Exit;
      end;
    end
    else
    begin
      { Short exit: Z reverts below +ExitZ (profit) or extends above +StopZ (stop) }
      if Z <= FExitZ then
      begin
        Buy(Underlying, Lots, 0, Exchange);
        PnL := PnL + (FEntryPrice - ATick.LTP) * Lots;
        FInPosition := False;
        FTicksSinceExit := 0;
        Exit;
      end;
      if Z >= FStopZ then
      begin
        Buy(Underlying, Lots, 0, Exchange);
        PnL := PnL + (FEntryPrice - ATick.LTP) * Lots;
        FInPosition := False;
        FTicksSinceExit := 0;
        Exit;
      end;
    end;

    Exit; // no new entry while in position
  end;

  { ── Cooldown ── }
  Inc(FTicksSinceExit);
  if FTicksSinceExit < FCooldownTicks then Exit;

  { ── Entry logic ── }

  { Long: Z-score deeply negative AND RSI oversold }
  if (Z <= -FEntryZ) and (RSIVal <= FRSIOversold) then
  begin
    Buy(Underlying, Lots, 0, Exchange);
    FInPosition := True;
    FPositionSide := 1;
    FEntryPrice := ATick.LTP;
    Exit;
  end;

  { Short: Z-score deeply positive AND RSI overbought }
  if (Z >= FEntryZ) and (RSIVal >= FRSIOverbought) then
  begin
    Sell(Underlying, Lots, 0, Exchange);
    FInPosition := True;
    FPositionSide := -1;
    FEntryPrice := ATick.LTP;
  end;
end;

procedure TMeanReversionStrategy.OnStop;
begin
  if FInPosition then
  begin
    if FPositionSide = 1 then
      Sell(Underlying, Lots, 0, Exchange)
    else
      Buy(Underlying, Lots, 0, Exchange);
    FInPosition := False;
  end;
end;

initialization
  RegisterStrategy('MeanReversion', TMeanReversionStrategy);

end.
