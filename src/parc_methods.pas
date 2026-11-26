{ Métodos de compresión (el formato base de FreeArc §7). Una cadena "a+b+c" se aplicó de izquierda a
  derecha al comprimir, así que al descomprimir se arma archivo -> c -> b -> a. }
unit parc_methods;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_bytes, parc_stream;

type
  EUnsupportedMethod = class(Exception);
  EPasswordRequired = class(Exception);   // el archivo está cifrado y no hay contraseña
  EBadPassword = class(Exception);        // el valor de comprobación no coincide

  TPpmdParams = record
    Order, Restore: Integer;
    Mem: QWord;
  end;

{ Parámetros de ppmd (compartido por el decodificador y el codificador). }
function ParsePpmdParams(const Params: TStringArray): TPpmdParams;

{ Contraseña para los archivos cifrados (bytes tal como los escribió el usuario, UTF-8). }
procedure SetArchivePassword(const Pwd: RawByteString);
{ La contraseña dada con SetArchivePassword ('' si no hay). }
function ArchivePassword: RawByteString;
{ Otra contraseña para probar (p. ej. -p y -hp distintas): cada bloque cifrado se abre con la
  primera de la lista cuyo valor de comprobación coincide. }
procedure AddArchivePassword(const Pwd: RawByteString);

{ Arma la cadena de decodificadores sobre Source (la cadena pasa a ser dueña de Source). }
function CreateDecoderChain(const Method: string; Source: TInStage): TInStage;

{ Descomprime un bloque de control (en memoria) a exactamente OrigSize bytes. }
function DecompressMem(const Method: string; Src: PByte; SrcLen: SizeInt; OrigSize: SizeInt): TBytes;

{ Memory size of a method parameter ("1mb", "244kb", "64m", "512b"; no unit = 2^N: "24" = 16mb):
  parc_bytes.ParseMemSize. }
function ParseMem(const S: string; out Value: QWord): Boolean;

function IsStoring(const Method: string): Boolean;

{ Memoria que estima el decodificador de un bloque (aproximada: solo decide cuántos bloques
  se procesan a la vez). }
function EstimateDecodeMem(const Method: string; OrigSize: Int64): Int64;
{ Memoria que declara el método de un bloque para decodificarlo (suma de los parámetros de
  memoria de sus etapas, sin búferes): lo que compara -ld<tamaño>. }
function DecodeMemNeeded(const Method: string): Int64;
{ Cuántos trabajos con esas estimaciones de memoria pueden correr a la vez: hasta Threads,
  mientras los más grandes entren en la mitad de la memoria física y del espacio de
  direcciones. }
function ThreadsForMemory(const Est: array of Int64; Threads: Integer; Limit: Int64 = 0): Integer;

implementation

uses
  parc_crypt, StrUtils, parc_os, parc_lzma, parc_filters, parc_delta, parc_lz4, parc_orep, parc_lzp, parc_ppmd,
  parc_dict, parc_bwt, parc_parallel, parc_tta, parc_mm, parc_dispack, parc_osrep, parc_cm,
  parc_bcj2, parc_plz, parc_4x4;

var
  GPassword: RawByteString;
  GHavePassword: Boolean;
  GExtraPasswords: array of RawByteString;

procedure SetArchivePassword(const Pwd: RawByteString);
begin
  GPassword := Pwd;
  GHavePassword := True;
end;

function ArchivePassword: RawByteString;
begin
  if GHavePassword then Result := GPassword else Result := '';
end;

procedure AddArchivePassword(const Pwd: RawByteString);
begin
  if not GHavePassword then begin SetArchivePassword(Pwd); Exit; end;
  SetLength(GExtraPasswords, Length(GExtraPasswords) + 1);
  GExtraPasswords[High(GExtraPasswords)] := Pwd;
end;

{ Clave de una etapa de cifrado: del caché, o probando las contraseñas dadas (-p, -hp y las que
  se pidieron por consola) contra el valor de comprobación de la etapa. }
function ResolveKey(const Par: TCryptParams): TMasterKey;
var
  p: Integer;
begin
  if CryptLookup(Par, Result) then Exit;
  if not GHavePassword then
    raise EPasswordRequired.Create('archive is encrypted: provide the password with -p<password>');
  if CryptTryPassword(Par, GPassword, Result) then Exit;
  for p := 0 to High(GExtraPasswords) do
    if CryptTryPassword(Par, GExtraPasswords[p], Result) then Exit;
  raise EBadPassword.Create('wrong password');
end;

function IsStoring(const Method: string): Boolean;
begin
  Result := Method = 'storing';
end;

