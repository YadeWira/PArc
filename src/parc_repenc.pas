{ REP (codificador): coincidencias de largo alcance. Port de Compression/REP/rep.cpp
  (rep_compress, CalcHashSize) y C_REP.cpp (REP_METHOD, parse_REP) de FreeArc 0.67,
  Bulat Ziganshin. Decodificador: parc_rep (TRepStage).

  Salida idéntica byte a byte a rep_compress con lecturas completas (fread): el C lee de a
  min(BlockSize-DataEnd, HTBLOCK) bytes y cada lectura devuelve todo lo pedido salvo al final
  del stream; acá cada "lectura" espera a tener esos bytes (o al Finish).

  Hilos: el C calcula los hashes (Job.process) en hilos de fondo y los consume en orden FIFO;
  el trabajo de un hilo solo lee bytes ya leídos que nadie modifica hasta consumirlo y solo
  escribe su propia ranura de ht[], así que calcularlo en el momento del Put da lo mismo.
  Lo que SÍ cambia la salida es HTBUFS = max(16, 2*GetCompressionThreads()): cuántas lecturas
  de adelanto se hacen (DataEnd acota la búsqueda) y el contenido "viejo" de las ranuras
  (ver ProcessJob). Con <= 8 hilos HTBUFS=16 (valor por defecto, Threads=1).

  Memoria: ventana BlockSize (se reserva a medida que llegan datos) + hash HashSize*4
  + ht HTBUFS*HTCOUNT*4 (256 KB con l512) + tablas de un bloque de 8 MB. }
unit parc_repenc;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_outstream;

type
  { Parámetros de REP_METHOD (C_REP.h) }
  TRepEncParams = record
    BlockSize: LongInt;       // b<mem> o memoria sin nombre (64mb): tamaño de la ventana
    MinCompression: LongInt;  // N%  (rep_compress no lo usa)
    ChunkSize: LongInt;       // c   (0 = automático)
    MinMatchLen: LongInt;     // l<n> o entero sin nombre (512)
    Barrier: LongInt;         // d<mem> (MaxInt)
    SmallestLen: LongInt;     // s<n> (512)
    HashBits: LongInt;        // h<n> (0 = automático)
    Amplifier: LongInt;       // a<n> / max (rep_compress no lo usa)
    Threads: LongInt;         // GetCompressionThreads() de FreeArc; solo afecta HTBUFS (no está en el método)
  end;

  ERepEncParams = class(Exception);
  TRepIntArray = array of LongInt;

  TRepJob = record
    Slot, BufPos, Bytes: LongInt;  // ranura en FHt, inicio en FBuf, bytes a indexar
  end;

  TRepEncStage = class(TOutStage)
  private
    FPar: TRepEncParams;
    FBlockSize, FL, FHashSize, FHashMask, FMinLen, FSmallLen, FBarrier: LongInt;
    FPowL: LongWord;                    // PRIME^L (mod 2^32)
    FBuf: array of Byte;                // ventana; crece hasta FBlockSize
    FHashArr: TRepIntArray;         // hasharr[]
    FHt: TRepIntArray;                  // ht[]: HTBUFS ranuras de HTCOUNT enteros
    FHtBufs, FHtBlock, FHtCount: LongInt;
    FJobs: array of TRepJob;            // cola FIFO de trabajos de hashing
    FJobHead, FJobCount: LongInt;
    FFreeJobs, FHtIndex, FNextJobI, FNextFlush: LongInt;
    FDataEnd, FLastI, FLastMatch: LongInt;
    FDoItOnce, FMoreInput, FMoreHashed, FFinal: Boolean;
    FState: Integer;
    FReqSize, FGot: LongInt;            // lectura pendiente: FReqSize bytes en FBuf[FDataEnd..]
    // tablas del bloque actual (Buffer lens/offsets/datalens/dataOffsets del C)
    FLens, FOffs, FDLens, FDOffs: TRepIntArray;
    FNLens, FNOffs, FNDLens, FNDOffs: LongInt;
    FLiterals: LongInt;
    procedure Push(var A: TRepIntArray; var N: LongInt; V: LongInt);
    procedure EnsureCap(Need: LongInt);
    procedure HashJob(Slot, BufPos, Bytes: LongInt);
    procedure AfterRead(Size: LongInt);
    procedure ProcessJob(const J: TRepJob);
    procedure EncodeBlock;
    procedure Pump;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const APar: TRepEncParams);
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
  end;

