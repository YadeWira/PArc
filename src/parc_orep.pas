{ OREP en PArc: coincidencias de largo alcance en un solo pase (deduplicación antes de lzma,
  tor, ppmd...). Reemplaza a REP de FreeArc (GPL): OREP es código propio, MIT, escrito para
  PArc por osrep (src/orep, versión en src/orep/VERSION). Esta unidad es el pegamento: el
  método `orep` (parámetros y texto canónico), la etapa de decodificación (TInStage) y la de
  codificación (TOutStage), y la memoria de cada lado.

  Método: orep[:<ventana>][:<largo mínimo>][:w<mem>][:l<n>][:a<n>][:s<n>][:c<n>][:b<mem>][:d<mem>]
    ventana (w, o una memoria sin nombre)   distancia máxima (512mb; hasta 3840mb)
    largo mínimo (l, o un entero sin nombre) coincidencia más corta que se busca (64; >= 16)
    a  alineación: largos múltiplos de a y literales en su posición módulo a (0 = por bloque:
       1 en texto, 4 en lo demás; 0..4096, <= l)
    s  densidad de anclas (4; 1..64): más alta encuentra más coincidencias cortas, más lento
    c  candidatos por ancla (4; 1..4): más encuentra coincidencias más largas, 1 es lo más rápido
    b  tamaño de bloque del stream (4mb; 64kb..64mb)
    d  coincidencias más cercanas que esto quedan para el compresor de atrás (0)
  Las memorias como en el resto de PArc (sufijo b/k/m/g; sin sufijo, 2^N). El stream lleva
  su propio encabezado (ventana, bloque, alineación): el decodificador no usa los parámetros
  del método salvo para acotar la memoria (ver TOrepDecStage).

  Hilos: OREP corre con P.Threads = 1, en el hilo que escribe el bloque (como antes la búsqueda
  de REP). Sus hilos propios (P.Threads >= 2: un coordinador que busca y Threads - 1 ayudantes)
  no saben del presupuesto global de PArc (parc_parallel): trabajan a ráfagas que desde afuera
  no se ven, y la API de OREP (0.0.2, 0.0.3) no da cómo avisarlas, así que no hay forma de darles
  fichas solo mientras trabajan y PArc pasaría de PARC_THREADS. Probado (2026-11, 512 MB de
  TILIN, orep:96m:l256): llamar a OREP de a un bloque con OREP_FLUSH y fichas para sus hilos
  solo dentro de la llamada daba 2,1 s con 4 hilos contra 1,9 s con uno (lo que gana OREP con
  hilos es solapar la búsqueda con la copia y la salida, no la búsqueda paralela) y el doble
  de CPU; correr OREP en un hilo propio de la etapa (con su ficha) y lzma/4x4 en el que
  escribe era más lento que en línea en -m1..-m5 (copias de más y fichas que se disputan) y
  apenas más rápido en -m9. Con un solo hilo la salida es la misma que con cualquier cantidad. }
unit parc_orep;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream, parc_outstream, orep;

type
  { Parámetros del método `orep` (los del codificador; el stream trae los suyos) }
  TOrepMethod = record
    Window: QWord;
    MinLen, Align, Density, Cands, Chunk: LongWord;
    MinDist: QWord;
  end;

const
  OREP_DEF_WINDOW = QWord(512) shl 20;
  OREP_DEF_MINLEN = 64;
  OREP_DEF_ALIGN = 0;      // por bloque
  OREP_DEF_DENSITY = 4;
  OREP_DEF_CANDS = 4;
  OREP_DEF_CHUNK = 4 shl 20;

function DefaultOrepMethod: TOrepMethod;
{ Params[0] = 'orep'. Parámetros inválidos -> EUnsupportedMethod. }
function ParseOrepMethod(const Params: TStringArray): TOrepMethod;
{ Los parámetros de OREP para estos del método (sin SizeHint: la ventana ya viene recortada al
  bloque sólido por parc_canon, y así el encabezado del stream es la ventana del método). }
function OrepParamsOf(const M: TOrepMethod; Threads: LongWord): TOrepParams;
{ Memoria del codificador (OrepEncMemory) y del decodificador (OrepDecMemory). }
function OrepMethodEncMemory(const M: TOrepMethod): QWord;
function OrepMethodDecMemory(const M: TOrepMethod): QWord;
{ La ventana más grande <= M.Window (en MB enteros, mínimo 1 MB) con la que el codificador usa
  a lo sumo MemLim bytes. }
function OrepFitWindow(const M: TOrepMethod; MemLim: QWord): QWord;

type
  TOrepDecStage = class(TInStage)
  private
    FDec: TOrepDec;
    FLimit: QWord;
    FInited, FEnd, FSrcEof: Boolean;
    FIn: array of Byte;
    FInPos, FInLen: SizeInt;
  public
    constructor Create(ASource: TInStage; const M: TOrepMethod);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

  POrepEnc = ^TOrepEnc;

  TOrepEncStage = class(TOutStage)
  private
    FEnc: POrepEnc;
    FInited: Boolean;
    FOut: array of Byte;
    procedure Run(Buf: PByte; Count: SizeInt; Mode: Integer);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const M: TOrepMethod);
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
    destructor Destroy; override;
  end;

