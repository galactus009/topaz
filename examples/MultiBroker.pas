{
  MultiBroker.pas — Talk to multiple Thorium instances simultaneously.

  With the Thorium adapter the broker selection (Upstox, Fyers, Kite, ...)
  lives on the Thorium server side. To use multiple brokers from the
  client, run two Thorium instances bound to different ports and connect
  to each one.

  Compile:
    fpc -Mdelphi MultiBroker.pas
}
program MultiBroker;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  Thorium.Broker;

var
  Primary, Secondary: TBroker;
  PrimaryLTP, SecondaryLTP: Double;
begin
  Primary   := TBroker.Create('http://127.0.0.1:5000', 'PRIMARY_APIKEY');
  Secondary := TBroker.Create('http://127.0.0.1:5001', 'SECONDARY_APIKEY');
  try
    Primary.Connect;
    Secondary.Connect;

    // Compare LTP across instances (each may be attached to a different broker)
    PrimaryLTP   := Primary.LTP('RELIANCE', exNSE);
    SecondaryLTP := Secondary.LTP('RELIANCE', exNSE);
    WriteLn('RELIANCE LTP (primary):   ', PrimaryLTP:0:2);
    WriteLn('RELIANCE LTP (secondary): ', SecondaryLTP:0:2);
    WriteLn('Diff: ', Abs(PrimaryLTP - SecondaryLTP):0:2);
  finally
    Secondary.Free;
    Primary.Free;
  end;
end.