function ParseMem(const S: string; out Value: QWord): Boolean;
begin
  Result := ParseMemSize(S, Value);
end;

type
  TLzmaParams = record
    lc, lp, pb: Integer;
    DictSize: QWord;
  end;

{ What the lzma decoder needs from the stage text: lc<n>, lp<n>, pb<n> and the dictionary
  (d<mem>, or a memory size with a unit; a plain number is an encoder setting). Defaults
  lc3 lp0 pb2, 64 MB. A leading '*' (optional parameter) is ignored. }
function ParseLzmaParams(const Params: TStringArray): TLzmaParams;
var
  k: Integer;
  p, Key, Rest: string;
  m: QWord;
begin
  Result.lc := 3;
  Result.lp := 0;
  Result.pb := 2;
  Result.DictSize := 64 shl 20;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if (p <> '') and (p[1] = '*') then p := Copy(p, 2, MaxInt);
    if p = '' then Continue;
    Key := Copy(p, 1, 2);
    Rest := Copy(p, 3, MaxInt);
    if Key = 'lc' then Result.lc := StrToIntDef(Rest, -1)
    else if Key = 'lp' then Result.lp := StrToIntDef(Rest, -1)
    else if Key = 'pb' then Result.pb := StrToIntDef(Rest, -1)
    else if (p[1] = 'd') and ParseMemSize(Copy(p, 2, MaxInt), m) then Result.DictSize := m
    else if (p[1] in ['0'..'9']) and not (p[Length(p)] in ['0'..'9']) and ParseMemSize(p, m) then
      Result.DictSize := m;
  end;
end;

{ ppmd: o<n> order, m<mem> or mem<mem> model memory, r / r<n> restart method (0 restart,
  1 cut-off); unnamed: a number is the order, a memory size the model memory. c<mem> (a chunk
  size of older versions) means nothing. Defaults: order 10, 48 MB, restart. }
function ParsePpmdParams(const Params: TStringArray): TPpmdParams;
var
  k: Integer;
  p: string;
  m: QWord;
begin
  Result.Order := 10;
  Result.Mem := 48 shl 20;
  Result.Restore := 0;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if Copy(p, 1, 3) = 'mem' then p := 'm' + Copy(p, 4, MaxInt);
    if p = '' then Continue;
    if p = 'r' then
      Result.Restore := 1
    else if (Length(p) > 1) and (p[1] = 'm') then
    begin
      if ParseMemSize(Copy(p, 2, MaxInt), m) then Result.Mem := m;
    end
    else if (Length(p) > 1) and (p[1] = 'o') then Result.Order := StrToIntDef(Copy(p, 2, MaxInt), -1)
    else if (Length(p) > 1) and (p[1] = 'r') then Result.Restore := StrToIntDef(Copy(p, 2, MaxInt), -1)
    else if (Length(p) > 1) and (p[1] = 'c') then
      // (ignored)
    else if StrToIntDef(p, -1) >= 0 then Result.Order := StrToInt(p)
    else if ParseMemSize(p, m) then Result.Mem := m;
  end;
end;

{ Tornado (`tor`) se quitó después de 0.0.5 (relicencia MIT): sus streams ya no se leen. }
procedure RaiseTornadoRemoved;
begin
  raise EUnsupportedMethod.Create('the tor (Tornado) method is no longer supported (removed after PArc 0.0.5); ' +
    'extract this archive with PArc 0.0.5');
end;

function CreateStage(const Stage: string; Source: TInStage): TInStage;
var
  Par: TCryptParams;
  Params: TStringArray;
  lz: TLzmaParams;
  pp: TPpmdParams;
