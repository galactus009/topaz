{
  Topaz.Strategy.ORB -- Opening Range Breakout strategy.

  Builds 1-minute candles from tick data, establishes the opening range
  from the first N candles, then trades breakouts with volume confirmation.

  Phase 1 (Forming):  Accumulate first RangeCandles 1-min candles,
                       track range_high and range_low.
  Phase 2 (Waiting):  Watch for close above range_high (buy) or below
                       range_low (sell) with volume surge confirmation.
  Phase 3 (Active):   Manage position with hard stop + trailing stop.
  Exit:               Stop loss, trailing stop, force exit at 15:20,
                       or max trades reached.

  Parameters (set via properties before starting):
    RangeCandles     -- number of 1-min candles for opening range (default 15)
    StopLossPct      -- hard stop as % from entry (default 0.5)
    TrailingStopPct  -- trailing stop as % from peak (default 0.35)
    VolumeSurgeMult  -- volume must be >= avg * mult to confirm (default 1.2)
    MaxTrades        -- max entries per day (default 2)
    AllowShort       -- allow short entries on range_low break (default True)
}
unit Topaz.Strategy.ORB;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  SysUtils, Math, DateUtils, Apollo.Broker, Topaz.EventTypes, Topaz.Strategy,
  Topaz.Indicators;

type
  TORBPhase = (opForming, opWaiting, opActive);

  TMinuteCandle = record
    Open: Double;
    High: Double;
    Low: Double;
    Close: Double;
    Volume: Int64;
    StartVolume: Int64;   // cumulative volume at candle open
    Started: Boolean;
  end;

  TORBStrategy = class(TStrategy)
  private
    FRangeCandles: Integer;
    FStopLossPct: Double;
    FTrailingStopPct: Double;
    FVolumeSurgeMult: Double;
    FMaxTrades: Integer;
    FAllowShort: Boolean;

    FPhase: TORBPhase;
    FRangeHigh: Double;
    FRangeLow: Double;
    FCandleCount: Integer;

    { 1-minute candle builder }
    FCurrentCandle: TMinuteCandle;
    FCandleStartSec: Int64;   // Unix second when current candle opened
    FFirstTickSec: Int64;     // Unix second of the very first tick
    FGotFirstTick: Boolean;

    { Completed candle volumes for average calculation }
    FVolumes: array[0..63] of Int64;
    FVolCount: Integer;

    { Position management }
    FInPosition: Boolean;
    FPositionSide: Integer;  // +1 = long, -1 = short
    FEntryPrice: Double;
    FPeakPrice: Double;      // best price since entry (for trailing)
    FTradeCount: Integer;
    FDayDone: Boolean;       // true after force exit or max trades
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  private
    procedure OpenCandle(Price: Double; CumVolume: Int64; TickSec: Int64);
    procedure CloseCandle;
    procedure ProcessCandle(const AC: TMinuteCandle);
    procedure TryEntry(const AC: TMinuteCandle);
    procedure ManagePosition(Price: Double);
    procedure ExitPosition(Price: Double);
    function AvgVolume: Double;
    function CurrentTimePastExit: Boolean;
  public
    constructor Create;
    function DeclareParams: TArray<TStrategyParam>; override;
    procedure ApplyParam(const AName, AValue: AnsiString); override;
    function GetParamValue(const AName: AnsiString): AnsiString; override;
    property RangeCandles: Integer read FRangeCandles write FRangeCandles;
    property StopLossPct: Double read FStopLossPct write FStopLossPct;
    property TrailingStopPct: Double read FTrailingStopPct write FTrailingStopPct;
    property VolumeSurgeMult: Double read FVolumeSurgeMult write FVolumeSurgeMult;
    property MaxTrades: Integer read FMaxTrades write FMaxTrades;
    property AllowShort: Boolean read FAllowShort write FAllowShort;
  end;

implementation

const
  CANDLE_DURATION_SEC = 60;
  FORCE_EXIT_HOUR    = 15;
  FORCE_EXIT_MIN     = 20;

function MkParam(const AName, ADisplay: AnsiString; AKind: TParamKind; const AValue: AnsiString): TStrategyParam;
begin
  Result.Name := AName;
  Result.Display := ADisplay;
  Result.Kind := AKind;
  Result.Value := AValue;
end;

{ ── Constructor ── }

constructor TORBStrategy.Create;
begin
  inherited Create;
  FRangeCandles := 15;
  FStopLossPct := 0.5;
  FTrailingStopPct := 0.35;
  FVolumeSurgeMult := 1.2;
  FMaxTrades := 2;
  FAllowShort := True;
end;

function TORBStrategy.DeclareParams: TArray<TStrategyParam>;
begin
  SetLength(Result, 6);
  Result[0] := MkParam('range_candles', 'Range Candles', pkInteger, IntToStr(FRangeCandles));
  Result[1] := MkParam('stop_loss_pct', 'Stop Loss %', pkFloat, FloatToStr(FStopLossPct));
  Result[2] := MkParam('trailing_stop_pct', 'Trailing Stop %', pkFloat, FloatToStr(FTrailingStopPct));
  Result[3] := MkParam('volume_surge_mult', 'Volume Surge Mult', pkFloat, FloatToStr(FVolumeSurgeMult));
  Result[4] := MkParam('max_trades', 'Max Trades', pkInteger, IntToStr(FMaxTrades));
  Result[5] := MkParam('allow_short', 'Allow Short', pkBoolean, BoolToStr(FAllowShort, True));
