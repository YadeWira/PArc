{ Codificadores y armado de cadenas de compresión. Un método "a+b+c" se comprime
  datos -> a -> b -> c -> destino (el espejo de parc_methods.CreateDecoderChain). }
unit parc_encoders;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, parc_outstream;

type
  EUnsupportedEncoder = class(Exception);

  { exe (BCJ x86 del LZMA SDK, parc_filters) al comprimir: convierte buffers llenos y guarda
    para el próximo lo que el filtro no llegó a procesar; un tramo final de <=5 bytes sale
    sin convertir. }
  TBcjEncStage = class(TOutStage)
  private
    FBuf: array of Byte;
    FLen: SizeInt;
    FIp, FState: LongWord;
    procedure Convert(Final: Boolean);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage);
  end;

  { srep (Compression/SREP): se acumula el bloque y se codifica en DoFinish; el bloque de
    FreeArc antepone un byte (1 = stream srep, 0 = guardado tal cual si no conviene). }
  TSrepEncStage = class(TOutStage)
  private
    FData: TBytes;
    FLen: SizeInt;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage);
  end;

var
  { Bytes de entrada de todo lo que se va a comprimir (lo fija el escritor del archivo; 0 si no
    se sabe, p. ej. -si). Con pocos datos para los hilos, 4x4 achica sus bloques (ver
    Adaptive4x4Block). }
  Enc4x4TotalHint: Int64 = 0;

threadvar
  { Bytes de entrada del bloque sólido cuya cadena se está armando en este hilo (0: no se
    sabe): con varios hilos, 4x4 achica sus últimos bloques (ver parc_4x4.T4x4EncStage.NextTarget). }
  Enc4x4BlockHint: Int64;

{ Arma la cadena de codificadores delante de Target (la cadena pasa a ser dueña de Target). }
function CreateEncoderChain(const Method: string; Target: TOutStage): TOutStage;

{ Comprime un bloque de control en memoria. }
function CompressMem(const Method: string; Src: PByte; SrcLen: SizeInt): TBytes;

{ Como SetDictionary de FreeArc: achica el diccionario de lzma (d<mem> o la memoria sin nombre)
  a la potencia de 2 >= DataSize (mínimo 64kb). El método ajustado es el que se guarda en el
  archivo, así que el descompresor también reserva solo eso. }
function LimitMethodToSize(const Method: string; DataSize: Int64): string;

{ Memoria que usa la cadena de codificadores de un bloque de DataSize bytes (todas sus etapas
  están vivas a la vez): estimación por etapa (ver StageEncodeMem). }
function EncodeMemEstimate(const Method: string; DataSize: Int64): Int64;

{ Method (canónico) achicado hasta que EncodeMemEstimate entre en Limit: se achica primero la
  etapa que más usa, de a poco, hasta que entra o ninguna se puede achicar más (como
  limit_compression_memory de FreeArc). }
function FitEncodeMem(const Method: string; DataSize, Limit: Int64): string;

{ True si CreateEncoderChain sabe comprimir con Method (sin crear nada). }
function EncoderAvailable(const Method: string): Boolean;
{ True si la cadena pide Tornado (tor, xtor, etor; también dentro de 4x4), que se quitó
  después de 0.0.5: el llamador da un error que dice qué usar en su lugar (plz). }
function TornadoRequested(const Method: string): Boolean;

{ Etapa de cifrado para un bloque nuevo: Algorithm es el de -ae= ("chacha", "aes", con
  :t/:m/:p opcionales), Password en UTF-8, Header = bloque de control (-hp). La etapa no lleva
  la clave (es la misma cadena que queda en el archivo); el nonce del bloque es nuevo en cada
  llamado. Lanza EUnsupportedEncoder si el algoritmo no vale. }
function MakeCipherStage(const Algorithm: string; const Password: RawByteString; Header: Boolean): string;

{ Method sin sus etapas de cifrado (la de un bloque viejo que se reempaqueta: la que quedó en
  el archivo no trae la clave y no sirve para comprimir). }
function WithoutCipher(const Method: string): string;

implementation

uses
  Math, parc_filters, parc_ppmd, parc_methods, parc_lzp, parc_parallel, parc_lzmaenc,
  parc_orep, parc_delta, parc_dictenc, parc_tta, parc_mm, parc_bwt,
  parc_crypt, parc_canon, parc_lz4enc, parc_dispack, parc_srep, parc_cm, parc_bcj2, parc_plzenc,
  parc_4x4;

