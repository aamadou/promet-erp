unit urepairimages;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, db, FileUtil, Forms, Controls, Graphics, Dialogs, Menus,
  DbCtrls, StdCtrls, DBGrids, ButtonPanel, ComCtrls, ExtCtrls, uExtControls,
  uOrder;

type

  { TfRepairImages }

  TfRepairImages = class(TForm)
    ButtonPanel1: TButtonPanel;
    Datasource1: TDatasource;
    DBNavigator1: TDBNavigator;
    eName: TDBEdit;
    gList: TDBGrid;
    eFilter: TEdit;
    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    mErrordesc: TDBMemo;
    mSolve: TDBMemo;
    pCommon: TPanel;
    pcPages: TExtMenuPageControl;
    tsCommon: TTabSheet;
    procedure AddHistory(Sender: TObject);
    procedure DataSetDataSetAfterScroll(DataSet: TDataSet);
    procedure Datasource1StateChange(Sender: TObject);
    procedure eFilterEnter(Sender: TObject);
    procedure FormCreate(Sender: TObject);
  private
    { private declarations }
    FDataSet: TOrderRepairImages;
    procedure SetDataSet(AValue: TOrderRepairImages);
    procedure DoOpen;
  public
    { public declarations }
    procedure SetLanguage;
    function Execute : Boolean;
    property DataSet : TOrderRepairImages read FDataSet write SetDataSet;
  end;

var
  fRepairImages: TfRepairImages;

implementation
uses uData,uHistoryFrame,uIntfStrConsts;
{$R *.lfm}

{ TfRepairImages }

procedure TfRepairImages.FormCreate(Sender: TObject);
begin
  DataSet := TOrderRepairImages.Create(nil,Data);
  DataSet.CreateTable;
  DataSet.Open;
end;

procedure TfRepairImages.Datasource1StateChange(Sender: TObject);
begin
  if DataSet.State=dsInsert then
    eName.SetFocus;
end;

procedure TfRepairImages.AddHistory(Sender: TObject);
begin
  TfHistoryFrame(Sender).BaseName:='REPI';
  TfHistoryFrame(Sender).DataSet := TOrderRepairImages(FDataSet).History;
  TfHistoryFrame(Sender).SetRights(True);
end;

procedure TfRepairImages.DataSetDataSetAfterScroll(DataSet: TDataSet);
begin
  DoOpen;
end;

procedure TfRepairImages.eFilterEnter(Sender: TObject);
begin
  DataSet.Filter(Data.ProcessTerm('UPPER('+Data.QuoteField('NAME')+')=UPPER('+Data.QuoteValue('*'+fRepairImages.eFilter.Text+'*'))+') OR UPPER('+Data.ProcessTerm(Data.QuoteField('SYMTOMS')+')=UPPER('+Data.QuoteValue('*'+fRepairImages.eFilter.Text+'*'))+')');
end;

procedure TfRepairImages.SetDataSet(AValue: TOrderRepairImages);
begin
  if FDataSet=AValue then Exit;
  FDataSet:=AValue;
  Datasource1.DataSet := AValue.DataSet;
end;

procedure TfRepairImages.DoOpen;
begin
  pcPages.CloseAll;
  pcPages.AddTabClass(TfHistoryFrame,strHistory,@AddHistory);
  TOrderRepairImages(DataSet).History.Open;
  if TOrderRepairImages(DataSet).History.Count > 0 then
    pcPages.AddTab(TfHistoryFrame.Create(Self),False);
end;

procedure TfRepairImages.SetLanguage;
begin
  if not Assigned(fRepairImages) then
    begin
      Application.CreateForm(TfRepairImages,fRepairImages);
      Self := fRepairImages;
    end;

end;

function TfRepairImages.Execute: Boolean;
begin
  if not Assigned(fRepairImages) then
    begin
      Application.CreateForm(TfRepairImages,fRepairImages);
      Self := fRepairImages;
    end;
  DataSet.DataSet.AfterScroll:=@DataSetDataSetAfterScroll;
  DoOpen;
  Result := fRepairImages.ShowModal = mrOK;
  if Result and DataSet.CanEdit then
    DataSet.Post;
end;

end.

