{
  DoubleRSI — Multi-timeframe RSI confluence strategy.

  Uses fast RSI(7) and slow RSI(14) on tick data, plus a synthetic
  higher-timeframe RSI built by accumulating every N ticks into an
  aggregated price. Entry requires confluence across both timeframes.

  Entry (long):  fast RSI crosses above slow RSI AND both < oversold
                 AND HTF RSI < HTF oversold.
  Entry (short): fast RSI crosses below slow RSI AND both > overbought
                 AND HTF RSI > HTF overbought.
  Exit:  RSI reversal (fast crosses back), trailing stop %, hard stop %.
}
unit Topaz.Strategy.DoubleRSI;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Thorium.Broker, Topaz.EventTypes, Topaz.Strategy,
  Topaz.Indicators;

type
  TDoubleRSIStrategy = class(TStrategy)
  private
    { Parameters }
    FFastRSIPeriod: Integer;
    FSlowRSIPeriod: Integer;
    FOversold: Double;
    FOverbought: Double;
    FHTFMultiplier: Integer;
    FHTFOversold: Double;
    FHTFOverbought: Double;
    FStopLossPct: Double;
    FTrailingStopPct: Double;

    { LTF indicators }
    FFastRSI: TRSI;
    FSlowRSI: TRSI;

    { HTF synthetic RSI }
    FHTFRSI: TRSI;
    FHTFAccum: Double;
    FHTFTickCount: Integer;

    { Crossover tracking }
    FPrevFastAboveSlow: Boolean;
    FPrevFastRSI: Double;
    FPrevSlowRSI: Double;

    { Position state }
    FInPosition: Boolean;
    FPositionSide: Integer;     // +1 = long, -1 = short
    FEntryPrice: Double;
    FBestPrice: Double;         // best price since entry (for trailing)

  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  public
    constructor Create;
    function DeclareParams: TArray<TStrategyParam>; override;
    procedure ApplyParam(const AName, AValue: AnsiString); override;
    function GetParamValue(const AName: AnsiString): AnsiString; override;
    property FastRSIPeriod: Integer read FFastRSIPeriod write FFastRSIPeriod;
    property SlowRSIPeriod: Integer read FSlowRSIPeriod write FSlowRSIPeriod;
    property Oversold: Double read FOversold write FOversold;
    property Overbought: Double read FOverbought write FOverbought;
    property HTFMultiplier: Integer read FHTFMultiplier write FHTFMultiplier;
    property HTFOversold: Double read FHTFOversold write FHTFOversold;
    property HTFOverbought: Double read FHTFOverbought write FHTFOverbought;
    property StopLossPct: Double read FStopLossPct write FStopLossPct;
    property TrailingStopPct: Double read FTrailingStopPct write FTrailingStopPct;
  end;

implementation

function MkParam(const AName, ADisplay: AnsiString; AKind: TParamKind; const AValue: AnsiString): TStrategyParam;
begin
  Result.Name := AName;
  Result.Display := ADisplay;
  Result.Kind := AKind;
  Result.Value := AValue;
end;

{ ── Constructor ── }

constructor TDoubleRSIStrategy.Create;
begin
  inherited Create;
  FFastRSIPeriod := 7;
  FSlowRSIPeriod := 14;
  FOversold := 35.0;
  FOverbought := 65.0;
  FHTFMultiplier := 12;
  FHTFOversold := 40.0;
  FHTFOverbought := 60.0;
  FStopLossPct := 0.6;
  FTrailingStopPct := 0.35;
  FInPosition := False;
end;

function TDoubleRSIStrategy.DeclareParams: TArray<TStrategyParam>;
begin
  SetLength(Result, 6);
  Result[0] := MkParam('fast_rsi_period', 'Fast RSI Period', pkInteger, IntToStr(FFastRSIPeriod));
  Result[1] := MkParam('slow_rsi_period', 'Slow RSI Period', pkInteger, IntToStr(FSlowRSIPeriod));
  Result[2] := MkParam('oversold', 'Oversold', pkFloat, FloatToStr(FOversold));
  Result[3] := MkParam('overbought', 'Overbought', pkFloat, FloatToStr(FOverbought));
  Result[4] := MkParam('stop_loss_pct', 'Stop Loss %', pkFloat, FloatToStr(FStopLossPct));
  Result[5] := MkParam('trailing_stop_pct', 'Trailing Stop %', pkFloat, FloatToStr(FTrailingStopPct));
