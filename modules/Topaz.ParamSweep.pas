{
  Topaz.ParamSweep — Parameter Sweep / Walk-Forward Optimisation.

  Grid search over strategy parameter combinations using the backtest
  engine.  Generates all combinations (cartesian product) of discrete
  parameter values, runs a full backtest for each, and tracks the best
  result by Sharpe ratio.

  Walk-forward note:
    For walk-forward analysis, split the CSV data externally (70 % train,
    30 % validate).  Run the sweep on the training set, take the best
    parameter combo, then run a single backtest on the validation set
    with those parameters to check for overfitting.  No separate class
    is needed — just call Run twice with different TBacktestConfig.DataPath.

  Usage:
    var
      Cfg: TBacktestConfig;
      Sweep: TParamSweep;
    begin
      Cfg := DefaultBacktestConfig('history.csv');
      Sweep := TParamSweep.Create(Cfg, @MyTickCallback);
      try
        Sweep.AddParam('fast_period', 5, 20, 1);
        Sweep.AddParam('atr_mult',    1.0, 3.0, 0.5);
        Sweep.Run;
        WriteLn('Best Sharpe: ', Sweep.BestResult.BacktestResult.Sharpe:0:4);
        WriteLn(Sweep.ResultsToJson);
      finally
        Sweep.Free;
      end;
    end;
}
unit Topaz.ParamSweep;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Math, Topaz.Backtest, Topaz.EventTypes;

type
  { ── Single parameter axis for the grid ── }
  TSweepParam = record
    Name: AnsiString;
    MinVal: Double;
    MaxVal: Double;
    Step: Double;
  end;

  { ── Result for one parameter combination ── }
  TSweepParamValue = record
    Name: AnsiString;
    Value: Double;
  end;

  TSweepResult = record
    Params: array of TSweepParamValue;
    BacktestResult: TBacktestResult;
  end;

  { ── Grid-search sweep engine ── }
  TParamSweep = class
  private
    FParams: array of TSweepParam;
    FConfig: TBacktestConfig;
    FCallback: TBacktestTickCallback;
    FResults: array of TSweepResult;
    FResultCount: Integer;
    FBestIdx: Integer;

    procedure RunCombination(const AValues: array of Double);
    procedure EnumerateRecursive(ADepth: Integer;
      var AValues: array of Double);
    function StepCount(const AP: TSweepParam): Integer;
  public
    constructor Create(const AConfig: TBacktestConfig;
      ACallback: TBacktestTickCallback);
    destructor Destroy; override;

    { Add a parameter axis.  All values from AMin to AMax in AStep
      increments are enumerated. }
    procedure AddParam(const AName: AnsiString;
      AMin, AMax, AStep: Double);

    { Run all combinations.  Results are sorted internally; best is
      tracked by highest Sharpe ratio. }
    procedure Run;

    { Access results }
    function BestResult: TSweepResult;
    function ResultCount: Integer;
    function GetResult(AIndex: Integer): TSweepResult;
    function ResultsToJson: AnsiString;
  end;

implementation

{ ── TParamSweep ───────────────────────────────────────────────────────── }

constructor TParamSweep.Create(const AConfig: TBacktestConfig;
  ACallback: TBacktestTickCallback);
begin
  inherited Create;
  FConfig := AConfig;
  FCallback := ACallback;
  FResultCount := 0;
  FBestIdx := -1;
  SetLength(FParams, 0);
  SetLength(FResults, 0);
end;

destructor TParamSweep.Destroy;
begin
  SetLength(FParams, 0);
  SetLength(FResults, 0);
  inherited;
end;

{ ── AddParam ── }

procedure TParamSweep.AddParam(const AName: AnsiString;
  AMin, AMax, AStep: Double);
var
  N: Integer;
begin
  if AStep <= 0 then
    raise Exception.Create('TParamSweep.AddParam: step must be > 0');
  if AMax < AMin then
    raise Exception.Create('TParamSweep.AddParam: max < min');

  N := Length(FParams);
  SetLength(FParams, N + 1);
  FParams[N].Name := AName;
  FParams[N].MinVal := AMin;
  FParams[N].MaxVal := AMax;
  FParams[N].Step := AStep;
end;

{ ── Number of discrete values for a parameter axis ── }

function TParamSweep.StepCount(const AP: TSweepParam): Integer;
begin
  Result := Trunc((AP.MaxVal - AP.MinVal) / AP.Step) + 1;
end;

