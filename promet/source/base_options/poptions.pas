{ This file was automatically created by Lazarus. Do not edit!
  This source is only used to compile and install the package.
 }

unit pOptions;

interface

uses
  uMandantOptions, uOptions, uOptionsFrame, uPersonalOptions, uProcessOptions, 
  uuseroptions, uSyncOptions, uUserfieldDefOptions, LazarusPackageIntf;

implementation

procedure Register;
begin
end;

initialization
  RegisterPackage('pOptions', @Register);
end.