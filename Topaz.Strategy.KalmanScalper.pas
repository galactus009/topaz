{
  KalmanScalper — Kalman-filtered XGBoost scalper strategy.

  Uses a Kalman filter to separate signal from noise in tick data,
  then feeds Kalman-derived features into XGBoost for entry/exit.

  Key insight: raw tick data is noisy. The Kalman filter estimates
  true price and velocity (rate of change). XGBoost classifies
  whether the Kalman velocity predicts a profitable scalp.

  Features (10):
    [0] Kalman price - raw price (filter deviation)
    [1] Kalman velocity (momentum signal)
    [2] Kalman uncertainty (regime: low=trending, high=volatile)
    [3] RSI(7) — short-term RSI for scalping
    [4] Bid-ask spread in bps
    [5] Volume acceleration (current vs SMA20 volume ratio)
    [6] Price ROC(5) — 5-tick rate of change
    [7] Kalman velocity acceleration (v - prev_v)
    [8] Bollinger %B(10) — short-term band position
    [9] Stochastic %K(7) — fast stochastic

  Designed for index futures / liquid stocks on 1-second tick data.

  Usage as Topaz strategy:
    Registered as 'KalmanScalper' — appears in Strategies dropdown.
    Set Underlying to e.g. 'NIFTY 50', Lots to 1.
    Requires signal_kalman.json model file trained with TrainKalman.
}
unit Topaz.Strategy.KalmanScalper;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  SysUtils, Thorium.Broker, Topaz.EventTypes, Topaz.Strategy,
  Topaz.Indicators, XGBoost.Wrapper;

type
  TKalmanScalper = class(TStrategy)
  private
    FModel: TBooster;
    FModelDM: TDMatrix;

    FKalman: TKalman;
    FRSI: TRSI;
    FBB: TBollingerBands;
    FStoch: TStochastic;
    FROC: TROC;
    FVolSMA: TSMA;

    FPrevVelocity: Double;
    FPrevVolume: Int64;

    FModelPath: AnsiString;
    FEntryThreshold: Double;
    FExitThreshold: Double;
    FCooldownTicks: Integer;
    FTicksSinceOrder: Integer;
    FMaxPositionTicks: Integer;
    FPositionTicks: Integer;

    FInPosition: Boolean;
    FPositionSide: Integer;
    FEntryPrice: Double;
    FTargetPoints: Double;
    FStopPoints: Double;
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  public
    constructor Create;
    function DeclareParams: TArray<TStrategyParam>; override;
    procedure ApplyParam(const AName, AValue: AnsiString); override;
    function GetParamValue(const AName: AnsiString): AnsiString; override;
    property ModelPath: AnsiString read FModelPath write FModelPath;
    property EntryThreshold: Double read FEntryThreshold write FEntryThreshold;
    property ExitThreshold: Double read FExitThreshold write FExitThreshold;
    property TargetPoints: Double read FTargetPoints write FTargetPoints;
    property StopPoints: Double read FStopPoints write FStopPoints;
  end;

implementation

const
  NUM_FEATURES = 10;

function MkParam(const AName, ADisplay: AnsiString; AKind: TParamKind; const AValue: AnsiString): TStrategyParam;
begin
  Result.Name := AName;
  Result.Display := ADisplay;
  Result.Kind := AKind;
  Result.Value := AValue;
end;

constructor TKalmanScalper.Create;
begin
  inherited Create;
  FModelPath := '';  // auto-derived in OnStart
  FEntryThreshold := 0.60;
  FExitThreshold := 0.40;
  FCooldownTicks := 15;
  FMaxPositionTicks := 120;
  FTargetPoints := 15.0;
  FStopPoints := 10.0;
  FInPosition := False;
end;