implementation

uses
  parc_methods, parc_bytes;

function DefaultOrepMethod: TOrepMethod;
begin
  Result.Window := OREP_DEF_WINDOW;
  Result.MinLen := OREP_DEF_MINLEN;
  Result.Align := OREP_DEF_ALIGN;
  Result.Density := OREP_DEF_DENSITY;
  Result.Cands := OREP_DEF_CANDS;
  Result.Chunk := OREP_DEF_CHUNK;
  Result.MinDist := 0;
end;

function ParseOrepMethod(const Params: TStringArray): TOrepMethod;
var
  k: Integer;
  p: string;

  procedure Bad;
  begin
    raise EUnsupportedMethod.CreateFmt('orep: invalid parameter "%s"', [p]);
  end;

  function Int(const S: string): LongWord;
  var
    v: Int64;
  begin
    v := StrToInt64Def(S, -1);
    if (S = '') or not (S[1] in ['0'..'9']) or (v < 0) or (v > High(LongWord)) then Bad;
    Result := LongWord(v);
  end;

  function Mem(const S: string): QWord;
  begin
    if not ParseMem(S, Result) then Bad;
  end;

var
  OP: TOrepParams;
begin
  if (Length(Params) = 0) or (Params[0] <> 'orep') then
    raise EUnsupportedMethod.Create('orep: not the method orep');
  Result := DefaultOrepMethod;
  for k := 1 to High(Params) do
  begin
    p := LowerCase(Params[k]);
    if p = '' then Bad;
    case p[1] of
      'w': Result.Window := Mem(Copy(p, 2, MaxInt));
      'l': Result.MinLen := Int(Copy(p, 2, MaxInt));
      'a': Result.Align := Int(Copy(p, 2, MaxInt));
      's': Result.Density := Int(Copy(p, 2, MaxInt));
      'c': Result.Cands := Int(Copy(p, 2, MaxInt));
      'b':
        begin
          Result.Chunk := High(LongWord);   // fuera de rango: lo rechaza la validación
          if Mem(Copy(p, 2, MaxInt)) < High(LongWord) then Result.Chunk := Mem(Copy(p, 2, MaxInt));
        end;
      'd': Result.MinDist := Mem(Copy(p, 2, MaxInt));
      '0'..'9':
        // sin nombre: un entero es el largo mínimo; una memoria con sufijo, la ventana
        if StrToInt64Def(p, -1) >= 0 then Result.MinLen := Int(p)
        else Result.Window := Mem(p);
    else
      Bad;
    end;
  end;
  // validar ya (con los límites de OREP), no al crear la etapa
  OP := OrepParamsOf(Result, 1);
  if OrepEncMemory(OP) = 0 then
    raise EUnsupportedMethod.CreateFmt('orep: invalid parameters "%s" (window 1b..3840mb, ' +
      'l16..65536, a0..4096 and <= l, s1..64, c1..4, b64kb..64mb)', [string.Join(':', Params)]);
end;

function OrepParamsOf(const M: TOrepMethod; Threads: LongWord): TOrepParams;
begin
  OrepParamsDefault(Result);
  Result.Window := M.Window;
  Result.SizeHint := 0;
  Result.MinLen := M.MinLen;
  Result.Chunk := M.Chunk;
  Result.Align := M.Align;
  Result.Density := M.Density;
  Result.Cands := M.Cands;
  Result.MinDist := M.MinDist;
  Result.Threads := Threads;
end;

function OrepMethodEncMemory(const M: TOrepMethod): QWord;
begin
  Result := OrepEncMemory(OrepParamsOf(M, 1));
end;

function OrepMethodDecMemory(const M: TOrepMethod): QWord;
begin
  Result := OrepDecMemory(M.Window, M.Chunk);
end;

function OrepFitWindow(const M: TOrepMethod; MemLim: QWord): QWord;
var
  T: TOrepMethod;
  Lo, Hi, Mid: QWord;
begin
  // búsqueda binaria en MB: la memoria crece con la ventana
  T := M;
  Hi := M.Window shr 20;
  if Hi < 1 then Exit(M.Window);
  Lo := 1;
  T.Window := Hi shl 20;
  if OrepMethodEncMemory(T) <= MemLim then Exit(T.Window);
  while Lo < Hi do
  begin
    Mid := (Lo + Hi + 1) div 2;
    T.Window := Mid shl 20;
    if OrepMethodEncMemory(T) <= MemLim then Lo := Mid else Hi := Mid - 1;
  end;
  Result := Lo shl 20;
end;

{ ---- decodificador ---- }