function StageName(const Stage: string): string; forward;
function FastInner4x4(const Inner: string): Boolean; forward;


const
  BCJ_ENC_BUFFER = 1 shl 20;

{ TBcjEncStage }

constructor TBcjEncStage.Create(ATarget: TOutStage);
begin
  inherited Create(ATarget);
  SetLength(FBuf, BCJ_ENC_BUFFER);
end;

procedure TBcjEncStage.Convert(Final: Boolean);
var
  Done, Rem: SizeInt;
begin
  if FLen = 0 then Exit;
  if FLen <= 5 then
    Done := FLen    // menos que una instrucción E8/E9 entera: no hay nada que convertir
  else
  begin
    Done := BcjX86Code(@FBuf[0], FLen, FIp, FState, True);
    if Final and (Done = 0) then Done := FLen;
  end;
  Inc(FIp, LongWord(Done));
  Emit(@FBuf[0], Done);
  Rem := FLen - Done;
  if Rem > 0 then Move(FBuf[Done], FBuf[0], Rem);
  FLen := Rem;
end;

procedure TBcjEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  while Count > 0 do
  begin
    n := Length(FBuf) - FLen;
    if n > Count then n := Count;
    Move(Buf^, FBuf[FLen], n);
    Inc(FLen, n);
    Inc(Buf, n);
    Dec(Count, n);
    if FLen = Length(FBuf) then Convert(False);
  end;
end;

procedure TBcjEncStage.DoFinish;
begin
  // Al final: convertir lo que quede hasta que el remanente sea <=5 bytes (sale tal cual)
  while FLen > 0 do Convert(True);
end;

{ Fábrica }

function StageName(const Stage: string): string;
var
  p: Integer;
begin
  p := Pos(':', Stage);
  if p > 0 then Result := Copy(Stage, 1, p - 1) else Result := Stage;
end;

{ 4x4 de lzma sin :b explícito con 2+ hilos: bloques parejos cuando el último bloque está
  casi lleno. Con S bytes en bloques de B quedan J = ceil(S/B) trabajos; S es lo que entra al
  método y REP puede achicarlo antes de 4x4: documentos, 66 MB en bloques de 24 MB (24+24+18)
  que REP deja en ~47 MB, son 24+23, dos trabajos con 4 hilos (9,9 s). En J bloques iguales
  (22+22+3 después de REP) son tres (5,3 s, +0,02 %). Sólo si J < N (con J >= N cada hilo ya
  tiene un trabajo y sólo se acortaría la cola: 4 bloques iguales en vez de 24x3+23 eran
  +0,03 % en archive -m5, +0,2 % en documentos -m5) y los bloques se achican a lo sumo 1/8:
  más chicos pierden relación (ejecutables, 24+24+11 -> 3x19,7 MB: +0,05 %; S/N o el
  múltiplo de N siguiente, 0,1..0,7 %). plz/lz4 no se tocan (su bloque es su ventana). El :b
  queda en el método guardado; el decodificador lee bloques de cualquier tamaño. }
function Balance4x4(const Method: string; DataSize: Int64): string;
var
  Stages: TStringArray;
  Inner, Own: string;
  Bs: SizeInt;
  N, i: Integer;
  B, J: Int64;
begin
  Result := Method;
  N := BudgetThreads;
  if (N < 2) or (DataSize <= 0) then Exit;
  Stages := Method.Split(['+']);
  for i := 0 to High(Stages) do
  begin
    if StageName(Stages[i]) <> '4x4' then Continue;
    Parse4x4(Stages[i], Inner, Bs);
    if StageName(Inner) <> 'lzma' then Continue;
    Own := Copy(Stages[i], 1, Length(Stages[i]) - Length(Inner));   // "4x4:" y sus parámetros
    if (Pos(':b', Own) > 0) or (Pos(':B', Own) > 0) then Continue;   // :b explícito
    if DataSize <= Bs then Continue;           // un solo trabajo: nada que repartir
    J := (DataSize + Bs - 1) div Bs;
    if J >= N then Continue;                  // un trabajo por hilo o más: sólo acortaría la cola
    B := (DataSize + J - 1) div J;
    if B < Int64(Bs) - Bs div 8 then Continue;   // el resto es chico: termina antes igual
    B := (B + 65535) and not Int64(65535);      // múltiplo de 64 KB
    if B = Bs then Continue;
    Stages[i] := '4x4:b' + IntToStr(B div 1024) + 'kb:' + Copy(Stages[i], 5, MaxInt);
  end;
  Result := string.Join('+', Stages);
