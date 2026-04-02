{
  Topaz.Strategy.ExpiryGamma -- 0DTE Straddle on Expiry Day.

  Sells (or buys) an ATM straddle on weekly expiry day (Thursday)
  and manages the combined premium with profit target / max loss.

  OnStart checks if today is Thursday (weekly expiry). If not,
  the strategy sets FSkipDay and does nothing.

  Entry: resolve ATM CE + PE via Broker, sell both (short straddle)
         or buy both (long straddle) depending on DefaultMode.
  Exit:  profit >= entry * ProfitTargetPct/100
         loss   >= entry * MaxLossPct/100
         OnStop squares off remaining legs.

  Parameters:
    DefaultMode      -- 'sell' for short straddle, 'buy' for long (default 'sell')
    ProfitTargetPct  -- target as % of entry premium (default 30)
    MaxLossPct       -- stop as % of entry premium (default 50)
    MaxAdjustments   -- max strike adjustments allowed (default 2)
}
unit Topaz.Strategy.ExpiryGamma;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  SysUtils, Apollo.Broker, Topaz.EventTypes, Topaz.Strategy;

type
  TGammaState = (gsInit, gsWaiting, gsPositioned, gsSquaredOff);

  TExpiryGammaStrategy = class(TStrategy)
  private
    FDefaultMode: AnsiString;       // 'sell' or 'buy'
    FProfitTargetPct: Double;
    FMaxLossPct: Double;
    FMaxAdjustments: Integer;

    FState: TGammaState;
    FSkipDay: Boolean;

    FExpiry: Int64;
    FStrike: Double;
    FLotSize: Integer;

    FCESymId: Integer;
    FPESymId: Integer;
    FCESymbol: AnsiString;
    FPESymbol: AnsiString;

    FCEEntry: Double;
    FPEEntry: Double;
    FEntryPremium: Double;

    FCELTP: Double;
    FPELTP: Double;
    FSpotLTP: Double;
    FGotCE: Boolean;
    FGotPE: Boolean;

    FCEOrderId: AnsiString;
    FPEOrderId: AnsiString;

    FAdjustmentCount: Integer;
    FIsSelling: Boolean;    // True if short straddle, False if long

    function IsExpiryDay: Boolean;
    function CurrentPremium: Double;
    procedure ResolveLegs;
    procedure EnterPosition;
    procedure ExitPosition;
  protected
    procedure OnStart; override;
    procedure OnTick(const ATick: TTickEvent); override;
    procedure OnStop; override;
  public
    constructor Create;
    function DeclareParams: TArray<TStrategyParam>; override;
    procedure ApplyParam(const AName, AValue: AnsiString); override;
    function GetParamValue(const AName: AnsiString): AnsiString; override;
    property DefaultMode: AnsiString read FDefaultMode write FDefaultMode;
    property ProfitTargetPct: Double read FProfitTargetPct write FProfitTargetPct;
    property MaxLossPct: Double read FMaxLossPct write FMaxLossPct;
    property MaxAdjustments: Integer read FMaxAdjustments write FMaxAdjustments;
  end;

implementation

const
  DEFAULT_LOT_SIZE = 75;

function MkParam(const AName, ADisplay: AnsiString; AKind: TParamKind; const AValue: AnsiString): TStrategyParam;
begin
  Result.Name := AName;
  Result.Display := ADisplay;
  Result.Kind := AKind;
  Result.Value := AValue;
end;

{ ── Constructor ── }

constructor TExpiryGammaStrategy.Create;
begin
  inherited Create;
  Exchange := exNFO;
  FDefaultMode := 'sell';
  FProfitTargetPct := 30.0;
  FMaxLossPct := 50.0;
  FMaxAdjustments := 2;
  FLotSize := DEFAULT_LOT_SIZE;
  FState := gsInit;
  FSkipDay := False;
  FCESymId := -1;
  FPESymId := -1;
  FAdjustmentCount := 0;
end;

