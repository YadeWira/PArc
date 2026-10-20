{ Verificación y reparación de un .parc con RECOVERY_BLOCK (`-rr`).

  La paridad es Reed-Solomon (parc_rs), versión "parc-rs1": los sectores del
  archivo se intercalan en S franjas (el sector i va a la franja i mod S, posición i div S)
  y cada franja lleva m sectores de paridad. Una franja se repara mientras tenga a lo sumo
  m sectores dañados, EN CUALQUIER POSICIÓN (datos o paridad), y un daño contiguo de hasta
  S*m sectores se reparte entre franjas. Mismos dos bloques que FreeArc: el de sectores
  y el de info+CRCs, con un segundo par (m, S) en el addinfo. La paridad j de la franja s
  va en el sector j*S + s: intercalada como los datos, para que un daño contiguo en el
  propio registro tampoco se lleve todas las paridades de una franja. Los CRCs por sector
  detectan qué está dañado. }
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
    RsParity: Integer;   // "parc-rs1": paridades por franja (m); 0 = sin paridad (-rr0%)
    RsStripes: Int64;    //   franjas (S); RecSectors = S * m
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
  parc_crc, parc_methods, parc_volume, parc_rs;

const
  RECOVERY_BLOCK = 5;
  RS_VERSION = 'parc-rs1';

type
  TBoolArr = array of Boolean;
  TIntArr = array of Integer;

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
      if got <> Length(D.Sectors) then Corrupt('incomplete recovery sector block');
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
      if got <> Length(D.Crcs) then Corrupt('incomplete recovery CRC block');
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
    D.Info.RsParity := 0;
    D.Info.RsStripes := 0;
    for i := 2 to npar do
      if (i = 2) and (D.Info.Version = RS_VERSION) then
      begin
        D.Info.RsParity := Integer(r.VInt);
        D.Info.RsStripes := Int64(r.VInt);
      end
      else
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
    if D.Info.Version = RS_VERSION then
      if (D.Info.RsParity < 1) or (D.Info.RsParity > 254) or
         (D.Info.RsStripes <> RsStripeCount((D.Info.ArcSize + D.Info.SectorSize - 1) div D.Info.SectorSize, D.Info.RsParity)) or
         (D.Info.RsStripes * D.Info.RsParity <> D.Info.RecSectors) then
        Corrupt('Reed-Solomon recovery record with invalid parameters');
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

{ parseNumber de FreeArc (Utils.hs): dígitos y un especificador; k/m/g/t (y b) dan bytes,
  '^' es 2^N, cualquier otro carácter se devuelve tal cual. Sin especificador, Default. }
function ParseNumber(const S: string; Default: Char; out Num: Int64; out Spec: Char): Boolean;
var
  i: Integer;
  t: string;
begin
  t := LowerCase(S) + Default;
  i := 1;
  while (i <= Length(t)) and (t[i] in ['0'..'9']) do Inc(i);
  Num := StrToInt64Def(Copy(t, 1, i - 1), -1);
  if i = 1 then Num := 0;   // readI "" = 0
  Spec := t[i];
  Result := Num >= 0;
  case Spec of
    'b': ;
    'k': Num := Num shl 10;
    'm': Num := Num shl 20;
    'g': Num := Num shl 30;
    't': Num := Num shl 40;
    '^': Num := Int64(1) shl Num;
  else
    Exit;
  end;
  Spec := 'b';
end;

{ parseSize: como ParseNumber con bytes por defecto; otro especificador es error. }
function ParseSize(const S: string; out Num: Int64): Boolean;
var
  c: Char;
begin
  Result := ParseNumber(S, 'b', Num, c) and (c = 'b');
end;

{ El texto de -rr como ArcRecover.hs (writeRecoveryBlocks):
    "r;ss"   cantidad r (como abajo) con sector de ss bytes;
    "n*ss"   n*ss bytes de recuperación exactos, sector de ss (los dos con parseSize);
    "r"      parseNumber con 's' por defecto: N o Ns = N*512, Nb/Nk/Nm = bytes, N% o Np =
             N * ceil(arcsize/100).
  Devuelve lo pedido (Wanted), el sector explícito (FixedSize, 0 si no hay) y, en la forma
  n*ss, el tamaño exacto (ExplicitRec, -1 si no hay). }
