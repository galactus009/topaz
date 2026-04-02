{
  Topaz.Backtest — Backtesting framework for historical tick replay.

  Loads tick data from CSV, feeds each tick to a user-supplied callback
  that returns a signal (+1 buy, -1 sell, 0 hold), simulates fills with
  commission and slippage, and computes comprehensive performance metrics.

  CSV format: timestamp,ltp,bid,ask,volume  (same as TrainModel.pas)

  Usage:
    var
      Cfg: TBacktestConfig;
      Engine: TBacktestEngine;
      Res: TBacktestResult;
    begin
      Cfg := DefaultBacktestConfig('history.csv');
      Engine := TBacktestEngine.Create(Cfg);
      try
        Res := Engine.Run(@MyTickCallback);
        WriteLn(Engine.ResultToJson(Res));
      finally
        Engine.Free;
      end;
    end;
}
unit Topaz.Backtest;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, Math, Topaz.EventTypes, Topaz.Metrics;

type
  { ── Backtest configuration ── }
  TBacktestConfig = record
    DataPath: AnsiString;       // CSV file path
    StartDate: TDateTime;       // optional filter (0 = no filter)
    EndDate: TDateTime;         // optional filter (0 = no filter)
    InitialCapital: Double;     // starting capital (default 100000)
    Commission: Double;         // per-order commission (default 20)
    Slippage: Double;           // points of slippage per trade (default 0.05)
    LotSize: Integer;           // qty per signal (default 1)
  end;

  { ── Backtest result summary ── }
  TBacktestResult = record
    TotalTrades: Integer;
    WinRate: Double;            // 0-100%
    ProfitFactor: Double;
    Sharpe: Double;
    MaxDrawdown: Double;
    CumulativePnL: Double;
    AvgWin: Double;
    AvgLoss: Double;
    Expectancy: Double;
    TotalCommission: Double;
    FinalCapital: Double;
    DurationMs: Int64;          // wall-clock time of the backtest run
    TicksProcessed: Integer;
    LargestWin: Double;
    LargestLoss: Double;
    MaxConsecWins: Integer;
    MaxConsecLosses: Integer;
  end;

  { ── Signal callback ──
    Receives the current tick, its index in the dataset, the engine's
    current position (+long, -short, 0 flat), and available capital.
    Return: +1 = buy, -1 = sell, 0 = hold }
  TBacktestTickCallback = function(const ATick: TTickEvent;
    ATickIndex: Integer; APosition: Integer;
    ACapital: Double): Integer;

  { ── Backtest engine ── }
  TBacktestEngine = class
  private
    FConfig: TBacktestConfig;
    FMetrics: TStrategyMetrics;
    FTicks: array of TTickEvent;
    FTickCount: Integer;

    // Simulated broker state
    FCapital: Double;
    FPosition: Integer;         // current qty: + long, - short, 0 flat
    FAvgPrice: Double;          // weighted average entry price
    FRealizedPnL: Double;
    FTotalCommission: Double;
    FPeakCapital: Double;
    FMaxDrawdown: Double;
    FEntryTime: Integer;        // tick index of last entry (for TTradeRecord)

    procedure LoadCSV(const APath: AnsiString);
    procedure SimulateBuy(AQty: Integer; APrice: Double; ATickIndex: Integer);
    procedure SimulateSell(AQty: Integer; APrice: Double; ATickIndex: Integer);
    procedure ClosePosition(APrice: Double; ATickIndex: Integer);
    procedure RecordClosedTrade(AEntryPrice, AExitPrice: Double;
      AQty, ASide: Integer; APnL: Double);
    procedure UpdateDrawdown;
  public
    constructor Create(const AConfig: TBacktestConfig);
    destructor Destroy; override;

    function Run(AOnTick: TBacktestTickCallback): TBacktestResult;
    function ResultToJson(const AResult: TBacktestResult): AnsiString;

    property Metrics: TStrategyMetrics read FMetrics;
    property TickCount: Integer read FTickCount;
  end;

{ Helper: create a config with sensible defaults }
function DefaultBacktestConfig(const ADataPath: AnsiString): TBacktestConfig;

implementation

{ ── DefaultBacktestConfig ──────────────────────────────────────────────── }

function DefaultBacktestConfig(const ADataPath: AnsiString): TBacktestConfig;
begin
  Result.DataPath := ADataPath;
  Result.StartDate := 0;
  Result.EndDate := 0;
  Result.InitialCapital := 100000;
  Result.Commission := 20;
  Result.Slippage := 0.05;
  Result.LotSize := 1;