function TExpiryGammaStrategy.DeclareParams: TArray<TStrategyParam>;
begin
  SetLength(Result, 4);
  Result[0] := MkParam('default_mode', 'Default Mode', pkString, FDefaultMode);
  Result[1] := MkParam('profit_target_pct', 'Profit Target %', pkFloat, FloatToStr(FProfitTargetPct));
  Result[2] := MkParam('max_loss_pct', 'Max Loss %', pkFloat, FloatToStr(FMaxLossPct));
  Result[3] := MkParam('max_adjustments', 'Max Adjustments', pkInteger, IntToStr(FMaxAdjustments));
end;

procedure TExpiryGammaStrategy.ApplyParam(const AName, AValue: AnsiString);
begin
  if AName = 'default_mode' then FDefaultMode := AValue
  else if AName = 'profit_target_pct' then FProfitTargetPct := StrToFloatDef(string(AValue), FProfitTargetPct)
  else if AName = 'max_loss_pct' then FMaxLossPct := StrToFloatDef(string(AValue), FMaxLossPct)
  else if AName = 'max_adjustments' then FMaxAdjustments := StrToIntDef(string(AValue), FMaxAdjustments);
end;

function TExpiryGammaStrategy.GetParamValue(const AName: AnsiString): AnsiString;
begin
  if AName = 'default_mode' then Result := FDefaultMode
  else if AName = 'profit_target_pct' then Result := FloatToStr(FProfitTargetPct)
  else if AName = 'max_loss_pct' then Result := FloatToStr(FMaxLossPct)
  else if AName = 'max_adjustments' then Result := IntToStr(FMaxAdjustments)
  else Result := '';
end;

{ ── Lifecycle ── }

procedure TExpiryGammaStrategy.OnStart;
begin
  inherited;
  FIsSelling := (FDefaultMode = 'sell');

  { Check if today is Thursday (weekly expiry) }
  { DayOfWeek: 1=Sunday, 2=Monday, ..., 5=Thursday, 6=Friday, 7=Saturday }
  if not IsExpiryDay then
  begin
    FSkipDay := True;
    Exit;
  end;

  FSkipDay := False;

  if Broker = nil then Exit;
  if Underlying = '' then Underlying := 'NIFTY 50';

  ResolveLegs;

  if (FCESymId >= 0) and (FPESymId >= 0) then
    FState := gsWaiting
  else
    FSkipDay := True;
end;

procedure TExpiryGammaStrategy.OnStop;
begin
  if FState = gsPositioned then
    ExitPosition;
end;

{ ── Tick processing ── }

procedure TExpiryGammaStrategy.OnTick(const ATick: TTickEvent);
var
  Premium, PnLAbs, PnLPct: Double;
begin
  if FSkipDay then Exit;
  if FState = gsSquaredOff then Exit;

  { Route tick to correct leg — always update prices even during warmup }
  if ATick.SymbolId = FCESymId then
  begin
    FCELTP := ATick.LTP;
    FGotCE := True;
  end
  else if ATick.SymbolId = FPESymId then
  begin
    FPELTP := ATick.LTP;
    FGotPE := True;
  end
  else
    FSpotLTP := ATick.LTP;

  if not WarmedUp then Exit;

  case FState of
    gsWaiting:
    begin
      { Wait until we have quotes on both legs before entering }
      if FGotCE and FGotPE and (FCELTP > 0) and (FPELTP > 0) then
        EnterPosition;
    end;

    gsPositioned:
    begin
      if (FCELTP <= 0) or (FPELTP <= 0) then Exit;

      Premium := CurrentPremium;

      { For short straddle: profit when premium decays }
      if FIsSelling then
      begin
        PnLAbs := FEntryPremium - Premium;
        PnL := PnLAbs * Lots * FLotSize;
      end
      else
      begin
        { For long straddle: profit when premium expands }
        PnLAbs := Premium - FEntryPremium;
        PnL := PnLAbs * Lots * FLotSize;
      end;

      if FEntryPremium > 0 then
        PnLPct := (PnLAbs / FEntryPremium) * 100
      else
        PnLPct := 0;

      { Profit target hit }
      if PnLPct >= FProfitTargetPct then
      begin
        ExitPosition;
        Exit;
      end;

      { Max loss hit }
      if PnLPct <= -FMaxLossPct then
      begin
        ExitPosition;
        Exit;
      end;
    end;
  end;