end;

procedure TORBStrategy.ApplyParam(const AName, AValue: AnsiString);
begin
  if AName = 'range_candles' then FRangeCandles := StrToIntDef(string(AValue), FRangeCandles)
  else if AName = 'stop_loss_pct' then FStopLossPct := StrToFloatDef(string(AValue), FStopLossPct)
  else if AName = 'trailing_stop_pct' then FTrailingStopPct := StrToFloatDef(string(AValue), FTrailingStopPct)
  else if AName = 'volume_surge_mult' then FVolumeSurgeMult := StrToFloatDef(string(AValue), FVolumeSurgeMult)
  else if AName = 'max_trades' then FMaxTrades := StrToIntDef(string(AValue), FMaxTrades)
  else if AName = 'allow_short' then FAllowShort := (AValue = 'True') or (AValue = 'true') or (AValue = '1');
end;

function TORBStrategy.GetParamValue(const AName: AnsiString): AnsiString;
begin
  if AName = 'range_candles' then Result := IntToStr(FRangeCandles)
  else if AName = 'stop_loss_pct' then Result := FloatToStr(FStopLossPct)
  else if AName = 'trailing_stop_pct' then Result := FloatToStr(FTrailingStopPct)
  else if AName = 'volume_surge_mult' then Result := FloatToStr(FVolumeSurgeMult)
  else if AName = 'max_trades' then Result := IntToStr(FMaxTrades)
  else if AName = 'allow_short' then Result := BoolToStr(FAllowShort, True)
  else Result := '';
end;

{ ── Lifecycle ── }

procedure TORBStrategy.OnStart;
begin
  inherited;
  FPhase := opForming;
  FRangeHigh := -1e18;
  FRangeLow := 1e18;
  FCandleCount := 0;
  FVolCount := 0;
  FInPosition := False;
  FPositionSide := 0;
  FEntryPrice := 0;
  FPeakPrice := 0;
  FTradeCount := 0;
  FDayDone := False;
  FGotFirstTick := False;
  FCurrentCandle.Started := False;
end;

procedure TORBStrategy.OnStop;
begin
  if FInPosition then
    ExitPosition(0);
end;

{ ── Tick processing ── }

procedure TORBStrategy.OnTick(const ATick: TTickEvent);
var
  TickSec: Int64;
begin
  if FDayDone then Exit;
  if not WarmedUp then Exit;

  { Force exit check by wall clock }
  if CurrentTimePastExit then
  begin
    if FInPosition then
      ExitPosition(ATick.LTP);
    FDayDone := True;
    Exit;
  end;

  { Derive a tick-second from wall clock (used for candle boundaries) }
  TickSec := DateTimeToUnix(Now);

  { First tick initializes candle timing }
  if not FGotFirstTick then
  begin
    FFirstTickSec := TickSec;
    FGotFirstTick := True;
    OpenCandle(ATick.LTP, ATick.Volume, TickSec);
  end;

  { Update current candle with this tick }
  if not FCurrentCandle.Started then
    OpenCandle(ATick.LTP, ATick.Volume, TickSec);

  with FCurrentCandle do
  begin
    if ATick.LTP > High then High := ATick.LTP;
    if ATick.LTP < Low then Low := ATick.LTP;
    Close := ATick.LTP;
  end;

  { Check if candle duration elapsed }
  if (TickSec - FCandleStartSec) >= CANDLE_DURATION_SEC then
  begin
    { Finalize volume as delta from cumulative }
    FCurrentCandle.Volume := ATick.Volume - FCurrentCandle.StartVolume;
    if FCurrentCandle.Volume < 0 then
      FCurrentCandle.Volume := 0;
    CloseCandle;
    { Start next candle }
    OpenCandle(ATick.LTP, ATick.Volume, TickSec);
  end;

  { If in active position, manage it on every tick }
  if FInPosition then
    ManagePosition(ATick.LTP);
end;

{ ── Candle helpers ── }

procedure TORBStrategy.OpenCandle(Price: Double; CumVolume: Int64; TickSec: Int64);
begin
  FCurrentCandle.Open := Price;
  FCurrentCandle.High := Price;
  FCurrentCandle.Low := Price;
  FCurrentCandle.Close := Price;
  FCurrentCandle.StartVolume := CumVolume;
  FCurrentCandle.Volume := 0;
  FCurrentCandle.Started := True;
  FCandleStartSec := TickSec;
end;

procedure TORBStrategy.CloseCandle;
begin
  ProcessCandle(FCurrentCandle);
  FCurrentCandle.Started := False;
end;