function ParseRrSpec(const Spec: string; ArcSize: Int64; out Wanted: Int64;
                     out FixedSize: Integer; out ExplicitRec: Int64): Boolean;
var
  s, amount: string;
  p: Integer;
  n, ss: Int64;
  c: Char;
begin
  Result := False; Wanted := 0; FixedSize := 0; ExplicitRec := -1;
  s := Trim(Spec);
  if s = '' then Exit;
  amount := s;
  p := Pos(';', s);
  if p > 0 then
  begin
    amount := Copy(s, 1, p - 1);
    if not ParseSize(Copy(s, p + 1, MaxInt), ss) then Exit;
    FixedSize := ss;
  end
  else
  begin
    p := Pos('*', s);
    if p > 0 then
    begin
      if not ParseSize(Copy(s, 1, p - 1), n) or not ParseSize(Copy(s, p + 1, MaxInt), ss) then Exit;
      FixedSize := ss;
      ExplicitRec := n * ss;
      amount := '';
    end;
  end;
  // Sectores de menos de 512 bytes: FreeArc se queda sin memoria (-rr4096*8 da "-12,918
  // recovery sectors"); acá, un error claro
  if (FixedSize <> 0) and (FixedSize < 512) then Exit;
  if ExplicitRec >= 0 then
    Wanted := 0   // (no se usa: rec_size = ExplicitRec)
  else
  begin
    if not ParseNumber(amount, 's', n, c) then Exit;
    case c of
      'b': Wanted := n;
      's': Wanted := n * 512;
      '%', 'p': Wanted := n * ((ArcSize + 99) div 100);   // arcsize `divRoundUp` 100
    else
      Exit;
    end;
  end;
  Result := True;
end;


{ Reed-Solomon: la menor cantidad de paridades por franja (m) que da al menos los R
  sectores de recuperación pedidos. Con N sectores hay S = ceil(N / (255 - m)) franjas y
  S * m sectores de paridad en total. }
procedure RsChoose(N, R: Int64; out m: Integer; out S: Int64);
begin
  m := 1;
  while (m < 254) and (RsStripeCount(N, m) * m < R) do Inc(m);
  S := RsStripeCount(N, m);
end;

function PlanAll(ArcSize: Int64; const Spec: string;
                 out SectorSize, RecSectors: Integer; out SectorsSize, CrcsSize: Int64;
                 out m: Integer; out S: Int64): Boolean;
var
  wanted, explicit_rec: Int64;
  fixed_size: Integer;
  arc_sectors, crcs_size0, rec_size: Int64;
  t: Integer;
  i64: Int64;
begin
  Result := False;
  SectorSize := 0; RecSectors := 0; SectorsSize := 0; CrcsSize := 0;
  m := 0; S := 0;
  if not ParseRrSpec(Spec, ArcSize, wanted, fixed_size, explicit_rec) then Exit;
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
  if explicit_rec >= 0 then rec_size := explicit_rec
  else
  begin
    rec_size := wanted;
    if crcs_size0 > rec_size then rec_size := crcs_size0;
  end;
  // (FreeArc puede dar negativo con n*ss chico y archivo grande; acá queda en 0: solo CRCs)
  if rec_size > crcs_size0 then
    RecSectors := (rec_size - crcs_size0 + SectorSize - 1) div SectorSize
  else
    RecSectors := 0;
  if RecSectors > 0 then
  begin
    RsChoose(arc_sectors, RecSectors, m, S);
    RecSectors := S * m;
  end;
  SectorsSize := Int64(RecSectors) * SectorSize;
  CrcsSize := crcs_size0 + Int64(RecSectors) * 4;
  Result := True;
end;

