{
  IndicatorDemo — Streaming indicators on live tick data.

  Connects to a broker, subscribes to NIFTY 50, and prints
  RSI, MACD, Bollinger Bands, and VWAP on every tick.
}
program IndicatorDemo;

{$mode Delphi}{$H+}

uses
  SysUtils, Apollo.Broker, Topaz.Indicators;

var
  B: TBroker;
  RSI: TRSI;
  MACD: TMACD;
  BB: TBollingerBands;
  VWAP: TVWAP;
  EMA20: TEMA;
  TickCount: Integer;

procedure OnTick(UserData: Pointer; SymbolId: Integer;
  LTP, Bid, Ask: Double; Volume, OI: Int64); cdecl;
begin
  RSI.Update(LTP);
  MACD.Update(LTP);
  BB.Update(LTP);
  VWAP.Update(LTP, Volume);
  EMA20.Update(LTP);

  Inc(TickCount);
  if TickCount mod 10 = 0 then  // print every 10th tick
  begin
    WriteLn(Format('[%s] LTP=%.2f  RSI=%.1f  MACD=%.2f/%.2f  BB=[%.2f-%.2f-%.2f]  VWAP=%.2f  EMA20=%.2f', [
      FormatDateTime('hh:nn:ss', Now), LTP,
      RSI.Value, MACD.Value, MACD.Signal,
      BB.Lower, BB.Middle, BB.Upper,
      VWAP.Value, EMA20.Value
    ]));
  end;
end;

procedure OnConnect(UserData: Pointer; Feed: PAnsiChar); cdecl;
begin
  WriteLn('Connected: ', Feed);
end;

procedure OnDisconnect(UserData: Pointer; Feed: PAnsiChar; Reason: PAnsiChar); cdecl;
begin
  WriteLn('Disconnected: ', Reason);
end;

begin
  // Init indicators
  RSI.Init(14);
  MACD.Init(12, 26, 9);
  BB.Init(20, 2.0);
  VWAP.Init;
  EMA20.Init(20);
  TickCount := 0;

  B := TBroker.Create('upstox', ParamStr(1), '');
  try
    B.Connect;
    WriteLn('Instruments: ', B.InstrumentCount);

    B.SetCallbacks(@OnTick, nil, nil, nil, @OnConnect, @OnDisconnect, nil);
    B.StreamStart;
    B.Subscribe('NIFTY 50', exNSE, smQuote);

    WriteLn('Streaming with indicators... Press Enter to stop.');
    ReadLn;
    B.StreamStop;
  finally
    B.Free;
  end;
end.
