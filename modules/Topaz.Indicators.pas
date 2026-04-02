{
  Topaz.Indicators — Streaming technical indicators for the hot path.

  All indicators are records (stack-allocated, zero heap after Init).
  Each has an Update method that accepts one price/tick and returns
  the current indicator value. Safe for SPSC ring buffer consumers.

  Indicators: EMA, SMA, RSI, MACD, BollingerBands, ATR, VWAP,
              Stochastic, ROC, OBV, Kalman
}
unit Topaz.Indicators;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

const
  MAX_PERIOD = 256;

type
  { ── EMA — Exponential Moving Average ── }
  TEMA = record
  private
    FAlpha: Double;
    FValue: Double;
    FReady: Boolean;
  public
    procedure Init(APeriod: Integer);
    function Update(APrice: Double): Double;
    function Value: Double;
    function Ready: Boolean;
  end;

  { ── SMA — Simple Moving Average ── }
  TSMA = record
  private
    FBuf: array[0..MAX_PERIOD-1] of Double;
    FSum: Double;
    FPeriod: Integer;
    FPos: Integer;
    FCount: Integer;
  public
    procedure Init(APeriod: Integer);
    function Update(APrice: Double): Double;
    function Value: Double;
    function Ready: Boolean;
  end;

  { ── RSI — Relative Strength Index ── }
  TRSI = record
  private
    FPeriod: Integer;
    FAvgGain: Double;
    FAvgLoss: Double;
    FPrev: Double;
    FCount: Integer;
    FValue: Double;
  public
    procedure Init(APeriod: Integer);
    function Update(APrice: Double): Double;
    function Value: Double;
    function Ready: Boolean;
  end;

  { ── MACD — Moving Average Convergence Divergence ── }
  TMACD = record
  private
    FFast: TEMA;
    FSlow: TEMA;
    FSignal: TEMA;
    FValue: Double;
    FSignalValue: Double;
    FHistogram: Double;
    FCount: Integer;
    FSlowPeriod: Integer;
  public
    procedure Init(AFast: Integer = 12; ASlow: Integer = 26; ASignal: Integer = 9);
    function Update(APrice: Double): Double;
    function Value: Double;
    function Signal: Double;
    function Histogram: Double;
    function Ready: Boolean;
  end;

  { ── Bollinger Bands ── }
  TBollingerBands = record
  private
    FSMA: TSMA;
    FBuf: array[0..MAX_PERIOD-1] of Double;
    FPeriod: Integer;
    FMult: Double;
    FPos: Integer;
    FCount: Integer;
    FMiddle: Double;
    FUpper: Double;
    FLower: Double;
    FWidth: Double;
  public
    procedure Init(APeriod: Integer = 20; AMultiplier: Double = 2.0);
    function Update(APrice: Double): Double;
    function Middle: Double;
    function Upper: Double;
    function Lower: Double;
    function Width: Double;
    function PctB(APrice: Double): Double;
    function Ready: Boolean;
  end;

  { ── ATR — Average True Range ── }
  TATR = record
  private
    FPeriod: Integer;
    FValue: Double;
    FPrevClose: Double;
    FCount: Integer;
  public
    procedure Init(APeriod: Integer = 14);
    function Update(AHigh, ALow, AClose: Double): Double;
    function Value: Double;
    function Ready: Boolean;
  end;

  { ── VWAP — Volume Weighted Average Price ── }
  TVWAP = record
  private
    FCumTPV: Double;
    FCumVol: Int64;
    FValue: Double;
  public
    procedure Init;
    procedure Reset;
    function Update(APrice: Double; AVolume: Int64): Double;
    function Value: Double;
  end;

  { ── Stochastic Oscillator ── }
  TStochastic = record
  private
    FHighBuf: array[0..MAX_PERIOD-1] of Double;
    FLowBuf: array[0..MAX_PERIOD-1] of Double;
    FPeriod: Integer;
    FPos: Integer;
    FCount: Integer;
    FK: Double;
    FDSmooth: TSMA;
  public
    procedure Init(APeriod: Integer = 14; ADPeriod: Integer = 3);
    function Update(AHigh, ALow, AClose: Double): Double;
    function K: Double;
    function D: Double;
    function Ready: Boolean;
  end;

  { ── ROC — Rate of Change (%) ── }
  TROC = record
  private
    FBuf: array[0..MAX_PERIOD-1] of Double;
    FPeriod: Integer;
    FPos: Integer;
    FCount: Integer;
    FValue: Double;
  public
    procedure Init(APeriod: Integer = 12);
    function Update(APrice: Double): Double;
    function Value: Double;
    function Ready: Boolean;
  end;

  { ── OBV — On Balance Volume ── }
  TOBV = record
  private
    FPrevClose: Double;
    FValue: Int64;
    FStarted: Boolean;
  public
    procedure Init;
    function Update(AClose: Double; AVolume: Int64): Int64;
    function Value: Int64;
  end;

  { ── Kalman Filter — 1D price filter with velocity ── }
  {
    State: [price, velocity]
    Estimates the true price and its rate of change (velocity).
    Q = process noise (how fast price can change; higher = more responsive)
    R = measurement noise (tick noise; higher = smoother)
  }
  TKalman = record
  private
    FX: Double;          // estimated price
    FV: Double;          // estimated velocity (price change per tick)
    FP00, FP01,
    FP10, FP11: Double;  // 2x2 error covariance
    FQ: Double;          // process noise
    FR: Double;          // measurement noise
    FStarted: Boolean;
  public
    procedure Init(AProcessNoise: Double = 0.01; AMeasurementNoise: Double = 1.0);
    function Update(AMeasured: Double): Double;
    function Price: Double;       // filtered price
    function Velocity: Double;    // estimated velocity (dp/dt)
    function Uncertainty: Double; // current estimation uncertainty
  end;

