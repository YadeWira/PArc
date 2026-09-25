{ Archivos en varios volúmenes, al estilo de 7-Zip: "copia.parc.001", "copia.parc.002", ...
  Un archivo multivolumen es el MISMO archivo de siempre partido en pedazos de tamaño fijo
  (el último, más chico): TVolumeStream presenta los pedazos como un único stream continuo,
  así que el formato, el lector y el escritor no cambian. Sirve para .parc y .arc (FreeArc no
  lee volúmenes: un .arc partido hay que juntarlo para abrirlo con FreeArc). }
unit parc_volume;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TVolumeStream = class(TStream)
  private
    FNames: TStringList;
    FFiles: array of TFileStream;
    FSizes: array of Int64;
    FVolSize: Int64;         // escritura: tamaño de cada volumen (0 = lectura)
    FBase: string;
    FPos, FSize: Int64;
    procedure Locate(Pos: Int64; out Part: Integer; out Ofs: Int64);
    function PartName(i: Integer): string;
    procedure AddPart;
  protected
    function GetSize: Int64; override;
  public
    { Lectura de los volúmenes Base.001, Base.002, ... (todos los que haya, consecutivos). }
    constructor OpenRead(const Base: string);
    { Escritura en Base.001, Base.002, ... de VolSize bytes cada uno. }
    constructor CreateWrite(const Base: string; VolSize: Int64);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Names: TStringList read FNames;   // los volúmenes, en orden
  end;

{ Nombre del volumen i (1..) de Base: "Base.001". }
function VolumeName(const Base: string; i: Integer): string;

{ ¿FileName es un archivo en volúmenes? Acepta el nombre del primero ("x.parc.001") o la base
  ("x.parc") cuando no existe como archivo suelto y sí existe "x.parc.001". Base = sin ".001". }
function IsVolumeSet(const FileName: string; out Base: string): Boolean;

{ El stream del archivo: un TFileStream, o un TVolumeStream si es multivolumen. }
function OpenArchiveStream(const FileName: string): TStream;

{ ¿Existe el archivo, suelto o en volúmenes? }
function ArchiveExists(const FileName: string): Boolean;

{ Borra los volúmenes Base.NNN desde From en adelante (los que sobran de una versión anterior). }
procedure DeleteVolumesFrom(const Base: string; From: Integer);

{ Tamaño de -v: dígitos y un sufijo b/k/m/g (sin sufijo, bytes), como -v de 7-Zip. }
function ParseVolumeSize(const S: string; out Size: Int64): Boolean;

implementation

uses
  parc_os;

function VolumeName(const Base: string; i: Integer): string;
begin
  Result := Base + '.' + Format('%.3d', [i]);
end;

function IsVolumeSet(const FileName: string; out Base: string): Boolean;
var
  Ext: string;
begin
  Base := FileName;
  Ext := ExtractFileExt(FileName);
  if (Length(Ext) = 4) and (Ext = '.001') then
  begin
    Base := Copy(FileName, 1, Length(FileName) - 4);
    Exit(True);
  end;
  Result := not FileExists(FsPath(FileName)) and FileExists(FsPath(VolumeName(FileName, 1)));
end;

function OpenArchiveStream(const FileName: string): TStream;
var
  Base: string;
begin
  if IsVolumeSet(FileName, Base) then Result := TVolumeStream.OpenRead(Base)
  else Result := TFileStream.Create(FsPath(FileName), fmOpenRead or fmShareDenyWrite);
end;

function ArchiveExists(const FileName: string): Boolean;
var
  Base: string;
begin
  Result := FileExists(FsPath(FileName)) or
            (IsVolumeSet(FileName, Base) and FileExists(FsPath(VolumeName(Base, 1))));
end;

procedure DeleteVolumesFrom(const Base: string; From: Integer);
var
  i: Integer;
begin
  i := From;
  while FileExists(FsPath(VolumeName(Base, i))) do
  begin
    DeleteFile(FsPath(VolumeName(Base, i)));
    Inc(i);
  end;
end;

function ParseVolumeSize(const S: string; out Size: Int64): Boolean;
var
  i: Integer;
  n: Int64;
  c: Char;
begin
  Result := False;
  Size := 0;
  i := 1;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do Inc(i);
  if i = 1 then Exit;
  n := StrToInt64Def(Copy(S, 1, i - 1), -1);
  if n <= 0 then Exit;
  if i > Length(S) then c := 'b' else c := LowerCase(S[i]);
  if (i < Length(S)) and not ((i + 1 = Length(S)) and (LowerCase(S[i + 1]) = 'b')) then Exit;
  case c of
    'b': Size := n;
    'k': Size := n shl 10;
    'm': Size := n shl 20;
    'g': Size := n shl 30;
  else
    Exit;
  end;
  Result := True;