function DefaultRepEncParams: TRepEncParams;
{ parse_REP: Params[0] = 'rep'. Parámetros inválidos -> ERepEncParams. }
function ParseRepEncParams(const Params: TStringArray): TRepEncParams;
{ CalcHashSize + validación: devuelve L y HashSize, o excepción si el C fallaría
  (división por cero, hash vacío, cuelgue con BlockSize <= L, desbordes de int). }
procedure CheckRepEncParams(const P: TRepEncParams; out L, HashSize: LongInt);
{ GetCompressionMem de REP_METHOD: BlockSize + HashSize*4 }
function RepEncMemory(const P: TRepEncParams): Int64;

implementation

uses
  parc_methods;

const
  PRIME = 153191;
  MAX_BLOCK = 8 shl 20;   // 8 MB de entrada por bloque de salida

  stOuter = 0; stInner = 1; stRead = 2; stWaitRead = 3; stGet = 4; stEncode = 5;
  stFinal = 6; stDone = 7; stNotStarted = 8;

{ parseInt de Common.cpp: '=' opcional y solo dígitos }
function FaParseInt(const S: string; out V: LongInt): Boolean;
var
  i: Integer;
  n: QWord;
begin
  Result := False;
  V := 0;
  i := 1;
  if (i <= Length(S)) and (S[i] = '=') then Inc(i);
  if i > Length(S) then Exit;
  n := 0;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    n := n * 10 + QWord(Ord(S[i]) - Ord('0'));
    if n > High(LongInt) then Exit;   // el C lo truncaría a int: lo rechazamos
    Inc(i);
  end;
  if i <= Length(S) then Exit;
  V := LongInt(n);
  Result := True;
end;

{ parseMem64 de FreeArc (sin sufijo = 2^N): es ParseMem de parc_methods, una sola
  implementación para todos los métodos. }
function FaParseMem(const S: string; out V: QWord): Boolean;
begin
  Result := ParseMem(S, V);
end;

function DefaultRepEncParams: TRepEncParams;
begin
  // REP_METHOD::REP_METHOD
  Result.BlockSize := 64 shl 20;
  Result.MinCompression := 100;
  Result.ChunkSize := 0;
  Result.MinMatchLen := 512;
  Result.HashBits := 0;
  Result.Barrier := High(LongInt);
  Result.SmallestLen := 512;
  Result.Amplifier := 1;
  Result.Threads := 1;
end;

function ParseRepEncParams(const Params: TStringArray): TRepEncParams;
var
  k: Integer;
  p: string;
  m: QWord;
  n: LongInt;

  procedure Bad;
  begin
    raise ERepEncParams.CreateFmt('rep: parámetro inválido "%s"', [p]);
  end;

  function Int(const S: string): LongInt;
  begin
    if not FaParseInt(S, Result) then Bad;
  end;

  function Mem(const S: string): LongInt;
  begin
    if not FaParseMem(S, m) then Bad;
    if m > QWord(High(LongInt)) then
      raise ERepEncParams.CreateFmt('rep: "%s" es demasiado grande (máx. 2 GB - 1)', [p]);
    Result := LongInt(m);
  end;

begin
  if (Length(Params) = 0) or (Params[0] <> 'rep') then
    raise ERepEncParams.Create('rep: no es el método rep');
  Result := DefaultRepEncParams;
  // parse_REP (C_REP.cpp)
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if p = 'max' then begin Result.Amplifier := 99; Continue; end;
    if p = '' then Bad;
    case p[1] of
      'b': begin Result.BlockSize := Mem(Copy(p, 2, MaxInt)); Continue; end;
      'l': begin Result.MinMatchLen := Int(Copy(p, 2, MaxInt)); Continue; end;
      'c': begin Result.ChunkSize := Int(Copy(p, 2, MaxInt)); Continue; end;
      'd': begin Result.Barrier := Mem(Copy(p, 2, MaxInt)); Continue; end;
      's': begin Result.SmallestLen := Int(Copy(p, 2, MaxInt)); Continue; end;
      'h': begin Result.HashBits := Int(Copy(p, 2, MaxInt)); Continue; end;
      'a': begin Result.Amplifier := Int(Copy(p, 2, MaxInt)); Continue; end;
    end;
    // "N%" = MinCompression (si no es un entero, se sigue probando como en el C)
    if (p[Length(p)] = '%') and FaParseInt(Copy(p, 1, Length(p) - 1), n) then
    begin
      Result.MinCompression := n;
      Continue;
    end;
    // Sin nombre: entero -> MinMatchLen; si no, memoria -> BlockSize
    if FaParseInt(p, n) then Result.MinMatchLen := n
    else Result.BlockSize := Mem(p);
  end;
  CheckRepEncParams(Result, n, n);   // validar ya, no al crear la etapa
