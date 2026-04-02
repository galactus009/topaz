{
  Topaz.IVAnalysis -- IV Rank/Percentile and Max Pain calculator.

  Provides:
    - Historical volatility from daily close prices
    - IV Rank and IV Percentile from stored historical IV values
    - Regime classification (Low/Normal/High/Extreme)
    - Max Pain strike calculation with put-call ratio
}
unit Topaz.IVAnalysis;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math, Apollo.Broker, Topaz.BlackScholes;

type
  TIVStats = record
    CurrentIV: Double;
    IV52High: Double;
    IV52Low: Double;
    IVRank: Double;        // (current - low) / (high - low) * 100
    IVPercentile: Double;  // % of days IV was below current
    Regime: AnsiString;    // 'Low', 'Normal', 'High', 'Extreme'
  end;

  TMaxPainResult = record
    Strike: Double;
    TotalPain: Double;     // minimum total loss for option writers
    PCR: Double;           // put-call ratio by OI
    TotalCallOI: Int64;
    TotalPutOI: Int64;
  end;

  TIVAnalyzer = class
  private
    FHistoricalIV: array of Double;
    FHistCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    // Feed historical IV values (e.g., from daily close prices -> compute HV)
    procedure AddHistoricalIV(AIV: Double);
    procedure LoadFromPrices(const APrices: array of Double; APeriod: Integer = 20);
    // APrices = array of daily close prices. Computes realized vol = stdev(ln returns) * sqrt(252)

    function ComputeStats(ACurrentIV: Double): TIVStats;

    // Max Pain calculation
    // AStrikes: array of strike prices
    // ACallOI, APutOI: open interest at each strike (parallel arrays)
    // ASpot: current spot price
    class function ComputeMaxPain(const AStrikes: array of Double;
      const ACallOI, APutOI: array of Int64; ASpot: Double): TMaxPainResult;

    // Compute historical volatility from price array
    class function HistoricalVol(const APrices: array of Double; APeriod: Integer = 20): Double;
  end;

implementation

{ ═══════════════════════════════════════════════════════════════════ }
{  TIVAnalyzer                                                        }
{ ═══════════════════════════════════════════════════════════════════ }

constructor TIVAnalyzer.Create;
begin
  inherited Create;
  FHistCount := 0;
  SetLength(FHistoricalIV, 0);
end;

destructor TIVAnalyzer.Destroy;
begin
  SetLength(FHistoricalIV, 0);
  inherited Destroy;
end;

procedure TIVAnalyzer.AddHistoricalIV(AIV: Double);
begin
  Inc(FHistCount);
  if FHistCount > Length(FHistoricalIV) then
    SetLength(FHistoricalIV, FHistCount + 64);
  FHistoricalIV[FHistCount - 1] := AIV;
end;

procedure TIVAnalyzer.LoadFromPrices(const APrices: array of Double; APeriod: Integer);
var
  I, N, WinStart: Integer;
  Vol: Double;
  LogReturns: array of Double;
  Mean, Variance, Sum, SumSq: Double;
begin
  N := Length(APrices);
  if N < APeriod + 1 then Exit;

  // Compute log returns
  SetLength(LogReturns, N - 1);
  for I := 0 to N - 2 do
  begin
    if APrices[I] <= 0 then
      LogReturns[I] := 0
    else
      LogReturns[I] := Ln(APrices[I + 1] / APrices[I]);
  end;

  // Reset historical IV storage
  FHistCount := 0;
  SetLength(FHistoricalIV, 0);

  // Compute rolling historical vol for each window
  for WinStart := 0 to Length(LogReturns) - APeriod do
  begin
    Sum := 0;
    SumSq := 0;
    for I := WinStart to WinStart + APeriod - 1 do
    begin
      Sum := Sum + LogReturns[I];
      SumSq := SumSq + LogReturns[I] * LogReturns[I];
    end;
    Mean := Sum / APeriod;
    Variance := (SumSq / APeriod) - (Mean * Mean);
    if Variance < 0 then Variance := 0;
    Vol := Sqrt(Variance) * Sqrt(252.0);
    AddHistoricalIV(Vol);
  end;
end;

function TIVAnalyzer.ComputeStats(ACurrentIV: Double): TIVStats;
var
  I, BelowCount: Integer;
  Hi, Lo: Double;