end;

{ ── TBacktestEngine ────────────────────────────────────────────────────── }

constructor TBacktestEngine.Create(const AConfig: TBacktestConfig);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.InitialCapital <= 0 then
    FConfig.InitialCapital := 100000;
  if FConfig.Commission < 0 then
    FConfig.Commission := 20;
  if FConfig.Slippage < 0 then
    FConfig.Slippage := 0.05;
  if FConfig.LotSize <= 0 then
    FConfig.LotSize := 1;

  FMetrics := TStrategyMetrics.Create;
  FTickCount := 0;
  FCapital := FConfig.InitialCapital;
  FPosition := 0;
  FAvgPrice := 0;
  FRealizedPnL := 0;
  FTotalCommission := 0;
  FPeakCapital := FCapital;
  FMaxDrawdown := 0;
  FEntryTime := 0;
end;

destructor TBacktestEngine.Destroy;
begin
  FMetrics.Free;
  inherited;
end;

{ ── CSV loading (same format as TrainModel.pas) ── }

procedure TBacktestEngine.LoadCSV(const APath: AnsiString);
var
  F: TextFile;
  Line: string;
  Parts: TStringList;
  Tick: TTickEvent;
begin
  FTickCount := 0;
  SetLength(FTicks, 100000);
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
      if Line = '' then Continue;
      Parts.DelimitedText := Line;
      if Parts.Count < 5 then Continue;

      Tick.SymbolId := 0;
      Tick.LTP := StrToFloatDef(Parts[1], 0);
      Tick.Bid := StrToFloatDef(Parts[2], 0);
      Tick.Ask := StrToFloatDef(Parts[3], 0);
      Tick.Volume := StrToInt64Def(Parts[4], 0);
      Tick.OI := 0;

      // Skip ticks with zero LTP
      if Tick.LTP <= 0 then Continue;

      if FTickCount >= Length(FTicks) then
        SetLength(FTicks, Length(FTicks) * 2);
      FTicks[FTickCount] := Tick;
      Inc(FTickCount);
    end;
    CloseFile(F);
  finally
    Parts.Free;
  end;
  SetLength(FTicks, FTickCount);
end;

{ ── Drawdown tracking ── }

procedure TBacktestEngine.UpdateDrawdown;
var
  Equity: Double;
  DD: Double;
begin
  // Equity = capital + unrealized P&L
  if FPosition > 0 then
    Equity := FCapital + (FTicks[0].LTP - FAvgPrice) * FPosition  // updated in Run
  else if FPosition < 0 then
    Equity := FCapital + (FAvgPrice - FTicks[0].LTP) * Abs(FPosition)
  else
    Equity := FCapital;

  if Equity > FPeakCapital then
    FPeakCapital := Equity;
  DD := FPeakCapital - Equity;
  if DD > FMaxDrawdown then
    FMaxDrawdown := DD;
end;

{ ── Trade recording ── }

procedure TBacktestEngine.RecordClosedTrade(AEntryPrice, AExitPrice: Double;
  AQty, ASide: Integer; APnL: Double);
var
  Trade: TTradeRecord;
begin
  Trade.EntryPrice := AEntryPrice;
  Trade.ExitPrice := AExitPrice;
  Trade.Qty := AQty;
  Trade.Side := ASide;
  Trade.PnL := APnL;
  Trade.EntryTime := 0;  // tick-based, not wall-clock
  Trade.ExitTime := 0;
  FMetrics.RecordTrade(Trade);
end;

{ ── Simulated fills ──
  Handles position building, reversal, and flattening.
  Slippage is applied adversely: buy at price + slippage, sell at price - slippage.
  Commission is deducted per order. }

procedure TBacktestEngine.SimulateBuy(AQty: Integer; APrice: Double;
  ATickIndex: Integer);
var
  FillPrice: Double;
  ClosedQty, NewQty: Integer;
  ClosedPnL: Double;
