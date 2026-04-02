{
  Topaz.OptionTemplates -- Pre-built Multi-Leg Strategy Templates.

  Builds multi-leg option structures (straddle, strangle, iron condor, etc.)
  by resolving strikes and symbols via TBroker, then packages them as
  TMultiLegIntent for atomic submission through the intent engine.

  Includes payoff-at-expiry calculation and max profit/loss/breakeven.
}
unit Topaz.OptionTemplates;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Math, Apollo.Broker, Topaz.Intents;

type
  TTemplateKind = (
    tkStraddle,       // ATM CE + PE (same strike)
    tkStrangle,       // OTM CE + PE (different strikes)
    tkIronCondor,     // sell OTM CE + PE, buy further OTM CE + PE (4 legs)
    tkIronButterfly,  // sell ATM CE + PE, buy OTM CE + PE (4 legs)
    tkBullCallSpread, // buy lower CE, sell higher CE
    tkBearPutSpread,  // buy higher PE, sell lower PE
    tkCalendarSpread, // sell near expiry, buy far expiry (same strike) — not implemented
    tkRatioSpread     // buy 1 ATM, sell 2 OTM (1:2 ratio)
  );

  TTemplateSide = (tsBuy, tsSell);  // buy = long the structure, sell = short it

  TTemplateLeg = record
    Symbol: AnsiString;
    SymbolId: Integer;
    Strike: Double;
    IsCall: Boolean;
    Side: TSide;
    Qty: Integer;
  end;

  TTemplateResult = record
    Kind: TTemplateKind;
    Legs: array of TTemplateLeg;
    MaxProfit: Double;     // at expiry
    MaxLoss: Double;       // at expiry
    BreakevenUp: Double;   // upper breakeven
    BreakevenDown: Double; // lower breakeven
    NetPremium: Double;    // positive = credit, negative = debit
  end;

  TOptionTemplate = class
  private
    class function FlipSide(ASide: TSide): TSide; static; inline;
    class function ResolveLeg(ABroker: TBroker; const AUnderlying: AnsiString;
      AExpiry: Int64; AStrike: Double; AIsCall: Boolean; ASide: TSide;
      AQty: Integer): TTemplateLeg; static;
  public
    { Build a template -- resolves all legs via broker }
    class function Build(ABroker: TBroker; const AUnderlying: AnsiString;
      AKind: TTemplateKind; ASide: TTemplateSide; ALots: Integer;
      AExpiry: Int64; ASpot: Double;
      AWidthPoints: Double = 100
    ): TTemplateResult; static;

    { Convert to multi-leg intent for submission }
    class function ToMultiLegIntent(const ATemplate: TTemplateResult;
      const ATag: AnsiString = ''): TMultiLegIntent; static;

    { Compute payoff at a given spot price at expiry }
    class function PayoffAtExpiry(const ATemplate: TTemplateResult;
      ASpotAtExpiry: Double): Double; static;
  end;

implementation

{ ── Helpers ──────────────────────────────────────────────────────────────────── }

class function TOptionTemplate.FlipSide(ASide: TSide): TSide;
begin
  if ASide = sdBuy then
    Result := sdSell
  else
    Result := sdBuy;
end;

class function TOptionTemplate.ResolveLeg(ABroker: TBroker;
  const AUnderlying: AnsiString; AExpiry: Int64; AStrike: Double;
  AIsCall: Boolean; ASide: TSide; AQty: Integer): TTemplateLeg;
var
  OT: TOptionType;
begin
  if AIsCall then
    OT := otCall
  else
    OT := otPut;

  Result.Strike := AStrike;
  Result.IsCall := AIsCall;
  Result.Side := ASide;
  Result.Qty := AQty;
  Result.SymbolId := ABroker.ResolveOption(AUnderlying, AExpiry, AStrike, OT, exNFO);
  if Result.SymbolId >= 0 then
    Result.Symbol := ABroker.CatalogSymbol(Result.SymbolId)
  else
    Result.Symbol := '';
end;

{ ── Build ────────────────────────────────────────────────────────────────────── }

class function TOptionTemplate.Build(ABroker: TBroker;
  const AUnderlying: AnsiString; AKind: TTemplateKind; ASide: TTemplateSide;
  ALots: Integer; AExpiry: Int64; ASpot: Double;
  AWidthPoints: Double): TTemplateResult;
var
  ATM: Double;
  BuySide, SellSide: TSide;
  P1, P2, P3, P4: Double;  // leg premiums (LTP)
