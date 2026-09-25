{ Verificación y reparación de un archivo FreeArc con RECOVERY_BLOCK (`-rr`).

  El esquema lo describe FORMATO-ARC.md §7.4 y sale de ArcRecover.hs: no es
  Reed-Solomon, es un XOR rotativo. El archivo se recorre desde InitPos en trozos de
  SectorSize, cada trozo se XOR-ea en un sector de recuperación que rota con
  i := (i+1) mod RecSectors arrancando en i0 = (-arc_sectors) mod RecSectors, y de cada
  trozo se guarda además su CRC.

  La reparación sale de la misma identidad, y es lo que hace elegante al esquema:
  si R es el sector de recuperación guardado (el XOR de los trozos ORIGINALES del
  grupo), X el XOR de los trozos ACTUALES y D el trozo dañado que se leyó, entonces

        original_dañado = R xor X xor D

  porque X = R xor original xor actual. Todo lo del lado derecho se conoce, así que un
  grupo con un solo sector dañado se reconstruye exacto. Por eso cada grupo tolera un
  daño y el archivo tolera hasta RecSectors mientras no caigan dos en el mismo grupo. }
unit parc_recovery;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_bytes, parc_stream, parc_archive;

type
  TRecoveryInfo = record
    Version: string;
    ArcSize: Int64;      // bytes protegidos
    Offset: Int64;
    InitPos: Int64;      // dónde arranca la zona protegida
    SectorSize: Integer;
    RecSectors: Integer;
  end;

  TRecoveryResult = record
    Info: TRecoveryInfo;
    BadSectors: array of Int64;      // índices de sectores con CRC distinto
    Unrecoverable: array of Int64;   // los que no se pueden reconstruir (2+ en su grupo)
    Repaired: array of Int64;
  end;

{ Lee y valida la info de control. False si el archivo no tiene RECOVERY_BLOCKs. }
function RecoveryInfoOf(const ArcName: string; out Info: TRecoveryInfo): Boolean;

{ Recorre el archivo y devuelve qué sectores están dañados, sin escribir nada. }
function RecoveryScan(const ArcName: string; out Res: TRecoveryResult): Boolean;

{ Igual que Scan y además escribe DestName con los sectores dañados reparados.
  DestName queda vacío si no hay nada que reparar. El original nunca se toca. }
function RecoveryRepair(const ArcName: string; out Res: TRecoveryResult;
                        out DestName: string): Boolean;

implementation

uses
  parc_crc, parc_methods;

const
  RECOVERY_BLOCK = 5;

type
  TRecoveryData = record
    Info: TRecoveryInfo;
    Sectors: TBytes;   // los sectores de recuperación (RecSectors*SectorSize bytes)
    Crcs: TBytes;      // la zona de info+CRCs completa
    CrcsOfs: SizeInt;  // dónde empiezan los CRCs dentro de Crcs (después del addinfo)
  end;

{ Lee los dos RECOVERY_BLOCK (sectores y CRCs) usando la API pública de TArchive. }
function LoadRecovery(const ArcName: string; out D: TRecoveryData): Boolean;
var
  arc: TArchive;
  blocks: array of TArcBlock;
  i, n: Integer;
  st: TInStage;
  buf: array[0..65535] of Byte;
  cnt, got: SizeInt;
  r: TByteReader;
  npar: QWord;
