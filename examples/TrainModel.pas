{
  TrainModel — Offline model training for MLStrategy.

  Reads historical tick data from a CSV file, computes the same 8
  indicators used by MLStrategy, labels each sample based on future
  price movement, trains an XGBoost model, and saves it.

  CSV format: timestamp,ltp,bid,ask,volume
  Output: models/<strategy>_<symbol>.json

  Usage:
    fpc -Mdelphi -Fu../modules TrainModel.pas
    ./TrainModel mlstrategy nifty50 history.csv
}
program TrainModel;

{$mode Delphi}{$H+}

uses
  SysUtils, Classes, Math, Topaz.Indicators, XGBoost.Wrapper;

const
  NUM_FEATURES = 8;
  LOOKAHEAD    = 20;     // ticks ahead to measure outcome
  MIN_MOVE_PCT = 0.05;   // minimum % move to label as buy/sell

type
  TTick = record
    LTP, Bid, Ask: Double;
    Volume: Int64;
  end;

var
  Ticks: array of TTick;
  TickCount: Integer;

procedure LoadCSV(const APath: string);
var
  F: TextFile;
  Line: string;
  Parts: TStringList;
begin
  TickCount := 0;
  SetLength(Ticks, 100000);
  Parts := TStringList.Create;
  Parts.Delimiter := ',';
  Parts.StrictDelimiter := True;
  try
    AssignFile(F, APath);
    Reset(F);
    ReadLn(F, Line);  // skip header
    while not Eof(F) do
    begin
      ReadLn(F, Line);
      Parts.DelimitedText := Line;
      if Parts.Count < 5 then Continue;
      if TickCount >= Length(Ticks) then
        SetLength(Ticks, Length(Ticks) * 2);
      Ticks[TickCount].LTP := StrToFloatDef(Parts[1], 0);
      Ticks[TickCount].Bid := StrToFloatDef(Parts[2], 0);
      Ticks[TickCount].Ask := StrToFloatDef(Parts[3], 0);
      Ticks[TickCount].Volume := StrToInt64Def(Parts[4], 0);
      Inc(TickCount);
    end;
    CloseFile(F);
  finally
    Parts.Free;
  end;
  SetLength(Ticks, TickCount);
  WriteLn(Format('Loaded %d ticks from %s', [TickCount, APath]));
end;

procedure Run;
var
  RSI: TRSI;
  MACD: TMACD;
  BB: TBollingerBands;
  VWAP: TVWAP;
  EMA20, EMA50: TEMA;
  ROC: TROC;
  Stoch: TStochastic;

  Features: array of Single;
  Labels: array of Single;
  SampleCount: Integer;
  I, WarmUp: Integer;
  FuturePrice, MovePct, Spread: Double;

  DMTrain: TDMatrix;
  Model: TBooster;
  Preds: TSingleArray;
  Correct: Integer;