implementation

uses
  Math;

{ ═══════════════════════════════════════════════════════════════════ }
{  EMA                                                                }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TEMA.Init(APeriod: Integer);
begin
  FAlpha := 2.0 / (APeriod + 1);
  FValue := 0;
  FReady := False;
end;

function TEMA.Update(APrice: Double): Double;
begin
  if not FReady then
  begin
    FValue := APrice;
    FReady := True;
  end
  else
    FValue := APrice * FAlpha + FValue * (1.0 - FAlpha);
  Result := FValue;
end;

function TEMA.Value: Double;
begin
  Result := FValue;
end;

function TEMA.Ready: Boolean;
begin
  Result := FReady;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  SMA                                                                }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TSMA.Init(APeriod: Integer);
begin
  if APeriod > MAX_PERIOD then APeriod := MAX_PERIOD;
  FPeriod := APeriod;
  FSum := 0;
  FPos := 0;
  FCount := 0;
  FillChar(FBuf, SizeOf(FBuf), 0);
end;

function TSMA.Update(APrice: Double): Double;
begin
  if FCount >= FPeriod then
    FSum := FSum - FBuf[FPos];
  FBuf[FPos] := APrice;
  FSum := FSum + APrice;
  FPos := (FPos + 1) mod FPeriod;
  if FCount < FPeriod then Inc(FCount);
  Result := FSum / FCount;
end;

function TSMA.Value: Double;
begin
  if FCount > 0 then Result := FSum / FCount
  else Result := 0;
end;

function TSMA.Ready: Boolean;
begin
  Result := FCount >= FPeriod;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  RSI                                                                }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TRSI.Init(APeriod: Integer);
begin
  FPeriod := APeriod;
  FAvgGain := 0;
  FAvgLoss := 0;
  FPrev := 0;
  FCount := 0;
  FValue := 50;
end;

function TRSI.Update(APrice: Double): Double;
var
  Delta, Gain, Loss, RS: Double;
begin
  if FCount = 0 then
  begin
    FPrev := APrice;
    Inc(FCount);
    FValue := 50;
    Exit(50);
  end;

  Delta := APrice - FPrev;
  FPrev := APrice;

  if Delta > 0 then begin Gain := Delta; Loss := 0; end
  else begin Gain := 0; Loss := -Delta; end;

  Inc(FCount);

  if FCount <= FPeriod then
  begin
    FAvgGain := FAvgGain + Gain;
    FAvgLoss := FAvgLoss + Loss;
    if FCount = FPeriod then
    begin
      FAvgGain := FAvgGain / FPeriod;
      FAvgLoss := FAvgLoss / FPeriod;
    end
    else
    begin
      FValue := 50;
      Exit(50);
    end;
  end
  else
  begin
    FAvgGain := (FAvgGain * (FPeriod - 1) + Gain) / FPeriod;
    FAvgLoss := (FAvgLoss * (FPeriod - 1) + Loss) / FPeriod;
  end;

  if FAvgLoss = 0 then
    FValue := 100
  else
  begin
    RS := FAvgGain / FAvgLoss;
    FValue := 100 - (100 / (1 + RS));
  end;

  Result := FValue;
end;

function TRSI.Value: Double;
begin
  Result := FValue;
end;

function TRSI.Ready: Boolean;
begin
  Result := FCount > FPeriod;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  MACD                                                               }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TMACD.Init(AFast, ASlow, ASignal: Integer);
begin
  FFast.Init(AFast);
  FSlow.Init(ASlow);
  FSignal.Init(ASignal);
  FSlowPeriod := ASlow;
  FValue := 0;
  FSignalValue := 0;
  FHistogram := 0;
  FCount := 0;
end;

