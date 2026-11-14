{*******************************************************************************
  Unit1.pas
  Demo VCL application for uDataSetGPUFilter (OpenGL 4.3 Compute Shader)

  Populates an in-memory TFDMemTable with 1,000,000 rows, uploads the indexed
  columns to GPU VRAM, and compares real-time GPU filtering against a classic
  single-threaded CPU dataset scan.
*******************************************************************************}
unit Unit1;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  System.Diagnostics, System.StrUtils, System.Types,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls,
  Vcl.Grids, Vcl.DBGrids, Vcl.Samples.Spin,
  Data.DB, FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Param,
  FireDAC.Stan.Error, FireDAC.DatS, FireDAC.Phys.Intf, FireDAC.DApt.Intf,
  FireDAC.Comp.DataSet, FireDAC.Comp.Client,
  uDataSetGPUFilter;

type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FpnlTop: TPanel;
    FedtSearch: TEdit;
    FcmbCategory: TComboBox;
    FspnMinAmount: TSpinEdit;
    FbtnBenchmarkCPU: TButton;
    FlblStats: TLabel;
    FDBGrid: TDBGrid;

    FMemTable: TFDMemTable;
    FDataSource: TDataSource;
    FGPUFilter: TDataSetGPUFilter;
    FHitMask: array of Byte;
    FUseFilterMask: Boolean;

    procedure BuildUI;
    procedure GenerateSampleData(ARowCount: Integer);
    procedure FilterChanged(Sender: TObject);
    procedure BenchmarkCPUClick(Sender: TObject);
    procedure MemTableFilterRecord(DataSet: TDataSet; var Accept: Boolean);
    procedure RunGPUFilter;
  public
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

const
  ROW_COUNT = 1000000; // 1 million sample records

  BRANDS: array[0..9] of string = (
    'YUTANI', 'ULTRA', 'NANO', 'HYPER', 'CYBER',
    'QUANTUM', 'TURBO', 'MEGA', 'CORE', 'PRIME'
  );
  ITEMS: array[0..9] of string = (
    'SENSOR', 'MODULE', 'SERVER', 'DISPLAY', 'BATTERY',
    'ENGINE', 'SCANNER', 'ROUTER', 'VALVE', 'DRIVE'
  );
  MODELS: array[0..9] of string = (
    'MK-IV', 'X200', 'V3', 'LITE', 'MAX',
    'PRO', 'PLUS', 'ALPHA', 'EDITION', 'HD'
  );

procedure TForm1.BuildUI;
var
  lbl1, lbl2, lbl3: TLabel;
  I: Integer;