end;

{ rounddown_to_power_of(n,2) de Common.h (n=0 -> 1) }
function RoundDownPow2(n: QWord): QWord;
begin
  Result := 1;
  if n = 0 then Exit;
  while Result <= n shr 1 do Result := Result shl 1;
end;

{ roundup_to_power_of(n,2) de Common.h (0 -> 0, 1 -> 1) }
function RoundUpPow2(n: QWord): QWord;
begin
  if n = 0 then Exit(0);
  Result := 1;
  while Result < n do Result := Result shl 1;
end;

procedure CheckRepEncParams(const P: TRepEncParams; out L, HashSize: LongInt);
var
  Len, Small: LongInt;
  q: QWord;
begin
  L := 0;
  HashSize := 0;
  if P.BlockSize <= 0 then raise ERepEncParams.Create('rep: tamaño de bloque inválido');
  if (P.MinMatchLen < 1) or (P.SmallestLen < 1) then
    raise ERepEncParams.Create('rep: largo mínimo de match inválido');
  if P.ChunkSize < 0 then raise ERepEncParams.Create('rep: ChunkSize inválido');
  if (P.HashBits < 0) or (P.HashBits > 30) then raise ERepEncParams.Create('rep: HashBits inválido (0..30)');
  if P.Barrier < 0 then raise ERepEncParams.Create('rep: Barrier inválido');
  if (P.Threads < 1) or (P.Threads > 4096) then raise ERepEncParams.Create('rep: cantidad de hilos inválida');
  // rep_compress: SmallestLen se limita a MinMatchLen; CalcHashSize
  Small := P.SmallestLen;
  if Small > P.MinMatchLen then Small := P.MinMatchLen;
  Len := Small;
  if P.MinMatchLen < Len then Len := P.MinMatchLen;
  if P.ChunkSize <> 0 then L := P.ChunkSize
  else L := LongInt(RoundDownPow2(QWord(Len - 1)) div 2);
  // L=0 (l1/l2 sin c) divide por cero en el C; con L > 2^28 desborda 4*L en HTBLOCK
  if (L < 1) or (L > 1 shl 28) then
    raise ERepEncParams.CreateFmt('rep: tamaño de bloque de hash L=%d inválido (l>=3 o c>=1)', [L]);
  // Con BlockSize <= L el C se cuelga (Get() sin trabajos pendientes)
  if P.BlockSize <= L then raise ERepEncParams.Create('rep: el bloque tiene que ser mayor que L');
  if P.HashBits > 0 then HashSize := LongInt(1) shl P.HashBits
  else
  begin
    q := RoundUpPow2(QWord(P.BlockSize) div 3 * 2);
    if L div 4 > 16 then q := q div QWord(L div 4) else q := q div 16;
    HashSize := LongInt(q);
  end;
  // Con HashSize=0 el C indexa hasharr[hash & -1]: fuera del arreglo
  if HashSize < 1 then raise ERepEncParams.Create('rep: el bloque es demasiado chico para el hash');
end;

function RepEncMemory(const P: TRepEncParams): Int64;
var
  L, H: LongInt;
begin
  CheckRepEncParams(P, L, H);
  Result := Int64(P.BlockSize) + Int64(H) * 4;
end;

{ TRepEncStage }

constructor TRepEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  Create(ATarget, ParseRepEncParams(Params));
end;

constructor TRepEncStage.Create(ATarget: TOutStage; const APar: TRepEncParams);
var
  i: Integer;
  pw, b: LongWord;