function TKalmanScalper.DeclareParams: TArray<TStrategyParam>;
begin
  SetLength(Result, 5);
  Result[0] := MkParam('entry_threshold', 'Entry Threshold', pkFloat, FloatToStr(FEntryThreshold));
  Result[1] := MkParam('exit_threshold', 'Exit Threshold', pkFloat, FloatToStr(FExitThreshold));
  Result[2] := MkParam('target_points', 'Target Points', pkFloat, FloatToStr(FTargetPoints));
  Result[3] := MkParam('stop_points', 'Stop Points', pkFloat, FloatToStr(FStopPoints));
  Result[4] := MkParam('cooldown_ticks', 'Cooldown Ticks', pkInteger, IntToStr(FCooldownTicks));
end;

procedure TKalmanScalper.ApplyParam(const AName, AValue: AnsiString);
begin
  if AName = 'entry_threshold' then FEntryThreshold := StrToFloatDef(string(AValue), FEntryThreshold)
  else if AName = 'exit_threshold' then FExitThreshold := StrToFloatDef(string(AValue), FExitThreshold)
  else if AName = 'target_points' then FTargetPoints := StrToFloatDef(string(AValue), FTargetPoints)
  else if AName = 'stop_points' then FStopPoints := StrToFloatDef(string(AValue), FStopPoints)
  else if AName = 'cooldown_ticks' then FCooldownTicks := StrToIntDef(string(AValue), FCooldownTicks);
end;

function TKalmanScalper.GetParamValue(const AName: AnsiString): AnsiString;
begin
  if AName = 'entry_threshold' then Result := FloatToStr(FEntryThreshold)
  else if AName = 'exit_threshold' then Result := FloatToStr(FExitThreshold)
  else if AName = 'target_points' then Result := FloatToStr(FTargetPoints)
  else if AName = 'stop_points' then Result := FloatToStr(FStopPoints)
  else if AName = 'cooldown_ticks' then Result := IntToStr(FCooldownTicks)
  else Result := '';
end;

procedure TKalmanScalper.OnStart;
var
  Zeros: array[0..NUM_FEATURES-1] of Single;
begin
  inherited;
  // Kalman: low process noise (smooth), moderate measurement noise
  FKalman.Init(0.005, 0.5);
  FRSI.Init(7);
  FBB.Init(10, 2.0);
  FStoch.Init(7, 3);
  FROC.Init(5);
  FVolSMA.Init(20);

  FPrevVelocity := 0;
  FPrevVolume := 0;
  FTicksSinceOrder := FCooldownTicks;

  if FModelPath = '' then
    FModelPath := ModelFilePath('kalmanscalper', Underlying);

  FillChar(Zeros, SizeOf(Zeros), 0);
  FModelDM := TDMatrix.Create(Zeros, 1, NUM_FEATURES);
  FModel := TBooster.Create([FModelDM]);
  FModel.LoadModel(FModelPath);
end;

procedure TKalmanScalper.OnTick(const ATick: TTickEvent);
var
  Features: array[0..NUM_FEATURES-1] of Single;
  DM: TDMatrix;
  Preds: TSingleArray;
  Prob: Double;
  KPrice, KVel, KUnc: Double;
  VelAccel, Spread, VolRatio: Double;
  PnLPoints: Double;
