{
  Topaz.EventTypes — Event records and cdecl callback trampolines.

  All record types use fixed-size fields only (no AnsiString, no dynamic
  arrays) so they are safe to pass through the lock-free ring buffer
  across thread boundaries.

  Callback procedures are cdecl and fire on Rust's internal thread.
  They must be fast, zero-alloc, and never touch GUI state.
}
unit Topaz.EventTypes;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

uses
  SysUtils, Topaz.RingBuffer;

const
  TICK_RING_CAPACITY    = 8192;
  ORDER_RING_CAPACITY   = 256;
  STATUS_RING_CAPACITY  = 64;
  MAX_STRATEGY_SLOTS    = 16;

type
  { ── Tick event (hot path — no managed types) ── }
  TTickEvent = record
    SymbolId: Integer;
    LTP: Double;
    Bid: Double;
    Ask: Double;
    Volume: Int64;
    OI: Int64;
  end;

  { ── Order event (from on_order callback) ── }
  TOrderEvent = record
    Json: array[0..2047] of AnsiChar;
    Len: Integer;
  end;

  { ── Connection status event ── }
  TStatusEvent = record
    Kind: Integer;   // 0 = connected, 1 = disconnected
    Feed: array[0..127] of AnsiChar;
    Reason: array[0..255] of AnsiChar;
  end;

  { ── Depth event ── }
  TDepthEvent = record
    SymbolId: Integer;
    Json: array[0..4095] of AnsiChar;
    Len: Integer;
  end;

  { ── Strategy tick bus slot ── }
  TStrategySlot = record
    Active: Boolean;
    Ticks: TRingBuffer<TTickEvent>;
  end;

  { ── Event bus: fan-out from callbacks to GUI + N strategies ── }
  TEventBus = class
  public
    GuiTicks: TRingBuffer<TTickEvent>;
    Orders: TRingBuffer<TOrderEvent>;
    Status: TRingBuffer<TStatusEvent>;
    Depths: TRingBuffer<TDepthEvent>;
    StrategySlots: array[0..MAX_STRATEGY_SLOTS - 1] of TStrategySlot;
    StrategyCount: Integer;
    constructor Create;
    function AddStrategySlot: Integer;     // returns slot index, -1 if full
    procedure RemoveStrategySlot(AIndex: Integer);
  end;

{ ── cdecl callback trampolines (UserData = TEventBus pointer) ── }

procedure CbTick(UserData: Pointer; SymbolId: Integer;
  LTP, Bid, Ask: Double; Volume, OI: Int64); cdecl;

procedure CbDepth(UserData: Pointer; SymbolId: Integer;
  Json: PAnsiChar); cdecl;

procedure CbCandle(UserData: Pointer; SymbolId: Integer;
  Json: PAnsiChar); cdecl;

procedure CbOrder(UserData: Pointer; Json: PAnsiChar); cdecl;

procedure CbConnect(UserData: Pointer; Feed: PAnsiChar); cdecl;

procedure CbDisconnect(UserData: Pointer; Feed: PAnsiChar;
  Reason: PAnsiChar); cdecl;

implementation

{ TEventBus }

constructor TEventBus.Create;
var
  I: Integer;
begin
  inherited Create;
  GuiTicks.Init(TICK_RING_CAPACITY);
  Orders.Init(ORDER_RING_CAPACITY);
  Status.Init(STATUS_RING_CAPACITY);
  Depths.Init(ORDER_RING_CAPACITY);
  StrategyCount := 0;
  for I := 0 to MAX_STRATEGY_SLOTS - 1 do
    StrategySlots[I].Active := False;
end;

function TEventBus.AddStrategySlot: Integer;
var
  I: Integer;
begin
  for I := 0 to MAX_STRATEGY_SLOTS - 1 do
  begin
    if not StrategySlots[I].Active then
    begin
      StrategySlots[I].Ticks.Init(TICK_RING_CAPACITY);
      StrategySlots[I].Active := True;
      Inc(StrategyCount);
      Exit(I);
    end;
  end;
  Result := -1;  // no free slot
end;

procedure TEventBus.RemoveStrategySlot(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex < MAX_STRATEGY_SLOTS) and StrategySlots[AIndex].Active then
  begin
    StrategySlots[AIndex].Active := False;
    StrategySlots[AIndex].Ticks.Reset;
    Dec(StrategyCount);
  end;
end;

{ ── Callback implementations ── }

procedure CbTick(UserData: Pointer; SymbolId: Integer;
  LTP, Bid, Ask: Double; Volume, OI: Int64); cdecl;
var
  Bus: TEventBus;
  Tick: TTickEvent;
  I: Integer;
begin
  Bus := TEventBus(UserData);
  Tick.SymbolId := SymbolId;
  Tick.LTP := LTP;
  Tick.Bid := Bid;
  Tick.Ask := Ask;
  Tick.Volume := Volume;
  Tick.OI := OI;

  // Fan-out: GUI + all active strategy slots
  Bus.GuiTicks.TryWrite(Tick);
  for I := 0 to MAX_STRATEGY_SLOTS - 1 do
    if Bus.StrategySlots[I].Active then
      Bus.StrategySlots[I].Ticks.TryWrite(Tick);
end;

procedure CbDepth(UserData: Pointer; SymbolId: Integer;
  Json: PAnsiChar); cdecl;
var
  Bus: TEventBus;
  Evt: TDepthEvent;
begin
  Bus := TEventBus(UserData);
  Evt.SymbolId := SymbolId;
  Evt.Len := StrLen(Json);
  if Evt.Len > SizeOf(Evt.Json) - 1 then
    Evt.Len := SizeOf(Evt.Json) - 1;
  Move(Json^, Evt.Json[0], Evt.Len);
  Evt.Json[Evt.Len] := #0;
  Bus.Depths.TryWrite(Evt);
end;

procedure CbCandle(UserData: Pointer; SymbolId: Integer;
  Json: PAnsiChar); cdecl;
begin
  // Reserved for future use — candle data logged but not queued yet
end;

procedure CbOrder(UserData: Pointer; Json: PAnsiChar); cdecl;
var
  Bus: TEventBus;
  Evt: TOrderEvent;
begin
  Bus := TEventBus(UserData);
  Evt.Len := StrLen(Json);
  if Evt.Len > SizeOf(Evt.Json) - 1 then
    Evt.Len := SizeOf(Evt.Json) - 1;
  Move(Json^, Evt.Json[0], Evt.Len);
  Evt.Json[Evt.Len] := #0;
  Bus.Orders.TryWrite(Evt);
end;

procedure CbConnect(UserData: Pointer; Feed: PAnsiChar); cdecl;
var
  Bus: TEventBus;
  Evt: TStatusEvent;
begin
  Bus := TEventBus(UserData);
  Evt.Kind := 0;  // connected
  StrLCopy(Evt.Feed, Feed, SizeOf(Evt.Feed) - 1);
  Evt.Reason[0] := #0;
  Bus.Status.TryWrite(Evt);
end;

procedure CbDisconnect(UserData: Pointer; Feed: PAnsiChar;
  Reason: PAnsiChar); cdecl;
var
  Bus: TEventBus;
  Evt: TStatusEvent;
begin
  Bus := TEventBus(UserData);
  Evt.Kind := 1;  // disconnected
  StrLCopy(Evt.Feed, Feed, SizeOf(Evt.Feed) - 1);
  if Reason <> nil then
    StrLCopy(Evt.Reason, Reason, SizeOf(Evt.Reason) - 1)
  else
    Evt.Reason[0] := #0;
  Bus.Status.TryWrite(Evt);
end;

end.