end;

{ TVolumeStream }

function TVolumeStream.PartName(i: Integer): string;
begin
  Result := VolumeName(FBase, i + 1);
end;

constructor TVolumeStream.OpenRead(const Base: string);
var
  i: Integer;
begin
  inherited Create;
  FBase := Base;
  FNames := TStringList.Create;
  i := 0;
  while FileExists(FsPath(PartName(i))) do
  begin
    SetLength(FFiles, i + 1);
    SetLength(FSizes, i + 1);
    FNames.Add(PartName(i));
    FFiles[i] := TFileStream.Create(FsPath(PartName(i)), fmOpenRead or fmShareDenyWrite);
    FSizes[i] := FFiles[i].Size;
    Inc(FSize, FSizes[i]);
    Inc(i);
  end;
  if i = 0 then raise EFOpenError.CreateFmt('no existe %s', [PartName(0)]);
  // Un hueco (falta uno del medio): los que siguen existen pero no se leerían
  if FileExists(FsPath(PartName(i + 1))) then
    raise EFOpenError.CreateFmt('falta el volumen %s (hay %s y %s)', [PartName(i), PartName(i - 1), PartName(i + 1)]);
end;

constructor TVolumeStream.CreateWrite(const Base: string; VolSize: Int64);
begin
  inherited Create;
  if VolSize <= 0 then raise EArgumentException.Create('tamaño de volumen inválido');
  FBase := Base;
  FVolSize := VolSize;
  FNames := TStringList.Create;
  AddPart;
end;

destructor TVolumeStream.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FFiles) do FFiles[i].Free;
  FNames.Free;
  inherited Destroy;
end;

procedure TVolumeStream.AddPart;
var
  i: Integer;
begin
  i := Length(FFiles);
  SetLength(FFiles, i + 1);
  SetLength(FSizes, i + 1);
  FFiles[i] := TFileStream.Create(FsPath(PartName(i)), fmCreate);
  FSizes[i] := 0;
  FNames.Add(PartName(i));
end;

function TVolumeStream.GetSize: Int64;
begin
  Result := FSize;
end;

{ En qué volumen y en qué posición de él cae Pos. En escritura los volúmenes tienen todos
  FVolSize (salvo el último); en lectura, el tamaño de cada uno. }
procedure TVolumeStream.Locate(Pos: Int64; out Part: Integer; out Ofs: Int64);
begin
  if FVolSize > 0 then
  begin
    Part := Pos div FVolSize;
    Ofs := Pos mod FVolSize;
    Exit;
  end;
  Part := 0;
  Ofs := Pos;
  while (Part < High(FSizes)) and (Ofs >= FSizes[Part]) do
  begin
    Dec(Ofs, FSizes[Part]);
    Inc(Part);
  end;
end;

function TVolumeStream.Read(var Buffer; Count: Longint): Longint;
var
  Part: Integer;
  Ofs, n: Int64;
  P: PByte;
  Got: Longint;
begin
  Result := 0;
  P := @Buffer;
  if FPos + Count > FSize then Count := FSize - FPos;
  while Count > 0 do
  begin
    Locate(FPos, Part, Ofs);
    if Part > High(FFiles) then Break;
    n := FSizes[Part] - Ofs;
    if n <= 0 then Break;
    if n > Count then n := Count;
    FFiles[Part].Position := Ofs;
    Got := FFiles[Part].Read(P^, n);
    if Got <= 0 then Break;
    Inc(P, Got); Inc(Result, Got); Inc(FPos, Got); Dec(Count, Got);
  end;
end;

function TVolumeStream.Write(const Buffer; Count: Longint): Longint;
var
  Part: Integer;
  Ofs, n: Int64;
  P: PByte;
begin
  if FVolSize = 0 then raise EStreamError.Create('volúmenes abiertos solo para lectura');
  Result := 0;
  P := @Buffer;
  while Count > 0 do
  begin
    Locate(FPos, Part, Ofs);
    while Part > High(FFiles) do AddPart;
    n := FVolSize - Ofs;
    if n > Count then n := Count;
    FFiles[Part].Position := Ofs;
    FFiles[Part].WriteBuffer(P^, n);
    if Ofs + n > FSizes[Part] then
    begin
      Inc(FSize, Ofs + n - FSizes[Part]);
      FSizes[Part] := Ofs + n;
    end;
    Inc(P, n); Inc(Result, n); Inc(FPos, n); Dec(Count, n);
  end;
end;

function TVolumeStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  case Origin of
    soBeginning: FPos := Offset;
    soCurrent: Inc(FPos, Offset);
    soEnd: FPos := FSize + Offset;
  end;
  if FPos < 0 then FPos := 0;
  Result := FPos;
end;

end.