begin
  // Update Kalman filter
  FKalman.Update(ATick.LTP);
  KPrice := FKalman.Price;
  KVel := FKalman.Velocity;
  KUnc := FKalman.Uncertainty;
  VelAccel := KVel - FPrevVelocity;
  FPrevVelocity := KVel;

  // Update other indicators
  FRSI.Update(ATick.LTP);
  FBB.Update(ATick.LTP);
  FStoch.Update(ATick.LTP, ATick.LTP, ATick.LTP);
  FROC.Update(ATick.LTP);

  // Volume ratio
  if ATick.Volume > FPrevVolume then
    FVolSMA.Update(ATick.Volume - FPrevVolume)
  else
    FVolSMA.Update(0);
  FPrevVolume := ATick.Volume;

  if not WarmedUp then Exit;

  // If in position, check exits first
  if FInPosition then
  begin
    Inc(FPositionTicks);

    if FPositionSide = 1 then
      PnLPoints := ATick.LTP - FEntryPrice
    else
      PnLPoints := FEntryPrice - ATick.LTP;

    PnL := PnLPoints * Lots;

    // Target hit
    if PnLPoints >= FTargetPoints then
    begin
      if FPositionSide = 1 then Sell(Underlying, Lots, 0, Exchange)
      else Buy(Underlying, Lots, 0, Exchange);
      FInPosition := False;
      FTicksSinceOrder := 0;
      Exit;
    end;

    // Stop loss
    if PnLPoints <= -FStopPoints then
    begin
      if FPositionSide = 1 then Sell(Underlying, Lots, 0, Exchange)
      else Buy(Underlying, Lots, 0, Exchange);
      FInPosition := False;
      FTicksSinceOrder := 0;
      Exit;
    end;

    // Time exit
    if FPositionTicks >= FMaxPositionTicks then
    begin
      if FPositionSide = 1 then Sell(Underlying, Lots, 0, Exchange)
      else Buy(Underlying, Lots, 0, Exchange);
      FInPosition := False;
      FTicksSinceOrder := 0;
      Exit;
    end;

    Exit;  // don't enter new positions while holding
  end;

  // Cooldown
  Inc(FTicksSinceOrder);
  if FTicksSinceOrder < FCooldownTicks then Exit;

  // Build feature vector
  Spread := ATick.Ask - ATick.Bid;
  if FVolSMA.Value > 0 then
    VolRatio := (ATick.Volume - FPrevVolume) / FVolSMA.Value
  else
    VolRatio := 1.0;

  Features[0] := KPrice - ATick.LTP;      // Kalman deviation
  Features[1] := KVel;                     // Kalman velocity
  Features[2] := KUnc;                     // Kalman uncertainty
  Features[3] := FRSI.Value;               // RSI(7)
  if ATick.LTP > 0 then
    Features[4] := (Spread / ATick.LTP) * 10000  // spread bps
  else
    Features[4] := 0;
  Features[5] := VolRatio;                 // volume acceleration
  Features[6] := FROC.Value;               // ROC(5)
  Features[7] := VelAccel;                 // velocity acceleration
  Features[8] := FBB.PctB(ATick.LTP);      // Bollinger %B
  Features[9] := FStoch.K;                 // Stochastic %K

  // Predict
  DM := TDMatrix.Create(Features, 1, NUM_FEATURES);
  try
    Preds := FModel.Predict(DM);
    if Length(Preds) = 0 then Exit;
    Prob := Preds[0];
  finally
    DM.Free;
  end;

  // Entry signals
  if (Prob > FEntryThreshold) and (KVel > 0) then
  begin
    // Kalman velocity confirms upward momentum
    Buy(Underlying, Lots, 0, Exchange);
    FInPosition := True;
    FPositionSide := 1;
    FEntryPrice := ATick.LTP;
    FPositionTicks := 0;
    FTicksSinceOrder := 0;
  end
  else if (Prob < FExitThreshold) and (KVel < 0) then
  begin
    // Kalman velocity confirms downward momentum
    Sell(Underlying, Lots, 0, Exchange);
    FInPosition := True;
    FPositionSide := -1;
    FEntryPrice := ATick.LTP;
    FPositionTicks := 0;
    FTicksSinceOrder := 0;
  end;
end;

procedure TKalmanScalper.OnStop;
begin
  if FInPosition then
  begin
    if FPositionSide = 1 then
      Sell(Underlying, Lots, 0, Exchange)
    else
      Buy(Underlying, Lots, 0, Exchange);
    FInPosition := False;
  end;

  FModel.Free;
  FModelDM.Free;
end;

initialization
  RegisterStrategy('KalmanScalper', TKalmanScalper);

end.