begin
  // Validar y reservar ANTES de inherited Create: si algo falla, Destroy ve FTarget=nil
  // y el destino sigue siendo del llamador.
  CheckRepEncParams(APar, FL, FHashSize);
  FPar := APar;
  FBlockSize := APar.BlockSize;
  FHashMask := FHashSize - 1;
  FMinLen := APar.MinMatchLen;
  FSmallLen := APar.SmallestLen;
  if FSmallLen > FMinLen then FSmallLen := FMinLen;
  FBarrier := APar.Barrier;
  // power(PRIME, L) en int: el resultado mod 2^32 no depende del orden de las operaciones
  pw := 1; b := PRIME; i := FL;
  while i > 0 do
  begin
    if Odd(i) then pw := pw * b;
    b := b * b;
    i := i shr 1;
  end;
  FPowL := pw;
  // HTBUFS / HTBLOCK / HTCOUNT de rep_compress
  FHtBufs := 2 * APar.Threads;
  if FHtBufs < 16 then FHtBufs := 16;
  if 256 * 1024 > 4 * FL then FHtBlock := 256 * 1024 else FHtBlock := 4 * FL;
  FHtBlock := FHtBlock div FL * FL;
  FHtCount := FHtBlock div FL * 2;
  SetLength(FHashArr, FHashSize);                 // memset(hasharr, 0)
  SetLength(FHt, Int64(FHtBufs) * FHtCount);      // BigAlloc = VirtualAlloc: en cero
  SetLength(FJobs, FHtBufs);
  inherited Create(ATarget);
  FFreeJobs := FHtBufs;
  FDoItOnce := True;
  FMoreInput := True;
  FMoreHashed := True;
  FState := stNotStarted;
end;

procedure TRepEncStage.Push(var A: TRepIntArray; var N: LongInt; V: LongInt);
begin
  if N >= Length(A) then SetLength(A, 2 * N + 1024);
  A[N] := V;
  Inc(N);
end;

procedure TRepEncStage.EnsureCap(Need: LongInt);
var
  NewCap: Int64;
begin
  if Need <= Length(FBuf) then Exit;
  NewCap := 2 * Int64(Length(FBuf));
  if NewCap < Need then NewCap := Need;
  if NewCap < 1 shl 20 then NewCap := 1 shl 20;
  if NewCap > FBlockSize then NewCap := FBlockSize;
  SetLength(FBuf, NewCap);
end;

{ Job::process: por cada bloque de L bytes guarda el hash máximo (con signo) de los L hashes
  rodantes que empiezan en él y su índice. }
procedure TRepEncStage.HashJob(Slot, BufPos, Bytes: LongInt);
var
  p, pe: PByte;
  hp: PLongInt;
  h, maxh: LongWord;
  i, maxi, blk, NumBlocks, L: LongInt;
  pl, pr: LongWord;
begin
  L := FL;
  pr := PRIME;
  NumBlocks := Bytes div L;
  if NumBlocks <= 0 then Exit;
  pl := FPowL;
  hp := @FHt[Slot];
  p := @FBuf[BufPos];
  h := 0;
  for i := 0 to L - 1 do h := h * pr + p[i];     // update_hash(0, buf[i])
  for blk := 0 to NumBlocks - 1 do
  begin
    maxh := h; maxi := 0;
    pe := p + L;
    i := 0;
    while p < pe do
    begin
      if LongInt(h) > LongInt(maxh) then begin maxh := h; maxi := i; end;
      h := h * pr + p[L] - LongWord(p[0]) * pl;  // update_hash(ptr[0], ptr[L])
      Inc(p); Inc(i);
    end;
    hp^ := LongInt(maxh); Inc(hp);
    hp^ := maxi; Inc(hp);
  end;
end;

{ Cola de rep_compress tras READ_LEN (bloque "ЧТЕНИЕ ВХОДНЫХ ДАННЫХ") }
procedure TRepEncStage.AfterRead(Size: LongInt);
var
  bytes: LongInt;
  J: TRepJob;
begin
  if FDoItOnce then begin EmitU32(LongWord(FBlockSize)); FDoItOnce := False; end;
  if Size = 0 then FMoreInput := False;
  Inc(FDataEnd, Size);
  bytes := FDataEnd - (FNextJobI + FL);
  if bytes <= 0 then
  begin
    if Size > 0 then Exit;     // continue: seguir leyendo sin encolar
    bytes := 0;                // trabajo vacío = fin de datos
  end;
  J.Slot := FHtIndex * FHtCount;
  J.BufPos := FNextJobI;
  J.Bytes := bytes;
  HashJob(J.Slot, J.BufPos, J.Bytes);    // en el C lo hace un hilo; ver comentario de la unidad
  FJobs[(FJobHead + FJobCount) mod FHtBufs] := J;
  Inc(FJobCount);
  Inc(FNextJobI, bytes);
  FHtIndex := (FHtIndex + 1) mod FHtBufs;
  Dec(FFreeJobs);