const
  OREP_IN_BUF = 256 * 1024;

constructor TOrepDecStage.Create(ASource: TInStage; const M: TOrepMethod);
begin
  inherited Create(ASource);
  // El encabezado del stream no puede pedir más memoria que la que declara el método (que es
  // lo que mira -ld): si lo hace, el stream o el método están dañados
  FLimit := OrepMethodDecMemory(M);
  OrepDecInit(FDec, FLimit);
  FInited := True;
  SetLength(FIn, OREP_IN_BUF);
end;

destructor TOrepDecStage.Destroy;
begin
  if FInited then OrepDecEnd(FDec);
  inherited Destroy;
end;

function TOrepDecStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  NextIn, NextOut: PByte;
  AvailIn, AvailOut: SizeUInt;
  r: Integer;
  Extra: Byte;
begin
  Result := 0;
  if FEnd or (Count <= 0) then Exit;
  while True do
  begin
    if (FInPos = FInLen) and not FSrcEof then
    begin
      FInPos := 0;
      FInLen := Source.Read(@FIn[0], Length(FIn));
      if FInLen = 0 then FSrcEof := True;
    end;
    NextIn := @FIn[FInPos];
    AvailIn := FInLen - FInPos;
    NextOut := Buf;
    AvailOut := Count;
    r := OrepDecRun(FDec, NextIn, AvailIn, NextOut, AvailOut);
    FInPos := FInLen - SizeInt(AvailIn);
    Result := Count - SizeInt(AvailOut);
    if r < 0 then
    begin
      if r = OREP_E_MEM then
        if OrepDecMemory(FDec.Window, FDec.Chunk) > FLimit then
          Corrupt('orep: the stream needs more memory than its method declares')
        else
          OutOfMemoryError;
      Corrupt('orep: ' + OrepErrorText(r));
    end;
    if r = OREP_END then
    begin
      FEnd := True;
      // nada después del fin del stream
      if (FInPos < FInLen) or (not FSrcEof and (Source.Read(@Extra, 1) <> 0)) then
        Corrupt('orep: data after the end of the stream');
      Exit;
    end;
    if Result > 0 then Exit;
    if AvailIn > 0 then Corrupt('orep: decoder stalled');
    if FSrcEof then Corrupt('orep: truncated stream');
  end;
end;

{ ---- codificador ---- }

const
  OREP_OUT_BUF = 1 shl 20;   // salida de una llamada a OREP

constructor TOrepEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  Create(ATarget, ParseOrepMethod(Params));
end;

constructor TOrepEncStage.Create(ATarget: TOutStage; const M: TOrepMethod);
var
  r: Integer;
begin
  // Validar y reservar ANTES de inherited Create: si algo falla, Destroy ve FTarget=nil y el
  // destino sigue siendo del llamador. El anillo de la ventana crece a medida que llegan datos.
  New(FEnc);
  r := OrepEncInit(FEnc^, OrepParamsOf(M, 1));
  if r <> OREP_OK then
  begin
    Dispose(FEnc);
    FEnc := nil;
    if r = OREP_E_MEM then OutOfMemoryError;
    raise EUnsupportedMethod.Create('orep: ' + OrepErrorText(r));
  end;
  FInited := True;
  SetLength(FOut, OREP_OUT_BUF);
  inherited Create(ATarget);
end;

destructor TOrepEncStage.Destroy;
begin
  if FInited then OrepEncEnd(FEnc^);
  FInited := False;
  if FEnc <> nil then Dispose(FEnc);
  inherited Destroy;
end;

{ OrepEncRun hasta consumir Count bytes (OREP_RUN) o hasta el fin del stream (OREP_FINISH);
  la salida va a la etapa siguiente de a OREP_OUT_BUF bytes. }
procedure TOrepEncStage.Run(Buf: PByte; Count: SizeInt; Mode: Integer);
var
  NextIn, NextOut: PByte;
  AvailIn, AvailOut: SizeUInt;
  r: Integer;
  n: SizeInt;
begin
  NextIn := Buf;
  AvailIn := Count;
  repeat
    NextOut := @FOut[0];
    AvailOut := Length(FOut);
    r := OrepEncRun(FEnc^, NextIn, AvailIn, NextOut, AvailOut, Mode);
    if r = OREP_E_MEM then OutOfMemoryError;
    if r < 0 then raise EUnsupportedMethod.Create('orep: ' + OrepErrorText(r));
    n := Length(FOut) - SizeInt(AvailOut);
    if n > 0 then Emit(@FOut[0], n);
  until (r = OREP_END) or ((Mode <> OREP_FINISH) and (AvailIn = 0) and (AvailOut > 0));
end;

procedure TOrepEncStage.DoWrite(Buf: PByte; Count: SizeInt);
begin
  Run(Buf, Count, OREP_RUN);
end;

procedure TOrepEncStage.DoFinish;
begin
  Run(nil, 0, OREP_FINISH);
end;

end.