begin
  Params := Stage.Split([':']);
  if Length(Params) = 0 then raise EUnsupportedMethod.Create('empty method');
  if IsCipherStage(Stage) then
  begin
    Par := ParseCipherStage(Stage);
    Exit(TAeadDecryptStage.Create(Source, Par, ResolveKey(Par)));
  end;
  case Params[0] of
    'storing':
      Result := Source;
    'lzma':
      begin
        lz := ParseLzmaParams(Params);
        Result := TLzmaStage.Create(Source, lz.lc, lz.lp, lz.pb, lz.DictSize);
      end;
    'exe':
      Result := TBcjX86Stage.Create(Source);
    'bcj2', 'exe2':
      Result := TBcj2DecStage.Create(Source);
    'delta':
      Result := TDeltaStage.Create(Source);
    'lz4':
      Result := TLz4Stage.Create(Source);   // el frame dice su tamaño de bloque
    'orep':
      Result := TOrepDecStage.Create(Source, ParseOrepMethod(Params));
    'rep':
      // REP de FreeArc (GPL) se reemplazó por OREP (MIT) en PArc 0.0.6
      raise EUnsupportedMethod.Create('method rep (FreeArc REP) is no longer supported: ' +
        'it was replaced by orep (extract this archive with PArc 0.0.5)');
    '4x4':
      Result := T4x4DecStage.Create(Source, Inner4x4Method(Params));
    'lzp':
      Result := TLzpStage.Create(Source, ParseLzpParams(Params));
    'dict':
      Result := TDictStage.Create(Source, ParseDictBlockSize(Params));
    'tor': RaiseTornadoRemoved;
    'plz':
      // El stream dice su ventana: los parámetros son del compresor
      Result := TPlzStage.Create(Source);
    'bwt':
      Result := TBwtStage.Create(Source, Params);
    'grzip':
      // GRZip (LGPL) se reemplazó por el bwt propio (MIT) en PArc 0.0.6
      raise EUnsupportedMethod.Create('method grzip (FreeArc GRZip) is no longer supported: ' +
        'it was replaced by bwt (extract this archive with PArc 0.0.5)');
    'tta':
      Result := TTtaStage.Create(Source, ParseTtaParams(Params));
    'mm':
      Result := TMmStage.Create(Source, ParseMmParams(Params));
    'ppmd':
      begin
        pp := ParsePpmdParams(Params);
        Result := TPpmdStage.Create(Source, pp.Order, pp.Mem, pp.Restore);
      end;
    'dispack', 'dispack070':
      Result := TDisPackStage.Create(Source, DispackBlockSize(Params));
    'srep', 'osrep':
      // OSREP desde PArc 0.0.6 (el stream dice lo suyo; los parámetros solo se validan)
      begin
        ParseSrepMethod(Params);
        Result := TSrepDecStage.Create(Source);
      end;
    'cm':
      Result := TCmDecStage.Create(Source);
  else
    // el cifrado de PArc 0.0.3 y anteriores (el esquema de FreeArc: "aes-256/ctr:...")
    if (Pos('/', Params[0]) > 0) and ((Pos('aes', Params[0]) = 1) or (Pos('blowfish', Params[0]) = 1) or
       (Pos('serpent', Params[0]) = 1) or (Pos('twofish', Params[0]) = 1)) then
      raise EUnsupportedMethod.Create('encrypted with the scheme of PArc 0.0.3 and earlier, ' +
        'which is no longer supported (extract it with PArc 0.0.3)');
    raise EUnsupportedMethod.CreateFmt('method not supported yet: "%s"', [Stage]);
  end;
end;

function CreateDecoderChain(const Method: string; Source: TInStage): TInStage;
var
  Stages: TStringArray;
  k: Integer;
begin
  Result := Source;
  try
    Stages := Method.Split(['+']);
    for k := High(Stages) downto 0 do
      Result := CreateStage(Stages[k], Result);
  except
    Result.Free;   // libera lo ya armado (y con eso Source)
    raise;
  end;
end;

function DecompressMem(const Method: string; Src: PByte; SrcLen: SizeInt; OrigSize: SizeInt): TBytes;
var
  Params: TStringArray;
  lz: TLzmaParams;
  Written: SizeInt;
  Chain: TInStage;
  Extra: Byte;
begin
  SetLength(Result, OrigSize);
  if IsStoring(Method) then
  begin
    if SrcLen <> OrigSize then Corrupt('wrong block size');
    if OrigSize > 0 then Move(Src^, Result[0], OrigSize);
    Exit;
  end;
  Params := Method.Split([':']);
  if (Pos('+', Method) = 0) and (Params[0] = 'lzma') then
  begin
    // FreeArc descomprime los bloques de control memoria-a-memoria (sin exigir marca de fin)
    lz := ParseLzmaParams(Params);
    if not ValidLzmaProps(lz.lc, lz.lp, lz.pb) then raise EUnsupportedMethod.Create('invalid lzma properties');
    if LzmaDecodeRaw(Src, SrcLen, PByte(Result), OrigSize, lz.lc, lz.lp, lz.pb, Written) = lzDataError then
      Corrupt('lzma decompression failed');
    if Written <> OrigSize then Corrupt('lzma decompression failed');
    Exit;
  end;
  // Cualquier otra cadena: en streaming
  Chain := CreateDecoderChain(Method, TMemStage.Create(Src, SrcLen));
  try
    if OrigSize > 0 then Chain.ReadExact(PByte(Result), OrigSize);
    if Chain.Read(@Extra, 1) <> 0 then Corrupt('block decompresses to more bytes than expected');
  finally
    Chain.Free;
  end;
end;

