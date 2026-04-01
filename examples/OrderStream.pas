{
  OrderStream.pas — Subscribe to real-time order/trade updates.
  Compile:
    fpc -Mdelphi OrderStream.pas
}
program OrderStream;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  Apollo.Broker;

procedure OnOrder(UserData: Pointer; Json: PAnsiChar); cdecl;
begin
  WriteLn('[ORDER] ', Json);
end;

procedure OnTick(UserData: Pointer; SymbolId: Integer;
  LTP, Bid, Ask: Double; Volume, OI: Int64); cdecl;
begin
  // Minimal tick handler — just count
end;

procedure OnConnect(UserData: Pointer; Feed: PAnsiChar); cdecl;
begin
  WriteLn('>> Connected: ', Feed);
end;

procedure OnDisconnect(UserData: Pointer; Feed: PAnsiChar; Reason: PAnsiChar); cdecl;
begin
  WriteLn('>> Disconnected: ', Feed, ' - ', Reason);
end;

var
  B: TBroker;
begin
  B := TBroker.Create('upstox', 'YOUR_TOKEN_HERE', '');
  try
    B.Connect;

    B.SetCallbacks(@OnTick, nil, nil, @OnOrder, @OnConnect, @OnDisconnect, nil);
    B.StreamStart;
    B.SubscribeOrders;

    WriteLn('Listening for order updates... Press ENTER to stop.');
    ReadLn;

    B.StreamStop;
  finally
    B.Free;
  end;
end.