begin
  Caption := 'Delphi GPGPU DataSet Filter (OpenGL 4.3 Compute Shader)';
  Width := 980;
  Height := 640;
  Position := poScreenCenter;

  FpnlTop := TPanel.Create(Self);
  FpnlTop.Parent := Self;
  FpnlTop.Align := alTop;
  FpnlTop.Height := 82;
  FpnlTop.BevelOuter := bvNone;

  lbl1 := TLabel.Create(Self);
  lbl1.Parent := FpnlTop;
  lbl1.Left := 12;
  lbl1.Top := 10;
  lbl1.Caption := 'Live Full-Text Search (GPU):';

  FedtSearch := TEdit.Create(Self);
  FedtSearch.Parent := FpnlTop;
  FedtSearch.Left := 12;
  FedtSearch.Top := 28;
  FedtSearch.Width := 220;
  FedtSearch.TextHint := 'e.g. YUTANI, TERRAFORM, SENSOR...';
  FedtSearch.OnChange := FilterChanged;

  lbl2 := TLabel.Create(Self);
  lbl2.Parent := FpnlTop;
  lbl2.Left := 248;
  lbl2.Top := 10;
  lbl2.Caption := 'Category:';

  FcmbCategory := TComboBox.Create(Self);
  FcmbCategory.Parent := FpnlTop;
  FcmbCategory.Left := 248;
  FcmbCategory.Top := 28;
  FcmbCategory.Width := 150;
  FcmbCategory.Style := csDropDownList;
  FcmbCategory.Items.Add('All Categories');
  for I := 1 to 10 do
    FcmbCategory.Items.Add('Category ' + IntToStr(I));
  FcmbCategory.ItemIndex := 0;
  FcmbCategory.OnChange := FilterChanged;

  lbl3 := TLabel.Create(Self);
  lbl3.Parent := FpnlTop;
  lbl3.Left := 414;
  lbl3.Top := 10;
  lbl3.Caption := 'Min Amount:';

  FspnMinAmount := TSpinEdit.Create(Self);
  FspnMinAmount.Parent := FpnlTop;
  FspnMinAmount.Left := 414;
  FspnMinAmount.Top := 28;
  FspnMinAmount.Width := 100;
  FspnMinAmount.MinValue := 0;
  FspnMinAmount.MaxValue := 100000;
  FspnMinAmount.Increment := 500;
  FspnMinAmount.Value := 0;
  FspnMinAmount.OnChange := FilterChanged;

  FbtnBenchmarkCPU := TButton.Create(Self);
  FbtnBenchmarkCPU.Parent := FpnlTop;
  FbtnBenchmarkCPU.Left := 532;
  FbtnBenchmarkCPU.Top := 26;
  FbtnBenchmarkCPU.Width := 185;
  FbtnBenchmarkCPU.Height := 25;
  FbtnBenchmarkCPU.Caption := 'Benchmark CPU Loop';
  FbtnBenchmarkCPU.OnClick := BenchmarkCPUClick;

  FlblStats := TLabel.Create(Self);
  FlblStats.Parent := FpnlTop;
  FlblStats.Left := 12;
  FlblStats.Top := 58;
  FlblStats.Font.Style := [fsBold];
  FlblStats.Caption := 'Initializing...';

  FDBGrid := TDBGrid.Create(Self);
  FDBGrid.Parent := Self;
  FDBGrid.Align := alClient;
  FDBGrid.Options := FDBGrid.Options + [dgRowSelect, dgAlwaysShowSelection];
end;

procedure TForm1.FormCreate(Sender: TObject);
var
  SW: TStopwatch;
begin
  BuildUI;

  FDataSource := TDataSource.Create(Self);
  FMemTable := TFDMemTable.Create(Self);
  FMemTable.OnFilterRecord := MemTableFilterRecord;

  FMemTable.FieldDefs.Add('ID', ftInteger);
  FMemTable.FieldDefs.Add('Category', ftInteger);
  FMemTable.FieldDefs.Add('Amount', ftFloat);
  FMemTable.FieldDefs.Add('ProductName', ftString, 40);
  FMemTable.CreateDataSet;
  FDataSource.DataSet := FMemTable;
  FDBGrid.DataSource := FDataSource;

  Screen.Cursor := crHourGlass;
  try
    GenerateSampleData(ROW_COUNT);

    FGPUFilter := TDataSetGPUFilter.Create(100000);
    SetLength(FHitMask, ROW_COUNT + 2);

    // Upload the entire dataset once into GPU VRAM
    SW := TStopwatch.StartNew;
    FGPUFilter.Attach(FMemTable, 'Category', 'Amount', 'ProductName');
    SW.Stop;

    FlblStats.Caption := Format('Ready: %d rows uploaded to VRAM (%d MB) in %.1f ms.',
      [ROW_COUNT, (ROW_COUNT * SizeOf(TGPUDataRow)) div (1024 * 1024), SW.Elapsed.TotalMilliseconds]);
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FGPUFilter.Free;
end;

procedure TForm1.GenerateSampleData(ARowCount: Integer);
var
  I: Integer;
  ProdName: string;
begin
  RandSeed := 42;
  FMemTable.DisableControls;
  try
    for I := 1 to ARowCount do
    begin
      if I = 420000 then
        ProdName := 'YUTANI TERRAFORM'
      else if I = 875432 then
        ProdName := 'DELPHI GPU BOOST'
      else
        ProdName := BRANDS[Random(10)] + ' ' + ITEMS[Random(10)] + ' ' + MODELS[Random(10)];

      FMemTable.AppendRecord([
        I,
        1 + Random(10),
        Round((10 + Random(999000) / 100) * 100) / 100,
        ProdName
      ]);
    end;
    FMemTable.First;
  finally
    FMemTable.EnableControls;
  end;
