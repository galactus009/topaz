(**
 * Topaz.Metrics — Strategy Performance Metrics
 *
 * Track per-strategy trade statistics in real-time. Zero-alloc after init.
 * Pre-allocates trade and return arrays; all RecordTrade calls update
 * counters in-place with no heap activity.
 *
 * Usage:
 *   M := TStrategyMetrics.Create;
 *   try
 *     M.RecordTrade(Trade);
 *     WriteLn('Win rate: ', M.WinRate:0:2, '%');
 *     WriteLn('Sharpe:   ', M.Sharpe:0:4);
 *     WriteLn(M.ToJson);
 *   finally
 *     M.Free;
 *   end;
 *)
unit Topaz.Metrics;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math;

const
  DEFAULT_MAX_TRADES = 65536;

type
  TTradeRecord = record
    EntryPrice: Double;
    ExitPrice: Double;
    Qty: Integer;
    Side: Integer;         // +1=long, -1=short
    PnL: Double;
    EntryTime: TDateTime;
    ExitTime: TDateTime;
  end;

  TStrategyMetrics = class
  private
    FTrades: array of TTradeRecord;
    FTradeCount: Integer;
    FWins: Integer;
    FLosses: Integer;
    FGrossProfit: Double;
    FGrossLoss: Double;
    FPeakPnL: Double;
    FMaxDrawdown: Double;
    FCumulativePnL: Double;
    FReturns: array of Double;  // per-trade returns for Sharpe
    FReturnCount: Integer;
    FLargestWin: Double;
    FLargestLoss: Double;
    FMaxConsecWins: Integer;
    FMaxConsecLosses: Integer;
    FCurrentConsecWins: Integer;
    FCurrentConsecLosses: Integer;
    FCapacity: Integer;
  public
    constructor Create(ACapacity: Integer = DEFAULT_MAX_TRADES);
    destructor Destroy; override;

    procedure RecordTrade(const ATrade: TTradeRecord);
    procedure Reset;

    // Metrics
    function WinRate: Double;          // wins / total (0-100%)
    function ProfitFactor: Double;     // gross_profit / gross_loss
    function Sharpe: Double;           // mean(returns) / stddev(returns) * sqrt(252)
    function MaxDrawdown: Double;      // peak-to-trough
    function AvgWin: Double;
    function AvgLoss: Double;
    function ExpectancyPerTrade: Double; // (win_rate * avg_win) - (loss_rate * avg_loss)
    function LargestWin: Double;
    function LargestLoss: Double;
    function TotalTrades: Integer;
    function ConsecutiveWins: Integer;
    function ConsecutiveLosses: Integer;
    function CumulativePnL: Double;

    // Serialization
    function ToJson: AnsiString;       // JSON summary
  end;

implementation

{ ── TStrategyMetrics ──────────────────────────────────────────────────────── }

constructor TStrategyMetrics.Create(ACapacity: Integer);
begin
  inherited Create;
  FCapacity := ACapacity;
  SetLength(FTrades, FCapacity);
  SetLength(FReturns, FCapacity);
  Reset;
end;

destructor TStrategyMetrics.Destroy;
begin
  inherited;
end;

procedure TStrategyMetrics.Reset;
begin
  FTradeCount := 0;
  FWins := 0;
  FLosses := 0;
  FGrossProfit := 0;
  FGrossLoss := 0;
  FPeakPnL := 0;
  FMaxDrawdown := 0;
  FCumulativePnL := 0;
  FReturnCount := 0;
  FLargestWin := 0;
  FLargestLoss := 0;
  FMaxConsecWins := 0;
  FMaxConsecLosses := 0;
  FCurrentConsecWins := 0;
  FCurrentConsecLosses := 0;
end;

procedure TStrategyMetrics.RecordTrade(const ATrade: TTradeRecord);
var
  PnL, Ret, Cost: Double;
begin
  if FTradeCount >= FCapacity then
    Exit;  // capacity reached — no alloc

  FTrades[FTradeCount] := ATrade;
  PnL := ATrade.PnL;

  // Cumulative PnL and drawdown
  FCumulativePnL := FCumulativePnL + PnL;
  if FCumulativePnL > FPeakPnL then
    FPeakPnL := FCumulativePnL;
  if (FPeakPnL - FCumulativePnL) > FMaxDrawdown then
    FMaxDrawdown := FPeakPnL - FCumulativePnL;

  // Win/loss tracking
  if PnL > 0 then
  begin
    Inc(FWins);
    FGrossProfit := FGrossProfit + PnL;
    if PnL > FLargestWin then
      FLargestWin := PnL;
    Inc(FCurrentConsecWins);
    FCurrentConsecLosses := 0;
    if FCurrentConsecWins > FMaxConsecWins then
      FMaxConsecWins := FCurrentConsecWins;
  end
  else if PnL < 0 then
  begin
    Inc(FLosses);
    FGrossLoss := FGrossLoss + Abs(PnL);
    if PnL < FLargestLoss then
      FLargestLoss := PnL;
    Inc(FCurrentConsecLosses);
    FCurrentConsecWins := 0;
    if FCurrentConsecLosses > FMaxConsecLosses then
      FMaxConsecLosses := FCurrentConsecLosses;
  end
  else
  begin
    // Breakeven — reset streaks
    FCurrentConsecWins := 0;
    FCurrentConsecLosses := 0;
  end;

  // Per-trade return for Sharpe calculation
  Cost := ATrade.EntryPrice * ATrade.Qty;
  if Cost <> 0 then
    Ret := PnL / Abs(Cost)
  else
    Ret := 0;
  FReturns[FReturnCount] := Ret;
  Inc(FReturnCount);

  Inc(FTradeCount);