begin
  FillChar(Result, SizeOf(TTemplateResult), 0);
  Result.Kind := AKind;

  ATM := ABroker.ATMStrike(AUnderlying, AExpiry, ASpot);

  // Determine base buy/sell sides; for tsSell we flip everything
  if ASide = tsBuy then
  begin
    BuySide := sdBuy;
    SellSide := sdSell;
  end
  else
  begin
    BuySide := sdSell;
    SellSide := sdBuy;
  end;

  case AKind of

    { ── Straddle: ATM CE + PE at same strike ── }
    tkStraddle:
    begin
      SetLength(Result.Legs, 2);
      Result.Legs[0] := ResolveLeg(ABroker, AUnderlying, AExpiry, ATM, True, BuySide, ALots);
      Result.Legs[1] := ResolveLeg(ABroker, AUnderlying, AExpiry, ATM, False, BuySide, ALots);

      P1 := ABroker.LTP(Result.Legs[0].Symbol, exNFO);
      P2 := ABroker.LTP(Result.Legs[1].Symbol, exNFO);

      if ASide = tsBuy then
      begin
        // Long straddle: pay premium
        Result.NetPremium := -(P1 + P2);
        Result.MaxLoss := (P1 + P2) * ALots;
        Result.MaxProfit := MaxDouble;  // unlimited
        Result.BreakevenUp := ATM + P1 + P2;
        Result.BreakevenDown := ATM - P1 - P2;
      end
      else
      begin
        // Short straddle: receive premium
        Result.NetPremium := P1 + P2;
        Result.MaxProfit := (P1 + P2) * ALots;
        Result.MaxLoss := MaxDouble;  // unlimited
        Result.BreakevenUp := ATM + P1 + P2;
        Result.BreakevenDown := ATM - P1 - P2;
      end;
    end;

    { ── Strangle: OTM CE + PE at different strikes ── }
    tkStrangle:
    begin
      SetLength(Result.Legs, 2);
      Result.Legs[0] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM + AWidthPoints, True, BuySide, ALots);
      Result.Legs[1] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM - AWidthPoints, False, BuySide, ALots);

      P1 := ABroker.LTP(Result.Legs[0].Symbol, exNFO);
      P2 := ABroker.LTP(Result.Legs[1].Symbol, exNFO);

      if ASide = tsBuy then
      begin
        Result.NetPremium := -(P1 + P2);
        Result.MaxLoss := (P1 + P2) * ALots;
        Result.MaxProfit := MaxDouble;
        Result.BreakevenUp := (ATM + AWidthPoints) + P1 + P2;
        Result.BreakevenDown := (ATM - AWidthPoints) - P1 - P2;
      end
      else
      begin
        Result.NetPremium := P1 + P2;
        Result.MaxProfit := (P1 + P2) * ALots;
        Result.MaxLoss := MaxDouble;
        Result.BreakevenUp := (ATM + AWidthPoints) + P1 + P2;
        Result.BreakevenDown := (ATM - AWidthPoints) - P1 - P2;
      end;
    end;

    { ── Iron Condor: sell OTM CE+PE, buy further OTM CE+PE (4 legs) ── }
    tkIronCondor:
    begin
      SetLength(Result.Legs, 4);
      // Sell inner wings
      Result.Legs[0] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM + AWidthPoints, True, SellSide, ALots);      // sell OTM CE
      Result.Legs[1] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM - AWidthPoints, False, SellSide, ALots);     // sell OTM PE
      // Buy outer wings
      Result.Legs[2] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM + 2 * AWidthPoints, True, BuySide, ALots);   // buy further OTM CE
      Result.Legs[3] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM - 2 * AWidthPoints, False, BuySide, ALots);  // buy further OTM PE

      P1 := ABroker.LTP(Result.Legs[0].Symbol, exNFO);
      P2 := ABroker.LTP(Result.Legs[1].Symbol, exNFO);
      P3 := ABroker.LTP(Result.Legs[2].Symbol, exNFO);
      P4 := ABroker.LTP(Result.Legs[3].Symbol, exNFO);

      if ASide = tsBuy then
      begin
        // Long iron condor (debit): buy inner, sell outer
        Result.NetPremium := -(P1 + P2 - P3 - P4);
        Result.MaxLoss := Abs(Result.NetPremium) * ALots;
        Result.MaxProfit := (AWidthPoints - Abs(Result.NetPremium)) * ALots;
      end
      else
      begin
        // Short iron condor (credit): sell inner, buy outer
        Result.NetPremium := P1 + P2 - P3 - P4;
        Result.MaxProfit := Result.NetPremium * ALots;
        Result.MaxLoss := (AWidthPoints - Result.NetPremium) * ALots;
      end;
      Result.BreakevenUp := (ATM + AWidthPoints) + Result.NetPremium;
      Result.BreakevenDown := (ATM - AWidthPoints) - Result.NetPremium;
    end;

    { ── Iron Butterfly: sell ATM CE+PE, buy OTM CE+PE (4 legs) ── }
    tkIronButterfly:
    begin
      SetLength(Result.Legs, 4);
      // Sell ATM
      Result.Legs[0] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM, True, SellSide, ALots);                     // sell ATM CE
      Result.Legs[1] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM, False, SellSide, ALots);                    // sell ATM PE
      // Buy wings
      Result.Legs[2] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM + AWidthPoints, True, BuySide, ALots);       // buy OTM CE
      Result.Legs[3] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM - AWidthPoints, False, BuySide, ALots);      // buy OTM PE

      P1 := ABroker.LTP(Result.Legs[0].Symbol, exNFO);
      P2 := ABroker.LTP(Result.Legs[1].Symbol, exNFO);
      P3 := ABroker.LTP(Result.Legs[2].Symbol, exNFO);
      P4 := ABroker.LTP(Result.Legs[3].Symbol, exNFO);

      if ASide = tsBuy then
      begin
        Result.NetPremium := -(P1 + P2 - P3 - P4);
        Result.MaxLoss := Abs(Result.NetPremium) * ALots;
        Result.MaxProfit := (AWidthPoints - Abs(Result.NetPremium)) * ALots;
      end
      else
      begin
        Result.NetPremium := P1 + P2 - P3 - P4;
        Result.MaxProfit := Result.NetPremium * ALots;
        Result.MaxLoss := (AWidthPoints - Result.NetPremium) * ALots;
      end;
      Result.BreakevenUp := ATM + Result.NetPremium;
      Result.BreakevenDown := ATM - Result.NetPremium;
    end;

    { ── Bull Call Spread: buy lower CE, sell higher CE ── }
    tkBullCallSpread:
    begin
      SetLength(Result.Legs, 2);
      Result.Legs[0] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM, True, BuySide, ALots);                      // buy ATM CE
      Result.Legs[1] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM + AWidthPoints, True, SellSide, ALots);      // sell OTM CE

      P1 := ABroker.LTP(Result.Legs[0].Symbol, exNFO);
      P2 := ABroker.LTP(Result.Legs[1].Symbol, exNFO);

      if ASide = tsBuy then
      begin
        Result.NetPremium := -(P1 - P2);  // debit
        Result.MaxLoss := Abs(Result.NetPremium) * ALots;
        Result.MaxProfit := (AWidthPoints - Abs(Result.NetPremium)) * ALots;
        Result.BreakevenUp := ATM + Abs(Result.NetPremium);
        Result.BreakevenDown := 0;  // no lower breakeven for bull spread
      end
      else
      begin
        Result.NetPremium := P1 - P2;  // credit
        Result.MaxProfit := Result.NetPremium * ALots;
        Result.MaxLoss := (AWidthPoints - Result.NetPremium) * ALots;
        Result.BreakevenUp := ATM + Result.NetPremium;
        Result.BreakevenDown := 0;
      end;
    end;

    { ── Bear Put Spread: buy higher PE, sell lower PE ── }
    tkBearPutSpread:
    begin
      SetLength(Result.Legs, 2);
      Result.Legs[0] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM, False, BuySide, ALots);                     // buy ATM PE
      Result.Legs[1] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM - AWidthPoints, False, SellSide, ALots);     // sell OTM PE

      P1 := ABroker.LTP(Result.Legs[0].Symbol, exNFO);
      P2 := ABroker.LTP(Result.Legs[1].Symbol, exNFO);

      if ASide = tsBuy then
      begin
        Result.NetPremium := -(P1 - P2);  // debit
        Result.MaxLoss := Abs(Result.NetPremium) * ALots;
        Result.MaxProfit := (AWidthPoints - Abs(Result.NetPremium)) * ALots;
        Result.BreakevenUp := 0;
        Result.BreakevenDown := ATM - Abs(Result.NetPremium);
      end
      else
      begin
        Result.NetPremium := P1 - P2;  // credit
        Result.MaxProfit := Result.NetPremium * ALots;
        Result.MaxLoss := (AWidthPoints - Result.NetPremium) * ALots;
        Result.BreakevenUp := 0;
        Result.BreakevenDown := ATM - Result.NetPremium;
      end;
    end;

    { ── Calendar Spread: requires two expiries — not implementable ── }
    tkCalendarSpread:
    begin
      // Calendar spread requires a second expiry parameter which is not
      // available in this interface. Legs are left empty.
      SetLength(Result.Legs, 0);
      Result.NetPremium := 0;
      Result.MaxProfit := 0;
      Result.MaxLoss := 0;
      Result.BreakevenUp := 0;
      Result.BreakevenDown := 0;
    end;

    { ── Ratio Spread: buy 1 ATM CE, sell 2 OTM CE (1:2) ── }
    tkRatioSpread:
    begin
      SetLength(Result.Legs, 2);
      Result.Legs[0] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM, True, BuySide, ALots);                          // buy 1 ATM CE
      Result.Legs[1] := ResolveLeg(ABroker, AUnderlying, AExpiry,
        ATM + AWidthPoints, True, SellSide, ALots * 2);     // sell 2 OTM CE

      P1 := ABroker.LTP(Result.Legs[0].Symbol, exNFO);
      P2 := ABroker.LTP(Result.Legs[1].Symbol, exNFO);

      if ASide = tsBuy then
      begin
        Result.NetPremium := -(P1 - 2 * P2);  // often a credit
        Result.MaxProfit := (AWidthPoints + Result.NetPremium) * ALots;
        Result.MaxLoss := MaxDouble;  // unlimited above upper strike
        Result.BreakevenUp := (ATM + AWidthPoints) +
          (AWidthPoints + Result.NetPremium);
        Result.BreakevenDown := ATM - Result.NetPremium;
      end
      else
      begin
        Result.NetPremium := P1 - 2 * P2;
        Result.MaxProfit := MaxDouble;
        Result.MaxLoss := (AWidthPoints - Result.NetPremium) * ALots;
        Result.BreakevenUp := (ATM + AWidthPoints) +
          (AWidthPoints - Result.NetPremium);
        Result.BreakevenDown := ATM + Result.NetPremium;
      end;
    end;
  end;