function RecoveryPlan(ArcSize: Int64; const Spec: string;
                      out SectorSize, RecSectors: Integer;
                      out SectorsSize, CrcsSize: Int64): Boolean;
var
  m: Integer;
  S: Int64;
begin
  Result := PlanAll(ArcSize, Spec, SectorSize, RecSectors, SectorsSize, CrcsSize, m, S);
end;

function RecoveryBuild(Arc: TStream; ArcSize, ProtectedFrom, CrcsBlockPos: Int64;
                       const Spec: string; out Sectors, Crcs: TBytes;
                       out Info: TRecoveryInfo): Boolean;
var
  m, j: Integer;
  Stripes, si, pi: Int64;
  arc_sectors, rec_sectors, k: Int64;
  sector_size: Integer;
  crcs_size, rec_sectors_size: Int64;
  l: LongWord;
  buf: TBytes;
  n, got: SizeInt;
  i, rs: Integer;
begin
  Result := False;
  SetLength(Sectors, 0); SetLength(Crcs, 0);
  // Los tamaños salen de RecoveryPlan: una sola implementación de la gramática de -rr
  if not PlanAll(ArcSize, Spec, sector_size, rs, rec_sectors_size, crcs_size, m, Stripes) then Exit;
  rec_sectors := rs;
  arc_sectors := (ArcSize + sector_size - 1) div sector_size;

  if m > 0 then Info.Version := RS_VERSION else Info.Version := '0.39';
  Info.RsParity := m;
  Info.RsStripes := Stripes;
  Info.ArcSize := ArcSize;
  Info.InitPos := ProtectedFrom;
  Info.Offset := CrcsBlockPos - ProtectedFrom;
  Info.SectorSize := sector_size;
  Info.RecSectors := rec_sectors;

  SetLength(Sectors, rec_sectors_size);
  if rec_sectors_size > 0 then FillChar(Sectors[0], rec_sectors_size, 0);
  SetLength(buf, sector_size);
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
    if m > 0 then
    begin
      // Reed-Solomon: el sector k es el dato pi de la franja si (el último, con ceros)
      if n < sector_size then FillChar(buf[n], sector_size - n, 0);
      si := k mod Stripes;
      pi := k div Stripes;
      for j := 0 to m - 1 do
        RsMulAdd(RsCoef(j, pi), @buf[0], @Sectors[(j * Stripes + si) * sector_size], sector_size);
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
  if m > 0 then VIntPut(buf, 2) else VIntPut(buf, 1);
  VIntPut(buf, QWord(sector_size));
  VIntPut(buf, QWord(rec_sectors));
  if m > 0 then
  begin
    VIntPut(buf, QWord(m));
    VIntPut(buf, QWord(Stripes));
  end;
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

{ Sin paridad (-rr0%): verifica los CRCs y marca los sectores dañados. }
function ScanCRCs(const ArcName: string; const D: TRecoveryData; out Res: TRecoveryResult): Boolean;
var
  fs: TStream;
  buf: TBytes;
  k, arc_sectors: Int64;
  n, got: SizeInt;
  crc: LongWord;
  r: TByteReader;
begin
  Result := False;
  Res.Info := D.Info;
  SetLength(Res.BadSectors, 0);
  SetLength(Res.Unrecoverable, 0);
  SetLength(Res.Repaired, 0);
  arc_sectors := (D.Info.ArcSize + D.Info.SectorSize - 1) div D.Info.SectorSize;
  r.Init(@D.Crcs[D.CrcsOfs], Length(D.Crcs) - D.CrcsOfs);
  fs := OpenArchiveStream(ArcName);
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
      if got <> n then Corrupt('could not read the protected area');
      crc := CalcCRC(PByte(@buf[0]), n);
      if crc <> r.U32 then
      begin
        SetLength(Res.BadSectors, Length(Res.BadSectors) + 1);
        Res.BadSectors[High(Res.BadSectors)] := k;
      end;
      Inc(k);
    end;
  finally
    fs.Free;
  end;
  Res.Unrecoverable := Copy(Res.BadSectors, 0, Length(Res.BadSectors));
  Result := True;