end;

{ Tamaño de bloque de 4x4 según los datos y los hilos: si todo lo que se comprime
  (Enc4x4TotalHint) no da al menos 3 bloques por hilo, los bloques se achican hasta eso (en MB
  enteros, como mucho a la cuarta parte y no menos de 1 MB). Si no, el final de cada archivo
  era uno o dos bloques grandes con los demás hilos sin trabajo (exe -m1, 4 hilos: 8 bloques
  de 16 MB). El tamaño depende solo de los datos y de PARC_THREADS: la salida es la misma en
  cada corrida con el mismo N. Bloques más chicos limitan la ventana del método interno (en
  datos de muchos archivos casi no cuesta; en un archivo grande la regla no cambia nada). }
function Adaptive4x4Block(BlockSize: SizeInt): SizeInt;
const
  MB = 1 shl 20;
var
  Want, c: Int64;
begin
  Result := BlockSize;
  if (BudgetThreads < 2) or (Enc4x4TotalHint <= 0) or (BlockSize <= MB) then Exit;
  Want := 3 * BudgetThreads;
  if Enc4x4TotalHint div BlockSize >= Want then Exit;
  c := (Enc4x4TotalHint + Want - 1) div Want;
  c := (c + MB - 1) div MB * MB;
  if c < BlockSize div 4 then c := BlockSize div 4;
  if c < MB then c := MB;
  if c < BlockSize then Result := c;
end;

{ ¿Método interno rápido (plz, lz4, lzma fast)? Solo con esos 4x4 achica bloques
  (Adaptive4x4Block y el final de T4x4EncStage, parc_4x4): son los niveles -m1..-m3, donde el
  tiempo pesa; con lzma normal/max, ppmd, etc. el bloque grande vale más por el tamaño (y
  esos niveles ya sobran en velocidad). }
function FastInner4x4(const Inner: string): Boolean;
begin
  case StageName(Inner) of
    'lz4', 'plz': Result := True;
    'lzma': Result := ParseLzmaEncParams(Inner.Split([':'])).Algorithm = 0;
  else
    Result := False;
  end;
end;

{ ¿El método 4x4 fija su tamaño de bloque (b<mem>)? }
function Has4x4BlockParam(const Stage: string): Boolean;
var
  Params: TStringArray;
  k: Integer;
begin
  Params := Stage.Split([':']);
  Result := False;
  for k := 1 to High(Params) do
    if (Params[k] <> '') and ((Params[k][1] in ['0'..'9']) or
       ((Length(Params[k]) > 1) and (Params[k][2] in ['0'..'9']))) then
    begin
      if Params[k][1] = 'b' then Exit(True);
    end
    else
      Break;   // desde acá, el método interno
end;

function LimitMethodToSize(const Method: string; DataSize: Int64): string;
var
  Lim: Int64;
begin
  // limitDictionary + el texto canónico de cada compresor (parc_canon, PA-Lab): el mismo
  // método que guarda FreeArc para un bloque de ese tamaño
  Result := LimitAndCanonize(Balance4x4(Method, DataSize), DataSize);
  // y la memoria de los codificadores: -lc o el límite automático (75 % de la RAM; en 32 bits
  // también lo que entra en el espacio de direcciones). Sin esto -m9 en win32 se quedaba sin
  // memoria (rep:1gb + lzma bt4 de 192 MB + 4x4/bloques en paralelo)
  Lim := EffectiveCompressLimit;
  if (Lim > 0) and (EncodeMemEstimate(Result, DataSize) > Lim) then
    Result := FitEncodeMem(Result, DataSize, Lim);
end;

const
  MB_ = Int64(1) shl 20;

{ Primera memoria con sufijo de los parámetros de una etapa (el diccionario o bloque). }
function FirstMemParam(const Parts: TStringArray; Def: Int64): Int64;
var
  j: Integer;
  m: QWord;