procedure TORBStrategy.ProcessCandle(const AC: TMinuteCandle);
begin
  { Store volume for average calculation }
  if FVolCount < Length(FVolumes) then
  begin
    FVolumes[FVolCount] := AC.Volume;
    Inc(FVolCount);
  end
  else
  begin
    { Shift left and append }
    Move(FVolumes[1], FVolumes[0], (Length(FVolumes) - 1) * SizeOf(Int64));
    FVolumes[High(FVolumes)] := AC.Volume;
  end;

  case FPhase of
    opForming:
    begin
      if AC.High > FRangeHigh then FRangeHigh := AC.High;
      if AC.Low < FRangeLow then FRangeLow := AC.Low;
      Inc(FCandleCount);
      if FCandleCount >= FRangeCandles then
        FPhase := opWaiting;
    end;

    opWaiting:
      TryEntry(AC);

    opActive:
      ; { position managed in OnTick per-tick }
  end;
end;

{ ── Entry logic ── }

procedure TORBStrategy.TryEntry(const AC: TMinuteCandle);
var
  AvgVol: Double;
  HasSurge: Boolean;
  Qty: Integer;
begin
  if FTradeCount >= FMaxTrades then
  begin
    FDayDone := True;
    Exit;
  end;
  if FInPosition then Exit;

  AvgVol := AvgVolume;
  HasSurge := (AvgVol > 0) and (AC.Volume >= AvgVol * FVolumeSurgeMult);

  Qty := Lots;
  if Qty <= 0 then Qty := 1;

  { Bullish breakout: close above range high with volume surge }
  if (AC.Close > FRangeHigh) and HasSurge then
  begin
    Buy(Underlying, Qty, 0, Exchange);
    FInPosition := True;
    FPositionSide := 1;
    FEntryPrice := AC.Close;
    FPeakPrice := AC.Close;
    FPhase := opActive;
    Inc(FTradeCount);
    Exit;
  end;

  { Bearish breakout: close below range low with volume surge }
  if FAllowShort and (AC.Close < FRangeLow) and HasSurge then
  begin
    Sell(Underlying, Qty, 0, Exchange);
    FInPosition := True;
    FPositionSide := -1;
    FEntryPrice := AC.Close;
    FPeakPrice := AC.Close;
    FPhase := opActive;
    Inc(FTradeCount);
    Exit;
  end;
end;

{ ── Position management ── }

procedure TORBStrategy.ManagePosition(Price: Double);
var
  PnLPct, TrailPct: Double;
begin
  if not FInPosition then Exit;

  { Update peak for trailing stop }
  if FPositionSide = 1 then
  begin
    if Price > FPeakPrice then FPeakPrice := Price;
  end
  else
  begin
    if Price < FPeakPrice then FPeakPrice := Price;
  end;

  { PnL % from entry }
  if FEntryPrice > 0 then
  begin
    if FPositionSide = 1 then
      PnLPct := ((Price - FEntryPrice) / FEntryPrice) * 100
    else
      PnLPct := ((FEntryPrice - Price) / FEntryPrice) * 100;
  end
  else
    PnLPct := 0;

  { Update strategy PnL property }
  if FPositionSide = 1 then
    PnL := (Price - FEntryPrice) * Lots
  else
    PnL := (FEntryPrice - Price) * Lots;

  { Hard stop loss }
  if PnLPct <= -FStopLossPct then
  begin
    ExitPosition(Price);
    Exit;
  end;

  { Trailing stop: % drawdown from peak }
  if FPositionSide = 1 then
  begin
    if FPeakPrice > 0 then
      TrailPct := ((FPeakPrice - Price) / FPeakPrice) * 100
    else
      TrailPct := 0;
  end
  else
  begin
    if FPeakPrice > 0 then
      TrailPct := ((Price - FPeakPrice) / FPeakPrice) * 100
    else
      TrailPct := 0;
  end;

  if (TrailPct > FTrailingStopPct) and (PnLPct > 0) then
    ExitPosition(Price);
end;

procedure TORBStrategy.ExitPosition(Price: Double);
var
  Qty: Integer;
begin
  if not FInPosition then Exit;

  Qty := Lots;
  if Qty <= 0 then Qty := 1;

  if FPositionSide = 1 then
    Sell(Underlying, Qty, 0, Exchange)
  else
    Buy(Underlying, Qty, 0, Exchange);

  FInPosition := False;
  FPositionSide := 0;

  { After exit, go back to waiting for next breakout (if trades remain) }
  if FTradeCount < FMaxTrades then
    FPhase := opWaiting
  else
    FDayDone := True;
end;

{ ── Utility ── }

function TORBStrategy.AvgVolume: Double;
var
  I: Integer;
  Sum: Int64;
begin
  if FVolCount = 0 then Exit(0);
  Sum := 0;
  for I := 0 to FVolCount - 1 do
    Sum := Sum + FVolumes[I];
  Result := Sum / FVolCount;
end;

function TORBStrategy.CurrentTimePastExit: Boolean;
var
  H, M, S, MS: Word;
begin
  DecodeTime(Now, H, M, S, MS);
  Result := (H > FORCE_EXIT_HOUR) or
            ((H = FORCE_EXIT_HOUR) and (M >= FORCE_EXIT_MIN));
end;

initialization
  RegisterStrategy('ORB', TORBStrategy);

end.