end;

{ ── Helpers ── }

function TExpiryGammaStrategy.IsExpiryDay: Boolean;
begin
  Result := (DayOfWeek(Date) = 5);  { 5 = Thursday }
end;

function TExpiryGammaStrategy.CurrentPremium: Double;
begin
  Result := FCELTP + FPELTP;
end;

procedure TExpiryGammaStrategy.ResolveLegs;
var
  Spot: Double;
begin
  Spot := Broker.LTP(Underlying, exNSE);
  if Spot <= 0 then Exit;
  FSpotLTP := Spot;

  FExpiry := Broker.NearestExpiry(Underlying, exNFO);
  if FExpiry <= 0 then Exit;

  FStrike := Broker.ATMStrike(Underlying, FExpiry, Spot);
  if FStrike <= 0 then Exit;

  FCESymId := Broker.ResolveOption(Underlying, FExpiry, FStrike, otCall, exNFO);
  FPESymId := Broker.ResolveOption(Underlying, FExpiry, FStrike, otPut, exNFO);

  if (FCESymId < 0) or (FPESymId < 0) then Exit;

  FCESymbol := Broker.CatalogSymbol(FCESymId);
  FPESymbol := Broker.CatalogSymbol(FPESymId);

  Broker.Subscribe(FCESymbol, exNFO, smQuote);
  Broker.Subscribe(FPESymbol, exNFO, smQuote);
end;

procedure TExpiryGammaStrategy.EnterPosition;
var
  Qty: Integer;
begin
  Qty := Lots * FLotSize;
  if Qty <= 0 then Qty := FLotSize;

  try
    if FIsSelling then
    begin
      { Short straddle: sell both legs }
      FCEOrderId := Sell(FCESymbol, Qty, 0, exNFO);
      FPEOrderId := Sell(FPESymbol, Qty, 0, exNFO);
    end
    else
    begin
      { Long straddle: buy both legs }
      FCEOrderId := Buy(FCESymbol, Qty, 0, exNFO);
      FPEOrderId := Buy(FPESymbol, Qty, 0, exNFO);
    end;

    FCEEntry := FCELTP;
    FPEEntry := FPELTP;
    FEntryPremium := FCEEntry + FPEEntry;
    FState := gsPositioned;
  except
    on E: Exception do
    begin
      { Attempt to unwind partial fill }
      if FCEOrderId <> '' then
      begin
        try
          if FIsSelling then
            Buy(FCESymbol, Qty, 0, exNFO)
          else
            Sell(FCESymbol, Qty, 0, exNFO);
        except
        end;
      end;
      FState := gsSquaredOff;
    end;
  end;
end;

procedure TExpiryGammaStrategy.ExitPosition;
var
  Qty: Integer;
begin
  Qty := Lots * FLotSize;
  if Qty <= 0 then Qty := FLotSize;

  try
    if FIsSelling then
    begin
      { Buy back sold legs }
      Buy(FCESymbol, Qty, 0, exNFO);
    end
    else
    begin
      { Sell bought legs }
      Sell(FCESymbol, Qty, 0, exNFO);
    end;
  except
  end;

  try
    if FIsSelling then
      Buy(FPESymbol, Qty, 0, exNFO)
    else
      Sell(FPESymbol, Qty, 0, exNFO);
  except
  end;

  if FEntryPremium > 0 then
  begin
    if FIsSelling then
      PnL := (FEntryPremium - CurrentPremium) * Lots * FLotSize
    else
      PnL := (CurrentPremium - FEntryPremium) * Lots * FLotSize;
  end;

  FState := gsSquaredOff;
end;

initialization
  RegisterStrategy('ExpiryGamma', TExpiryGammaStrategy);

end.
