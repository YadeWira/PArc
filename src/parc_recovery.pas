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

{ Construye los DOS cuerpos de RECOVERY_BLOCK para un archivo ya escrito (espejo
  del escritor de ArcRecover.hs). El llamador los mete en bloques de control
  RECOVERY_BLOCK, el de sectores primero y el de info+CRCs después.

  ArcSize es el tamaño protegido; ProtectedFrom es dónde arranca la protección (para
  el escritor de PArc es 0, o sea todo el archivo hasta antes de la recuperación);
  CrcsBlockPos es la posición ABSOLUTA donde va a quedar el bloque de info+CRCs, que
  es lo que se guarda como offset en el addinfo. Spec es el texto de -rr ("4%", "10s",
  "1*512"...). }
{ Los tamaños que van a salir, para poder reservar lugar ANTES de construir: el
  offset del addinfo es la posición del bloque de CRCs, así que el escritor necesita
  saber cuánto ocupan los dos bloques antes de saber dónde caen.

  OJO con CrcsSize: es el tamaño de los CRCs SOLAMENTE, sin el addinfo que va delante
  en el mismo bloque. El bloque de CRCs real mide CrcsSize + el addinfo, y el addinfo
  no tiene tamaño fijo porque se serializa con VInt (versión + arcsize + offset + la
  lista de pares): en un .arc de 104.535 bytes protegidos con 4% son 18 bytes, pero
  cambia con el tamaño del archivo y con los parámetros. Si necesitás el total exacto,
  se obtiene después de RecoveryBuild como Length(Crcs), que ya incluye el addinfo. }
function RecoveryPlan(ArcSize: Int64; const Spec: string;
                      out SectorSize, RecSectors: Integer;
                      out SectorsSize, CrcsSize: Int64): Boolean;

function RecoveryBuild(Arc: TStream; ArcSize, ProtectedFrom, CrcsBlockPos: Int64;
                       const Spec: string; out Sectors, Crcs: TBytes;
                       out Info: TRecoveryInfo): Boolean;

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
    { Con -rr0% no hay sectores de recuperación (versión 0.39): se puede VERIFICAR,
      no reparar. RecSectors = 0 es válido acá. }
    if D.Info.SectorSize <= 0 then Exit;
    if D.Info.RecSectors < 0 then Exit;
    D.Info.InitPos := blocks[1].Pos - D.Info.Offset;
    if (D.Info.InitPos < 0) or (D.Info.ArcSize <= 0) then Exit;
    Result := True;
  finally
    arc.Free;
  end;
end;


{ --- escritura del recovery record (espejo de ArcRecover.hs:104-181) --------- }

{ VInt: la forma más corta. La cantidad de bits 1 bajos del primer byte indica
  cuántos bytes extra siguen, y el valor va desplazado t bits en una palabra LE. }
procedure VIntPut(var B: TBytes; V: QWord);
var
  t, i: Integer;
  w: QWord;
  mark: QWord;
begin
  t := 1;
  while (t < 9) and (V >= (QWord(1) shl (7 * t))) do Inc(t);
  mark := (QWord(1) shl (t - 1)) - 1;      // t=1 -> 0, t=2 -> 01b, t=3 -> 011b...
  w := (V shl t) or mark;
  for i := 0 to t - 1 do
  begin
    SetLength(B, Length(B) + 1);
    B[High(B)] := Byte(w and $FF);
    w := w shr 8;
  end;
end;

procedure CStrPut(var B: TBytes; const S: string);
var i: Integer;
begin
  for i := 1 to Length(S) do
  begin
    SetLength(B, Length(B) + 1);
    B[High(B)] := Byte(S[i]);
  end;
  SetLength(B, Length(B) + 1);
  B[High(B)] := 0;
end;

procedure U32Put(var B: TBytes; V: LongWord);
begin
  SetLength(B, Length(B) + 4);
  B[High(B) - 3] := Byte(V); B[High(B) - 2] := Byte(V shr 8);
  B[High(B) - 1] := Byte(V shr 16); B[High(B)] := Byte(V shr 24);
end;

{ Parsea el texto de -rr. Devuelve en Wanted el tamaño pedido y en FixedSize el
  sector_size explícito (0 si no se pidió). }
function ParseRrSpec(const Spec: string; ArcSize: Int64; out Wanted: Int64;
                     out FixedSize: Integer): Boolean;
var
  s: string;
  p: Integer;
  n: Int64;
  mult: Int64;
  dig: string;
