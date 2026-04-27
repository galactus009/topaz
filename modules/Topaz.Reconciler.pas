(**
 * Topaz.Reconciler — Broker State Reconciliation
 *
 * Compares local position state (TStateManager) with broker-reported
 * positions (TBroker.PositionsJson) and identifies drifts:
 *   - match:        local and broker agree on symbol and qty
 *   - qty_mismatch: symbol exists in both but qty differs
 *   - broker_only:  broker has a position not tracked locally (orphan)
 *   - local_only:   local tracks a position the broker doesn't show (stale)
 *
 * FlattenOrphans can auto-exit broker_only positions via TBroker.ExitPosition.
 *)
unit Topaz.Reconciler;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, fpjson, jsonparser,
  Thorium.Broker, Topaz.State;

type
  TDriftItem = record
    Symbol: AnsiString;
    Exchange: TExchange;          // exchange the broker reported (or local default)
    LocalQty: Integer;
    BrokerQty: Integer;
    LocalAvgPrice: Double;
    BrokerAvgPrice: Double;
    Action: AnsiString;  // 'match', 'local_only', 'broker_only', 'qty_mismatch'
  end;

  TReconciler = class
  private
    FBroker: TBroker;
    FState: TStateManager;
    FDrifts: TList<TDriftItem>;
    FLastReconcileTime: TDateTime;
    FBrokerPositions: TList<TDriftItem>;  // parsed broker view (reused internally)

    procedure ParseBrokerPositions(const AJson: AnsiString);
  public
    constructor Create(ABroker: TBroker; AState: TStateManager);
    destructor Destroy; override;

    // Run reconciliation: compare local state with broker positions
    procedure Reconcile;

    // Query results
    function DriftCount: Integer;
    function GetDrift(AIndex: Integer): TDriftItem;
    function HasDrift: Boolean;
    function DriftSummary: AnsiString;  // human-readable summary

    // Auto-flatten orphaned broker positions not in local state
    procedure FlattenOrphans;

    property LastReconcileTime: TDateTime read FLastReconcileTime;
  end;

implementation

{ TReconciler }

constructor TReconciler.Create(ABroker: TBroker; AState: TStateManager);
begin
  inherited Create;
  FBroker := ABroker;
  FState := AState;
  FDrifts := TList<TDriftItem>.Create;
  FBrokerPositions := TList<TDriftItem>.Create;
  FLastReconcileTime := 0;
end;

destructor TReconciler.Destroy;
begin
  FBrokerPositions.Free;
  FDrifts.Free;
  inherited;
end;

function ExchangeFromString(const S: AnsiString): TExchange;
var
  U: AnsiString;
begin
  U := UpperCase(S);
  if      (U = 'NSE') or (U = 'NSE_EQ') or (U = 'NSE_INDEX') then Result := exNSE
  else if (U = 'BSE') or (U = 'BSE_EQ') or (U = 'BSE_INDEX') then Result := exBSE
  else if (U = 'NFO') or (U = 'NSE_FO') then Result := exNFO
  else if (U = 'BFO') or (U = 'BSE_FO') then Result := exBFO
  else if  U = 'MCX' then Result := exMCX
  else if (U = 'CDS') or (U = 'BCD')    then Result := exCDS
  else                                       Result := exNSE;
end;

procedure TReconciler.ParseBrokerPositions(const AJson: AnsiString);
var
  Root: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  Item: TDriftItem;
  Qty: Integer;
  I: Integer;
begin
  FBrokerPositions.Clear;
  if AJson = '' then Exit;

  Root := GetJSON(AJson);
  try
    if not (Root is TJSONArray) then Exit;
    Arr := TJSONArray(Root);

    for I := 0 to Arr.Count - 1 do
    begin
      if not (Arr.Items[I] is TJSONObject) then Continue;
      Obj := TJSONObject(Arr.Items[I]);

      Item := Default(TDriftItem);
      Item.Symbol := Obj.Get('symbol', '');
      Item.Exchange := ExchangeFromString(Obj.Get('exchange', ''));
      // Thorium's positionbook reports `quantity` and `netqty`; some legacy
      // proxies still emit `qty`. `netqty` is canonical for net position.
      Qty := Obj.Get('netqty',
        Obj.Get('quantity', Obj.Get('qty', 0)));
      Item.BrokerQty := Qty;
      Item.BrokerAvgPrice := Obj.Get('average_price',
        Obj.Get('avg_price', Double(0)));
      Item.LocalQty := 0;
      Item.LocalAvgPrice := 0;
      Item.Action := '';

      // Skip zero-qty positions (already closed at broker)
      if Item.BrokerQty <> 0 then
        FBrokerPositions.Add(Item);
    end;
  finally
    Root.Free;
  end;
end;

procedure TReconciler.Reconcile;
var
  LocalPositions: TArray<TPositionState>;
  LocalMatched: array of Boolean;
  BrokerItem, Drift: TDriftItem;
  I, J: Integer;
  Found: Boolean;