end;

{ ── ToMultiLegIntent ─────────────────────────────────────────────────────────── }

class function TOptionTemplate.ToMultiLegIntent(const ATemplate: TTemplateResult;
  const ATag: AnsiString): TMultiLegIntent;
var
  I: Integer;
begin
  SetLength(Result.Legs, Length(ATemplate.Legs));
  Result.AtomicExecution := True;
  Result.Tag := ATag;

  for I := 0 to High(ATemplate.Legs) do
  begin
    FillChar(Result.Legs[I], SizeOf(TIntent), 0);
    Result.Legs[I].Kind := ikEntry;
    Result.Legs[I].Symbol := ATemplate.Legs[I].Symbol;
    Result.Legs[I].Exchange := exNFO;
    Result.Legs[I].Side := ATemplate.Legs[I].Side;
    Result.Legs[I].Qty := ATemplate.Legs[I].Qty;
    Result.Legs[I].Price := 0;  // market order
    Result.Legs[I].Tag := ATag;
  end;
end;

{ ── PayoffAtExpiry ───────────────────────────────────────────────────────────── }

class function TOptionTemplate.PayoffAtExpiry(const ATemplate: TTemplateResult;
  ASpotAtExpiry: Double): Double;
var
  I: Integer;
  Intrinsic: Double;
  Multiplier: Integer;
begin
  Result := 0;

  for I := 0 to High(ATemplate.Legs) do
  begin
    // Compute intrinsic value at expiry
    if ATemplate.Legs[I].IsCall then
      Intrinsic := Max(0, ASpotAtExpiry - ATemplate.Legs[I].Strike)
    else
      Intrinsic := Max(0, ATemplate.Legs[I].Strike - ASpotAtExpiry);

    // Signed by side: buy = +1, sell = -1
    if ATemplate.Legs[I].Side = sdBuy then
      Multiplier := ATemplate.Legs[I].Qty
    else
      Multiplier := -ATemplate.Legs[I].Qty;

    Result := Result + Intrinsic * Multiplier;
  end;

  // Add net premium received/paid
  Result := Result + ATemplate.NetPremium;
end;

end.
