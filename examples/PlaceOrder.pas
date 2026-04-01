{
  PlaceOrder.pas — Place, modify, and cancel orders.
  Compile:
    fpc -Mdelphi PlaceOrder.pas
}
program PlaceOrder;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  Apollo.Broker;

var
  B: TBroker;
  OrderId: AnsiString;
begin
  B := TBroker.Create('upstox', 'YOUR_TOKEN_HERE', '');
  try
    B.Connect;
    WriteLn('Margin: ', B.AvailableMargin:0:2);

    // Market buy 1 share of SBIN intraday
    OrderId := B.PlaceOrder('SBIN', exNSE,
      sdBuy, okMarket, ptIntraday, vDay,
      1,       // qty
      0, 0,    // price, trigger (0 for market)
      'demo');  // tag
    WriteLn('Order placed: ', OrderId);

    // Modify to limit order at 750
    if B.ModifyOrder(OrderId, okLimit, 1, 750.0, 0) then
      WriteLn('Modified to limit @ 750')
    else
      WriteLn('Modify failed: ', B.LastError);

    // Cancel
    if B.CancelOrder(OrderId) then
      WriteLn('Cancelled')
    else
      WriteLn('Cancel failed: ', B.LastError);

    // Check positions
    WriteLn('Positions: ', B.PositionsJson);
  finally
    B.Free;
  end;
end.