begin
  if TickCount < 200 then
  begin
    WriteLn('Not enough ticks (need at least 200)');
    Exit;
  end;

  RSI.Init(14);
  MACD.Init(12, 26, 9);
  BB.Init(20, 2.0);
  VWAP.Init;
  EMA20.Init(20);
  EMA50.Init(50);
  ROC.Init(12);
  Stoch.Init(14, 3);

  WarmUp := 60;
  SampleCount := 0;
  SetLength(Features, (TickCount - WarmUp - LOOKAHEAD) * NUM_FEATURES);
  SetLength(Labels, TickCount - WarmUp - LOOKAHEAD);

  // Compute features and labels
  for I := 0 to TickCount - 1 do
  begin
    RSI.Update(Ticks[I].LTP);
    MACD.Update(Ticks[I].LTP);
    BB.Update(Ticks[I].LTP);
    VWAP.Update(Ticks[I].LTP, Ticks[I].Volume);
    EMA20.Update(Ticks[I].LTP);
    EMA50.Update(Ticks[I].LTP);
    ROC.Update(Ticks[I].LTP);
    Stoch.Update(Ticks[I].LTP, Ticks[I].LTP, Ticks[I].LTP);

    if I < WarmUp then Continue;
    if I + LOOKAHEAD >= TickCount then Continue;

    // Features
    Features[SampleCount * NUM_FEATURES + 0] := RSI.Value;
    Features[SampleCount * NUM_FEATURES + 1] := MACD.Histogram;
    Features[SampleCount * NUM_FEATURES + 2] := BB.PctB(Ticks[I].LTP);
    if VWAP.Value > 0 then
      Features[SampleCount * NUM_FEATURES + 3] := ((Ticks[I].LTP - VWAP.Value) / VWAP.Value) * 100
    else
      Features[SampleCount * NUM_FEATURES + 3] := 0;
    if EMA50.Value > 0 then
      Features[SampleCount * NUM_FEATURES + 4] := (EMA20.Value - EMA50.Value) / EMA50.Value * 100
    else
      Features[SampleCount * NUM_FEATURES + 4] := 0;
    Features[SampleCount * NUM_FEATURES + 5] := ROC.Value;
    Features[SampleCount * NUM_FEATURES + 6] := Stoch.K;
    Spread := Ticks[I].Ask - Ticks[I].Bid;
    if Ticks[I].LTP > 0 then
      Features[SampleCount * NUM_FEATURES + 7] := (Spread / Ticks[I].LTP) * 10000
    else
      Features[SampleCount * NUM_FEATURES + 7] := 0;

    // Label: 1.0 if price goes up by MIN_MOVE_PCT, else 0.0
    FuturePrice := Ticks[I + LOOKAHEAD].LTP;
    MovePct := ((FuturePrice - Ticks[I].LTP) / Ticks[I].LTP) * 100;
    if MovePct > MIN_MOVE_PCT then
      Labels[SampleCount] := 1.0
    else
      Labels[SampleCount] := 0.0;

    Inc(SampleCount);
  end;

  WriteLn(Format('Samples: %d  Features: %d', [SampleCount, NUM_FEATURES]));
  SetLength(Features, SampleCount * NUM_FEATURES);
  SetLength(Labels, SampleCount);

  // Count class distribution
  Correct := 0;
  for I := 0 to SampleCount - 1 do
    if Labels[I] > 0.5 then Inc(Correct);
  WriteLn(Format('Buy labels: %d (%.1f%%)  Sell labels: %d (%.1f%%)',
    [Correct, Correct / SampleCount * 100,
     SampleCount - Correct, (SampleCount - Correct) / SampleCount * 100]));

  // Train
  DMTrain := TDMatrix.Create(Features, SampleCount, NUM_FEATURES);
  DMTrain.SetLabels(Labels);
  try
    Model := TBooster.Create([DMTrain]);
    try
      Model.SetParam('objective', 'binary:logistic');
      Model.SetParam('max_depth', '5');
      Model.SetParam('eta', '0.1');
      Model.SetParam('subsample', '0.8');
      Model.SetParam('colsample_bytree', '0.8');
      Model.SetParam('eval_metric', 'logloss');
      Model.SetParam('nthread', '4');

      WriteLn('Training 200 rounds...');
      Model.Train(DMTrain, 200);

      // In-sample accuracy
      Preds := Model.Predict(DMTrain);
      Correct := 0;
      for I := 0 to SampleCount - 1 do
        if ((Preds[I] > 0.5) and (Labels[I] > 0.5)) or
           ((Preds[I] <= 0.5) and (Labels[I] <= 0.5)) then
          Inc(Correct);
      WriteLn(Format('In-sample accuracy: %.1f%%', [Correct / SampleCount * 100]));

      ForceDirectories('models');
      Model.SaveModel('models/' + ParamStr(1) + '_' + ParamStr(2) + '.json');
      WriteLn('Model saved to models/' + ParamStr(1) + '_' + ParamStr(2) + '.json');
    finally
      Model.Free;
    end;
  finally
    DMTrain.Free;
  end;
end;

begin
  if ParamCount < 3 then
  begin
    WriteLn('Usage: TrainModel <strategy> <symbol> <ticks.csv>');
    WriteLn('  e.g. TrainModel mlstrategy nifty50 history.csv');
    WriteLn('  Output: models/mlstrategy_nifty50.json');
    Halt(1);
  end;

  LoadCSV(ParamStr(3));
  Run;
end.