{ Memoria que estima el decodificador de un bloque: por cada etapa, el mayor parámetro de
  memoria (diccionario, ventana de rep, modelo de ppmd...) sin pasar del tamaño del bloque (con
  un mínimo, por los modelos que no dependen de él), más los búferes. Es aproximada: solo
  decide cuántos bloques se decodifican a la vez; si se queda corta, el trabajo al que le falte
  memoria se rehace solo. }
{ Mayor parámetro de memoria de cada etapa (diccionario, ventana de rep, modelo de ppmd...),
  sin pasar de Cap. }
function StageMemSum(const Method: string; Cap: Int64): Int64;
var
  Stages, Params: TStringArray;
  s, k: Integer;
  p: string;
  m: QWord;
  StageMax: Int64;
begin
  Result := 0;
  Stages := Method.Split(['+']);
  for s := 0 to High(Stages) do
  begin
    if IsCipherStage(Stages[s]) then Continue;   // (la sal y el nonce en hex no son memoria)
    Params := Stages[s].Split([':']);
    StageMax := 0;
    if Params[0] = 'orep' then
    begin
      // OREP: la ventana circular del decodificador (ventana + un bloque, redondeada a bloques)
      try
        StageMax := Int64(OrepMethodDecMemory(ParseOrepMethod(Params)));
      except
        on EUnsupportedMethod do StageMax := 0;   // lo informa el decodificador
      end;
      if StageMax > Cap then StageMax := Cap;
      Inc(Result, StageMax);
      Continue;
    end;
    if (Params[0] = 'srep') or (Params[0] = 'osrep') then
    begin
      // OSREP: todo el bloque (la salida y el stream, que no es más grande) y sus búferes
      StageMax := SrepDecMemory;
      if Cap < High(Int64) div 4 then Inc(StageMax, 2 * Cap);
      Inc(Result, StageMax);
      Continue;
    end;
    for k := 1 to High(Params) do
    begin
      p := Params[k];
      while (p <> '') and not (p[1] in ['0'..'9']) do Delete(p, 1, 1);   // d64m, mem48m, *1gb...
      // Solo con sufijo explícito: un entero pelado suele ser un orden o un nivel
      if (p <> '') and (LowerCase(p[Length(p)]) in ['b', 'k', 'm', 'g']) and ParseMem(p, m) then
        if (m <= QWord(High(Int64))) and (Int64(m) > StageMax) then StageMax := Int64(m);
    end;
    if StageMax > Cap then StageMax := Cap;
    Inc(Result, StageMax);
  end;
end;

function EstimateDecodeMem(const Method: string; OrigSize: Int64): Int64;
var
  Cap: Int64;
begin
  Cap := OrigSize;
  if Cap < 64 shl 20 then Cap := 64 shl 20;
  Result := (8 shl 20) + StageMemSum(Method, Cap);
end;

function DecodeMemNeeded(const Method: string): Int64;
begin
  Result := StageMemSum(Method, High(Int64));
end;

{ Cuántos bloques se pueden decodificar a la vez: hasta Threads, mientras los más grandes
  entren en la mitad de la memoria física y del espacio de direcciones (ulimit -v, ~2 GB en
  win32). }
function ThreadsForMemory(const Est: array of Int64; Threads: Integer; Limit: Int64): Integer;
var
  Sorted: array of Int64;
  i, j: Integer;
  t, Budget, Lim, Sum: Int64;
begin
  Budget := High(Int64);
  Lim := PhysicalMemory;
  if Lim > 0 then Budget := Lim div 2;
  Lim := AddressSpaceLimit;
  if (Lim > 0) and (Lim div 2 < Budget) then Budget := Lim div 2;
  {$IFNDEF CPU64}
  if Budget > Int64(1) shl 30 then Budget := Int64(1) shl 30;
  {$ENDIF}
  if Limit > 0 then Budget := Limit;   // -lc / límite automático de compresión
  SetLength(Sorted, Length(Est));
  for i := 0 to High(Est) do Sorted[i] := Est[i];
  // Los Threads más grandes (selección parcial, de mayor a menor)
  for i := 0 to High(Sorted) do
  begin
    if i >= Threads then Break;
    for j := i + 1 to High(Sorted) do
      if Sorted[j] > Sorted[i] then
      begin
        t := Sorted[i]; Sorted[i] := Sorted[j]; Sorted[j] := t;
      end;
  end;
  Result := 0;
  Sum := 0;
  while (Result < Threads) and (Result <= High(Sorted)) do
  begin
    if Sum + Sorted[Result] > Budget then Break;
    Inc(Sum, Sorted[Result]);
    Inc(Result);
  end;
end;

end.