begin
  for j := 1 to High(Parts) do
    if (Parts[j] <> '') and (Parts[j][1] in ['0'..'9']) and (StrToIntDef(Parts[j], -1) < 0) and
       ParseMem(Parts[j], m) then Exit(Int64(m));
  Result := Def;
end;

{ Memoria de una etapa al comprimir un bloque de DataSize bytes. Lo exacto donde el codificador
  lo sabe (lzma, rep); lo demás, de lo que reserva cada uno:
  - ppmd: el modelo; plz: ventana + tablas; lzp: entrada + salida + hash;
  - dict: ~3 veces el bloque; bwt: ~6 veces el bloque (BwtEncodeBlockMemory) por bloque en
    vuelo; dispack: ~2 veces su bloque;
  - orep: lo que dice OrepEncMemory (anillo de la ventana + un bloque, tabla de anclas, búferes);
  - cm y srep guardan todo el bloque (cm: ~4 veces más sus modelos de 64 MB; srep: ~3 veces);
  - 4x4: los trabajos en vuelo (hasta los hilos, máx. 16) por (método interno + 2 bloques);
  - delta: su bloque (8 MB por defecto) y las tablas del análisis;
  - filtros (exe, mm, tta, bcj2) y cifrado: búferes de unos MB. }
function StageEncodeMem(const Stage: string; DataSize: Int64): Int64;
var
  Parts: TStringArray;
  Inner: string;
  Bs: SizeInt;
  Lz: TLzpParams;
  Om: TOrepMethod;
  J: Integer;
  B: Int64;
  Bp: TBwtParams;
begin
  if IsCipherStage(Stage) then Exit(MB_);
  Parts := Stage.Split([':']);
  if DataSize < 0 then DataSize := 0;
  try
    case StageName(Stage) of
      'lzma':
        begin
          Result := Int64(Min(LzmaEncMemory(ParseLzmaEncParams(Parts)), QWord(High(Int64) div 2)));
          Inc(Result, 2 * MB_);
        end;
      'orep':
        begin
          Om := ParseOrepMethod(Parts);
          // el anillo (ranuras de un bloque de OREP que se reservan al usarlas, desde 0.0.4 sin
          // copias al crecer): con un bloque sólido más chico que la ventana, lo del bloque
          if (DataSize > 0) and (QWord(DataSize) < Om.Window) then Om.Window := DataSize;
          // + la salida de una llamada (1 MB)
          Result := Int64(OrepMethodEncMemory(Om)) + 2 * MB_;
        end;
      'ppmd': Result := Int64(ParsePpmdParams(Parts).Mem) + 2 * MB_;
      'lzp':
        begin
          Lz := ParseLzpParams(Parts);
          Result := 2 * Int64(Lz.BlockSize) + (Int64(8) shl Lz.HashSizeLog) + MB_;
        end;
      'delta':
        begin
          // the block (it grows with the data) plus the analysis tables
          B := ParseDeltaEncParams(Parts).BlockSize;
          if (DataSize > 0) and (DataSize < B) then B := DataSize;
          Result := B + MB_;
        end;
      'dict': Result := 3 * FirstMemParam(Parts, 64 * MB_) + MB_;
      'bwt', 'grzip':
        begin
          B := ParseBwtParams(Parts).BlockSize;
          if (DataSize > 0) and (DataSize < B) then B := DataSize;
          Bp := ParseBwtParams(Parts);
          Bp.BlockSize := B;
          Result := BwtEncodeBlockMemory(Bp);
        end;
      'dispack', 'dispack070':
        begin
          // the block plus look-ahead, and the streams (about the block again)
          B := DispackBlockSize(Parts);
          if (DataSize > 0) and (DataSize < B) then B := DataSize;
          Result := 2 * B + 2 * MB_;
        end;
      'cm': Result := CmEncMemory(ParseCmLevel(Parts), DataSize);
      'srep': Result := 3 * DataSize + 64 * MB_;
      'lz4': Result := 3 * FirstMemParam(Parts, MB_) + MB_;
      'plz': Result := PlzEncMemory(ParsePlzEncParams(Parts), True) + MB_;
      '4x4':
        begin
          Parse4x4(Stage, Inner, Bs);
          J := BudgetThreads;
          if J > FX_MAXTHREADS then J := FX_MAXTHREADS;
          if J < 1 then J := 1;
          Result := Int64(J) * (EncodeMemEstimate(Inner, Bs) + 2 * Int64(Bs)) + Int64(Bs);
        end;
    else
      Result := 4 * MB_;   // exe, mm, tta, bcj2, storing...
    end;
  except
    Result := 64 * MB_;    // parámetros raros: el codificador dará el error
  end;
