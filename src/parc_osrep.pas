{ srep en PArc: OSREP -m6 (coincidencias de largo alcance sobre todo el bloque sólido, antes de
  lzma, plz, ppmd...). Reemplaza a SREP de FreeArc (GPL): OSREP es código propio, MIT, escrito
  por osrep (src/osrep, versión en src/osrep/VERSION). Esta unidad es el pegamento: el método
  `srep` (parámetros y texto canónico), la etapa de codificación (TOutStage) y la de
  decodificación (TInStage), y la memoria de cada lado.

  Método: srep[:<largo mínimo>][:l<n>][:a<n>][:b<mem>]   (también `osrep`, el mismo método)
    largo mínimo (l, o un entero sin nombre)  coincidencia más corta (512; 32..65536)
    a  los largos son múltiplos de a (16, la posición módulo 16 que modela lzma; 1..4096)
    b  bloque de literales del stream (8mb; 64kb..256mb): no cambia las coincidencias
  `m<...>` (el modo de SREP de FreeArc, p. ej. m3f) se acepta y se ignora.

  Bloque: un byte y el resto. 1 = un stream .osr v7 de OSREP (sin digest: lo que protege al
  bloque es el CRC de PArc; el stream trae igual sus CRC-32C), 0 = los datos tal cual (cuando el
  stream no sale más chico). Un bloque vacío no tiene nada. Ver FORMATO-PARC.md §6.13.

  OSREP necesita todo el bloque en memoria: la etapa lo acumula y lo codifica al terminar
  (DoFinish), en el hilo que escribe; OSREP no crea hilos (no toca el presupuesto de
  PARC_THREADS). El decodificador lee todo el stream y escribe la salida en su lugar. }
unit parc_osrep;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream, parc_outstream, osrep_m6;

type
  TSrepMethod = record
    MinLen, Align, Block: LongWord;
  end;

const
  SREP_DEF_MINLEN = OSREP_M6_MINLEN_DEFAULT;   // 512
  SREP_DEF_ALIGN = OSREP_M6_ALIGN_DEFAULT;     // 16
  SREP_DEF_BLOCK = OSREP_M6_BLOCK_DEFAULT;     // 8 MB

function DefaultSrepMethod: TSrepMethod;
{ Params[0] = 'srep' u 'osrep'. Parámetros inválidos -> EUnsupportedMethod. }
function ParseSrepMethod(const Params: TStringArray): TSrepMethod;
{ Texto canónico: `srep` y los parámetros que no son los de por defecto. }
function SrepMethodText(const M: TSrepMethod): string;
{ Memoria del codificador para un bloque de DataSize bytes: el bloque acumulado, la salida
  (OsrepM6Bound) y lo que reserva OSREP (OsrepM6EncMem). }
function SrepEncMemory(const M: TSrepMethod; DataSize: Int64): Int64;
{ Memoria del decodificador fuera del stream y la salida (OsrepM6DecMem). }
function SrepDecMemory: Int64;

type
  TSrepEncStage = class(TOutStage)
  private
    FM: TSrepMethod;
    FData: PByte;
    FLen, FCap: SizeInt;
    procedure FreeData;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    { SizeHint: los bytes que se esperan (0 = no se sabe), para reservar de una vez. }
    constructor Create(ATarget: TOutStage; const M: TSrepMethod; SizeHint: Int64);
    destructor Destroy; override;
  end;

  TSrepDecStage = class(TInStage)
  private
    FOut: PByte;
    FLen, FPos: SizeInt;
    FLoaded: Boolean;
    procedure Load;
  public
    constructor Create(ASource: TInStage);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

implementation

uses
  parc_methods, parc_bytes;

const
  FLAG_STORED = 0;
  FLAG_OSREP = 1;

function DefaultSrepMethod: TSrepMethod;
begin
  Result.MinLen := SREP_DEF_MINLEN;
  Result.Align := SREP_DEF_ALIGN;
  Result.Block := SREP_DEF_BLOCK;
end;

function ParamsOf(const M: TSrepMethod): TOsrepM6Params;
begin
  OsrepM6ParamsDefault(Result);
  Result.MinLen := M.MinLen;
  Result.Align := M.Align;
  Result.BlockSize := M.Block;
  Result.Threads := 1;
  Result.Digest := False;
end;

function ParseSrepMethod(const Params: TStringArray): TSrepMethod;
var
  k: Integer;
  p: string;

  procedure Bad;
  begin
    raise EUnsupportedMethod.CreateFmt('srep: invalid parameter "%s"', [p]);
  end;

  function Int(const S: string): LongWord;
  var
    v: Int64;
  begin
    v := StrToInt64Def(S, -1);
    if (S = '') or not (S[1] in ['0'..'9']) or (v < 0) or (v > High(LongWord)) then Bad;
    Result := LongWord(v);
  end;