begin
  FillPrice := APrice + FConfig.Slippage;
  FCapital := FCapital - FConfig.Commission;
  FTotalCommission := FTotalCommission + FConfig.Commission;

  if FPosition < 0 then
  begin
    // Closing short (partially or fully) then possibly going long
    ClosedQty := Min(AQty, Abs(FPosition));
    ClosedPnL := (FAvgPrice - FillPrice) * ClosedQty;
    FRealizedPnL := FRealizedPnL + ClosedPnL;
    FCapital := FCapital + ClosedPnL;
    RecordClosedTrade(FAvgPrice, FillPrice, ClosedQty, -1, ClosedPnL);

    NewQty := AQty - ClosedQty;
    FPosition := FPosition + ClosedQty;
    if (FPosition = 0) and (NewQty > 0) then
    begin
      // Opening new long
      FPosition := NewQty;
      FAvgPrice := FillPrice;
      FEntryTime := ATickIndex;
    end
    else if NewQty > 0 then
    begin
      // Still short — reduced position
      // This shouldn't happen with ClosedQty = Min(AQty, Abs(FPosition))
      FPosition := FPosition + NewQty;
      FAvgPrice := FillPrice;
      FEntryTime := ATickIndex;
    end;
  end
  else if FPosition = 0 then
  begin
    // Opening new long
    FPosition := AQty;
    FAvgPrice := FillPrice;
    FEntryTime := ATickIndex;
  end
  else
  begin
    // Adding to existing long — average up/down
    FAvgPrice := (FAvgPrice * FPosition + FillPrice * AQty) / (FPosition + AQty);
    FPosition := FPosition + AQty;
  end;
end;

procedure TBacktestEngine.SimulateSell(AQty: Integer; APrice: Double;
  ATickIndex: Integer);
var
  FillPrice: Double;
  ClosedQty, NewQty: Integer;
  ClosedPnL: Double;
begin
  FillPrice := APrice - FConfig.Slippage;
  FCapital := FCapital - FConfig.Commission;
  FTotalCommission := FTotalCommission + FConfig.Commission;

  if FPosition > 0 then
  begin
    // Closing long (partially or fully) then possibly going short
    ClosedQty := Min(AQty, FPosition);
    ClosedPnL := (FillPrice - FAvgPrice) * ClosedQty;
    FRealizedPnL := FRealizedPnL + ClosedPnL;
    FCapital := FCapital + ClosedPnL;
    RecordClosedTrade(FAvgPrice, FillPrice, ClosedQty, +1, ClosedPnL);

    NewQty := AQty - ClosedQty;
    FPosition := FPosition - ClosedQty;
    if (FPosition = 0) and (NewQty > 0) then
    begin
      // Opening new short
      FPosition := -NewQty;
      FAvgPrice := FillPrice;
      FEntryTime := ATickIndex;
    end
    else if NewQty > 0 then
    begin
      FPosition := FPosition - NewQty;
      FAvgPrice := FillPrice;
      FEntryTime := ATickIndex;
    end;
  end
  else if FPosition = 0 then
  begin
    // Opening new short
    FPosition := -AQty;
    FAvgPrice := FillPrice;
    FEntryTime := ATickIndex;
  end
  else
  begin
    // Adding to existing short — average
    FAvgPrice := (FAvgPrice * Abs(FPosition) + FillPrice * AQty) /
                 (Abs(FPosition) + AQty);
    FPosition := FPosition - AQty;
  end;
end;

{ ── Close any open position at market ── }

procedure TBacktestEngine.ClosePosition(APrice: Double; ATickIndex: Integer);
begin
  if FPosition > 0 then
    SimulateSell(FPosition, APrice, ATickIndex)
  else if FPosition < 0 then
    SimulateBuy(Abs(FPosition), APrice, ATickIndex);
end;

{ ── Main backtest loop ── }

function TBacktestEngine.Run(AOnTick: TBacktestTickCallback): TBacktestResult;
var
  I, Signal: Integer;
  StartTick: Int64;
  Equity, UnrealizedPnL, DD: Double;