end;

function TStrategyMetrics.WinRate: Double;
begin
  if FTradeCount > 0 then
    Result := (FWins / FTradeCount) * 100.0
  else
    Result := 0;
end;

function TStrategyMetrics.ProfitFactor: Double;
begin
  if FGrossLoss > 0 then
    Result := FGrossProfit / FGrossLoss
  else if FGrossProfit > 0 then
    Result := Infinity
  else
    Result := 0;
end;

function TStrategyMetrics.Sharpe: Double;
var
  I: Integer;
  Sum, Mean, Variance, StdDev: Double;
begin
  if FReturnCount < 2 then
    Exit(0);

  Sum := 0;
  for I := 0 to FReturnCount - 1 do
    Sum := Sum + FReturns[I];
  Mean := Sum / FReturnCount;

  Variance := 0;
  for I := 0 to FReturnCount - 1 do
    Variance := Variance + Sqr(FReturns[I] - Mean);
  Variance := Variance / (FReturnCount - 1);
  StdDev := Sqrt(Variance);

  if StdDev > 0 then
    Result := (Mean / StdDev) * Sqrt(252.0)
  else
    Result := 0;
end;

function TStrategyMetrics.MaxDrawdown: Double;
begin
  Result := FMaxDrawdown;
end;

function TStrategyMetrics.AvgWin: Double;
begin
  if FWins > 0 then
    Result := FGrossProfit / FWins
  else
    Result := 0;
end;

function TStrategyMetrics.AvgLoss: Double;
begin
  if FLosses > 0 then
    Result := FGrossLoss / FLosses
  else
    Result := 0;
end;

function TStrategyMetrics.ExpectancyPerTrade: Double;
var
  WR, LR: Double;
begin
  if FTradeCount = 0 then
    Exit(0);
  WR := FWins / FTradeCount;
  LR := FLosses / FTradeCount;
  Result := (WR * AvgWin) - (LR * AvgLoss);
end;

function TStrategyMetrics.LargestWin: Double;
begin
  Result := FLargestWin;
end;

function TStrategyMetrics.LargestLoss: Double;
begin
  Result := FLargestLoss;
end;

function TStrategyMetrics.TotalTrades: Integer;
begin
  Result := FTradeCount;
end;

function TStrategyMetrics.ConsecutiveWins: Integer;
begin
  Result := FMaxConsecWins;
end;

function TStrategyMetrics.ConsecutiveLosses: Integer;
begin
  Result := FMaxConsecLosses;
end;

function TStrategyMetrics.CumulativePnL: Double;
begin
  Result := FCumulativePnL;
end;

function TStrategyMetrics.ToJson: AnsiString;
var
  PF: Double;
begin
  PF := ProfitFactor;
  Result := '{' +
    '"total_trades":' + IntToStr(FTradeCount) + ',' +
    '"wins":' + IntToStr(FWins) + ',' +
    '"losses":' + IntToStr(FLosses) + ',' +
    '"win_rate":' + FloatToStrF(WinRate, ffFixed, 15, 2) + ',' +
    '"gross_profit":' + FloatToStrF(FGrossProfit, ffFixed, 15, 2) + ',' +
    '"gross_loss":' + FloatToStrF(FGrossLoss, ffFixed, 15, 2) + ',' +
    '"profit_factor":';
  if IsInfinite(PF) then
    Result := Result + '"Inf"'
  else
    Result := Result + FloatToStrF(PF, ffFixed, 15, 4);
  Result := Result + ',' +
    '"sharpe":' + FloatToStrF(Sharpe, ffFixed, 15, 4) + ',' +
    '"max_drawdown":' + FloatToStrF(FMaxDrawdown, ffFixed, 15, 2) + ',' +
    '"cumulative_pnl":' + FloatToStrF(FCumulativePnL, ffFixed, 15, 2) + ',' +
    '"avg_win":' + FloatToStrF(AvgWin, ffFixed, 15, 2) + ',' +
    '"avg_loss":' + FloatToStrF(AvgLoss, ffFixed, 15, 2) + ',' +
    '"expectancy":' + FloatToStrF(ExpectancyPerTrade, ffFixed, 15, 2) + ',' +
    '"largest_win":' + FloatToStrF(FLargestWin, ffFixed, 15, 2) + ',' +
    '"largest_loss":' + FloatToStrF(FLargestLoss, ffFixed, 15, 2) + ',' +
    '"max_consec_wins":' + IntToStr(FMaxConsecWins) + ',' +
    '"max_consec_losses":' + IntToStr(FMaxConsecLosses) +
    '}';
end;

end.