begin
  Result := False;
  D.Info.Version := '';
  arc := TArchive.Open(ArcName);
  try
    SetLength(blocks, 0);
    for i := 0 to High(arc.ControlBlocks) do
      if arc.ControlBlocks[i].BlockType = RECOVERY_BLOCK then
      begin
        SetLength(blocks, Length(blocks) + 1);
        blocks[High(blocks)] := arc.ControlBlocks[i];
      end;
    if Length(blocks) < 2 then Exit;   // sin recuperación
    // El primer bloque son los sectores y el segundo la info+CRCs.
    st := arc.OpenBlockData(blocks[0]);
    try
      SetLength(D.Sectors, blocks[0].OrigSize);
      got := 0;
      while got < Length(D.Sectors) do
      begin
        cnt := Length(D.Sectors) - got;
        if cnt > SizeOf(buf) then cnt := SizeOf(buf);
        n := st.Read(@buf[0], cnt);
        if n <= 0 then Break;
        Move(buf[0], D.Sectors[got], n);
        Inc(got, n);
      end;
      if got <> Length(D.Sectors) then Corrupt('bloque de sectores de recuperación incompleto');
    finally
      st.Free;
    end;
    st := arc.OpenBlockData(blocks[1]);
    try
      SetLength(D.Crcs, blocks[1].OrigSize);
      got := 0;
      while got < Length(D.Crcs) do
      begin
        cnt := Length(D.Crcs) - got;
        if cnt > SizeOf(buf) then cnt := SizeOf(buf);
        n := st.Read(@buf[0], cnt);
        if n <= 0 then Break;
        Move(buf[0], D.Crcs[got], n);
        Inc(got, n);
      end;
      if got <> Length(D.Crcs) then Corrupt('bloque de CRCs de recuperación incompleto');
    finally
      st.Free;
    end;
    // addinfo: CStr version · VInt arcsize · VInt offset · VInt n · n pares (VInt, VInt)
    r.Init(@D.Crcs[0], Length(D.Crcs));
    D.Info.Version := string(r.CStr);
    D.Info.ArcSize := Int64(r.VInt);
    D.Info.Offset := Int64(r.VInt);
    npar := r.VInt;
    if npar < 1 then Exit;
    D.Info.SectorSize := Integer(r.VInt);
    D.Info.RecSectors := Integer(r.VInt);
    for i := 2 to npar do
    begin
      r.VInt; r.VInt;   // pares extra de otras versiones: se ignoran
    end;
    D.CrcsOfs := Length(D.Crcs) - r.Remaining;
    if (D.Info.SectorSize <= 0) or (D.Info.RecSectors <= 0) then Exit;
    D.Info.InitPos := blocks[1].Pos - D.Info.Offset;
    if (D.Info.InitPos < 0) or (D.Info.ArcSize <= 0) then Exit;
    Result := True;
  finally
    arc.Free;
  end;
end;

function RecoveryInfoOf(const ArcName: string; out Info: TRecoveryInfo): Boolean;
var
  D: TRecoveryData;
begin
  Result := LoadRecovery(ArcName, D);
  if Result then Info := D.Info;
end;

{ Recorre la zona protegida, acumula el XOR rotativo y compara los CRCs. }
function ScanFile(const ArcName: string; const D: TRecoveryData; out Res: TRecoveryResult;
                  var XorAcc: TBytes): Boolean;
var
  fs: TFileStream;
  buf: TBytes;
  i, k, arc_sectors: Int64;
  n, got, idx: SizeInt;
  crc: LongWord;
  r: TByteReader;
  cntBad: array of Integer;
begin
  Result := False;
  Res.Info := D.Info;
  SetLength(Res.BadSectors, 0);
  SetLength(Res.Unrecoverable, 0);
  SetLength(Res.Repaired, 0);
  arc_sectors := (D.Info.ArcSize + D.Info.SectorSize - 1) div D.Info.SectorSize;
  // El mismo arranque de la rotación que el escritor: i0 = (-arc_sectors) mod rec_sectors
  i := ((-arc_sectors) mod D.Info.RecSectors + D.Info.RecSectors) mod D.Info.RecSectors;
  SetLength(XorAcc, Int64(D.Info.RecSectors) * D.Info.SectorSize);
  FillChar(XorAcc[0], Length(XorAcc), 0);
  r.Init(@D.Crcs[D.CrcsOfs], Length(D.Crcs) - D.CrcsOfs);
  fs := TFileStream.Create(ArcName, fmOpenRead or fmShareDenyNone);
  try
    fs.Position := D.Info.InitPos;
    SetLength(buf, D.Info.SectorSize);
    k := 0;
    while k < arc_sectors do
    begin
      n := D.Info.SectorSize;
      if Int64(k) * D.Info.SectorSize + n > D.Info.ArcSize then
        n := D.Info.ArcSize - Int64(k) * D.Info.SectorSize;
      got := fs.Read(buf[0], n);
      if got <> n then Corrupt('no se pudo leer la zona protegida');
      // XOR en el sector de recuperación que toca
      for idx := 0 to n - 1 do
        XorAcc[Int64(i) * D.Info.SectorSize + idx] :=
          XorAcc[Int64(i) * D.Info.SectorSize + idx] xor buf[idx];
      crc := CalcCRC(PByte(@buf[0]), n);
      if crc <> r.U32 then
      begin
        SetLength(Res.BadSectors, Length(Res.BadSectors) + 1);
        Res.BadSectors[High(Res.BadSectors)] := k;
      end;
      Inc(k);
      i := (i + 1) mod D.Info.RecSectors;
    end;
  finally
    fs.Free;
  end;
  // Cuántos dañados por grupo: si hay más de uno, ese grupo no se puede reparar
  SetLength(cntBad, D.Info.RecSectors);
  for n := 0 to High(Res.BadSectors) do
  begin
    k := Res.BadSectors[n];
    i := (k + (((-arc_sectors) mod D.Info.RecSectors + D.Info.RecSectors) mod D.Info.RecSectors)) mod D.Info.RecSectors;
    Inc(cntBad[i]);
  end;
  for n := 0 to High(Res.BadSectors) do
  begin
    k := Res.BadSectors[n];
    i := (k + (((-arc_sectors) mod D.Info.RecSectors + D.Info.RecSectors) mod D.Info.RecSectors)) mod D.Info.RecSectors;
    if cntBad[i] > 1 then
    begin
      SetLength(Res.Unrecoverable, Length(Res.Unrecoverable) + 1);
      Res.Unrecoverable[High(Res.Unrecoverable)] := k;
    end;
  end;
  Result := True;