begin
  Result := False; Wanted := 0; FixedSize := 0;
  s := Trim(Spec);
  if s = '' then Exit;
  // forma "n*size": sector_size explícito
  p := Pos('*', s);
  if p > 0 then
  begin
    dig := Copy(s, 1, p - 1);
    n := StrToInt64Def(dig, -1);
    if n < 0 then Exit;
    dig := Copy(s, p + 1, MaxInt);
    mult := 1;
    if (dig <> '') and (dig[Length(dig)] = 'b') then Delete(dig, Length(dig), 1);
    if (dig <> '') and (dig[Length(dig)] = 's') then
    begin mult := 512; Delete(dig, Length(dig), 1); end;
    FixedSize := StrToInt64Def(dig, -1);
    if FixedSize < 1 then Exit;
    Wanted := n * FixedSize;
    Result := True;
    Exit;
  end;
  // sufijo
  mult := 1;
  if (s <> '') and (s[Length(s)] = 'b') then Delete(s, Length(s), 1);
  if (s <> '') and (s[Length(s)] = 's') then begin mult := 512; Delete(s, Length(s), 1); end;
  if (s <> '') and ((s[Length(s)] = '%') or (s[Length(s)] = 'p')) then
  begin
    Delete(s, Length(s), 1);
    n := StrToInt64Def(s, -1);
    if n < 0 then Exit;
    Wanted := (ArcSize div 100) * n;
    Result := True;
    Exit;
  end;
  n := StrToInt64Def(s, -1);
  if n < 0 then Exit;
  Wanted := n * mult;
  Result := True;
end;


function RecoveryPlan(ArcSize: Int64; const Spec: string;
                      out SectorSize, RecSectors: Integer;
                      out SectorsSize, CrcsSize: Int64): Boolean;
var
  wanted: Int64;
  fixed_size: Integer;
  arc_sectors, crcs_size0, rec_size: Int64;
  t: Integer;
  i64: Int64;
begin
  Result := False;
  SectorSize := 0; RecSectors := 0; SectorsSize := 0; CrcsSize := 0;
  if not ParseRrSpec(Spec, ArcSize, wanted, fixed_size) then Exit;
  if wanted < 0 then Exit;
  if fixed_size > 0 then
    SectorSize := fixed_size
  else if wanted = 0 then
    SectorSize := 4096
  else
  begin
    t := 0;
    i64 := (40 * ArcSize) div wanted;
    while (QWord(1) shl (t + 1)) <= QWord(i64) do Inc(t);
    SectorSize := 1 shl t;
    if SectorSize < 512 then SectorSize := 512;
  end;
  arc_sectors := (ArcSize + SectorSize - 1) div SectorSize;
  crcs_size0 := arc_sectors * 4;
  rec_size := wanted;
  if crcs_size0 > rec_size then rec_size := crcs_size0;
  RecSectors := (rec_size - crcs_size0 + SectorSize - 1) div SectorSize;
  if RecSectors < 0 then RecSectors := 0;
  SectorsSize := RecSectors * SectorSize;
  CrcsSize := crcs_size0 + RecSectors * 4;
  Result := True;
end;

function RecoveryBuild(Arc: TStream; ArcSize, ProtectedFrom, CrcsBlockPos: Int64;
                       const Spec: string; out Sectors, Crcs: TBytes;
                       out Info: TRecoveryInfo): Boolean;
var
  wanted, rec_size, arc_sectors, rec_sectors, i64, k: Int64;
  sector_size, fixed_size: Integer;
  crcs_size0, crcs_size, rec_sectors_size: Int64;
  l: LongWord;
  buf: TBytes;
  n, got, idx: SizeInt;
  i, t: Integer;
