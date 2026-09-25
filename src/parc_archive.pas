{ Lectura de la estructura de un archivo FreeArc: descriptor final, FOOTER y DIR_BLOCKs.
  Referencia: docs/formato/FORMATO-ARC.md (§3, §5, §6). }
unit parc_archive;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_os, parc_bytes, parc_stream, parc_volume;

const
  ARC_SIGNATURE  = $01437241;  // "ArC\x01" little-endian (FreeArc .arc)
  PARC_SIGNATURE = $01724150;  // "PAr\x01" little-endian (.parc, FORMATO-PARC.md §1)
  PARC_FORMAT_VERSION = 1;     // versión del formato .parc que este lector entiende

  // Campos opcionales del directorio de .parc (FORMATO-PARC.md §2)
  DIRTAG_END       = 0;
  DIRTAG_MTIME_NS  = 1;
  DIRTAG_WIN_ATTR  = 2;
  DIRTAG_UNIX_MODE = 3;
  SCAN_MAX = 4096;             // el descriptor del FOOTER empieza dentro de los últimos 4096 bytes

  DESCR_BLOCK    = 0;
  HEADER_BLOCK   = 1;
  DATA_BLOCK     = 2;
  DIR_BLOCK      = 3;
  FOOTER_BLOCK   = 4;
  RECOVERY_BLOCK = 5;

type
  TArcBlock = record
    BlockType: Integer;
    Method: string;
    Pos: Int64;         // posición absoluta en el archivo
    OrigSize: Int64;    // DATA_BLOCK: suma de los tamaños de sus archivos
    CompSize: Int64;
    Crc: LongWord;      // DATA_BLOCK: 0 (no se guarda)
    FirstFile: Integer; // DATA_BLOCK: índice del primer archivo en TArchive.Files
    FileCount: Integer; // DATA_BLOCK: cantidad de archivos
  end;

  TArcFileEntry = record
    Name: string;       // ruta completa dentro del archivo, separador '/', UTF-8
    Size: Int64;
    Time: Int64;        // segundos Unix
    IsDir: Boolean;
    Crc: LongWord;
    DataBlock: Integer; // índice en TArchive.DataBlocks
    Offset: Int64;      // offset dentro del bloque sólido descomprimido
    // Extensiones de .parc (FORMATO-PARC.md §2); en .arc quedan en False
    HasMTimeNs, HasWinAttr, HasUnixMode: Boolean;
    MTimeNs: Int64;     // nanosegundos desde 1970 UTC
    WinAttr, UnixMode: LongWord;
  end;

  TArchive = class
  private
    FStream: TStream;           // un archivo, o los volúmenes x.001, x.002... (parc_volume)
    FFileName: string;
    procedure ReadAt(Pos: Int64; var Buf; Count: SizeInt);
    function TryReadDescriptor(const Raw: TBytes; Ofs, Len: SizeInt; DescrPos: Int64;
      out Block: TArcBlock; out Sig: LongWord): Boolean;
    procedure CheckParcHeader;
    function FindFooterDescriptor: TArcBlock;
    function ReadControlBlock(const Block: TArcBlock): TBytes;
    procedure ParseFooter(const Footer: TArcBlock);
    procedure ParseDirectory(const DirBlock: TArcBlock);
  public
    ArcSize: Int64;
    IsParc: Boolean;    // formato .parc (firma PAr\x01) en vez de .arc
    Footer: TArcBlock;
    ControlBlocks: array of TArcBlock;   // del FOOTER, en orden de archivo, sin el propio footer
    DataBlocks: array of TArcBlock;
    Files: array of TArcFileEntry;
    Locked: Boolean;
    Recovery: string;
    Comment: RawByteString;
    SFXSize: Int64;
    constructor Open(const AFileName: string);
    { Los bytes comprimidos de un bloque, como etapa de entrada (no es dueña del archivo). }
    function OpenBlockData(const Block: TArcBlock): TInStage;
    destructor Destroy; override;
    property FileName: string read FFileName;
  end;

function BlockTypeName(t: Integer): string;
function SanitizePath(const P: string): string;

implementation

uses
  parc_crc, parc_methods;

function BlockTypeName(t: Integer): string;
begin
  case t of
    DESCR_BLOCK:    Result := 'descriptor';
    HEADER_BLOCK:   Result := 'header';
    DATA_BLOCK:     Result := 'data';
    DIR_BLOCK:      Result := 'directory';
    FOOTER_BLOCK:   Result := 'footer';
    RECOVERY_BLOCK: Result := 'recovery';
  else
    Result := 'unknown(' + IntToStr(t) + ')';
  end;
end;

{ Normaliza separadores a '/', quita raíces absolutas ("/", "C:") y componentes "." y ".."
  (equivalente a remove_unsafe_dirs de FreeArc: evita escribir fuera del destino al extraer). }