function TMACD.Update(APrice: Double): Double;
begin
  FFast.Update(APrice);
  FSlow.Update(APrice);
  Inc(FCount);

  FValue := FFast.Value - FSlow.Value;
  FSignalValue := FSignal.Update(FValue);
  FHistogram := FValue - FSignalValue;
  Result := FValue;
end;

function TMACD.Value: Double;
begin
  Result := FValue;
end;

function TMACD.Signal: Double;
begin
  Result := FSignalValue;
end;

function TMACD.Histogram: Double;
begin
  Result := FHistogram;
end;

function TMACD.Ready: Boolean;
begin
  Result := FCount > FSlowPeriod;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Bollinger Bands                                                    }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TBollingerBands.Init(APeriod: Integer; AMultiplier: Double);
begin
  if APeriod > MAX_PERIOD then APeriod := MAX_PERIOD;
  FSMA.Init(APeriod);
  FPeriod := APeriod;
  FMult := AMultiplier;
  FPos := 0;
  FCount := 0;
  FMiddle := 0;
  FUpper := 0;
  FLower := 0;
  FWidth := 0;
  FillChar(FBuf, SizeOf(FBuf), 0);
end;

function TBollingerBands.Update(APrice: Double): Double;
var
  I, N: Integer;
  Mean, Variance, StdDev: Double;
begin
  FMiddle := FSMA.Update(APrice);
  FBuf[FPos] := APrice;
  FPos := (FPos + 1) mod FPeriod;
  if FCount < FPeriod then Inc(FCount);

  N := FCount;
  Mean := FMiddle;
  Variance := 0;
  for I := 0 to N - 1 do
    Variance := Variance + Sqr(FBuf[I] - Mean);
  Variance := Variance / N;
  StdDev := Sqrt(Variance);

  FUpper := Mean + FMult * StdDev;
  FLower := Mean - FMult * StdDev;
  if FLower > 0 then
    FWidth := (FUpper - FLower) / Mean * 100
  else
    FWidth := 0;

  Result := FMiddle;
end;

function TBollingerBands.Middle: Double;
begin Result := FMiddle; end;

function TBollingerBands.Upper: Double;
begin Result := FUpper; end;

function TBollingerBands.Lower: Double;
begin Result := FLower; end;

function TBollingerBands.Width: Double;
begin Result := FWidth; end;

function TBollingerBands.PctB(APrice: Double): Double;
begin
  if FUpper <> FLower then
    Result := (APrice - FLower) / (FUpper - FLower)
  else
    Result := 0.5;
end;

function TBollingerBands.Ready: Boolean;
begin
  Result := FCount >= FPeriod;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  ATR                                                                }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TATR.Init(APeriod: Integer);
begin
  FPeriod := APeriod;
  FValue := 0;
  FPrevClose := 0;
  FCount := 0;
end;

function TATR.Update(AHigh, ALow, AClose: Double): Double;
var
  TR: Double;
begin
  if FCount = 0 then
  begin
    TR := AHigh - ALow;
    FValue := TR;
    FPrevClose := AClose;
    Inc(FCount);
    Exit(FValue);
  end;

  TR := Max(AHigh - ALow, Max(Abs(AHigh - FPrevClose), Abs(ALow - FPrevClose)));
  FPrevClose := AClose;
  Inc(FCount);

  if FCount <= FPeriod then
    FValue := FValue + (TR - FValue) / FCount
  else
    FValue := (FValue * (FPeriod - 1) + TR) / FPeriod;

  Result := FValue;
end;

function TATR.Value: Double;
begin
  Result := FValue;
end;

function TATR.Ready: Boolean;
begin
  Result := FCount >= FPeriod;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  VWAP                                                               }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TVWAP.Init;
begin
  FCumTPV := 0;
  FCumVol := 0;
  FValue := 0;
end;

procedure TVWAP.Reset;
begin
  Init;
end;

function TVWAP.Update(APrice: Double; AVolume: Int64): Double;
begin
  FCumTPV := FCumTPV + APrice * AVolume;
  FCumVol := FCumVol + AVolume;
  if FCumVol > 0 then
    FValue := FCumTPV / FCumVol
  else
    FValue := APrice;
  Result := FValue;
end;

function TVWAP.Value: Double;
begin
  Result := FValue;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Stochastic                                                         }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TStochastic.Init(APeriod, ADPeriod: Integer);
begin
  if APeriod > MAX_PERIOD then APeriod := MAX_PERIOD;
  FPeriod := APeriod;
  FPos := 0;
  FCount := 0;
  FK := 50;
  FDSmooth.Init(ADPeriod);
  FillChar(FHighBuf, SizeOf(FHighBuf), 0);
  FillChar(FLowBuf, SizeOf(FLowBuf), 0);
end;

function TStochastic.Update(AHigh, ALow, AClose: Double): Double;
var
  I, N: Integer;
  HH, LL: Double;