var
  m: QWord;
begin
  if (Length(Params) = 0) or ((Params[0] <> 'srep') and (Params[0] <> 'osrep')) then
    raise EUnsupportedMethod.Create('srep: not the method srep');
  Result := DefaultSrepMethod;
  for k := 1 to High(Params) do
  begin
    p := LowerCase(Params[k]);
    if p = '' then Bad;
    case p[1] of
      'l': Result.MinLen := Int(Copy(p, 2, MaxInt));
      'a': Result.Align := Int(Copy(p, 2, MaxInt));
      'b':
        begin
          if not ParseMem(Copy(p, 2, MaxInt), m) then Bad;
          if m > High(LongWord) then m := High(LongWord);   // fuera de rango: lo rechaza Check
          Result.Block := LongWord(m);
        end;
      'm': ;   // el modo de SREP de FreeArc (m3f...): no tiene sentido en OSREP
      '0'..'9': Result.MinLen := Int(p);
    else
      Bad;
    end;
  end;
  if OsrepM6Check(ParamsOf(Result)) <> OSREP_M6_OK then
    raise EUnsupportedMethod.CreateFmt('srep: invalid parameters "%s" (l32..65536, a1..4096, ' +
      'b64kb..256mb)', [string.Join(':', Params)]);
end;

function MemText(V: Int64): string;
begin
  if (V > 0) and (V mod (1 shl 20) = 0) then Result := IntToStr(V shr 20) + 'mb'
  else if (V > 0) and (V mod 1024 = 0) then Result := IntToStr(V shr 10) + 'kb'
  else Result := IntToStr(V) + 'b';
end;

function SrepMethodText(const M: TSrepMethod): string;
begin
  Result := 'srep';
  if M.MinLen <> SREP_DEF_MINLEN then Result := Result + ':l' + IntToStr(M.MinLen);
  if M.Align <> SREP_DEF_ALIGN then Result := Result + ':a' + IntToStr(M.Align);
  if M.Block <> SREP_DEF_BLOCK then Result := Result + ':b' + MemText(M.Block);
end;

function SrepEncMemory(const M: TSrepMethod; DataSize: Int64): Int64;
var
  P: TOsrepM6Params;
  N: QWord;
begin
  if DataSize < 0 then DataSize := 0;
  N := QWord(DataSize);
  P := ParamsOf(M);
  Result := Int64(OsrepM6EncMem(N, P)) + DataSize + Int64(OsrepM6Bound(N, P)) + (1 shl 20);
end;

function SrepDecMemory: Int64;
begin
  Result := Int64(OsrepM6DecMem(False, OSREP_M6_BLOCK_DEFAULT));
end;

{ ---- codificador ---- }

{ Pasa Len bytes a la etapa siguiente de a 64 MB (Len puede pasar de 2 GB, y no todas las etapas
  ni TStream.WriteBuffer aceptan tanto de una vez). }
procedure EmitAll(St: TSrepEncStage; P: PByte; Len: SizeInt);
var
  n: SizeInt;
begin
  while Len > 0 do
  begin
    n := Len;
    if n > 64 shl 20 then n := 64 shl 20;
    St.Emit(P, n);
    Inc(P, n);
    Dec(Len, n);
  end;
end;

constructor TSrepEncStage.Create(ATarget: TOutStage; const M: TSrepMethod; SizeHint: Int64);
begin
  inherited Create(ATarget);
  FM := M;
  FData := nil;
  FLen := 0;
  FCap := 0;
  // reservar de una vez lo que se espera (sin tocar las páginas: GetMem no las llena)
  if (SizeHint > 0) and (SizeHint < High(SizeInt) div 2) then
  begin
    FCap := SizeInt(SizeHint);
    FData := GetMem(FCap);
  end;
end;

destructor TSrepEncStage.Destroy;
begin
  FreeData;
  inherited Destroy;
end;

procedure TSrepEncStage.FreeData;
begin
  if FData <> nil then FreeMem(FData);
  FData := nil;
  FCap := 0;
end;

procedure TSrepEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  NewCap: SizeInt;
begin
  if Count <= 0 then Exit;
  if Count > FCap - FLen then
  begin
    // crecer de a 1,5 veces (no 2: el bloque puede ser de varios GB)
    NewCap := FCap + FCap div 2;
    if NewCap < 1 shl 20 then NewCap := 1 shl 20;
    if NewCap - FLen < Count then NewCap := FLen + Count;
    ReAllocMem(FData, NewCap);
    FCap := NewCap;
  end;
  Move(Buf^, FData[FLen], Count);
  Inc(FLen, Count);
end;

procedure TSrepEncStage.DoFinish;
var
  P: TOsrepM6Params;
  Cap, OutLen: QWord;
  Dst: PByte;
  r: LongInt;
  Flag: Byte;