function SanitizePath(const P: string): string;
var
  Parts: TStringArray;
  s, Part: string;
begin
  s := StringReplace(P, '\', '/', [rfReplaceAll]);
  if (Length(s) >= 2) and (s[2] = ':') then Delete(s, 1, 2);
  Result := '';
  Parts := s.Split(['/']);
  for Part in Parts do
  begin
    if (Part = '') or (Part = '.') or (Part = '..') then Continue;
    if Result <> '' then Result := Result + '/';
    Result := Result + Part;
  end;
end;

constructor TArchive.Open(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
  FStream := OpenArchiveStream(AFileName);
  ArcSize := FStream.Size;
  try
    Footer := FindFooterDescriptor;
  except
    // En volúmenes, lo más probable es que falte el último (el footer va al final)
    on E: EArcCorrupt do
      if FStream is TVolumeStream then
        Corrupt(E.Message + Format('; se leyeron %d volumen(es), hasta %s: ¿falta el siguiente?',
          [TVolumeStream(FStream).Names.Count, TVolumeStream(FStream).Names[TVolumeStream(FStream).Names.Count - 1]]))
      else
        raise;
  end;
  ParseFooter(Footer);
end;

destructor TArchive.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

function TArchive.OpenBlockData(const Block: TArcBlock): TInStage;
begin
  if (Block.Pos < 0) or (Block.CompSize < 0) or (Block.Pos + Block.CompSize > ArcSize) then
    Corrupt('bloque de datos fuera del archivo');
  Result := TFileSliceStage.Create(FStream, Block.Pos, Block.CompSize);
end;

procedure TArchive.ReadAt(Pos: Int64; var Buf; Count: SizeInt);
begin
  if (Pos < 0) or (Count < 0) or (Pos + Count > ArcSize) then Corrupt('bloque fuera del archivo');
  FStream.Position := Pos;
  FStream.ReadBuffer(Buf, Count);
end;

{ Intenta decodificar un descriptor local que empieza en Raw[Ofs] (con como mucho Len bytes
  disponibles). El CRC del descriptor ocupa los 4 bytes que siguen a sus campos, así que primero
  parseamos los campos y después verificamos el CRC sobre exactamente esos bytes. }
function TArchive.TryReadDescriptor(const Raw: TBytes; Ofs, Len: SizeInt; DescrPos: Int64;
  out Block: TArcBlock; out Sig: LongWord): Boolean;
var
  r: TByteReader;
  Stored: LongWord;
  FieldsLen: SizeInt;
begin
  Result := False;
  Sig := 0;
  Block := Default(TArcBlock);
  r.Init(@Raw[Ofs], Len);
  try
    Sig := r.U32;
    if (Sig <> ARC_SIGNATURE) and (Sig <> PARC_SIGNATURE) then Exit;
    Block.BlockType := r.VIntSize;
    Block.Method := r.CStr;
    Block.OrigSize := Int64(r.VInt);
    Block.CompSize := Int64(r.VInt);
    Block.Crc := r.U32;
    FieldsLen := r.Pos;
    Stored := r.U32;
  except
    on EArcCorrupt do Exit;
  end;
  if CalcCRC(@Raw[Ofs], FieldsLen) <> Stored then Exit;
  if (Block.OrigSize < 0) or (Block.CompSize < 0) or (Block.CompSize > DescrPos) then Exit;
  Block.Pos := DescrPos - Block.CompSize;
  Result := True;
end;

{ Busca hacia atrás, en los últimos SCAN_MAX bytes, la última firma que sea un descriptor válido. }
function TArchive.FindFooterDescriptor: TArcBlock;
var
  Sig: LongWord;
  Raw: TBytes;
  n, i: SizeInt;
  Base: Int64;
begin
  n := SCAN_MAX;
  if ArcSize < n then n := ArcSize;
  if n < 4 then Corrupt('no es un archivo FreeArc (demasiado chico)');
  Base := ArcSize - n;
  SetLength(Raw, n);
  ReadAt(Base, Raw[0], n);
  for i := n - 4 downto 0 do
    if (Raw[i + 3] = $01) and (((Raw[i] = $41) and (Raw[i + 1] = $72) and (Raw[i + 2] = $43)) or
                               ((Raw[i] = $50) and (Raw[i + 1] = $41) and (Raw[i + 2] = $72))) then
      if TryReadDescriptor(Raw, i, n - i, Base + i, Result, Sig) then
      begin
        if Result.BlockType <> FOOTER_BLOCK then
          Corrupt('el último bloque no es el footer');
        IsParc := Sig = PARC_SIGNATURE;
        Exit;
      end;
  raise EArcCorrupt.Create('no es un archivo FreeArc o está dañado (no se encontró el footer)');
end;

function TArchive.ReadControlBlock(const Block: TArcBlock): TBytes;
var
  Comp: TBytes;
begin
  if (Block.CompSize > High(SizeInt)) or (Block.OrigSize > High(SizeInt)) then
    Corrupt('bloque de control demasiado grande');
  SetLength(Comp, Block.CompSize);
  if Block.CompSize > 0 then ReadAt(Block.Pos, Comp[0], Block.CompSize);
  Result := DecompressMem(Block.Method, PByte(Comp), Length(Comp), Block.OrigSize);
  if CalcCRC(PByte(Result), Length(Result)) <> Block.Crc then
    Corrupt(Format('CRC incorrecto en bloque %s en pos %d', [BlockTypeName(Block.BlockType), Block.Pos]));
end;

procedure TArchive.ParseFooter(const Footer: TArcBlock);
var
  Data: TBytes;
  r: TByteReader;
  n, i: SizeInt;
  RelPos: QWord;
begin
  Data := ReadControlBlock(Footer);
  r.Init(PByte(Data), Length(Data));
  n := r.VIntSize;
  if n > r.Remaining then Corrupt('cantidad de bloques inválida');
  SetLength(ControlBlocks, n);
  for i := 0 to n - 1 do
    with ControlBlocks[i] do
    begin
      BlockType := r.VIntSize;
      Method := r.CStr;
      RelPos := r.VInt;
      if RelPos > QWord(Footer.Pos) then Corrupt('posición de bloque inválida');
      Pos := Footer.Pos - Int64(RelPos);
      OrigSize := Int64(r.VInt);
      CompSize := Int64(r.VInt);
      Crc := r.U32;
    end;
  Locked := r.U8 <> 0;
  n := r.VIntSize;                 // comentario viejo en UCS-4: FreeArc 0.67 escribe 0
  if n > r.Remaining div 4 then Corrupt('comentario inválido');
  r.Skip(n * 4);
  if not r.Eof then Recovery := r.CStr;
  if not r.Eof then
  begin
    n := r.VIntSize;
    Comment := r.Bytes(n);
    SetCodePage(Comment, CP_UTF8, False);
  end;

  SFXSize := Footer.Pos;
  for i := 0 to High(ControlBlocks) do
    if ControlBlocks[i].Pos < SFXSize then SFXSize := ControlBlocks[i].Pos;

  if IsParc then CheckParcHeader;
  for i := 0 to High(ControlBlocks) do
    if ControlBlocks[i].BlockType = DIR_BLOCK then
      ParseDirectory(ControlBlocks[i]);
end;

{ El HEADER de un .parc es "PAr\x01" + U32 versión (FORMATO-PARC.md §1): una versión mayor
  que la que entendemos puede usar extensiones obligatorias, así que se rechaza. }
procedure TArchive.CheckParcHeader;
var
  i: Integer;
  Data: TBytes;
  Version: LongWord;
begin
  for i := 0 to High(ControlBlocks) do
    if ControlBlocks[i].BlockType = HEADER_BLOCK then
    begin
      Data := ReadControlBlock(ControlBlocks[i]);
      if (Length(Data) < 8) or (Data[0] <> $50) or (Data[1] <> $41) or (Data[2] <> $72) or (Data[3] <> $01) then
        Corrupt('encabezado .parc inválido');
      Version := LongWord(Data[4]) or (LongWord(Data[5]) shl 8) or (LongWord(Data[6]) shl 16) or (LongWord(Data[7]) shl 24);
      if Version > PARC_FORMAT_VERSION then
        raise EArcCorrupt.CreateFmt('formato .parc versión %d: esta versión de PArc solo entiende hasta la %d',
          [Version, PARC_FORMAT_VERSION]);
      Exit;
    end;
end;

procedure TArchive.ParseDirectory(const DirBlock: TArcBlock);
var
  Data: TBytes;
  r: TByteReader;
  NBlocks, NDirs, Total, i, b, FirstBlock, FirstFile, k: SizeInt;
  Counts: array of SizeInt;
  Dirs: array of string;
  DirIdx: SizeInt;
  Ofs: QWord;
  Tag: QWord;
  Mandatory: Boolean;
  FieldLen, FieldEnd: SizeInt;
  BlockOfs: Int64;
begin
  Data := ReadControlBlock(DirBlock);
  r.Init(PByte(Data), Length(Data));

  NBlocks := r.VIntSize;
  if NBlocks > r.Remaining then Corrupt('cantidad de bloques de datos inválida');
  FirstBlock := Length(DataBlocks);
  FirstFile := Length(Files);
  SetLength(DataBlocks, FirstBlock + NBlocks);
  SetLength(Counts, NBlocks);
  Total := 0;
  for b := 0 to NBlocks - 1 do
  begin
    Counts[b] := r.VIntSize;
    if Counts[b] > r.Remaining then Corrupt('cantidad de archivos inválida');
    DataBlocks[FirstBlock + b] := Default(TArcBlock);
    DataBlocks[FirstBlock + b].BlockType := DATA_BLOCK;
    DataBlocks[FirstBlock + b].FirstFile := FirstFile + Total;
    DataBlocks[FirstBlock + b].FileCount := Counts[b];
    Inc(Total, Counts[b]);
  end;
  for b := 0 to NBlocks - 1 do
    DataBlocks[FirstBlock + b].Method := r.CStr;
  for b := 0 to NBlocks - 1 do
  begin
    Ofs := r.VInt;
    if Ofs > QWord(DirBlock.Pos) then Corrupt('posición de bloque de datos inválida');
    DataBlocks[FirstBlock + b].Pos := DirBlock.Pos - Int64(Ofs);
  end;
  for b := 0 to NBlocks - 1 do
    DataBlocks[FirstBlock + b].CompSize := Int64(r.VInt);

  NDirs := r.VIntSize;
  if NDirs > r.Remaining then Corrupt('cantidad de directorios inválida');
  SetLength(Dirs, NDirs);
  for i := 0 to NDirs - 1 do
    Dirs[i] := SanitizePath(r.CStr);

  // Cada campo por archivo va en su propia columna (FORMATO-ARC.md §6)
  if Total > r.Remaining then Corrupt('cantidad de archivos inválida');
  SetLength(Files, FirstFile + Total);
  for i := 0 to Total - 1 do
    Files[FirstFile + i].Name := r.CStr;
  for i := 0 to Total - 1 do
  begin
    DirIdx := r.VIntSize;
    if DirIdx >= NDirs then Corrupt('índice de directorio inválido');
    if Dirs[DirIdx] <> '' then
      Files[FirstFile + i].Name := Dirs[DirIdx] + '/' + SanitizePath(Files[FirstFile + i].Name)
    else
      Files[FirstFile + i].Name := SanitizePath(Files[FirstFile + i].Name);
  end;
  for i := 0 to Total - 1 do Files[FirstFile + i].Size := Int64(r.VInt);
  for i := 0 to Total - 1 do Files[FirstFile + i].Time := LongInt(r.U32);  // CTime de 32 bits con signo
  for i := 0 to Total - 1 do Files[FirstFile + i].IsDir := r.U8 <> 0;
  for i := 0 to Total - 1 do Files[FirstFile + i].Crc := r.U32;
  // Campos opcionales (FORMATO-PARC.md §2): tag, mandatory, len, datos; hasta tag = 0.
  // FreeArc 0.67 solo escribe el tag de fin
  while not r.Eof do
  begin
    Tag := r.VInt;
    if Tag = DIRTAG_END then Break;
    Mandatory := r.U8 <> 0;
    FieldLen := r.VIntSize;
    if FieldLen > r.Remaining then Corrupt('campo opcional del directorio truncado');
    FieldEnd := r.Pos + FieldLen;
    case Tag of
      DIRTAG_MTIME_NS:
        if FieldLen = 8 * Total then
          for i := 0 to Total - 1 do
          begin
            Files[FirstFile + i].MTimeNs := Int64(QWord(r.U32) or (QWord(r.U32) shl 32));
            Files[FirstFile + i].HasMTimeNs := True;
          end;
      DIRTAG_WIN_ATTR:
        if FieldLen = 4 * Total then
          for i := 0 to Total - 1 do
          begin
            Files[FirstFile + i].WinAttr := r.U32;
            Files[FirstFile + i].HasWinAttr := True;
          end;
      DIRTAG_UNIX_MODE:
        if FieldLen = 4 * Total then
          for i := 0 to Total - 1 do
          begin
            Files[FirstFile + i].UnixMode := r.U32;
            Files[FirstFile + i].HasUnixMode := True;
          end;
    else
      if Mandatory then
        raise EArcCorrupt.CreateFmt('el directorio usa una extensión obligatoria desconocida (tag %d)', [Tag]);
    end;
    r.Pos := FieldEnd;   // saltear lo que no se usó (tamaño inesperado o tag desconocido)
  end;

  // Derivados: bloque de datos, offset dentro del bloque sólido y tamaño original del bloque
  k := FirstFile;
  for b := 0 to NBlocks - 1 do
  begin
    BlockOfs := 0;
    for i := 0 to Counts[b] - 1 do
    begin
      Files[k].DataBlock := FirstBlock + b;
      Files[k].Offset := BlockOfs;
      Inc(BlockOfs, Files[k].Size);
      Inc(k);
    end;
    DataBlocks[FirstBlock + b].OrigSize := BlockOfs;
  end;
end;

end.