end;

procedure TForm1.FilterChanged(Sender: TObject);
begin
  RunGPUFilter;
end;

procedure TForm1.RunGPUFilter;
var
  SW: TStopwatch;
  Hits: TIntegerDynArray;
  TotalMatches, I: Integer;
  HasFilter: Boolean;
begin
  if not Assigned(FGPUFilter) then Exit;

  HasFilter := (Trim(FedtSearch.Text) <> '') or (FcmbCategory.ItemIndex > 0) or (FspnMinAmount.Value > 0);
  if not HasFilter then
  begin
    FUseFilterMask := False;
    FMemTable.Filtered := False;
    FlblStats.Caption := Format('Showing all %d rows (no filter active).', [ROW_COUNT]);
    Exit;
  end;

  // Execute parallel OpenGL 4.3 Compute Shader query
  SW := TStopwatch.StartNew;
  Hits := FGPUFilter.Filter(FedtSearch.Text, FcmbCategory.ItemIndex, FspnMinAmount.Value, TotalMatches);
  SW.Stop;

  // Update fast O(1) lookup bitmask for TDBGrid display
  if Length(FHitMask) > 0 then
    FillChar(Pointer(FHitMask)^, Length(FHitMask), 0);

  for I := 0 to High(Hits) do
    if (Hits[I] >= 1) and (Hits[I] < Length(FHitMask)) then
      FHitMask[Hits[I]] := 1;

  FUseFilterMask := True;
  FMemTable.DisableControls;
  try
    FMemTable.Filtered := False;
    FMemTable.Filtered := True;
    if Length(Hits) > 0 then
      FMemTable.First;
  finally
    FMemTable.EnableControls;
  end;

  FlblStats.Caption := Format('GPU Filter: %d matches found in %.2f ms! (Grid capped at %d rows)',
    [TotalMatches, SW.Elapsed.TotalMilliseconds, FGPUFilter.MaxResults]);
end;

procedure TForm1.MemTableFilterRecord(DataSet: TDataSet; var Accept: Boolean);
var
  RowID: Integer;
begin
  if not FUseFilterMask then
  begin
    Accept := True;
    Exit;
  end;
  // Match directly against the 1-based ID column (1..ROW_COUNT)
  RowID := DataSet.Fields[0].AsInteger;
  Accept := (RowID >= 1) and (RowID < Length(FHitMask)) and (FHitMask[RowID] = 1);
end;

procedure TForm1.BenchmarkCPUClick(Sender: TObject);
var
  SW: TStopwatch;
  SearchUpper: string;
  TargetCat, CpuMatches: Integer;
  MinAmt: Single;
  FldCat, FldAmt, FldTxt: TField;
begin
  SearchUpper := UpperCase(Trim(FedtSearch.Text));
  TargetCat := FcmbCategory.ItemIndex;
  MinAmt := FspnMinAmount.Value;

  FMemTable.DisableControls;
  try
    FMemTable.Filtered := False;
    FldCat := FMemTable.FieldByName('Category');
    FldAmt := FMemTable.FieldByName('Amount');
    FldTxt := FMemTable.FieldByName('ProductName');

    // Classic sequential CPU table scan for direct speed comparison
    CpuMatches := 0;
    SW := TStopwatch.StartNew;
    FMemTable.First;
    while not FMemTable.Eof do
    begin
      if ((TargetCat <= 0) or (FldCat.AsInteger = TargetCat)) and
         (FldAmt.AsFloat >= MinAmt) and
         ((SearchUpper = '') or ContainsText(FldTxt.AsString, SearchUpper)) then
      begin
        Inc(CpuMatches);
      end;
      FMemTable.Next;
    end;
    SW.Stop;
  finally
    FMemTable.EnableControls;
  end;

  if FUseFilterMask then
    FMemTable.Filtered := True;

  ShowMessage(Format('Classic CPU Loop over %d rows:'#13#10 +
    'Matches: %d'#13#10 +
    'Duration: %.2f ms',
    [ROW_COUNT, CpuMatches, SW.Elapsed.TotalMilliseconds]));
end;

end.

