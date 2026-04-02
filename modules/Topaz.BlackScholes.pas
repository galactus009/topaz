{
  Topaz.BlackScholes -- Black-Scholes Greeks calculator.

  Record-based, zero-heap, suitable for hot-path usage.
  Uses Abramowitz & Stegun (1964) rational approximation for the
  cumulative standard normal distribution (max error ~7.5e-8).

  Edge cases: returns zeroed TGreeks when TTE <= 0, IV <= 0, or Spot <= 0.
}
unit Topaz.BlackScholes;

{$mode Delphi}{$H+}

interface

type
  TGreeks = record
    Delta: Double;
    Gamma: Double;
    Theta: Double;
    Vega:  Double;
    Rho:   Double;
  end;

  TBlackScholes = record
  private
    class function NormPDF(X: Double): Double; static; inline;
    class function NormCDF(X: Double): Double; static;
  public
    { Calculate Black-Scholes Greeks.
        Spot     - underlying price
        Strike   - option strike price
        TTE      - time to expiry in years
        IV       - implied volatility (annualised, e.g. 0.20 = 20%)
        RFR      - risk-free rate (annualised, e.g. 0.05 = 5%)
        DivYield - continuous dividend yield (annualised)
        IsCall   - True for call, False for put }
    class function Calculate(Spot, Strike, TTE, IV, RFR, DivYield: Double;
      IsCall: Boolean): TGreeks; static;
  end;

implementation

uses
  Math;

const
  INV_SQRT_2PI = 0.3989422804014327;  // 1 / sqrt(2 * pi)
  DAYS_PER_YEAR = 365.0;

{ ── Standard normal PDF: exp(-x^2/2) / sqrt(2*pi) ── }

class function TBlackScholes.NormPDF(X: Double): Double;
begin
  Result := INV_SQRT_2PI * Exp(-0.5 * X * X);
end;

{ ── Standard normal CDF — Abramowitz & Stegun 26.2.17 ── }

class function TBlackScholes.NormCDF(X: Double): Double;
const
  A1 =  0.254829592;
  A2 = -0.284496736;
  A3 =  1.421413741;
  A4 = -1.453152027;
  A5 =  1.061405429;
  P  =  0.3275911;
var
  T, Poly: Double;
  AbsX: Double;
begin
  AbsX := Abs(X);
  T := 1.0 / (1.0 + P * AbsX);
  Poly := ((((A5 * T + A4) * T + A3) * T + A2) * T + A1) * T;
  Result := 1.0 - Poly * Exp(-0.5 * AbsX * AbsX);
  if X < 0.0 then
    Result := 1.0 - Result;
end;

{ ── Calculate Greeks ── }

class function TBlackScholes.Calculate(Spot, Strike, TTE, IV, RFR, DivYield: Double;
  IsCall: Boolean): TGreeks;
var
  SqrtT, D1, D2: Double;
  DiscountDiv, DiscountRFR: Double;
  Nd1, Nd2, Pd1: Double;
begin
  // Edge cases: return zero Greeks
  if (TTE <= 0.0) or (IV <= 0.0) or (Spot <= 0.0) or (Strike <= 0.0) then
  begin
    Result.Delta := 0.0;
    Result.Gamma := 0.0;
    Result.Theta := 0.0;
    Result.Vega  := 0.0;
    Result.Rho   := 0.0;
    Exit;
  end;

  SqrtT := Sqrt(TTE);
  DiscountDiv := Exp(-DivYield * TTE);
  DiscountRFR := Exp(-RFR * TTE);

  D1 := (Ln(Spot / Strike) + (RFR - DivYield + 0.5 * IV * IV) * TTE)
        / (IV * SqrtT);
  D2 := D1 - IV * SqrtT;

  Pd1 := NormPDF(D1);

  if IsCall then
  begin
    Nd1 := NormCDF(D1);
    Nd2 := NormCDF(D2);

    Result.Delta := DiscountDiv * Nd1;
    Result.Gamma := DiscountDiv * Pd1 / (Spot * IV * SqrtT);
    Result.Theta := (-(Spot * DiscountDiv * Pd1 * IV) / (2.0 * SqrtT)
                     - RFR * Strike * DiscountRFR * Nd2
                     + DivYield * Spot * DiscountDiv * Nd1) / DAYS_PER_YEAR;
    Result.Vega  := Spot * DiscountDiv * Pd1 * SqrtT / 100.0;
    Result.Rho   := Strike * TTE * DiscountRFR * Nd2 / 100.0;
  end
  else
  begin
    Nd1 := NormCDF(-D1);
    Nd2 := NormCDF(-D2);

    Result.Delta := -DiscountDiv * Nd1;
    Result.Gamma := DiscountDiv * Pd1 / (Spot * IV * SqrtT);
    Result.Theta := (-(Spot * DiscountDiv * Pd1 * IV) / (2.0 * SqrtT)
                     + RFR * Strike * DiscountRFR * Nd2
                     - DivYield * Spot * DiscountDiv * Nd1) / DAYS_PER_YEAR;
    Result.Vega  := Spot * DiscountDiv * Pd1 * SqrtT / 100.0;
    Result.Rho   := -Strike * TTE * DiscountRFR * Nd2 / 100.0;
  end;
end;

end.