begin
  Result := False;
  SetLength(Sectors, 0); SetLength(Crcs, 0);
  if not ParseRrSpec(Spec, ArcSize, wanted, fixed_size) then Exit;
  if wanted < 0 then Exit;
  // sector_size: explícito, o 2^floor(log2(40*arcsize div wanted)), mínimo 512
  if fixed_size > 0 then
    sector_size := fixed_size
  else if wanted = 0 then
    sector_size := 4096
  else
  begin
    t := 0;
    if wanted > 0 then
    begin
      i64 := (40 * ArcSize) div wanted;
      while (QWord(1) shl (t + 1)) <= QWord(i64) do Inc(t);
    end;
    sector_size := 1 shl t;
    if sector_size < 512 then sector_size := 512;
  end;
  arc_sectors := (ArcSize + sector_size - 1) div sector_size;
  crcs_size0 := arc_sectors * 4;
  rec_size := wanted;
  if crcs_size0 > rec_size then rec_size := crcs_size0;
  rec_sectors := (rec_size - crcs_size0 + sector_size - 1) div sector_size;
  if rec_sectors < 0 then rec_sectors := 0;
  rec_sectors_size := rec_sectors * sector_size;
  crcs_size := crcs_size0 + rec_sectors * 4;

  Info.Version := '0.36';
  if rec_sectors = 0 then Info.Version := '0.39';
  Info.ArcSize := ArcSize;
  Info.InitPos := ProtectedFrom;
  Info.Offset := CrcsBlockPos - ProtectedFrom;
  Info.SectorSize := sector_size;
  Info.RecSectors := rec_sectors;

  SetLength(Sectors, rec_sectors_size);
  if rec_sectors_size > 0 then FillChar(Sectors[0], rec_sectors_size, 0);
  SetLength(buf, sector_size);
  // CRCs de los datos, y XOR rotativo. i0 = (-arc_sectors) mod rec_sectors
  if rec_sectors > 0 then
    i64 := (((-arc_sectors) mod rec_sectors) + rec_sectors) mod rec_sectors
  else
    i64 := 0;
  Arc.Position := ProtectedFrom;
  // while y no for: el contador es Int64, y FPC no acepta for de 64 bits en i386 (win32)
  k := 0;
  while k < arc_sectors do
  begin
    n := sector_size;
    if (k + 1) * sector_size > ArcSize then n := ArcSize - k * sector_size;
    got := Arc.Read(buf[0], n);
    if got <> n then Exit;
    U32Put(Crcs, CalcCRC(PByte(@buf[0]), n));
    if rec_sectors > 0 then
    begin
      for idx := 0 to n - 1 do
        Sectors[i64 * sector_size + idx] := Sectors[i64 * sector_size + idx] xor buf[idx];
      i64 := (i64 + 1) mod rec_sectors;
    end;
    Inc(k);
  end;
  // CRCs de los sectores de recuperación
  for i := 0 to rec_sectors - 1 do
  begin
    l := CalcCRC(PByte(@Sectors[i * sector_size]), sector_size);
    U32Put(Crcs, l);
  end;
  // el addinfo va DELANTE de los CRCs en el bloque
  SetLength(buf, 0);
  CStrPut(buf, Info.Version);
  VIntPut(buf, QWord(ArcSize));
  VIntPut(buf, QWord(Info.Offset));
  VIntPut(buf, 1);
  VIntPut(buf, QWord(sector_size));
  VIntPut(buf, QWord(rec_sectors));
  // concat: addinfo + crcs
  SetLength(buf, Length(buf) + Length(Crcs));
  Move(Crcs[0], buf[Length(buf) - Length(Crcs)], Length(Crcs));
  Crcs := buf;
  Result := True;
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
  // El mismo arranque de la rotación que el escritor: i0 = (-arc_sectors) mod rec_sectors.
  // Con -rr0% no hay rotación (RecSectors = 0): sólo se verifican los CRCs.
  if D.Info.RecSectors > 0 then
    i := ((-arc_sectors) mod D.Info.RecSectors + D.Info.RecSectors) mod D.Info.RecSectors
  else
    i := 0;
  SetLength(XorAcc, Int64(D.Info.RecSectors) * D.Info.SectorSize);
  if Length(XorAcc) > 0 then FillChar(XorAcc[0], Length(XorAcc), 0);
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
      // XOR en el sector de recuperación que toca (con -rr0% no hay ninguno)
      if D.Info.RecSectors > 0 then
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
      if D.Info.RecSectors > 0 then i := (i + 1) mod D.Info.RecSectors;
    end;
  finally
    fs.Free;
  end;
  // Cuántos dañados por grupo: si hay más de uno, ese grupo no se puede reparar
  if D.Info.RecSectors = 0 then
  begin
    Res.Unrecoverable := Copy(Res.BadSectors, 0, Length(Res.BadSectors));
    Result := True;
    Exit;
  end;
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
  { Con -rr0% (RecSectors = 0) no hay paridad: se puede verificar pero no reparar.
    Los dañados quedan en Res.Unrecoverable y no se escribe nada. }
  if D.Info.RecSectors = 0 then Exit(True);

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