end;

{ --- Reed-Solomon ("parc-rs1") --- }

{ CRCs de todos los sectores: Bad[k] para los del archivo, BadPar[i] para los de paridad.
  Una franja con más de m dañados (datos + paridad) no se puede reparar. }
function ScanRS(const ArcName: string; const D: TRecoveryData; out Res: TRecoveryResult;
                out Bad, BadPar: TBoolArr; out PerStripe: TIntArr): Boolean;
var
  fs: TStream;
  buf: TBytes;
  k, arc_sectors, i: Int64;
  n, got: SizeInt;
  r: TByteReader;
  S: Int64;
  m, j: Integer;
begin
  Result := False;
  Res.Info := D.Info;
  SetLength(Res.BadSectors, 0);
  SetLength(Res.Unrecoverable, 0);
  SetLength(Res.Repaired, 0);
  arc_sectors := (D.Info.ArcSize + D.Info.SectorSize - 1) div D.Info.SectorSize;
  S := D.Info.RsStripes;
  m := D.Info.RsParity;
  SetLength(Bad, arc_sectors);
  SetLength(BadPar, D.Info.RecSectors);
  SetLength(PerStripe, S);
  r.Init(@D.Crcs[D.CrcsOfs], Length(D.Crcs) - D.CrcsOfs);
  fs := OpenArchiveStream(ArcName);
  try
    fs.Position := D.Info.InitPos;
    SetLength(buf, D.Info.SectorSize);
    k := 0;
    while k < arc_sectors do
    begin
      n := D.Info.SectorSize;
      if k * D.Info.SectorSize + n > D.Info.ArcSize then n := D.Info.ArcSize - k * D.Info.SectorSize;
      got := fs.Read(buf[0], n);
      if got <> n then Corrupt('could not read the protected area');
      Bad[k] := CalcCRC(PByte(@buf[0]), n) <> r.U32;
      if Bad[k] then
      begin
        SetLength(Res.BadSectors, Length(Res.BadSectors) + 1);
        Res.BadSectors[High(Res.BadSectors)] := k;
        Inc(PerStripe[k mod S]);
      end;
      Inc(k);
    end;
  finally
    fs.Free;
  end;
  // la paridad también puede estar dañada (cuenta como un borrado más de su franja)
  // (contadores Integer: FPC no acepta for con Int64 en i386)
  for j := 0 to D.Info.RecSectors - 1 do
  begin
    BadPar[j] := CalcCRC(PByte(@D.Sectors[Int64(j) * D.Info.SectorSize]), D.Info.SectorSize) <> r.U32;
    if BadPar[j] then Inc(PerStripe[j mod S]);
  end;
  for j := 0 to High(Res.BadSectors) do
    if PerStripe[Res.BadSectors[j] mod S] > m then
    begin
      SetLength(Res.Unrecoverable, Length(Res.Unrecoverable) + 1);
      Res.Unrecoverable[High(Res.Unrecoverable)] := Res.BadSectors[j];
    end;
  Result := True;
end;

function RepairRS(const ArcName: string; const D: TRecoveryData; out Res: TRecoveryResult;
                  out DestName: string): Boolean;
var
  Bad, BadPar: TBoolArr;
  PerStripe: TIntArr;
  fs: TStream;
  out2: TFileStream;
  VolBase: string;
  arc_sectors, S, st, idx: Int64;
  m, kk, p, j, SS: Integer;
  n, got: SizeInt;
  Mem: TBytes;
  Ptrs: array of PByte;
  Present: array of Boolean;
  reparables: Integer;