end;

{ Bucle principal de búsqueda sobre los resultados de un trabajo de hashing.
  Rareza del C: consume ceil((next_fill-last_i)/L) pares aunque el trabajo haya escrito
  floor(bytes/L); si bytes no es múltiplo de L (última lectura parcial, o BlockSize que no es
  múltiplo de HTBLOCK/L) lee un par "viejo" de la ranura (cero o de un trabajo anterior).
  Eso es determinista y acá se reproduce igual, porque FHt tiene las mismas ranuras. }
procedure TRepEncStage.ProcessJob(const J: TRepJob);
var
  hp, next_fill, hash, i, match, LowBound, HighBound, st, en, q, pm, offset, lim: LongInt;
  b: PByte;
begin
  b := @FBuf[0];
  hp := J.Slot;
  next_fill := J.BufPos + J.Bytes;
  while FLastI < next_fill do
  begin
    if hp + 1 >= Length(FHt) then
      raise Exception.Create('rep: estado interno inconsistente (ht)');
    hash := FHt[hp];
    i := FHt[hp + 1] + FLastI;
    Inc(hp, 2);
    if i >= FLastMatch then
    begin
      match := FHashArr[LongWord(hash) and LongWord(FHashMask)];
      if (match <> 0) and not ((match >= i) and (match < FDataEnd)) then
      begin
        if match < i then LowBound := i - match
        else if match - FDataEnd > i then LowBound := 0
        else LowBound := i - (match - FDataEnd);
        HighBound := FBlockSize - match + i;
        // find_match_start(buf+match, buf+i, buf+max(last_match,LowBound))
        lim := FLastMatch; if LowBound > lim then lim := LowBound;
        q := i; pm := match;
        st := -1;
        while q > lim do
        begin
          Dec(pm); Dec(q);
          if b[pm] <> b[q] then begin st := q + 1; Break; end;
        end;
        if st < 0 then st := q;
        // find_match_end(buf+match, buf+i, buf+min(DataEnd,HighBound))
        lim := FDataEnd; if HighBound < lim then lim := HighBound;
        q := i; pm := match;
        while (q < lim) and (b[pm] = b[q]) do begin Inc(pm); Inc(q); end;
        en := q;
        if i - match < FBarrier then lim := FMinLen else lim := FSmallLen;
        if en - st >= lim then
        begin
          offset := i - match;
          if offset < 0 then Inc(offset, FBlockSize);
          Push(FDOffs, FNDOffs, FLastMatch);
          Push(FDLens, FNDLens, st - FLastMatch);
          Push(FOffs, FNOffs, offset);
          Push(FLens, FNLens, en - st);
          Inc(FLiterals, st - FLastMatch);
          FLastMatch := en;
        end;
      end;
    end;
    // no_match: el bloque entra al hash
    FHashArr[LongWord(hash) and LongWord(FHashMask)] := i;
    Inc(FLastI, FL);
  end;
end;

{ encode_data: cierra y emite un bloque }
procedure TRepEncStage.EncodeBlock;
var
  Hdr: array of Byte;
  outsize, k, n, pos: LongInt;

  procedure Put(V: LongInt);
  begin
    Hdr[pos] := Byte(V); Hdr[pos + 1] := Byte(V shr 8);
    Hdr[pos + 2] := Byte(V shr 16); Hdr[pos + 3] := Byte(V shr 24);
    Inc(pos, 4);
  end;