end;

function EncodeMemEstimate(const Method: string; DataSize: Int64): Int64;
var
  St: string;
begin
  Result := 4 * MB_;
  for St in Method.Split(['+']) do Inc(Result, StageEncodeMem(St, DataSize));
end;

function FitEncodeMem(const Method: string; DataSize, Limit: Int64): string;
var
  St: TStringArray;
  Mem: array of Int64;
  Frozen: array of Boolean;
  i, j, Iter: Integer;
  Total, Target, Second: Int64;
  S2: string;
begin
  St := Method.Split(['+']);
  SetLength(Mem, Length(St));
  SetLength(Frozen, Length(St));
  for i := 0 to High(St) do Frozen[i] := IsCipherStage(St[i]);
  for Iter := 1 to 400 do
  begin
    Total := 4 * MB_;
    for i := 0 to High(St) do
    begin
      Mem[i] := StageEncodeMem(St[i], DataSize);
      Inc(Total, Mem[i]);
    end;
    if Total <= Limit then Break;
    j := -1;
    for i := 0 to High(St) do
      if not Frozen[i] and ((j < 0) or (Mem[i] > Mem[j])) then j := i;
    if j < 0 then Break;   // no entra ni con todo al mínimo: queda lo más chico posible
    // Lo que sobra, sacado de la más grande, pero de a lo sumo la mitad por paso (el mapeo
    // memoria -> parámetros de cada etapa es aproximado; se vuelve a medir)
    Target := Mem[j] - (Total - Limit);
    if Target < Mem[j] div 2 then Target := Mem[j] div 2;
    // y no por debajo de la que le sigue: así se reparten el recorte en vez de vaciar una
    // sola (TILIN -m9 en 1,5 GB: rep:290mb+lzma:88mb daba 856 MB, peor que -m7 con
    // rep:512mb+lzma:64mb, 821 MB)
    Second := 0;
    for i := 0 to High(St) do
      if (i <> j) and not Frozen[i] and (Mem[i] > Second) then Second := Mem[i];
    if (Second < Mem[j]) and (Target < Second) then Target := Second;
    if Target < MB_ then Target := MB_;
    S2 := CanonStageMem(St[j], Target);
    // El mapeo memoria -> parámetros de cada etapa es aproximado (4x4 reparte entre sus hilos
    // sin contar sus búferes): si con ese objetivo no cambia, se insiste más abajo antes de
    // darla por imposible (si no, se achicaba de más la siguiente: TILIN -m5 en win32 dejaba
    // 4x4:lzma:24mb y bajaba rep:96m a 55mb)
    while (S2 = St[j]) and (Target > 2 * MB_) do
    begin
      Target := Target div 4 * 3;
      S2 := CanonStageMem(St[j], Target);
    end;
    if S2 = St[j] then Frozen[j] := True
    else St[j] := S2;
  end;
  Result := string.Join('+', St);
end;

function TornadoRequested(const Method: string): Boolean;
var
  Stage, Inner: string;
  Bs: SizeInt;
begin
  for Stage in Method.Split(['+']) do
    case StageName(Stage) of
      'tor', 'xtor', 'etor': Exit(True);
      '4x4':
        begin
          Parse4x4(Stage, Inner, Bs);
          if TornadoRequested(Inner) then Exit(True);
        end;
    end;
  Result := False;
end;

function EncoderAvailable(const Method: string): Boolean;
var
  Stage, Inner: string;
  Bs: SizeInt;