begin
  Result := False;
  DestName := '';
  if not ScanRS(ArcName, D, Res, Bad, BadPar, PerStripe) then Exit;
  if Length(Res.BadSectors) = 0 then Exit(True);
  if Length(Res.Unrecoverable) = Length(Res.BadSectors) then Exit(True);   // nada reparable
  reparables := Length(Res.BadSectors) - Length(Res.Unrecoverable);
  if reparables = 0 then Exit(True);
  arc_sectors := (D.Info.ArcSize + D.Info.SectorSize - 1) div D.Info.SectorSize;
  S := D.Info.RsStripes;
  m := D.Info.RsParity;
  SS := D.Info.SectorSize;
  if not IsVolumeSet(ArcName, VolBase) then VolBase := ArcName;
  DestName := ExtractFilePath(VolBase) + 'fixed.' + ExtractFileName(VolBase);
  if FileExists(DestName) then DeleteFile(DestName);
  out2 := TFileStream.Create(DestName, fmCreate);
  try
    fs := OpenArchiveStream(ArcName);
    try
      out2.CopyFrom(fs, 0);
      SetLength(Mem, Int64(RS_MAX_SECTORS) * SS);
      SetLength(Ptrs, RS_MAX_SECTORS);
      SetLength(Present, RS_MAX_SECTORS);
      st := -1;
      while st < S - 1 do   // (while: FPC no acepta for con Int64 en i386)
      begin
        Inc(st);
        if (PerStripe[st] = 0) or (PerStripe[st] > m) then Continue;
        kk := RsStripeLen(arc_sectors, S, st);
        // ¿algún dato dañado? (si solo está dañada la paridad, no hay nada que escribir)
        n := 0;
        for p := 0 to kk - 1 do
          if Bad[Int64(p) * S + st] then Inc(n);
        if n = 0 then Continue;
        FillChar(Mem[0], Int64(kk + m) * SS, 0);
        for p := 0 to kk - 1 do
        begin
          idx := Int64(p) * S + st;
          Ptrs[p] := @Mem[Int64(p) * SS];
          Present[p] := not Bad[idx];
          n := SS;
          if (idx + 1) * SS > D.Info.ArcSize then n := D.Info.ArcSize - idx * SS;
          if Present[p] then
          begin
            fs.Position := D.Info.InitPos + idx * SS;
            got := fs.Read(Ptrs[p]^, n);
            if got <> n then Corrupt('could not read a stripe sector');
          end;
        end;
        for j := 0 to m - 1 do
        begin
          Ptrs[kk + j] := @Mem[Int64(kk + j) * SS];
          Present[kk + j] := not BadPar[j * S + st];
          Move(D.Sectors[(j * S + st) * SS], Ptrs[kk + j]^, SS);
        end;
        if not RsRecover(kk, m, Ptrs[0..kk + m - 1], Present[0..kk + m - 1], SS) then
          Corrupt('Reed-Solomon: could not rebuild a repairable stripe');
        for p := 0 to kk - 1 do
        begin
          idx := Int64(p) * S + st;
          if not Bad[idx] then Continue;
          n := SS;
          if (idx + 1) * SS > D.Info.ArcSize then n := D.Info.ArcSize - idx * SS;
          out2.Position := D.Info.InitPos + idx * SS;
          out2.WriteBuffer(Ptrs[p]^, n);
          SetLength(Res.Repaired, Length(Res.Repaired) + 1);
          Res.Repaired[High(Res.Repaired)] := idx;
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

function RecoveryScan(const ArcName: string; out Res: TRecoveryResult): Boolean;
var
  D: TRecoveryData;
  Bad, BadPar: TBoolArr;
  PerStripe: TIntArr;
begin
  Result := False;
  if not LoadRecovery(ArcName, D) then Exit;
  if D.Info.RsParity > 0 then
    Result := ScanRS(ArcName, D, Res, Bad, BadPar, PerStripe)
  else
    Result := ScanCRCs(ArcName, D, Res);
end;

function RecoveryRepair(const ArcName: string; out Res: TRecoveryResult;
                        out DestName: string): Boolean;
var
  D: TRecoveryData;
begin
  Result := False;
  DestName := '';
  if not LoadRecovery(ArcName, D) then Exit;
  if D.Info.RsParity > 0 then Exit(RepairRS(ArcName, D, Res, DestName));
  // -rr0%: sin paridad solo se puede verificar, no reparar
  Result := ScanCRCs(ArcName, D, Res);
end;

end.