end;

function RecoveryScan(const ArcName: string; out Res: TRecoveryResult): Boolean;
var
  D: TRecoveryData;
  XorAcc: TBytes;
begin
  Result := False;
  if not LoadRecovery(ArcName, D) then Exit;
  Result := ScanFile(ArcName, D, Res, XorAcc);
end;

function RecoveryRepair(const ArcName: string; out Res: TRecoveryResult;
                        out DestName: string): Boolean;
var
  D: TRecoveryData;
  XorAcc, orig: TBytes;
  fs, out2: TFileStream;
  i, k, arc_sectors, base: Int64;
  n, got, idx, j: SizeInt;
  cntBad: array of Integer;
  reparados, malos, reparables: Integer;
begin
  Result := False;
  DestName := '';
  if not LoadRecovery(ArcName, D) then Exit;
  if not ScanFile(ArcName, D, Res, XorAcc) then Exit;
  SetLength(cntBad, D.Info.RecSectors);
  arc_sectors := (D.Info.ArcSize + D.Info.SectorSize - 1) div D.Info.SectorSize;
  base := ((-arc_sectors) mod D.Info.RecSectors + D.Info.RecSectors) mod D.Info.RecSectors;
  for n := 0 to High(Res.BadSectors) do
    Inc(cntBad[(Res.BadSectors[n] + base) mod D.Info.RecSectors]);
  if Length(Res.BadSectors) = 0 then Exit(True);   // no hay nada que reparar

  { Copia del archivo, y se sobreescriben los sectores reparables. Si no hay ninguno
    reparable no se escribe nada, que es lo que hace `arc r`: no deja un fixed.*
    idéntico al original dando a entender que arregló algo. }
  reparables := 0;
  for n := 0 to High(Res.BadSectors) do
    if cntBad[(Res.BadSectors[n] + base) mod D.Info.RecSectors] <= 1 then Inc(reparables);
  if reparables = 0 then Exit(True);

  DestName := ExtractFilePath(ArcName) + 'fixed.' + ExtractFileName(ArcName);
  if FileExists(DestName) then DeleteFile(DestName);
  out2 := TFileStream.Create(DestName, fmCreate);
  try
    fs := TFileStream.Create(ArcName, fmOpenRead or fmShareDenyNone);
    try
      out2.CopyFrom(fs, 0);
      SetLength(orig, D.Info.SectorSize);
      reparados := 0; malos := 0;
      for n := 0 to High(Res.BadSectors) do
      begin
        k := Res.BadSectors[n];
        i := (k + base) mod D.Info.RecSectors;
        if cntBad[i] > 1 then begin Inc(malos); Continue; end;
        // n del trozo (el último puede ser más corto)
        j := D.Info.SectorSize;
        if (k + 1) * D.Info.SectorSize > D.Info.ArcSize then
          j := D.Info.ArcSize - k * D.Info.SectorSize;
        // D = el trozo dañado tal como está
        fs.Position := D.Info.InitPos + k * D.Info.SectorSize;
        got := fs.Read(orig[0], j);
        if got <> j then Corrupt('no se pudo leer el sector dañado');
        // original = R xor X xor D
        for idx := 0 to j - 1 do
          orig[idx] := D.Sectors[Int64(i) * D.Info.SectorSize + idx] xor
                       XorAcc[Int64(i) * D.Info.SectorSize + idx] xor orig[idx];
        out2.Position := D.Info.InitPos + k * D.Info.SectorSize;
        out2.WriteBuffer(orig[0], j);
        Inc(reparados);
      end;
      SetLength(Res.Repaired, 0);
      for n := 0 to High(Res.BadSectors) do
      begin
        k := Res.BadSectors[n];
        i := (k + base) mod D.Info.RecSectors;
        if cntBad[i] <= 1 then
        begin
          SetLength(Res.Repaired, Length(Res.Repaired) + 1);
          Res.Repaired[High(Res.Repaired)] := k;
        end;
      end;
      Result := True;
    finally
      fs.Free;
    end;
  finally
    out2.Free;
  end;
end;

end.
