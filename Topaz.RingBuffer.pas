{
  Topaz.RingBuffer — Lock-free single-producer single-consumer ring buffer.

  Zero allocation after Init. No locks. No managed types allowed in T.
  Producer calls TryWrite from callback thread; consumer calls TryRead
  from GUI or strategy thread. They never block each other.

  Capacity must be a power of 2 (enforced by Init).
}
unit Topaz.RingBuffer;

{$IFDEF FPC}{$mode Delphi}{$H+}{$ENDIF}

interface

type
  TRingBuffer<T> = record
  private
    FItems: array of T;
    FMask: Integer;       // capacity - 1, for fast modulo via AND
    FWriteIdx: Integer;   // only modified by producer
    FReadIdx: Integer;    // only modified by consumer
  public
    procedure Init(ACapacity: Integer);
    function TryWrite(const AItem: T): Boolean;
    function TryRead(out AItem: T): Boolean;
    function Count: Integer;
    procedure Reset;
  end;

implementation

{ TRingBuffer<T> }

procedure TRingBuffer<T>.Init(ACapacity: Integer);
var
  Cap: Integer;
begin
  // Round up to next power of 2
  Cap := 16;
  while Cap < ACapacity do
    Cap := Cap shl 1;
  SetLength(FItems, Cap);
  FMask := Cap - 1;
  FWriteIdx := 0;
  FReadIdx := 0;
end;

function TRingBuffer<T>.TryWrite(const AItem: T): Boolean;
var
  NextIdx: Integer;
begin
  NextIdx := (FWriteIdx + 1) and FMask;
  if NextIdx = FReadIdx then
    Exit(False);  // full
  FItems[FWriteIdx] := AItem;
  // Store barrier: ensure item is written before index advances.
  // On x86/ARM64 with single-word stores this is naturally ordered,
  // but we add a compiler barrier to prevent reordering.
  {$IFDEF FPC}
  ReadWriteBarrier;
  {$ENDIF}
  FWriteIdx := NextIdx;
  Result := True;
end;

function TRingBuffer<T>.TryRead(out AItem: T): Boolean;
begin
  if FReadIdx = FWriteIdx then
    Exit(False);  // empty
  AItem := FItems[FReadIdx];
  {$IFDEF FPC}
  ReadWriteBarrier;
  {$ENDIF}
  FReadIdx := (FReadIdx + 1) and FMask;
  Result := True;
end;

function TRingBuffer<T>.Count: Integer;
begin
  Result := (FWriteIdx - FReadIdx) and FMask;
end;

procedure TRingBuffer<T>.Reset;
begin
  FWriteIdx := 0;
  FReadIdx := 0;
end;

end.