begin
  for Stage in Method.Split(['+']) do
    if IsCipherStage(Stage) then Continue
    else case StageName(Stage) of
      '4x4':
        begin
          Parse4x4(Stage, Inner, Bs);
          if not EncoderAvailable(Inner) then Exit(False);
        end;
      'lz4': if not Lz4EncAvailable(Stage) then Exit(False);
      'plz': if not PlzEncAvailable(Stage) then Exit(False);
      'storing', 'exe', 'ppmd', 'lzp', 'lzma', 'orep', 'delta', 'dict', 'tta', 'mm', 'bwt', 'grzip', 'cm',
      'dispack', 'dispack070', 'srep', 'bcj2', 'exe2': ;
    else
      Exit(False);
    end;
  Result := True;
end;

function CreateStage(const Stage: string; Target: TOutStage): TOutStage;
var
  Par: TCryptParams;
  Master: TMasterKey;
  pp: TPpmdParams;
  Parts: TStringArray;
  Inner: string;
  Bs: SizeInt;
  Hint: Int64;
  mc, k: Integer;
begin
  Parts := Stage.Split([':']);
  if IsCipherStage(Stage) then
  begin
    // la clave ya está en el caché: la derivó MakeCipherStage al armar la etapa
    Par := ParseCipherStage(Stage);
    if not CryptLookup(Par, Master) then
      raise EUnsupportedEncoder.Create('encryption: key not derived');
    Exit(TAeadEncryptStage.Create(Target, Par, Master));
  end;
  case StageName(Stage) of
    '4x4':
      begin
        Parse4x4(Stage, Inner, Bs);
        Hint := 0;
        if not Has4x4BlockParam(Stage) and FastInner4x4(Inner) then
        begin
          Bs := Adaptive4x4Block(Bs);
          if BudgetThreads >= 2 then Hint := Enc4x4BlockHint;
        end;
        Result := T4x4EncStage.Create(Target, Inner, Bs, Noise4x4(Stage), Hint);
      end;
    'storing': Result := TStoringStage.Create(Target);
    'cm':      Result := TCmEncStage.Create(Target, ParseCmLevel(Parts));
    'orep':    Result := TOrepEncStage.Create(Target, Parts);
    'delta':   Result := TDeltaEncStage.Create(Target, Parts);
    'dict':    Result := TDictEncStage.Create(Target, Parts);
    'lz4':     Result := TLz4EncStage.Create(Target, Parts);
    'plz':     Result := TPlzEncStage.Create(Target, Parts);
    'bwt', 'grzip': Result := TBwtEncStage.Create(Target, Parts);
    'tta':     Result := TTtaEncStage.Create(Target, Parts);
    'mm':      Result := TMmEncStage.Create(Target, Parts);
    'lzma':
      // Con marca de fin: en los bloques de datos el decodificador de FreeArc la exige
      Result := TLzmaEncStage.Create(Target, ParseLzmaEncParams(Parts), True);
    'exe':     Result := TBcjEncStage.Create(Target);
    'bcj2', 'exe2': Result := TBcj2EncStage.Create(Target);
    'dispack', 'dispack070':
      Result := TDisPackEncStage.Create(Target, DispackBlockSize(Parts));
    'srep':
      Result := TSrepEncStage.Create(Target);
    'lzp':
      begin
        { MinCompression ("N%"): lo usa solo el compresor; ParseLzpParams lo saltea. }
        mc := 0;
        for k := 1 to High(Parts) do
          if (Parts[k] <> '') and (Parts[k][Length(Parts[k])] = '%') then
            mc := StrToIntDef(Copy(Parts[k], 1, Length(Parts[k]) - 1), 0);
        Result := TLzpEncStage.Create(Target, ParseLzpParams(Parts), mc);
      end;
    'ppmd':
      begin
        // La misma sintaxis que el decodificador: una sola implementación
        pp := ParsePpmdParams(Parts);
        Result := TPpmdEncStage.Create(Target, pp.Order, pp.Mem, pp.Restore);
      end;
  else
    raise EUnsupportedEncoder.CreateFmt('cannot compress with "%s" yet', [Stage]);
  end;
end;

{ TSrepEncStage }

constructor TSrepEncStage.Create(ATarget: TOutStage);
begin
  inherited Create(ATarget);
  FData := nil;
  FLen := 0;
end;

procedure TSrepEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  Cap: SizeInt;
begin
  if Count <= 0 then Exit;
  if FLen + Count > Length(FData) then
  begin
    Cap := Length(FData);
    if Cap = 0 then Cap := 64 * 1024;
    while Cap < FLen + Count do Cap := Cap * 2;
    SetLength(FData, Cap);
  end;
  Move(Buf^, FData[FLen], Count);
  Inc(FLen, Count);
