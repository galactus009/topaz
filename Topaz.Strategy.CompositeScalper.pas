{
  Topaz.Strategy.CompositeScalper -- 8-factor composite scoring scalper.

  Combines 8 technical indicators into a single composite score (0-100).
  Each indicator produces a sub-score 0-100, then a weighted average
  determines the final signal.

  Factors:
    [0] ROC          -- momentum (rate of change)
    [1] EMA crossover -- fast/slow EMA trend
    [2] VWAP deviation -- mean-reversion signal
    [3] RSI          -- overbought/oversold
    [4] MACD histogram -- trend strength
    [5] Bollinger %B -- volatility band position
    [6] Volume ratio -- volume confirmation
    [7] ATR trend    -- volatility expansion/contraction

  Entry: composite > EntryThreshold -> buy
         composite < (100 - EntryThreshold) -> sell
  Exit:  ATR-based stop/target, trailing stop

  Parameters:
    EntryThreshold -- minimum score to trigger entry (default 55)
    StopATRMult    -- stop distance in ATR multiples (default 1.5)
    TargetATRMult  -- target distance in ATR multiples (default 2.0)
    Weights        -- array of 8 weights (default equal = 1.0 each)
}
unit Topaz.Strategy.CompositeScalper;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  SysUtils, Math, DateUtils, Apollo.Broker, Topaz.EventTypes, Topaz.Strategy,
  Topaz.Indicators;

const
  NUM_FACTORS = 8;

  { Factor indices }
  FACTOR_ROC       = 0;
  FACTOR_EMA_CROSS = 1;
  FACTOR_VWAP_DEV  = 2;
  FACTOR_RSI       = 3;
  FACTOR_MACD_HIST = 4;
  FACTOR_BOLL_B    = 5;
  FACTOR_VOL_RATIO = 6;
  FACTOR_ATR_TREND = 7;

type
  TCompositeScalper = class(TStrategy)
  private
    FEntryThreshold: Double;
    FStopATRMult: Double;
    FTargetATRMult: Double;
    FWeights: array[0..NUM_FACTORS - 1] of Double;

    { Indicators }
    FROC: TROC;
    FEMAFast: TEMA;
    FEMASlow: TEMA;
    FVWAP: TVWAP;
    FRSI: TRSI;
    FMACD: TMACD;
    FBollinger: TBollingerBands;
    FVolSMA: TSMA;
    FATR: TATR;
    FAtrSlow: TSMA;       // SMA of ATR for trend detection

    { Candle builder for ATR (1-min candles from ticks) }
    FCandleHigh: Double;
    FCandleLow: Double;
    FCandleClose: Double;
    FCandleStartSec: Int64;
    FCandleReady: Boolean;
    FGotFirstTick: Boolean;
    FPrevVolume: Int64;

    { Position state }
    FInPosition: Boolean;
    FPositionSide: Integer;   // +1 = long, -1 = short
    FEntryPrice: Double;
    FStopPrice: Double;
    FTargetPrice: Double;
    FPeakPrice: Double;       // for trailing stop
    FTrailingATR: Double;     // ATR at entry for trailing calculation

    FWarmupCount: Integer;
    FWarmupNeeded: Integer;

    { Factor scoring }
    function ScoreROC: Double;
    function ScoreEMACross: Double;
    function ScoreVWAPDev(Price: Double): Double;
    function ScoreRSI: Double;
    function ScoreMACDHist: Double;
    function ScoreBollingerB(Price: Double): Double;
    function ScoreVolumeRatio(TickVol: Int64): Double;
    function ScoreATRTrend: Double;
    function CompositeScore(Price: Double; TickVol: Int64): Double;

    procedure TryEntry(Price: Double; TickVol: Int64);
    procedure ManagePosition(Price: Double);
    procedure ExitPosition(Price: Double);
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  public
    constructor Create;
    property EntryThreshold: Double read FEntryThreshold write FEntryThreshold;
    property StopATRMult: Double read FStopATRMult write FStopATRMult;
    property TargetATRMult: Double read FTargetATRMult write FTargetATRMult;
    procedure SetWeight(AIndex: Integer; AValue: Double);
    function GetWeight(AIndex: Integer): Double;
  end;