end;

procedure TDoubleRSIStrategy.ApplyParam(const AName, AValue: AnsiString);
begin
  if AName = 'fast_rsi_period' then FFastRSIPeriod := StrToIntDef(string(AValue), FFastRSIPeriod)
  else if AName = 'slow_rsi_period' then FSlowRSIPeriod := StrToIntDef(string(AValue), FSlowRSIPeriod)
  else if AName = 'oversold' then FOversold := StrToFloatDef(string(AValue), FOversold)
  else if AName = 'overbought' then FOverbought := StrToFloatDef(string(AValue), FOverbought)
  else if AName = 'stop_loss_pct' then FStopLossPct := StrToFloatDef(string(AValue), FStopLossPct)
  else if AName = 'trailing_stop_pct' then FTrailingStopPct := StrToFloatDef(string(AValue), FTrailingStopPct);
end;

function TDoubleRSIStrategy.GetParamValue(const AName: AnsiString): AnsiString;
begin
  if AName = 'fast_rsi_period' then Result := IntToStr(FFastRSIPeriod)
  else if AName = 'slow_rsi_period' then Result := IntToStr(FSlowRSIPeriod)
  else if AName = 'oversold' then Result := FloatToStr(FOversold)
  else if AName = 'overbought' then Result := FloatToStr(FOverbought)
  else if AName = 'stop_loss_pct' then Result := FloatToStr(FStopLossPct)
  else if AName = 'trailing_stop_pct' then Result := FloatToStr(FTrailingStopPct)
  else Result := '';
end;

{ ── Lifecycle ── }

procedure TDoubleRSIStrategy.OnStart;
begin
  inherited;
  FFastRSI.Init(FFastRSIPeriod);
  FSlowRSI.Init(FSlowRSIPeriod);
  FHTFRSI.Init(FSlowRSIPeriod);

  FHTFAccum := 0;
  FHTFTickCount := 0;
  FPrevFastAboveSlow := False;
  FPrevFastRSI := 50.0;
  FPrevSlowRSI := 50.0;

  FInPosition := False;
end;

procedure TDoubleRSIStrategy.OnTick(const ATick: TTickEvent);
var
  FastVal, SlowVal, HTFVal: Double;
  FastAboveSlow: Boolean;
  CrossUp, CrossDown: Boolean;
  PnLPct, TrailStop, HardStop: Double;
