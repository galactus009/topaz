{
  StreamTicks.pas — Subscribe to real-time ticks and print to console.
  Compile:
    fpc -Mdelphi StreamTicks.pas
}
program StreamTicks;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  Apollo.Broker;

procedure OnTick(UserData: Pointer; SymbolId: Integer;
  LTP, Bid, Ask: Double; Volume, OI: Int64); cdecl;
begin
  WriteLn(Format('[%s] Sym=%d  LTP=%.2f  Bid=%.2f  Ask=%.2f  Vol=%d  OI=%d',
    [FormatDateTime('hh:nn:ss.zzz', Now), SymbolId, LTP, Bid, Ask, Volume, OI]));
end;

procedure OnDepth(UserData: Pointer; SymbolId: Integer; Json: PAnsiChar); cdecl;
begin
  WriteLn('Depth #', SymbolId, ': ', Json);
end;

procedure OnConnect(UserData: Pointer; Feed: PAnsiChar); cdecl;
begin
  WriteLn('>> Stream connected: ', Feed);
end;

procedure OnDisconnect(UserData: Pointer; Feed: PAnsiChar; Reason: PAnsiChar); cdecl;
begin
  WriteLn('>> Disconnected [', Feed, ']: ', Reason);
end;

var
  B: TBroker;
begin
  B := TBroker.Create('upstox', 'YOUR_TOKEN_HERE', '');
  try
    B.Connect;
    WriteLn('Connected. Instruments: ', B.InstrumentCount);

    B.SetCallbacks(@OnTick, @OnDepth, nil, nil, @OnConnect, @OnDisconnect, nil);
    B.StreamStart;

    // smLTP = LTP only, smQuote = +bid/ask, smFull = +depth
    B.Subscribe('NIFTY 50', exNSE, smFull);
    B.Subscribe('SBIN', exNSE, smQuote);
    B.Subscribe('RELIANCE', exNSE, smLTP);

    WriteLn('Streaming... Press ENTER to stop.');
    ReadLn;

    B.StreamStop;
    WriteLn('Total ticks received: ', B.TickCount);
  finally
    B.Free;
  end;
end.