implementation

const
  CANDLE_DURATION_SEC = 60;

{ ── Constructor ── }

constructor TCompositeScalper.Create;
var
  I: Integer;
begin
  inherited Create;
  FEntryThreshold := 55.0;
  FStopATRMult := 1.5;
  FTargetATRMult := 2.0;
  for I := 0 to NUM_FACTORS - 1 do
    FWeights[I] := 1.0;
  FInPosition := False;
end;

{ ── Weight accessors ── }

procedure TCompositeScalper.SetWeight(AIndex: Integer; AValue: Double);
begin
  if (AIndex >= 0) and (AIndex < NUM_FACTORS) then
    FWeights[AIndex] := AValue;
end;

function TCompositeScalper.GetWeight(AIndex: Integer): Double;
begin
  if (AIndex >= 0) and (AIndex < NUM_FACTORS) then
    Result := FWeights[AIndex]
  else
    Result := 0;
end;

{ ── Lifecycle ── }

procedure TCompositeScalper.OnStart;
begin
  FROC.Init(12);
  FEMAFast.Init(9);
  FEMASlow.Init(21);
  FVWAP.Init;
  FRSI.Init(14);
  FMACD.Init(12, 26, 9);
  FBollinger.Init(20, 2.0);
  FVolSMA.Init(20);
  FATR.Init(14);
  FAtrSlow.Init(10);

  FCandleHigh := 0;
  FCandleLow := 1e18;
  FCandleClose := 0;
  FCandleStartSec := 0;
  FCandleReady := False;
  FGotFirstTick := False;
  FPrevVolume := 0;

  FInPosition := False;
  FPositionSide := 0;
  FEntryPrice := 0;
  FStopPrice := 0;
  FTargetPrice := 0;
  FPeakPrice := 0;

  { Need enough ticks to warm up the slowest indicator (MACD slow=26 + signal=9) }
  FWarmupNeeded := 40;
  FWarmupCount := 0;
end;

procedure TCompositeScalper.OnStop;
begin
  if FInPosition then
    ExitPosition(0);
end;

{ ── Tick processing ── }

procedure TCompositeScalper.OnTick(const ATick: TTickEvent);
var
  TickSec: Int64;
  TickVol: Int64;
begin
  TickSec := DateTimeToUnix(Now);

  { Initialize candle on first tick }
  if not FGotFirstTick then
  begin
    FGotFirstTick := True;
    FCandleStartSec := TickSec;
    FCandleHigh := ATick.LTP;
    FCandleLow := ATick.LTP;
    FCandleClose := ATick.LTP;
  end;

  { Update candle high/low/close }
  if ATick.LTP > FCandleHigh then FCandleHigh := ATick.LTP;
  if ATick.LTP < FCandleLow then FCandleLow := ATick.LTP;
  FCandleClose := ATick.LTP;

  { Close candle every 60 seconds and feed ATR }
  if (TickSec - FCandleStartSec) >= CANDLE_DURATION_SEC then
  begin
    FATR.Update(FCandleHigh, FCandleLow, FCandleClose);
    FAtrSlow.Update(FATR.Value);

    { Reset candle }
    FCandleHigh := ATick.LTP;
    FCandleLow := ATick.LTP;
    FCandleClose := ATick.LTP;
    FCandleStartSec := TickSec;
    FCandleReady := FATR.Ready;
  end;

  { Update streaming indicators }
  FROC.Update(ATick.LTP);
  FEMAFast.Update(ATick.LTP);
  FEMASlow.Update(ATick.LTP);
  FRSI.Update(ATick.LTP);
  FMACD.Update(ATick.LTP);
  FBollinger.Update(ATick.LTP);

  { Volume: compute per-tick delta }
  if ATick.Volume >= FPrevVolume then
    TickVol := ATick.Volume - FPrevVolume
  else
    TickVol := 0;
  FPrevVolume := ATick.Volume;
  FVolSMA.Update(TickVol);

  { VWAP update }
  FVWAP.Update(ATick.LTP, ATick.Volume);

  { Warmup }
  Inc(FWarmupCount);
  if FWarmupCount < FWarmupNeeded then Exit;

  { Position management takes priority }
  if FInPosition then
    ManagePosition(ATick.LTP)
  else
    TryEntry(ATick.LTP, TickVol);