begin
  FDrifts.Clear;

  // Get broker positions
  ParseBrokerPositions(FBroker.PositionsJson);

  // Get local positions
  LocalPositions := FState.GetPositions;
  SetLength(LocalMatched, Length(LocalPositions));
  for I := 0 to High(LocalMatched) do
    LocalMatched[I] := False;

  // For each broker position, find matching local position
  for I := 0 to FBrokerPositions.Count - 1 do
  begin
    BrokerItem := FBrokerPositions[I];
    Found := False;

    for J := 0 to High(LocalPositions) do
    begin
      if LocalPositions[J].Symbol = BrokerItem.Symbol then
      begin
        LocalMatched[J] := True;
        Found := True;

        Drift := Default(TDriftItem);
        Drift.Symbol := BrokerItem.Symbol;
        Drift.Exchange := BrokerItem.Exchange;
        Drift.BrokerQty := BrokerItem.BrokerQty;
        Drift.BrokerAvgPrice := BrokerItem.BrokerAvgPrice;
        Drift.LocalQty := LocalPositions[J].Qty;
        Drift.LocalAvgPrice := LocalPositions[J].AvgPrice;

        if Drift.LocalQty = Drift.BrokerQty then
          Drift.Action := 'match'
        else
          Drift.Action := 'qty_mismatch';

        FDrifts.Add(Drift);
        Break;
      end;
    end;

    if not Found then
    begin
      // Broker has position not tracked locally — orphan
      Drift := Default(TDriftItem);
      Drift.Symbol := BrokerItem.Symbol;
      Drift.Exchange := BrokerItem.Exchange;
      Drift.BrokerQty := BrokerItem.BrokerQty;
      Drift.BrokerAvgPrice := BrokerItem.BrokerAvgPrice;
      Drift.LocalQty := 0;
      Drift.LocalAvgPrice := 0;
      Drift.Action := 'broker_only';
      FDrifts.Add(Drift);
    end;
  end;

  // Local positions not found at broker — stale
  for J := 0 to High(LocalPositions) do
  begin
    if not LocalMatched[J] then
    begin
      Drift := Default(TDriftItem);
      Drift.Symbol := LocalPositions[J].Symbol;
      Drift.LocalQty := LocalPositions[J].Qty;
      Drift.LocalAvgPrice := LocalPositions[J].AvgPrice;
      Drift.BrokerQty := 0;
      Drift.BrokerAvgPrice := 0;
      Drift.Action := 'local_only';
      FDrifts.Add(Drift);
    end;
  end;

  FLastReconcileTime := Now;
end;

function TReconciler.DriftCount: Integer;
begin
  Result := FDrifts.Count;
end;

function TReconciler.GetDrift(AIndex: Integer): TDriftItem;
begin
  Result := FDrifts[AIndex];
end;

function TReconciler.HasDrift: Boolean;
var
  I: Integer;
begin
  for I := 0 to FDrifts.Count - 1 do
    if FDrifts[I].Action <> 'match' then
      Exit(True);
  Result := False;
end;

function TReconciler.DriftSummary: AnsiString;
var
  SL: TStringList;
  D: TDriftItem;
  I: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Add(Format('Reconciliation at %s — %d items:',
      [FormatDateTime('hh:nn:ss', FLastReconcileTime), FDrifts.Count]));

    for I := 0 to FDrifts.Count - 1 do
    begin
      D := FDrifts[I];
      if D.Action = 'match' then
        SL.Add(Format('  [OK]    %s  qty=%d  avg=%.2f',
          [D.Symbol, D.BrokerQty, D.BrokerAvgPrice]))
      else if D.Action = 'qty_mismatch' then
        SL.Add(Format('  [DRIFT] %s  local=%d  broker=%d  (avg local=%.2f broker=%.2f)',
          [D.Symbol, D.LocalQty, D.BrokerQty, D.LocalAvgPrice, D.BrokerAvgPrice]))
      else if D.Action = 'broker_only' then
        SL.Add(Format('  [ORPHAN] %s  broker_qty=%d  avg=%.2f  (not tracked locally)',
          [D.Symbol, D.BrokerQty, D.BrokerAvgPrice]))
      else if D.Action = 'local_only' then
        SL.Add(Format('  [STALE] %s  local_qty=%d  avg=%.2f  (not at broker)',
          [D.Symbol, D.LocalQty, D.LocalAvgPrice]));
    end;

    if not HasDrift then
      SL.Add('  All positions in sync.');

    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TReconciler.FlattenOrphans;
var
  D: TDriftItem;
  I: Integer;
begin
  for I := 0 to FDrifts.Count - 1 do
  begin
    D := FDrifts[I];
    if D.Action = 'broker_only' then
      FBroker.ExitPosition(D.Symbol, D.Exchange);
  end;
end;

end.
