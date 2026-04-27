{
  OptionChain.pas — Resolve options, find ATM, get nearest expiry.
  Compile:
    fpc -Mdelphi OptionChain.pas
}
program OptionChain;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  Thorium.Broker;

var
  B: TBroker;
  Expiry: Int64;
  Strike: Double;
  CE, PE: Integer;
  Spot: Double;
begin
  B := TBroker.Create('http://127.0.0.1:5000', 'YOUR_THORIUM_APIKEY');
  try
    B.Connect;

    // Get NIFTY spot price
    Spot := B.LTP('NIFTY 50', exNSE);
    WriteLn('NIFTY 50 spot: ', Spot:0:2);

    // Nearest weekly expiry
    Expiry := B.NearestExpiry('NIFTY 50', exNFO);
    WriteLn('Nearest expiry (unix): ', Expiry);

    // All expiries
    WriteLn('Expiries: ', B.ListExpiriesJson('NIFTY 50', exNFO));

    // ATM strike
    Strike := B.ATMStrike('NIFTY 50', Expiry, Spot);
    WriteLn('ATM strike: ', Strike:0:0);

    // All strikes for this expiry
    WriteLn('Strikes: ', B.ListStrikesJson('NIFTY 50', Expiry, exNFO));

    // Resolve CE and PE
    CE := B.ResolveOption('NIFTY 50', Expiry, Strike, otCall, exNFO);
    PE := B.ResolveOption('NIFTY 50', Expiry, Strike, otPut,  exNFO);
    WriteLn('CE SymbolId=', CE, '  name=', B.CatalogSymbol(CE));
    WriteLn('PE SymbolId=', PE, '  name=', B.CatalogSymbol(PE));

    // Get LTP for the options
    WriteLn('CE LTP: ', B.LTP(B.CatalogSymbol(CE), exNFO):0:2);
    WriteLn('PE LTP: ', B.LTP(B.CatalogSymbol(PE), exNFO):0:2);

    // Place an option order
    // OrderId := B.PlaceOrder(B.CatalogSymbol(CE), exNFO,
    //   sdBuy, okMarket, ptIntraday, vDay, 50, 0, 0);
  finally
    B.Free;
  end;
end.
