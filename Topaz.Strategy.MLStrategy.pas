{
  MLStrategy — Full integration: Apollo + Indicators + XGBoost.

  A Topaz strategy that:
  1. Computes RSI, MACD, Bollinger %B, VWAP deviation, OBV trend
     from live tick data (via Topaz.Indicators)
  2. Feeds the 8-feature vector into a pre-trained XGBoost model
  3. Places buy/sell orders through Apollo based on ML prediction

  The model should be trained offline on historical data with the
  same 8 features. See TrainModel.pas for the training example.

  Features (8):
    [0] RSI(14)
    [1] MACD histogram
    [2] Bollinger %B
    [3] VWAP deviation %
    [4] EMA20 - EMA50 crossover (normalized)
    [5] ROC(12)
    [6] Stochastic %K
    [7] Spread (ask-bid) / LTP * 10000 (bps)
}
unit Topaz.Strategy.MLStrategy;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  SysUtils, Apollo.Broker, Topaz.EventTypes, Topaz.Strategy,
  Topaz.Indicators, XGBoost.Wrapper;

type
  TMLStrategy = class(TStrategy)
  private
    FModel: TBooster;
    FModelDM: TDMatrix;

    FRSI: TRSI;
    FMACD: TMACD;
    FBB: TBollingerBands;
    FVWAP: TVWAP;
    FEMA20: TEMA;
    FEMA50: TEMA;
    FROC: TROC;
    FStoch: TStochastic;

    FModelPath: AnsiString;
    FThresholdBuy: Double;
    FThresholdSell: Double;
    FTicksSinceSignal: Integer;
    FCooldown: Integer;
    FInPosition: Boolean;
    FPositionSide: Integer;  // 1=long, -1=short
    FWarmupTicks: Integer;
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  public
    constructor Create;
    property ModelPath: AnsiString read FModelPath write FModelPath;
    property ThresholdBuy: Double read FThresholdBuy write FThresholdBuy;
    property ThresholdSell: Double read FThresholdSell write FThresholdSell;
    property Cooldown: Integer read FCooldown write FCooldown;
  end;

implementation

const
  NUM_FEATURES = 8;
  DEFAULT_WARMUP = 60;
  DEFAULT_COOLDOWN = 30;

constructor TMLStrategy.Create;
begin
  inherited Create;
  FModelPath := '';  // auto-derived in OnStart
  FThresholdBuy := 0.65;
  FThresholdSell := 0.35;
  FCooldown := DEFAULT_COOLDOWN;
  FWarmupTicks := DEFAULT_WARMUP;
  FInPosition := False;
  FPositionSide := 0;
end;

procedure TMLStrategy.OnStart;
var
  Zeros: array[0..NUM_FEATURES-1] of Single;
begin
  FRSI.Init(14);
  FMACD.Init(12, 26, 9);
  FBB.Init(20, 2.0);
  FVWAP.Init;
  FEMA20.Init(20);
  FEMA50.Init(50);
  FROC.Init(12);
  FStoch.Init(14, 3);

  if FModelPath = '' then
    FModelPath := ModelFilePath('mlstrategy', Underlying);

  FillChar(Zeros, SizeOf(Zeros), 0);
  FModelDM := TDMatrix.Create(Zeros, 1, NUM_FEATURES);
  FModel := TBooster.Create([FModelDM]);
  FModel.LoadModel(FModelPath);

  FTicksSinceSignal := FCooldown;
end;

procedure TMLStrategy.OnTick(const ATick: TTickEvent);
var
  Features: array[0..NUM_FEATURES-1] of Single;
  DM: TDMatrix;
  Preds: TSingleArray;
  Prob: Double;
  Spread: Double;
begin
  // Update all indicators
  FRSI.Update(ATick.LTP);
  FMACD.Update(ATick.LTP);
  FBB.Update(ATick.LTP);
  FVWAP.Update(ATick.LTP, ATick.Volume);
  FEMA20.Update(ATick.LTP);
  FEMA50.Update(ATick.LTP);
  FROC.Update(ATick.LTP);
  FStoch.Update(ATick.LTP, ATick.LTP, ATick.LTP);  // using LTP as H/L/C for tick data

  Dec(FWarmupTicks);
  if FWarmupTicks > 0 then Exit;

  Inc(FTicksSinceSignal);
  if FTicksSinceSignal < FCooldown then Exit;

  // Build feature vector
  Features[0] := FRSI.Value;
  Features[1] := FMACD.Histogram;
  Features[2] := FBB.PctB(ATick.LTP);
  if FVWAP.Value > 0 then
    Features[3] := ((ATick.LTP - FVWAP.Value) / FVWAP.Value) * 100
  else
    Features[3] := 0;
  if FEMA50.Value > 0 then
    Features[4] := (FEMA20.Value - FEMA50.Value) / FEMA50.Value * 100
  else
    Features[4] := 0;
  Features[5] := FROC.Value;
  Features[6] := FStoch.K;
  Spread := ATick.Ask - ATick.Bid;
  if ATick.LTP > 0 then
    Features[7] := (Spread / ATick.LTP) * 10000
  else
    Features[7] := 0;

  // Predict
  DM := TDMatrix.Create(Features, 1, NUM_FEATURES);
  try
    Preds := FModel.Predict(DM);
    if Length(Preds) = 0 then Exit;
    Prob := Preds[0];
  finally
    DM.Free;
  end;

  // Act on signal
  if (Prob > FThresholdBuy) and (not FInPosition) then
  begin
    Buy(Underlying, Lots, 0, Exchange);
    FInPosition := True;
    FPositionSide := 1;
    FTicksSinceSignal := 0;
    PnL := PnL;  // touch to update GUI
  end
  else if (Prob < FThresholdSell) and FInPosition and (FPositionSide = 1) then
  begin
    Sell(Underlying, Lots, 0, Exchange);
    FInPosition := False;
    FPositionSide := 0;
    FTicksSinceSignal := 0;
  end
  else if (Prob < FThresholdSell) and (not FInPosition) then
  begin
    Sell(Underlying, Lots, 0, Exchange);
    FInPosition := True;
    FPositionSide := -1;
    FTicksSinceSignal := 0;
  end
  else if (Prob > FThresholdBuy) and FInPosition and (FPositionSide = -1) then
  begin
    Buy(Underlying, Lots, 0, Exchange);
    FInPosition := False;
    FPositionSide := 0;
    FTicksSinceSignal := 0;
  end;
end;

procedure TMLStrategy.OnStop;
begin
  // Square off if still in position
  if FInPosition then
  begin
    if FPositionSide = 1 then
      Sell(Underlying, Lots, 0, Exchange)
    else if FPositionSide = -1 then
      Buy(Underlying, Lots, 0, Exchange);
    FInPosition := False;
  end;

  FModel.Free;
  FModelDM.Free;
end;

initialization
  RegisterStrategy('MLStrategy', TMLStrategy);

end.