begin
  if FLen > 0 then
  begin
    P := ParamsOf(FM);
    Cap := OsrepM6Bound(QWord(FLen), P);
    Dst := nil;
    if Cap < QWord(High(SizeInt)) then Dst := GetMem(SizeInt(Cap));
    try
      if Dst = nil then r := OSREP_M6_E_MEM
      else r := OsrepM6Encode(FData, QWord(FLen), Dst, Cap, OutLen, P);
      if r = OSREP_M6_E_MEM then OutOfMemoryError;
      if r <> OSREP_M6_OK then
        raise Exception.CreateFmt('srep (OSREP): %s', [OsrepM6LastError]);
      if OutLen < QWord(FLen) then
      begin
        // el bloque ya no hace falta: se libera antes de pasar la salida (lzma crece detrás)
        FreeData;
        Flag := FLAG_OSREP;
        Emit(@Flag, 1);
        EmitAll(Self, Dst, SizeInt(OutLen));
      end
      else
      begin
        // no conviene: se guarda tal cual
        FreeMem(Dst);
        Dst := nil;
        Flag := FLAG_STORED;
        Emit(@Flag, 1);
        EmitAll(Self, FData, FLen);
        FreeData;
      end;
    finally
      if Dst <> nil then FreeMem(Dst);
    end;
  end;
  inherited DoFinish;
end;

{ ---- decodificador ---- }

{ ¿Un bloque de SREP de FreeArc (lo que escribía PArc 0.0.5 y antes)? El stream de SREP empieza
  con $26351817 y 'SREP'. }
function IsOldSrep(P: PByte; Len: SizeInt): Boolean;
begin
  Result := (Len >= 8) and (P[0] = $17) and (P[1] = $18) and (P[2] = $35) and (P[3] = $26) and
    (P[4] = Ord('S')) and (P[5] = Ord('R')) and (P[6] = Ord('E')) and (P[7] = Ord('P'));
end;

constructor TSrepDecStage.Create(ASource: TInStage);
begin
  inherited Create(ASource);
  FOut := nil;
  FLen := 0;
  FPos := 0;
  FLoaded := False;
end;

{ En la primera lectura, no en el constructor: una excepción en el constructor liberaría la
  fuente, que también libera CreateDecoderChain. }
procedure TSrepDecStage.Load;
var
  In_: PByte;
  Cap, N, K: SizeInt;
  Orig: QWord;
  r: LongInt;
begin
  FLoaded := True;
  In_ := nil;
  try
    // todo el bloque
    Cap := 1 shl 16;
    In_ := GetMem(Cap);
    N := 0;
    while True do
    begin
      if N = Cap then
      begin
        Cap := Cap + Cap div 2;
        ReAllocMem(In_, Cap);
      end;
      K := Source.Read(@In_[N], Cap - N);
      if K <= 0 then Break;
      Inc(N, K);
    end;
    if N = 0 then Exit;   // bloque vacío
    if In_[0] = FLAG_STORED then
    begin
      // tal cual: se sirve desde el mismo búfer, después del byte
      FOut := In_;
      In_ := nil;
      FLen := N;
      FPos := 1;
      Exit;
    end;
    if In_[0] <> FLAG_OSREP then Corrupt('srep: invalid block');
    if IsOldSrep(@In_[1], N - 1) then
      raise EUnsupportedMethod.Create('this srep block is FreeArc SREP, which is no longer ' +
        'supported: srep is now OSREP (extract this archive with PArc 0.0.5)');
    r := OsrepM6OrigSize(@In_[1], QWord(N - 1), Orig);
    if r <> OSREP_M6_OK then Corrupt('srep: ' + OsrepM6LastError);
    if Orig >= QWord(High(SizeInt)) then Corrupt('srep: block too large for this system');
    FLen := SizeInt(Orig);
    if FLen > 0 then FOut := GetMem(FLen);
    if (FOut = nil) and (FLen > 0) then OutOfMemoryError;
    r := OsrepM6Decode(@In_[1], QWord(N - 1), FOut, Orig);
    if r = OSREP_M6_E_MEM then OutOfMemoryError;
    if r <> OSREP_M6_OK then Corrupt('srep: ' + OsrepM6LastError);
  finally
    if In_ <> nil then FreeMem(In_);
  end;
end;

destructor TSrepDecStage.Destroy;
begin
  if FOut <> nil then FreeMem(FOut);
  FOut := nil;
  inherited Destroy;
end;

function TSrepDecStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  if not FLoaded then Load;
  Result := FLen - FPos;
  if Result > Count then Result := Count;
  if Result > 0 then
  begin
    Move(FOut[FPos], Buf^, Result);
    Inc(FPos, Result);
  end
  else
    Result := 0;
end;

end.
