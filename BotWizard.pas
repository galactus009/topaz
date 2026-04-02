{
  BotWizard -- Modal dialog for configuring and launching a new bot.

  Presents strategy selection, underlying symbol, lots, warmup ticks,
  and a grid for strategy-specific parameters.
}
unit BotWizard;

{$mode Delphi}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Dialogs,
  StdCtrls, Spin, Grids, Topaz.Strategy;

type
  TfrmBotWizard = class(TForm)
    lblStrategy: TLabel;
    cbxStrategy: TComboBox;
    lblUnderlying: TLabel;
    edtUnderlying: TEdit;
    lblLots: TLabel;
    edtLots: TSpinEdit;
    lblWarmup: TLabel;
    edtWarmup: TSpinEdit;
    lblParams: TLabel;
    gridParams: TStringGrid;
    btnOK: TButton;
    btnCancel: TButton;

    procedure FormCreate(Sender: TObject);
    procedure cbxStrategyChange(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
  private
    procedure PopulateStrategies;
    procedure PopulateParams;
  public
    function GetStrategyName: AnsiString;
    function GetUnderlying: AnsiString;
    function GetLots: Integer;
    function GetWarmupTicks: Integer;
    function GetParamCount: Integer;
    function GetParamName(I: Integer): AnsiString;
    function GetParamValue(I: Integer): AnsiString;
  end;

var
  frmBotWizard: TfrmBotWizard;

implementation

{$R *.lfm}

procedure TfrmBotWizard.FormCreate(Sender: TObject);
begin
  edtLots.Value := 1;
  edtWarmup.Value := 50;

  gridParams.ColCount := 2;
  gridParams.FixedRows := 1;
  gridParams.RowCount := 1;
  gridParams.Cells[0, 0] := 'Name';
  gridParams.Cells[1, 0] := 'Value';
  gridParams.ColWidths[0] := 140;
  gridParams.ColWidths[1] := 140;
  gridParams.Options := gridParams.Options + [goEditing] - [goRowSelect];

  PopulateStrategies;
end;

procedure TfrmBotWizard.PopulateStrategies;
var
  Regs: TArray<TStrategyRegistration>;
  I: Integer;
begin
  Regs := GetRegisteredStrategies;
  cbxStrategy.Items.Clear;
  for I := 0 to High(Regs) do
    cbxStrategy.Items.Add(string(Regs[I].Name));
  if cbxStrategy.Items.Count > 0 then
  begin
    cbxStrategy.ItemIndex := 0;
    PopulateParams;
  end;
end;

procedure TfrmBotWizard.cbxStrategyChange(Sender: TObject);
begin
  PopulateParams;
end;

procedure TfrmBotWizard.PopulateParams;
var
  Regs: TArray<TStrategyRegistration>;
  Idx: Integer;
  TempStrat: TStrategy;
  Params: TArray<TStrategyParam>;
  I: Integer;
begin
  gridParams.RowCount := 1;
  Idx := cbxStrategy.ItemIndex;
  if Idx < 0 then Exit;

  Regs := GetRegisteredStrategies;
  if Idx > High(Regs) then Exit;

  TempStrat := Regs[Idx].StrategyClass.Create;
  try
    Params := TempStrat.DeclareParams;
    if Params = nil then Exit;
    for I := 0 to High(Params) do
    begin
      gridParams.RowCount := gridParams.RowCount + 1;
      gridParams.Cells[0, I + 1] := string(Params[I].Name);
      gridParams.Cells[1, I + 1] := string(Params[I].Value);
    end;
  finally
    TempStrat.Free;
  end;
end;

procedure TfrmBotWizard.btnOKClick(Sender: TObject);
begin
  if cbxStrategy.ItemIndex < 0 then
  begin
    MessageDlg('Please select a strategy.', mtError, [mbOK], 0);
    Exit;
  end;
  if Trim(edtUnderlying.Text) = '' then
  begin
    MessageDlg('Please enter an underlying symbol.', mtError, [mbOK], 0);
    Exit;
  end;
  ModalResult := mrOK;
end;

procedure TfrmBotWizard.btnCancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

function TfrmBotWizard.GetStrategyName: AnsiString;
begin
  Result := AnsiString(cbxStrategy.Text);
end;

function TfrmBotWizard.GetUnderlying: AnsiString;
begin
  Result := AnsiString(edtUnderlying.Text);
end;

function TfrmBotWizard.GetLots: Integer;
begin
  Result := edtLots.Value;
end;

function TfrmBotWizard.GetWarmupTicks: Integer;
begin
  Result := edtWarmup.Value;
end;

function TfrmBotWizard.GetParamCount: Integer;
begin
  Result := gridParams.RowCount - 1;
end;

function TfrmBotWizard.GetParamName(I: Integer): AnsiString;
begin
  Result := AnsiString(gridParams.Cells[0, I + 1]);
end;

function TfrmBotWizard.GetParamValue(I: Integer): AnsiString;
begin
  Result := AnsiString(gridParams.Cells[1, I + 1]);
end;

end.