end;

{ ── Factor scoring (each returns 0..100) ── }

function TCompositeScalper.ScoreROC: Double;
var
  R: Double;
begin
  { ROC > 0 is bullish; map [-2..+2]% to [0..100] }
  R := FROC.Value;
  Result := EnsureRange((R + 2.0) / 4.0 * 100.0, 0, 100);
end;

function TCompositeScalper.ScoreEMACross: Double;
var
  FastV, SlowV, Diff, Pct: Double;
begin
  FastV := FEMAFast.Value;
  SlowV := FEMASlow.Value;
  if SlowV > 0 then
    Pct := ((FastV - SlowV) / SlowV) * 100
  else
    Pct := 0;
  { Map [-0.5..+0.5]% to [0..100] }
  Diff := EnsureRange((Pct + 0.5) / 1.0 * 100.0, 0, 100);
  Result := Diff;
end;

function TCompositeScalper.ScoreVWAPDev(Price: Double): Double;
var
  Dev: Double;
begin
  { Price above VWAP is bullish; map [-1..+1]% to [0..100] }
  if FVWAP.Value > 0 then
    Dev := ((Price - FVWAP.Value) / FVWAP.Value) * 100
  else
    Dev := 0;
  Result := EnsureRange((Dev + 1.0) / 2.0 * 100.0, 0, 100);
end;

function TCompositeScalper.ScoreRSI: Double;
begin
  { RSI is already 0..100; higher = more bullish for momentum }
  Result := FRSI.Value;
end;

function TCompositeScalper.ScoreMACDHist: Double;
var
  H: Double;
begin
  { MACD histogram > 0 is bullish; normalize roughly }
  H := FMACD.Histogram;
  { Map [-5..+5] to [0..100] (adjust for typical index scale) }
  Result := EnsureRange((H + 5.0) / 10.0 * 100.0, 0, 100);
end;

function TCompositeScalper.ScoreBollingerB(Price: Double): Double;
var
  PctB: Double;
begin
  { %B: 0 = at lower band, 1 = at upper band }
  PctB := FBollinger.PctB(Price);
  Result := EnsureRange(PctB * 100.0, 0, 100);
end;

function TCompositeScalper.ScoreVolumeRatio(TickVol: Int64): Double;
var
  Ratio: Double;
begin
  { Volume above average is confirmation; map [0..3x] to [0..100] }
  if FVolSMA.Value > 0 then
    Ratio := TickVol / FVolSMA.Value
  else
    Ratio := 1.0;
  Result := EnsureRange((Ratio / 3.0) * 100.0, 0, 100);
end;

function TCompositeScalper.ScoreATRTrend: Double;
var
  Ratio: Double;
begin
  { ATR rising (above its SMA) suggests expanding volatility = opportunity }
  if FAtrSlow.Value > 0 then
    Ratio := FATR.Value / FAtrSlow.Value
  else
    Ratio := 1.0;
  { Map [0.5..1.5] to [0..100] }
  Result := EnsureRange((Ratio - 0.5) / 1.0 * 100.0, 0, 100);
end;

function TCompositeScalper.CompositeScore(Price: Double; TickVol: Int64): Double;
var
  Scores: array[0..NUM_FACTORS - 1] of Double;
  WeightSum, Total: Double;
  I: Integer;