begin
  { Update LTF RSI }
  FastVal := FFastRSI.Update(ATick.LTP);
  SlowVal := FSlowRSI.Update(ATick.LTP);

  { Update HTF RSI: accumulate N ticks, feed average into HTF RSI }
  FHTFAccum := FHTFAccum + ATick.LTP;
  Inc(FHTFTickCount);
  if FHTFTickCount >= FHTFMultiplier then
  begin
    FHTFRSI.Update(FHTFAccum / FHTFTickCount);
    FHTFAccum := 0;
    FHTFTickCount := 0;
  end;
  HTFVal := FHTFRSI.Value;

  { Crossover detection }
  FastAboveSlow := FastVal > SlowVal;
  CrossUp := FastAboveSlow and (not FPrevFastAboveSlow);
  CrossDown := (not FastAboveSlow) and FPrevFastAboveSlow;
  FPrevFastAboveSlow := FastAboveSlow;
  FPrevFastRSI := FastVal;
  FPrevSlowRSI := SlowVal;

  if not WarmedUp then Exit;

  { ── Exit logic ── }
  if FInPosition then
  begin
    if FPositionSide = 1 then
    begin
      PnLPct := ((ATick.LTP - FEntryPrice) / FEntryPrice) * 100.0;

      { Update best price for trailing }
      if ATick.LTP > FBestPrice then
        FBestPrice := ATick.LTP;

      { Trailing stop: price fell TrailingStopPct from high }
      TrailStop := FBestPrice * (1.0 - FTrailingStopPct / 100.0);
      if ATick.LTP <= TrailStop then
      begin
        Sell(Underlying, Lots, 0, Exchange);
        PnL := PnL + (ATick.LTP - FEntryPrice) * Lots;
        FInPosition := False;
        Exit;
      end;

      { Hard stop }
      HardStop := FEntryPrice * (1.0 - FStopLossPct / 100.0);
      if ATick.LTP <= HardStop then
      begin
        Sell(Underlying, Lots, 0, Exchange);
        PnL := PnL + (ATick.LTP - FEntryPrice) * Lots;
        FInPosition := False;
        Exit;
      end;

      { RSI reversal exit: fast crosses below slow while overbought }
      if CrossDown and (FastVal > FOverbought) then
      begin
        Sell(Underlying, Lots, 0, Exchange);
        PnL := PnL + (ATick.LTP - FEntryPrice) * Lots;
        FInPosition := False;
        Exit;
      end;
    end
    else
    begin
      PnLPct := ((FEntryPrice - ATick.LTP) / FEntryPrice) * 100.0;

      { Update best price for trailing (short: lower is better) }
      if ATick.LTP < FBestPrice then
        FBestPrice := ATick.LTP;

      { Trailing stop: price rose TrailingStopPct from low }
      TrailStop := FBestPrice * (1.0 + FTrailingStopPct / 100.0);
      if ATick.LTP >= TrailStop then
      begin
        Buy(Underlying, Lots, 0, Exchange);
        PnL := PnL + (FEntryPrice - ATick.LTP) * Lots;
        FInPosition := False;
        Exit;
      end;

      { Hard stop }
      HardStop := FEntryPrice * (1.0 + FStopLossPct / 100.0);
      if ATick.LTP >= HardStop then
      begin
        Buy(Underlying, Lots, 0, Exchange);
        PnL := PnL + (FEntryPrice - ATick.LTP) * Lots;
        FInPosition := False;
        Exit;
      end;

      { RSI reversal exit: fast crosses above slow while oversold }
      if CrossUp and (FastVal < FOversold) then
      begin
        Buy(Underlying, Lots, 0, Exchange);
        PnL := PnL + (FEntryPrice - ATick.LTP) * Lots;
        FInPosition := False;
        Exit;
      end;
    end;

    Exit; // no new entry while in position
  end;

  { ── Entry logic ── }
  if not (FFastRSI.Ready and FSlowRSI.Ready and FHTFRSI.Ready) then Exit;

  { Long: fast RSI crosses above slow, both oversold, HTF confirms }
  if CrossUp and (FastVal < FOversold) and (SlowVal < FOversold)
    and (HTFVal < FHTFOversold) then
  begin
    Buy(Underlying, Lots, 0, Exchange);
    FInPosition := True;
    FPositionSide := 1;
    FEntryPrice := ATick.LTP;
    FBestPrice := ATick.LTP;
    Exit;
  end;

  { Short: fast RSI crosses below slow, both overbought, HTF confirms }
  if CrossDown and (FastVal > FOverbought) and (SlowVal > FOverbought)
    and (HTFVal > FHTFOverbought) then
  begin
    Sell(Underlying, Lots, 0, Exchange);
    FInPosition := True;
    FPositionSide := -1;
    FEntryPrice := ATick.LTP;
    FBestPrice := ATick.LTP;
  end;
end;

procedure TDoubleRSIStrategy.OnStop;
begin
  if FInPosition then
  begin
    if FPositionSide = 1 then
      Sell(Underlying, Lots, 0, Exchange)
    else
      Buy(Underlying, Lots, 0, Exchange);
    FInPosition := False;
  end;
end;

initialization
  RegisterStrategy('DoubleRSI', TDoubleRSIStrategy);

end.