begin
  FillChar(Result, SizeOf(Result), 0);

  // Load data
  LoadCSV(FConfig.DataPath);
  if FTickCount = 0 then
  begin
    Result.FinalCapital := FConfig.InitialCapital;
    Exit;
  end;

  // Reset state
  FCapital := FConfig.InitialCapital;
  FPosition := 0;
  FAvgPrice := 0;
  FRealizedPnL := 0;
  FTotalCommission := 0;
  FPeakCapital := FCapital;
  FMaxDrawdown := 0;
  FMetrics.Reset;

  StartTick := GetTickCount64;

  // Replay loop
  for I := 0 to FTickCount - 1 do
  begin
    // Call user strategy callback
    Signal := AOnTick(FTicks[I], I, FPosition, FCapital);

    // Execute signal
    if Signal > 0 then
      SimulateBuy(FConfig.LotSize, FTicks[I].LTP, I)
    else if Signal < 0 then
      SimulateSell(FConfig.LotSize, FTicks[I].LTP, I);

    // Track equity and drawdown (including unrealized P&L)
    if FPosition > 0 then
      UnrealizedPnL := (FTicks[I].LTP - FAvgPrice) * FPosition
    else if FPosition < 0 then
      UnrealizedPnL := (FAvgPrice - FTicks[I].LTP) * Abs(FPosition)
    else
      UnrealizedPnL := 0;

    Equity := FCapital + UnrealizedPnL;
    if Equity > FPeakCapital then
      FPeakCapital := Equity;
    DD := FPeakCapital - Equity;
    if DD > FMaxDrawdown then
      FMaxDrawdown := DD;
  end;

  // Close any remaining position at last tick price
  if FPosition <> 0 then
    ClosePosition(FTicks[FTickCount - 1].LTP, FTickCount - 1);

  // Build result
  Result.TotalTrades := FMetrics.TotalTrades;
  Result.WinRate := FMetrics.WinRate;
  Result.ProfitFactor := FMetrics.ProfitFactor;
  Result.Sharpe := FMetrics.Sharpe;
  Result.MaxDrawdown := FMaxDrawdown;
  Result.CumulativePnL := FMetrics.CumulativePnL;
  Result.AvgWin := FMetrics.AvgWin;
  Result.AvgLoss := FMetrics.AvgLoss;
  Result.Expectancy := FMetrics.ExpectancyPerTrade;
  Result.TotalCommission := FTotalCommission;
  Result.FinalCapital := FCapital;
  Result.DurationMs := GetTickCount64 - StartTick;
  Result.TicksProcessed := FTickCount;
  Result.LargestWin := FMetrics.LargestWin;
  Result.LargestLoss := FMetrics.LargestLoss;
  Result.MaxConsecWins := FMetrics.ConsecutiveWins;
  Result.MaxConsecLosses := FMetrics.ConsecutiveLosses;
end;

{ ── JSON serialization ── }

function TBacktestEngine.ResultToJson(const AResult: TBacktestResult): AnsiString;
var
  PF: Double;
begin
  PF := AResult.ProfitFactor;
  Result := '{' +
    '"total_trades":' + IntToStr(AResult.TotalTrades) + ',' +
    '"win_rate":' + FloatToStrF(AResult.WinRate, ffFixed, 15, 2) + ',' +
    '"profit_factor":';
  if IsInfinite(PF) then
    Result := Result + '"Inf"'
  else
    Result := Result + FloatToStrF(PF, ffFixed, 15, 4);
  Result := Result + ',' +
    '"sharpe":' + FloatToStrF(AResult.Sharpe, ffFixed, 15, 4) + ',' +
    '"max_drawdown":' + FloatToStrF(AResult.MaxDrawdown, ffFixed, 15, 2) + ',' +
    '"cumulative_pnl":' + FloatToStrF(AResult.CumulativePnL, ffFixed, 15, 2) + ',' +
    '"avg_win":' + FloatToStrF(AResult.AvgWin, ffFixed, 15, 2) + ',' +
    '"avg_loss":' + FloatToStrF(AResult.AvgLoss, ffFixed, 15, 2) + ',' +
    '"expectancy":' + FloatToStrF(AResult.Expectancy, ffFixed, 15, 2) + ',' +
    '"total_commission":' + FloatToStrF(AResult.TotalCommission, ffFixed, 15, 2) + ',' +
    '"initial_capital":' + FloatToStrF(FConfig.InitialCapital, ffFixed, 15, 2) + ',' +
    '"final_capital":' + FloatToStrF(AResult.FinalCapital, ffFixed, 15, 2) + ',' +
    '"return_pct":' + FloatToStrF(
      ((AResult.FinalCapital - FConfig.InitialCapital) / FConfig.InitialCapital) * 100,
      ffFixed, 15, 2) + ',' +
    '"largest_win":' + FloatToStrF(AResult.LargestWin, ffFixed, 15, 2) + ',' +
    '"largest_loss":' + FloatToStrF(AResult.LargestLoss, ffFixed, 15, 2) + ',' +
    '"max_consec_wins":' + IntToStr(AResult.MaxConsecWins) + ',' +
    '"max_consec_losses":' + IntToStr(AResult.MaxConsecLosses) + ',' +
    '"ticks_processed":' + IntToStr(AResult.TicksProcessed) + ',' +
    '"duration_ms":' + IntToStr(AResult.DurationMs) +
    '}';
end;

end.