end;

procedure TSrepEncStage.DoFinish;
var
  Enc: TBytes;
  Flag: Byte;
begin
  if FLen > 0 then
  begin
    Enc := SrepEncode(@FData[0], FLen);
    if (Length(Enc) = 0) or (Length(Enc) >= FLen) then
    begin
      // no conviene: se guarda tal cual (0)
      Flag := 0;
      Emit(@Flag, 1);
      Emit(@FData[0], FLen);
    end
    else
    begin
      Flag := 1;
      Emit(@Flag, 1);
      Emit(@Enc[0], Length(Enc));
    end;
  end;
  inherited DoFinish;
end;

{ Memoria: si detrás de orep (después de filtros 1:1) va lzma con match finder bt/hc, su memoria
  crece con la entrada hasta el diccionario (bt4 ~9 bytes por byte, hc4 ~5). OREP demora su
  salida N bytes y se libera al terminar antes de pasarlos: el pico baja de lzma + OREP a ~lzma
  + OREP - (g - 1) N. N = memoria de OREP / (g - 1), hasta 64 MB. }
procedure SetOrepTail(St: TOrepEncStage; const Stages: TStringArray; k: Integer);
var
  j: Integer;
  Lp: TLzmaEncParams;
  g: Int64;
  Om: TOrepMethod;
  N: Int64;
begin
  St.SetTail(0, 0);
  j := k + 1;
  while (j <= High(Stages)) and ((StageName(Stages[j]) = 'exe') or (StageName(Stages[j]) = 'delta')) do Inc(j);
  if (j > High(Stages)) or (StageName(Stages[j]) <> 'lzma') then Exit;
  Lp := ParseLzmaEncParams(Stages[j].Split([':']));
  case Lp.MatchFinder of
    mfBT2, mfBT3, mfBT4: g := 9;
    mfHC4: g := 5;
  else
    Exit;
  end;
  Om := ParseOrepMethod(Stages[k].Split([':']));
  N := Int64(OrepMethodEncMemory(Om)) div (g - 1);
  if N > 64 * MB_ then N := 64 * MB_;
  St.SetTail(N, Lp.DictSize);
end;

function CreateEncoderChain(const Method: string; Target: TOutStage): TOutStage;
var
  Stages: TStringArray;
  k: Integer;
begin
  // Validar todo antes de crear nada: si no, habría que desarmar la cadena a medias
  if not EncoderAvailable(Method) then
  begin
    Target.Free;
    raise EUnsupportedEncoder.CreateFmt('cannot compress with "%s" yet', [Method]);
  end;
  Result := Target;
  try
    Stages := Method.Split(['+']);
    for k := High(Stages) downto 0 do
    begin
      Result := CreateStage(Stages[k], Result);
      if StageName(Stages[k]) = 'orep' then SetOrepTail(TOrepEncStage(Result), Stages, k);
    end;
  except
    Result.Free;   // libera lo ya armado (y con eso Target)
    raise;
  end;
end;

function CompressMem(const Method: string; Src: PByte; SrcLen: SizeInt): TBytes;
var
  Sink: TMemSink;
  Chain: TOutStage;
begin
  Sink := TMemSink.Create;
  Chain := CreateEncoderChain(Method, Sink);
  try
    Chain.Write(Src, SrcLen);
    Chain.Finish;
    Result := Sink.Bytes;
  finally
    Chain.Free;   // libera también Sink
  end;
end;

function MakeCipherStage(const Algorithm: string; const Password: RawByteString; Header: Boolean): string;
var
  C: TCipherChoice;
begin
  if not ParseCipherChoice(Algorithm, C) then
    raise EUnsupportedEncoder.CreateFmt('invalid encryption algorithm: "%s" (chacha or aes)', [Algorithm]);
  Result := CryptStageForWrite(C, Password, Header);
end;

function WithoutCipher(const Method: string): string;
var
  Stage: string;
begin
  Result := '';
  for Stage in Method.Split(['+']) do
    if not IsCipherStage(Stage) then
    begin
      if Result <> '' then Result := Result + '+';
      Result := Result + Stage;
    end;
  if Result = '' then Result := 'storing';
end;

end.