begin
  Result.CurrentIV := ACurrentIV;
  Result.IV52High := 0;
  Result.IV52Low := 0;
  Result.IVRank := 0;
  Result.IVPercentile := 0;
  Result.Regime := 'Normal';

  if FHistCount = 0 then Exit;

  // Find 52-week (or available) high and low
  Hi := FHistoricalIV[0];
  Lo := FHistoricalIV[0];
  BelowCount := 0;

  for I := 0 to FHistCount - 1 do
  begin
    if FHistoricalIV[I] > Hi then Hi := FHistoricalIV[I];
    if FHistoricalIV[I] < Lo then Lo := FHistoricalIV[I];
    if FHistoricalIV[I] < ACurrentIV then
      Inc(BelowCount);
  end;

  Result.IV52High := Hi;
  Result.IV52Low := Lo;

  // IV Rank = (current - low) / (high - low) * 100
  if (Hi - Lo) > 1e-12 then
    Result.IVRank := ((ACurrentIV - Lo) / (Hi - Lo)) * 100.0
  else
    Result.IVRank := 50.0;

  // IV Percentile = % of days IV was below current
  Result.IVPercentile := (BelowCount / FHistCount) * 100.0;

  // Regime classification
  if Result.IVRank < 20 then
    Result.Regime := 'Low'
  else if Result.IVRank < 50 then
    Result.Regime := 'Normal'
  else if Result.IVRank < 80 then
    Result.Regime := 'High'
  else
    Result.Regime := 'Extreme';
end;

class function TIVAnalyzer.ComputeMaxPain(const AStrikes: array of Double;
  const ACallOI, APutOI: array of Int64; ASpot: Double): TMaxPainResult;
var
  I, J, N, MinIdx: Integer;
  Pain, MinPain: Double;
  CallPain, PutPain: Double;
  SumCallOI, SumPutOI: Int64;
begin
  N := Length(AStrikes);
  Result.Strike := ASpot;
  Result.TotalPain := 0;
  Result.PCR := 0;
  Result.TotalCallOI := 0;
  Result.TotalPutOI := 0;

  if (N = 0) or (Length(ACallOI) <> N) or (Length(APutOI) <> N) then Exit;

  // Compute PCR and totals
  SumCallOI := 0;
  SumPutOI := 0;
  for I := 0 to N - 1 do
  begin
    SumCallOI := SumCallOI + ACallOI[I];
    SumPutOI := SumPutOI + APutOI[I];
  end;
  Result.TotalCallOI := SumCallOI;
  Result.TotalPutOI := SumPutOI;
  if SumCallOI > 0 then
    Result.PCR := SumPutOI / SumCallOI
  else
    Result.PCR := 0;

  // For each strike S, compute total pain
  MinPain := MaxDouble;
  MinIdx := 0;

  for I := 0 to N - 1 do
  begin
    Pain := 0;
    for J := 0 to N - 1 do
    begin
      // Call pain at strike S (=AStrikes[I]): if S > K then CallOI[K] * (S - K)
      if AStrikes[I] > AStrikes[J] then
      begin
        CallPain := ACallOI[J] * (AStrikes[I] - AStrikes[J]);
        Pain := Pain + CallPain;
      end;
      // Put pain at strike S: if S < K then PutOI[K] * (K - S)
      if AStrikes[I] < AStrikes[J] then
      begin
        PutPain := APutOI[J] * (AStrikes[J] - AStrikes[I]);
        Pain := Pain + PutPain;
      end;
    end;

    if Pain < MinPain then
    begin
      MinPain := Pain;
      MinIdx := I;
    end;
  end;

  Result.Strike := AStrikes[MinIdx];
  Result.TotalPain := MinPain;
end;

class function TIVAnalyzer.HistoricalVol(const APrices: array of Double; APeriod: Integer): Double;
var
  I, N: Integer;
  LogReturns: array of Double;
  Mean, Variance, Sum, SumSq: Double;
begin
  Result := 0;
  N := Length(APrices);
  if N < APeriod + 1 then Exit;

  // Use last APeriod+1 prices to get APeriod log returns
  SetLength(LogReturns, APeriod);
  for I := 0 to APeriod - 1 do
  begin
    if APrices[N - APeriod - 1 + I] <= 0 then
      LogReturns[I] := 0
    else
      LogReturns[I] := Ln(APrices[N - APeriod + I] / APrices[N - APeriod - 1 + I]);
  end;

  Sum := 0;
  SumSq := 0;
  for I := 0 to APeriod - 1 do
  begin
    Sum := Sum + LogReturns[I];
    SumSq := SumSq + LogReturns[I] * LogReturns[I];
  end;
  Mean := Sum / APeriod;
  Variance := (SumSq / APeriod) - (Mean * Mean);
  if Variance < 0 then Variance := 0;
  Result := Sqrt(Variance) * Sqrt(252.0);
end;

end.