{ ── Store one combination's backtest result ── }

procedure TParamSweep.RunCombination(const AValues: array of Double);
var
  Engine: TBacktestEngine;
  Res: TBacktestResult;
  I: Integer;
begin
  Engine := TBacktestEngine.Create(FConfig);
  try
    Res := Engine.Run(FCallback);
  finally
    Engine.Free;
  end;

  // Grow results array if needed
  if FResultCount >= Length(FResults) then
  begin
    if Length(FResults) = 0 then
      SetLength(FResults, 64)
    else
      SetLength(FResults, Length(FResults) * 2);
  end;

  // Store parameter values
  SetLength(FResults[FResultCount].Params, Length(FParams));
  for I := 0 to High(FParams) do
  begin
    FResults[FResultCount].Params[I].Name := FParams[I].Name;
    FResults[FResultCount].Params[I].Value := AValues[I];
  end;
  FResults[FResultCount].BacktestResult := Res;

  // Track best by Sharpe ratio
  if (FBestIdx < 0) or (Res.Sharpe > FResults[FBestIdx].BacktestResult.Sharpe) then
    FBestIdx := FResultCount;

  Inc(FResultCount);
end;

{ ── Recursive enumeration of all parameter combinations ── }

procedure TParamSweep.EnumerateRecursive(ADepth: Integer;
  var AValues: array of Double);
var
  V: Double;
  SC: Integer;
  I: Integer;
begin
  if ADepth >= Length(FParams) then
  begin
    // All parameters set — run this combination
    RunCombination(AValues);
    Exit;
  end;

  SC := StepCount(FParams[ADepth]);
  for I := 0 to SC - 1 do
  begin
    V := FParams[ADepth].MinVal + I * FParams[ADepth].Step;
    // Clamp to MaxVal to avoid floating-point overshoot
    if V > FParams[ADepth].MaxVal then
      V := FParams[ADepth].MaxVal;
    AValues[ADepth] := V;
    EnumerateRecursive(ADepth + 1, AValues);
  end;
end;

{ ── Run ── }

procedure TParamSweep.Run;
var
  Values: array of Double;
begin
  if Length(FParams) = 0 then
    raise Exception.Create('TParamSweep.Run: no parameters added');

  FResultCount := 0;
  FBestIdx := -1;
  SetLength(Values, Length(FParams));
  EnumerateRecursive(0, Values);
  SetLength(FResults, FResultCount);  // trim excess
end;

{ ── BestResult ── }

function TParamSweep.BestResult: TSweepResult;
begin
  if FBestIdx < 0 then
    raise Exception.Create('TParamSweep.BestResult: no results (call Run first)');
  Result := FResults[FBestIdx];
end;

{ ── ResultCount ── }

function TParamSweep.ResultCount: Integer;
begin
  Result := FResultCount;
end;

{ ── GetResult ── }

function TParamSweep.GetResult(AIndex: Integer): TSweepResult;
begin
  if (AIndex < 0) or (AIndex >= FResultCount) then
    raise Exception.CreateFmt('TParamSweep.GetResult: index %d out of range', [AIndex]);
  Result := FResults[AIndex];
end;

{ ── JSON serialization ── }

function TParamSweep.ResultsToJson: AnsiString;
var
  I, J: Integer;
  S: AnsiString;
  PF: Double;
begin
  S := '{"sweep_results":[';
  for I := 0 to FResultCount - 1 do
  begin
    if I > 0 then S := S + ',';
    S := S + '{"params":{';
    for J := 0 to High(FResults[I].Params) do
    begin
      if J > 0 then S := S + ',';
      S := S + '"' + FResults[I].Params[J].Name + '":' +
        FloatToStrF(FResults[I].Params[J].Value, ffFixed, 15, 4);
    end;
    PF := FResults[I].BacktestResult.ProfitFactor;
    S := S + '},"sharpe":' +
      FloatToStrF(FResults[I].BacktestResult.Sharpe, ffFixed, 15, 4) +
      ',"pnl":' +
      FloatToStrF(FResults[I].BacktestResult.CumulativePnL, ffFixed, 15, 2) +
      ',"trades":' + IntToStr(FResults[I].BacktestResult.TotalTrades) +
      ',"win_rate":' +
      FloatToStrF(FResults[I].BacktestResult.WinRate, ffFixed, 15, 2) +
      ',"profit_factor":';
    if IsInfinite(PF) then
      S := S + '"Inf"'
    else
      S := S + FloatToStrF(PF, ffFixed, 15, 4);
    S := S + ',"max_drawdown":' +
      FloatToStrF(FResults[I].BacktestResult.MaxDrawdown, ffFixed, 15, 2) +
      '}';
  end;
  S := S + '],"total_combinations":' + IntToStr(FResultCount);
  if FBestIdx >= 0 then
    S := S + ',"best_index":' + IntToStr(FBestIdx);
  S := S + '}';
  Result := S;
end;

end.