begin
  if (FNextFlush = FBlockSize) or not FMoreHashed then FLastI := FDataEnd;
  if FLastMatch > FLastI then
    Push(FDLens, FNDLens, 0)   // datalens siempre tiene num+1 entradas
  else
  begin
    Push(FDOffs, FNDOffs, FLastMatch);
    Push(FDLens, FNDLens, FLastI - FLastMatch);
    Inc(FLiterals, FLastI - FLastMatch);
    FLastMatch := FLastI;
  end;
  if FNextFlush = FBlockSize then
  begin
    // Fin de la ventana: seguir llenándola desde el principio
    FDataEnd := 0; FLastMatch := 0; FLastI := 0; FNextJobI := 0; FNextFlush := 0;
  end;
  outsize := 4 * 2 + 4 * FNLens + 4 * FNOffs + 4 * FNDLens + FLiterals;
  SetLength(Hdr, 8 + 4 * (FNLens + FNOffs + FNDLens));
  pos := 0;
  Put(outsize - 4);
  Put(FNLens);
  for k := 0 to FNLens - 1 do Put(FLens[k]);
  for k := 0 to FNOffs - 1 do Put(FOffs[k]);
  for k := 0 to FNDLens - 1 do Put(FDLens[k]);
  Emit(@Hdr[0], pos);
  // Literales: pares (dataOffsets[k], datalens[k])
  for k := 0 to FNDOffs - 1 do
  begin
    n := FDLens[k];
    if n > 0 then Emit(@FBuf[FDOffs[k]], n);
  end;
end;

{ Máquina de estados equivalente a los bucles de rep_compress; se detiene solo cuando una
  lectura no puede completarse todavía (faltan datos y no es el Finish). }
procedure TRepEncStage.Pump;
var
  J: TRepJob;
  datalen: LongInt;
begin
  repeat
    case FState of
      stNotStarted, stOuter:
        begin
          // while (MoreHashedData): vaciar tablas y fijar el próximo límite de 8 MB
          FNLens := 0; FNOffs := 0; FNDLens := 0; FNDOffs := 0; FLiterals := 0;
          if FBlockSize - FNextFlush < MAX_BLOCK then Inc(FNextFlush, FBlockSize - FNextFlush)
          else Inc(FNextFlush, MAX_BLOCK);
          FState := stInner;
        end;
      stInner:
        if FLastI + FL < FNextFlush then FState := stRead else FState := stEncode;
      stRead:
        if (FFreeJobs > 0) and (FDataEnd < FBlockSize) and FMoreInput then
        begin
          FReqSize := FBlockSize - FDataEnd;
          if FReqSize > FHtBlock then FReqSize := FHtBlock;
          FGot := 0;
          EnsureCap(FDataEnd + FReqSize);
          FState := stWaitRead;
        end
        else
          FState := stGet;
      stWaitRead:
        begin
          if (FGot < FReqSize) and not FFinal then Exit;
          AfterRead(FGot);
          FState := stRead;
        end;
      stGet:
        begin
          // HashingThreads.Get(): en el C, sin trabajos pendientes se colgaría
          if FJobCount = 0 then raise Exception.Create('rep: estado interno inconsistente (sin trabajos)');
          J := FJobs[FJobHead];
          FJobHead := (FJobHead + 1) mod FHtBufs;
          Dec(FJobCount);
          Inc(FFreeJobs);
          if J.Bytes = 0 then
          begin
            FMoreHashed := False;
            FState := stEncode;
          end
          else
          begin
            ProcessJob(J);
            FState := stInner;
          end;
        end;
      stEncode:
        begin
          EncodeBlock;
          if FMoreHashed then FState := stOuter else FState := stFinal;
        end;
      stFinal:
        begin
          // Bloque final con el resto sin comprimir (en la práctica vacío) y el 0 de fin
          datalen := FDataEnd - FLastMatch;
          if datalen <> 0 then
          begin
            EmitU32(LongWord(8 + datalen));
            EmitU32(0);
            EmitU32(LongWord(datalen));
            Emit(@FBuf[FLastMatch], datalen);
          end;
          EmitU32(0);
          FState := stDone;
        end;
    else
      Exit;   // stDone
    end;
  until False;
end;

procedure TRepEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  if FState = stNotStarted then Pump;
  while Count > 0 do
  begin
    if FState <> stWaitRead then raise Exception.Create('rep: estado interno inconsistente (escritura)');
    n := FReqSize - FGot;
    if n > Count then n := Count;
    Move(Buf^, FBuf[FDataEnd + FGot], n);
    Inc(FGot, n);
    Inc(Buf, n);
    Dec(Count, n);
    if FGot = FReqSize then Pump;
  end;
end;

procedure TRepEncStage.DoFinish;
begin
  FFinal := True;
  Pump;
  // La memoria grande ya no hace falta
  FBuf := nil; FHashArr := nil; FHt := nil;
end;

end.