begin
  FHighBuf[FPos] := AHigh;
  FLowBuf[FPos] := ALow;
  FPos := (FPos + 1) mod FPeriod;
  if FCount < FPeriod then Inc(FCount);

  N := FCount;
  HH := FHighBuf[0];
  LL := FLowBuf[0];
  for I := 1 to N - 1 do
  begin
    if FHighBuf[I] > HH then HH := FHighBuf[I];
    if FLowBuf[I] < LL then LL := FLowBuf[I];
  end;

  if HH <> LL then
    FK := ((AClose - LL) / (HH - LL)) * 100
  else
    FK := 50;

  FDSmooth.Update(FK);
  Result := FK;
end;

function TStochastic.K: Double;
begin Result := FK; end;

function TStochastic.D: Double;
begin Result := FDSmooth.Value; end;

function TStochastic.Ready: Boolean;
begin
  Result := FCount >= FPeriod;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  ROC                                                                }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TROC.Init(APeriod: Integer);
begin
  if APeriod > MAX_PERIOD then APeriod := MAX_PERIOD;
  FPeriod := APeriod;
  FPos := 0;
  FCount := 0;
  FValue := 0;
  FillChar(FBuf, SizeOf(FBuf), 0);
end;

function TROC.Update(APrice: Double): Double;
var
  Old: Double;
begin
  if FCount >= FPeriod then
  begin
    Old := FBuf[FPos];
    if Old <> 0 then
      FValue := ((APrice - Old) / Old) * 100
    else
      FValue := 0;
  end
  else
    FValue := 0;

  FBuf[FPos] := APrice;
  FPos := (FPos + 1) mod FPeriod;
  if FCount < FPeriod then Inc(FCount);
  Result := FValue;
end;

function TROC.Value: Double;
begin Result := FValue; end;

function TROC.Ready: Boolean;
begin Result := FCount >= FPeriod; end;

{ ═══════════════════════════════════════════════════════════════════ }
{  OBV                                                                }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TOBV.Init;
begin
  FPrevClose := 0;
  FValue := 0;
  FStarted := False;
end;

function TOBV.Update(AClose: Double; AVolume: Int64): Int64;
begin
  if not FStarted then
  begin
    FPrevClose := AClose;
    FStarted := True;
    Result := 0;
    Exit;
  end;

  if AClose > FPrevClose then
    FValue := FValue + AVolume
  else if AClose < FPrevClose then
    FValue := FValue - AVolume;

  FPrevClose := AClose;
  Result := FValue;
end;

function TOBV.Value: Int64;
begin
  Result := FValue;
end;

{ ═══════════════════════════════════════════════════════════════════ }
{  Kalman Filter                                                      }
{ ═══════════════════════════════════════════════════════════════════ }

procedure TKalman.Init(AProcessNoise, AMeasurementNoise: Double);
begin
  FQ := AProcessNoise;
  FR := AMeasurementNoise;
  FX := 0;
  FV := 0;
  FP00 := 1; FP01 := 0;
  FP10 := 0; FP11 := 1;
  FStarted := False;
end;

function TKalman.Update(AMeasured: Double): Double;
var
  // Predicted state
  XP, VP: Double;
  // Predicted covariance
  PP00, PP01, PP10, PP11: Double;
  // Kalman gain
  S, K0, K1: Double;
  // Innovation
  Y: Double;
begin
  if not FStarted then
  begin
    FX := AMeasured;
    FV := 0;
    FStarted := True;
    Result := FX;
    Exit;
  end;

  // Predict: state = F * state  (F = [[1,1],[0,1]])
  XP := FX + FV;
  VP := FV;

  // Predict: P = F*P*F' + Q*I
  PP00 := FP00 + FP10 + FP01 + FP11 + FQ;
  PP01 := FP01 + FP11;
  PP10 := FP10 + FP11;
  PP11 := FP11 + FQ;

  // Update: innovation
  Y := AMeasured - XP;

  // S = H*P*H' + R  (H = [1, 0])
  S := PP00 + FR;

  // Kalman gain K = P*H'/S
  K0 := PP00 / S;
  K1 := PP10 / S;

  // Updated state
  FX := XP + K0 * Y;
  FV := VP + K1 * Y;

  // Updated covariance: P = (I - K*H) * PP
  FP00 := PP00 - K0 * PP00;
  FP01 := PP01 - K0 * PP01;
  FP10 := PP10 - K1 * PP00;
  FP11 := PP11 - K1 * PP01;

  Result := FX;
end;

function TKalman.Price: Double;
begin
  Result := FX;
end;

function TKalman.Velocity: Double;
begin
  Result := FV;
end;

function TKalman.Uncertainty: Double;
begin
  Result := FP00;
end;

end.