begin
  Scores[FACTOR_ROC]       := ScoreROC;
  Scores[FACTOR_EMA_CROSS] := ScoreEMACross;
  Scores[FACTOR_VWAP_DEV]  := ScoreVWAPDev(Price);
  Scores[FACTOR_RSI]       := ScoreRSI;
  Scores[FACTOR_MACD_HIST] := ScoreMACDHist;
  Scores[FACTOR_BOLL_B]    := ScoreBollingerB(Price);
  Scores[FACTOR_VOL_RATIO] := ScoreVolumeRatio(TickVol);
  Scores[FACTOR_ATR_TREND] := ScoreATRTrend;

  Total := 0;
  WeightSum := 0;
  for I := 0 to NUM_FACTORS - 1 do
  begin
    Total := Total + Scores[I] * FWeights[I];
    WeightSum := WeightSum + FWeights[I];
  end;

  if WeightSum > 0 then
    Result := Total / WeightSum
  else
    Result := 50;
end;

{ ── Entry logic ── }

procedure TCompositeScalper.TryEntry(Price: Double; TickVol: Int64);
var
  Score: Double;
  AtrVal: Double;
  Qty: Integer;
begin
  if not FCandleReady then Exit;

  Score := CompositeScore(Price, TickVol);
  AtrVal := FATR.Value;
  if AtrVal <= 0 then Exit;

  Qty := Lots;
  if Qty <= 0 then Qty := 1;

  { Bullish entry }
  if Score > FEntryThreshold then
  begin
    Buy(Underlying, Qty, 0, Exchange);
    FInPosition := True;
    FPositionSide := 1;
    FEntryPrice := Price;
    FStopPrice := Price - AtrVal * FStopATRMult;
    FTargetPrice := Price + AtrVal * FTargetATRMult;
    FPeakPrice := Price;
    FTrailingATR := AtrVal;
    Exit;
  end;

  { Bearish entry }
  if Score < (100.0 - FEntryThreshold) then
  begin
    Sell(Underlying, Qty, 0, Exchange);
    FInPosition := True;
    FPositionSide := -1;
    FEntryPrice := Price;
    FStopPrice := Price + AtrVal * FStopATRMult;
    FTargetPrice := Price - AtrVal * FTargetATRMult;
    FPeakPrice := Price;
    FTrailingATR := AtrVal;
  end;
end;

{ ── Position management ── }

procedure TCompositeScalper.ManagePosition(Price: Double);
var
  TrailingStop: Double;
begin
  if not FInPosition then Exit;

  if FPositionSide = 1 then
  begin
    { Long position }
    PnL := (Price - FEntryPrice) * Lots;

    { Update peak for trailing }
    if Price > FPeakPrice then
      FPeakPrice := Price;

    { Target hit }
    if Price >= FTargetPrice then
    begin
      ExitPosition(Price);
      Exit;
    end;

    { Hard stop }
    if Price <= FStopPrice then
    begin
      ExitPosition(Price);
      Exit;
    end;

    { Trailing stop: 1 ATR below peak }
    TrailingStop := FPeakPrice - FTrailingATR;
    if (TrailingStop > FStopPrice) and (Price <= TrailingStop) then
    begin
      ExitPosition(Price);
      Exit;
    end;
  end
  else
  begin
    { Short position }
    PnL := (FEntryPrice - Price) * Lots;

    { Update peak (trough) for trailing }
    if Price < FPeakPrice then
      FPeakPrice := Price;

    { Target hit }
    if Price <= FTargetPrice then
    begin
      ExitPosition(Price);
      Exit;
    end;

    { Hard stop }
    if Price >= FStopPrice then
    begin
      ExitPosition(Price);
      Exit;
    end;

    { Trailing stop: 1 ATR above trough }
    TrailingStop := FPeakPrice + FTrailingATR;
    if (TrailingStop < FStopPrice) and (Price >= TrailingStop) then
    begin
      ExitPosition(Price);
      Exit;
    end;
  end;
end;

procedure TCompositeScalper.ExitPosition(Price: Double);
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
end;

initialization
  RegisterStrategy('CompositeScalper', TCompositeScalper);

end.
