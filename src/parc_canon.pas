unit parc_canon;
{ ================================================================================
  LimitAndCanonize — port de la canonización de métodos de FreeArc 0.67.1.

  Por cada etapa del método de un bloque de datos hace lo que hace FreeArc:
    1. limitDictionary (ArcvProcessRead.hs:120):
         mem = roundMemUp(totalBytes + totalBytes div 100 + 512);
         por etapa, si GetDictionary() > mem -> SetDictionary(mem) (Compression.h:419).
       4x4 propaga el límite al compresor interno (C_4x4.h:35).
    2. Canonización: ShowCompressionMethod(buf, purify=TRUE) de cada clase
       (CompressionLibrary.cpp:644) — el string que queda almacenado.

  Portado de Compression/*/C_*.cpp y C_*.h; el oráculo es la salida real de
  arc.exe 0.67.1 (lb-f*.txt del corpus compat). Etapas sin diccionario
  (exe/delta/mm/tta/ppmd/storing) solo se canonizan.             — PA-Lab
  ================================================================================ }
{$mode objfpc}{$H+}
interface

function LimitAndCanonize(const Method: string; BlockSize: Int64): string;

{ Una etapa ya canónica achicada para que su codificador use a lo sumo MemLim bytes (aprox.):
  lzma con su estimación exacta (LzmaFitDictionary), tor búfer + hash, orep con OrepEncMemory,
  lzp/dict a la mitad,
  grzip a 1/8 (BWT), ppmd el modelo, y el método interno de 4x4 con MemLim repartido entre sus
  hilos. cm, srep y los filtros no cambian. Lo usa el ajuste de la cadena entera
  (parc_encoders.FitEncodeMem), que mide con la estimación de cada codificador y repite. }
function CanonStageMem(const Stage: string; MemLim: Int64): string;

{ Límite de memoria de los codificadores que corren a la vez (bytes; 0 = sin límite):
  -lc<tamaño>, o el automático (CompressMemLimit < 0): 75 % de la RAM; en 32 bits además a lo
  sumo 2,25 GB y 9/16 del espacio de direcciones (lo demás es para búferes, DLLs y la
  fragmentación de un proceso de 2 o 4 GB). }
function EffectiveCompressLimit: Int64;

var
  { -lc: -1 = automático; 0 = sin límite (-lc-); si no, bytes. Se fija al leer la línea de
    comandos, antes de comprimir (después solo se lee, desde varios hilos). }
  CompressMemLimit: Int64 = -1;

implementation

uses SysUtils, Math, parc_os, parc_methods, parc_torenc, parc_lzmaenc, parc_parallel, parc_orep;

const
  KB = 1024; MB = 1024*1024; GB = Int64(1024)*1024*1024;
  INT_MAX = High(Integer);
  GRZ_MaxBlockSize = 64*MB;   { C_GRZip; no alcanza a capar en el corpus }
  default_Tornado_method = 5; { Tornado.cpp:77 }

{ --- showMem (Compression.hs:547-556) -------------------------------------- }

function ShowMem(Mem: Int64): string;
  function Fmt(Val, NextVal: Int64; const Str: string): string;
  begin
    if (Mem mod Val = 0) or (NextVal > 0) and (Mem div NextVal >= 4096) then
      Result := IntToStr((Mem + Val div 2) div Val) + Str
    else if Val > KB then
      Result := Fmt(KB, 0, 'kb')
    else if Val = KB then
      Result := Fmt(1, 0, 'b')   // ni kb exactos: en bytes (antes recursión infinita)
    else
      Result := IntToStr(Mem) + 'b';
  end;
begin
  if Mem = 0 then Exit('0b');
  if (Mem mod GB = 0) or (Mem div MB >= 4096) then Exit(Fmt(GB, 0, 'gb'));
  if (Mem mod MB = 0) or (Mem div KB >= 4096) then Exit(Fmt(MB, 0, 'mb'));
  Result := Fmt(KB, 0, 'kb');
end;

{ --- roundMemUp (Compression.hs:559-560) ------------------------------------ }

function RoundMemUp(Mem: Int64): Int64;
begin
  if Mem >= 4096*KB then Result := ((Mem + MB - 1) div MB) * MB
                    else Result := ((Mem + KB - 1) div KB) * KB;
end;

function LB(X: Int64): Integer;   { floor(log2(X)), X>0 }
begin
  Result := 0;
  while (X shr (Result+1)) > 0 do Inc(Result);
end;

function RoundUpPow2(X: Int64): Int64;   { roundup_to_power_of(x,2) }
begin
  Result := 1;
  while Result < X do Result := Result shl 1;
end;

{ --- parseMem de FreeArc: sufijos b/kb/mb/gb; pelado = bytes ---------------- }

function ParseMem(const S: string; Def: Int64): Int64;
var T: string; Mult: Int64; N: Integer;
begin
  Result := Def; T := LowerCase(Trim(S)); if T = '' then Exit;
  N := 0; Mult := 1;
  if Copy(T, Length(T)-1, 2) = 'gb' then begin Mult := GB; N := 2 end
  else if Copy(T, Length(T)-1, 2) = 'mb' then begin Mult := MB; N := 2 end
  else if Copy(T, Length(T)-1, 2) = 'kb' then begin Mult := KB; N := 2 end
  else if T[Length(T)] = 'b' then N := 1
  else if T[Length(T)] = 'k' then begin Mult := KB; N := 1 end
  else if T[Length(T)] = 'm' then begin Mult := MB; N := 1 end
  else if T[Length(T)] = 'g' then begin Mult := GB; N := 1 end;
  Result := StrToInt64Def(Copy(T, 1, Length(T)-N), -1) * Mult;
  if Result < 0 then Result := Def;
end;

{ parseMem del C (Common.cpp): sin sufijo es 2^N. }
function CMem(const S: string; Def: Int64): Int64;
var
  q: QWord;
begin
  if parc_methods.ParseMem(S, q) then Result := q else Result := Def;
end;

{ showMem del C (Common.cpp:255): la unidad más grande que divide exacto. }
function CShowMem(Mem: Int64): string;
begin
  if Mem = 0 then Result := '0b'
  else if Mem mod GB = 0 then Result := IntToStr(Mem div GB) + 'gb'
  else if Mem mod MB = 0 then Result := IntToStr(Mem div MB) + 'mb'
  else if Mem mod KB = 0 then Result := IntToStr(Mem div KB) + 'kb'
  else Result := IntToStr(Mem) + 'b';
end;

function IsMem(const S: string): Boolean;
begin
  Result := (S <> '') and (S[1] in ['0'..'9']);
end;

function Num(const S: string; Def: Int64): Int64;
begin
  Result := StrToInt64Def(S, Def);
end;

const
  StdEnc:  array[0..16] of Integer = (0,1,2,3,3,4,4,4,4,4,4,4,4,4,4,4,4);
  StdHS:   array[0..16] of Int64   = (0,16*KB,64*KB,128*KB,2*MB,8*MB,32*MB,128*MB,512*MB,2*GB,2*GB,
                                       256*MB,256*MB,384*MB,512*MB,512*MB,128*MB);
  StdBuf:  array[0..16] of Int64   = (1*MB,1*MB,2*MB,4*MB,8*MB,16*MB,64*MB,256*MB,1*GB,1*GB,1*GB,
                                       128*MB,128*MB,128*MB,128*MB,128*MB,128*MB);

function StageNameOf(const S: string): string;
begin
  Result := LowerCase(S.Split([':'])[0]);
end;

{ ================================================================================ }
{ Canoniza una cadena de etapas con un límite de diccionario ya calculado          }

{$IFDEF CPU32}
const
  { 32 bits: el codificador lzma (ventana + hash + árbol) no pasa de 2 GB y sus piezas, más
    kLzmaEnc32Headroom para el resto del proceso, se tienen que poder reservar de verdad (el
    límite real es el espacio de direcciones fragmentado de 2 a 4 GB, no la RAM). Sin esto,
    lzma:1gb fallaba con "Out of memory". }
  kLzmaEnc32MaxMem = Int64(2) shl 30;
  kLzmaEnc32Headroom = Int64(256) shl 20;

{$ENDIF}

{ Diccionario lzma cuyo codificador entra en MaxMem (LzmaFitDictionary): la memoria de 32 bits
  o el límite de -lc. MFi como en CanonStage. }
function FitLzma(BS, MFi, Alg, NFB, MC, LC, LP: Int64; MaxMem, Headroom: Int64): Int64;
var
  P: TLzmaEncParams;
begin
  P := DefaultLzmaEncParams;
  P.DictSize := BS;
  P.Algorithm := Alg;
  P.NumFastBytes := NFB;
  P.MatchFinderCycles := MC;
  P.lc := LC;
  P.lp := LP;
  case MFi of
    1: P.MatchFinder := mfBT2;
    2: P.MatchFinder := mfBT3;
    3: P.MatchFinder := mfBT4;
    4: P.MatchFinder := mfHC4;
  else
    P.MatchFinder := mfHT4;
  end;
  Result := LzmaFitDictionary(P, MaxMem, Headroom);
end;


{ Tamaño para -lc: hacia abajo a MB enteros (a KB por debajo de 4 MB), al menos 1 MB. }
function FitMem(X: Int64): Int64;
begin
  if X >= 4*MB then Result := (X div MB) * MB else Result := (X div KB) * KB;
  if Result < MB then Result := MB;
end;

function CanonChain(const Method: string; Limit, MemLim: Int64): string;
var
  Stages: TStringArray;
  I: Integer;

  function CanonStage(const S: string): string;
  var
    Parts: TStringArray;
    Name, P: string;
    J: Integer;
    BS, MC, MML, Bar, Sm, HSL, Amp, Hash, Alg, MFi, NFB, PB, LC, LP, HS: Int64;
    MFSet: Boolean;
    M, MR, W, MM, MS, Num9, Enc, Lvl, BPos: Int64;
    PP: TPpmdParams;
    StartI: Integer;
    L: string;
    LZP, A, C3, Ext: Boolean;
    Interno: string;
    I: Integer;
    TM, TD: TTorMethod;
    OM: TOrepMethod;

    function Pr(N: Integer): string;
    begin
      if N < Length(Parts) then Result := Parts[N] else Result := '';
    end;

begin

    Parts := S.Split([':']);
    Name  := LowerCase(Parts[0]);
    P     := '';

    { --- orep (parc_orep, MIT). La ventana se limita al bloque (como SetDictionary) y a la
          memoria (OrepEncMemory); queda siempre, y los demás parámetros solo si no son los de
          por omisión (l64, a0, s4, c4, b4mb, d0). Parámetros inválidos: igual (el codificador da
          el error). }
    if Name = 'orep' then
    begin
      try
        OM := ParseOrepMethod(Parts);
      except
        on EUnsupportedMethod do Exit(S);
      end;
      if Int64(OM.Window) > Limit then OM.Window := Limit;
      if (MemLim > 0) and (Int64(OrepMethodEncMemory(OM)) > MemLim) then
        OM.Window := OrepFitWindow(OM, MemLim);
      Result := 'orep:' + ShowMem(OM.Window);
      if OM.MinLen <> OREP_DEF_MINLEN then Result := Result + ':l' + IntToStr(OM.MinLen);
      if OM.Align <> OREP_DEF_ALIGN then Result := Result + ':a' + IntToStr(OM.Align);
      if OM.Density <> OREP_DEF_DENSITY then Result := Result + ':s' + IntToStr(OM.Density);
      if OM.Cands <> OREP_DEF_CANDS then Result := Result + ':c' + IntToStr(OM.Cands);
      if OM.Chunk <> OREP_DEF_CHUNK then Result := Result + ':b' + ShowMem(OM.Chunk);
      if OM.MinDist <> 0 then Result := Result + ':d' + ShowMem(OM.MinDist);
      Exit;
    end;

    { --- lzma (C_LZMA.cpp/.h). Defaults: 64mb, h0, alg1, nfb32, mfHT4,
          mc0, pb2, lc3, lp0. SetDictionary: dict=max(32kb, mem) en 32-bit. }
    if Name = 'lzma' then
    begin
      BS := ParseMem(Pr(1), 64*MB);
      if BS > Limit then BS := Limit;
      if BS < 32*KB then BS := 32*KB;
      Hash := Int64(0); Alg := 1; MFi := 0;  { 0=HT4 1=BT2 2=BT3 3=BT4 4=HC4 }
      MFSet := False;
      NFB := Int64(32); MC := 0; PB := 2; LC := 3; LP := 0;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if (L <> '') and (L[1] in ['0'..'9']) then NFB := Num(L, 32)
        { hc4/ht4 antes que "h<tamaño>" (si no, se tomaban como tamaño de hash y se perdían) }
        else if L = 'hc4' then begin MFi := 4; MFSet := True; end
        else if L = 'ht4' then begin MFi := 0; MFSet := True; end
        else if Copy(L,1,1) = 'h' then Hash := ParseMem(Copy(L,2,MaxInt), 0)
        { C_LZMA.cpp:623-627: los presets fijan algoritmo, fast bytes y ciclos, y el match
          finder solo si todavía no se dio uno ("max" = normal + bt4 + 128) }
        else if L = 'fastest' then begin Alg := 0; if not MFSet then MFi := 0; MFSet := True; NFB := 5; MC := 1; end
        else if L = 'fast' then begin Alg := 0; if not MFSet then MFi := 0; MFSet := True; NFB := 32; MC := 0; end
        else if L = 'normal' then begin Alg := 1; if not MFSet then MFi := 0; MFSet := True; NFB := 32; MC := 0; end
        else if L = 'max' then begin Alg := 1; if not MFSet then MFi := 3; MFSet := True; NFB := 128; MC := 0; end
        else if L = 'ultra' then begin Alg := 1; if not MFSet then MFi := 3; MFSet := True; NFB := 128; MC := 128; end
        else if (Copy(L,1,1) = 'a') and (Length(L) = 2) then Alg := Num(Copy(L,2,1), 1)
        else if L = 'bt2' then begin MFi := 1; MFSet := True; end
        else if L = 'bt3' then begin MFi := 2; MFSet := True; end
        else if L = 'bt4' then begin MFi := 3; MFSet := True; end
        else if Copy(L,1,2) = 'mc' then MC := Num(Copy(L,3,MaxInt), 0)
        else if Copy(L,1,2) = 'pb' then PB := Num(Copy(L,3,MaxInt), 2)
        else if Copy(L,1,2) = 'lc' then LC := Num(Copy(L,3,MaxInt), 3)
        else if Copy(L,1,2) = 'lp' then LP := Num(Copy(L,3,MaxInt), 0);
      end;
      {$IFDEF CPU32}
      // Con el límite de compresión (EffectiveCompressLimit, automático en 32 bits) la cadena
      // ya entra: sin la prueba de reservar de verdad, que dependía de lo que otros bloques
      // tenían reservado en ese momento (el método cambiaba entre corridas). Solo con -lc- se
      // sigue probando.
      if EffectiveCompressLimit > 0 then
        BS := FitLzma(BS, MFi, Alg, NFB, MC, LC, LP, kLzmaEnc32MaxMem, 0)
      else
        BS := FitLzma(BS, MFi, Alg, NFB, MC, LC, LP, kLzmaEnc32MaxMem, kLzmaEnc32Headroom);
      {$ENDIF}
      if MemLim > 0 then BS := FitLzma(BS, MFi, Alg, NFB, MC, LC, LP, MemLim, 0);
      Result := 'lzma:' + ShowMem(BS);
      if Hash <> 0 then Result := Result + (':h' + ShowMem(Hash));
      if MFi = 0 then
      begin
        if Alg = 2 then Result := Result + ':a2'
        else if Alg = 0 then Result := Result + ':fast'
        else Result := Result + ':normal';
      end
      else
      begin
        if Alg = 0 then Result := Result + ':fast' else if Alg = 1 then Result := Result + ':normal' else Result := Result + ':max';
        case MFi of 1: Result := Result + ':bt2'; 2: Result := Result + ':bt3'; 3: Result := Result + ':bt4'; 4: Result := Result + ':hc4'; end;
      end;
      Result := Result + (':' + IntToStr(NFB));
      if MC <> 0 then Result := Result + (':mc' + IntToStr(MC));
      if PB <> 2 then Result := Result + (':pb' + IntToStr(PB));
      if LC <> 3 then Result := Result + (':lc' + IntToStr(LC));
      if LP <> 0 then Result := Result + (':lp' + IntToStr(LP));
      Exit;
    end;

    { --- grzip (C_GRZip.cpp/.h). Defaults: m1, 8mb, lzp on, mm32, h15.
          SetBlockSize: BS=min(bs,GRZ_Max); h=min(h, 1+lb(BS-1)).
          Show imprime l<h> SIEMPRE que EnableLZP. }
    if Name = 'grzip' then
    begin
      BS := Int64(0); M := 1; MML := 32; HSL := 15;
      LZP := True; A := False;
      for J := 0 to High(Parts) do
      begin
        if J = 0 then Continue;
        L := LowerCase(Parts[J]);
        if (L <> '') and (L[1] in ['0'..'9']) and (BS = 0) then BS := ParseMem(L, 0)
        else if (Copy(L,1,1) = 'm') and (Length(L) >= 2) and (L[2] in ['0'..'9']) then M := Num(Copy(L,2,MaxInt), 1)
        else if L = 'l' then LZP := False
        else if Copy(L,1,1) = 'l' then MML := Num(Copy(L,2,MaxInt), 32)
        else if Copy(L,1,1) = 'h' then HSL := Num(Copy(L,2,MaxInt), 15)
        else if L = 'a' then A := True
        else if BS = 0 then BS := ParseMem(L, 0);
      end;
      if BS = 0 then BS := 8*MB;
      if BS > Limit then BS := Limit;
      if BS > GRZ_MaxBlockSize then BS := GRZ_MaxBlockSize;
      if (MemLim > 0) and (BS > MemLim div 8) then BS := FitMem(MemLim div 8);
      if HSL > 1 + LB(BS-1) then HSL := 1 + LB(BS-1);
      Result := 'grzip:' + ShowMem(BS) + ':m' + IntToStr(M) + ':';
      if LZP then Result := Result + ('l' + IntToStr(MML) + ':h' + IntToStr(HSL))
             else Result := Result + 'l';
      if A then Result := Result + (':a');
      Exit;
    end;

    { --- dict (C_Dict.cpp/.h). Defaults: 64mb, mc100, c20, l2048, m100, s50, r4.
          Presets: p -> l8192 m400 s100; f -> l2048 m100 s50 r0. }
    if Name = 'dict' then
    begin
      BS := ParseMem(Pr(1), 64*MB);
      if BS > Limit then BS := Limit;
      MC := 100; W := 20; LC := 2048; MM := 100; MS := 50; MR := 4;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if L = 'p' then begin LC := 8192; MM := 400; MS := 100; MR := 4 end
        else if L = 'f' then begin LC := 2048; MM := 100; MS := 50; MR := 0 end
        else if (L <> '') and (L[1] in ['0'..'9']) then
          if Copy(L, Length(L), 1) = '%' then MC := Num(Copy(L, 1, Length(L)-1), 100)
          else BS := ParseMem(L, 64*MB)
        else if Copy(L,1,1) = 'c' then W := Num(Copy(L,2,MaxInt), 20)
        else if Copy(L,1,1) = 'l' then LC := Num(Copy(L,2,MaxInt), 2048)
        else if Copy(L,1,1) = 'm' then MM := Num(Copy(L,2,MaxInt), 100)
        else if Copy(L,1,1) = 's' then MS := Num(Copy(L,2,MaxInt), 50)
        else if Copy(L,1,1) = 'r' then MR := Num(Copy(L,2,MaxInt), 4);
      end;
      if BS > Limit then BS := Limit;
      if (MemLim > 0) and (BS > MemLim div 2) then BS := FitMem(MemLim div 2);
      Result := 'dict:' + ShowMem(BS);
      if MC <> 100 then Result := Result + (':' + IntToStr(MC) + '%');
      if W <> 20 then Result := Result + (':c' + IntToStr(W));
      if LC <> 2048 then Result := Result + (':l' + IntToStr(LC));
      if MM <> 100 then Result := Result + (':m' + IntToStr(MM));
      if MS <> 50 then Result := Result + (':s' + IntToStr(MS));
      if MR <> 4 then Result := Result + (':r' + IntToStr(MR));
      Exit;
    end;

    { --- lzp (C_LZP.cpp/.h). Defaults: 8mb, mc100, mm64, h18, dINTMAX, s32.
          Show imprime :<mm>:h<h> SIEMPRE. SetBlockSize: h=min(h,1+lb(BS-1)). }
    if Name = 'lzp' then
    begin
      BS := ParseMem(Pr(1), 8*MB);
      if BS > Limit then BS := Limit;
      MC := 100; MML := 64; HSL := 18; Bar := INT_MAX; Sm := 32;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if (L <> '') and (L[1] in ['0'..'9']) then
          if Copy(L, Length(L), 1) = '%' then MC := Num(Copy(L, 1, Length(L)-1), 100)
          else MML := Num(L, 64)
        else if Copy(L,1,1) = 'h' then HSL := Num(Copy(L,2,MaxInt), 18)
        else if Copy(L,1,1) = 'd' then Bar := ParseMem(Copy(L,2,MaxInt), INT_MAX)
        else if Copy(L,1,1) = 's' then Sm := Num(Copy(L,2,MaxInt), 32);
      end;
      if (MemLim > 0) and (BS > MemLim div 2) then BS := FitMem(MemLim div 2);
      if HSL > 1 + LB(BS-1) then HSL := 1 + LB(BS-1);
      Result := 'lzp:' + ShowMem(BS);
      if MC <> 100 then Result := Result + (':' + IntToStr(MC) + '%');
      Result := Result + (':' + IntToStr(MML) + ':h' + IntToStr(HSL));
      if Bar <> INT_MAX then Result := Result + (':d' + ShowMem(Bar));
      if Sm <> 32 then Result := Result + (':s' + IntToStr(Sm));
      Exit;
    end;

    { --- tornado (C_Tornado.cpp): TORNADO_METHOD::ShowCompressionMethod, con todos los
          parámetros que difieren de std_Tornado_method[m.number] (antes acá solo quedaban
          número, buffer, h y c: el resto -l, p, s, x, u, t, ah, al, fb- se perdía, y una opción
          desconocida se tomaba como buffer). El número se imprime sólo si <> 5.
          SetDictionary: si mem < buffer, hashsize = 4*min(hs/4, roundup2(mem)).
          Si los parámetros no son válidos queda igual (el codificador da el error). }
    if Name = 'tor' then
    begin
      if not TorParseWithDefaults(Parts, TM, TD) then Exit(S);
      BS := TM.Buffer; HS := TM.HashSize;
      if BS > Limit then
      begin
        HS := 4 * Min(Int64(HS div 4), RoundUpPow2(Limit));  { PtrVal=4, 32-bit }
        BS := Limit;
      end;
      // -lc: búfer + hash dentro del límite (se achica el mayor de los dos)
      if MemLim > 0 then
        while (BS + HS > MemLim) and ((BS > 64*KB) or (HS > 64*KB)) do
          if (HS >= BS) and (HS > 64*KB) then HS := HS div 2 else BS := BS div 2;
      Result := 'tor';
      if TM.Number <> default_Tornado_method then Result := Result + (':' + IntToStr(TM.Number));
      Result := Result + (':' + ShowMem(BS));
      if HS <> TD.HashSize then Result := Result + (':h' + ShowMem(HS));
      if TM.HashRowWidth <> TD.HashRowWidth then Result := Result + (':l' + IntToStr(TM.HashRowWidth));
      if TM.EncodingMethod <> TD.EncodingMethod then Result := Result + (':c' + IntToStr(TM.EncodingMethod));
      if TM.MatchParser <> TD.MatchParser then Result := Result + (':p' + IntToStr(TM.MatchParser));
      if TM.MatchFinder <> TD.MatchFinder then Result := Result + (':x' + IntToStr(TM.MatchFinder));
      if TM.UpdateStep <> TD.UpdateStep then Result := Result + (':u' + IntToStr(TM.UpdateStep));
      if TM.FindTables <> TD.FindTables then Result := Result + (':t' + IntToStr(Ord(TM.FindTables)));
      if TM.AuxHashSize <> TD.AuxHashSize then Result := Result + (':ah' + ShowMem(TM.AuxHashSize));
      if TM.AuxHashRowWidth <> TD.AuxHashRowWidth then Result := Result + (':al' + IntToStr(TM.AuxHashRowWidth));
      if TM.Hash3 <> TD.Hash3 then Result := Result + (':s' + IntToStr(TM.Hash3));
      if TM.FastBytes <> TD.FastBytes then Result := Result + (':fb' + IntToStr(TM.FastBytes));
      Exit;
    end;

    { --- srep: compresor externo; el método guardado es siempre "srep". }
    if Name = 'srep' then Exit('srep');

    { --- dispack (C_DisPack.cpp): BlockSize por defecto 8 MB; :x no cambia el flujo. }
    if (Name = 'dispack') or (Name = 'dispack070') then
    begin
      BS := 8*MB;
      Ext := False;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if L = 'x' then
        begin
          Ext := True;
          Continue;
        end;
        if (L <> '') and (L[1] = 'b') and (Length(L) > 1) then
          BS := CMem(Copy(L, 2, MaxInt), BS)
        else if L <> '' then
          BS := CMem(L, BS);
      end;
      if BS <= 0 then BS := 8*MB;
      Result := 'dispack070';
      if BS <> 8*MB then Result := Result + (':' + ShowMem(BS));   // Show no pone la 'b'
      if Ext then Result := Result + (':x');
      Exit;
    end;

    { --- ppmd (parc_ppmd, LZMA SDK var.I): orden, memoria y método de recuperación, con la
      misma lectura que el codificador y el decodificador (ParsePpmdParams). Sin límite. }
    if Name = 'ppmd' then
    begin
      PP := ParsePpmdParams(Parts);
      M := Int64(PP.Mem);
      if (MemLim > 0) and (M > MemLim) then M := FitMem(MemLim);
      Result := 'ppmd:' + IntToStr(PP.Order) + ':' + ShowMem(M);
      if PP.Restore = 1 then Result := Result + ':r'
      else if PP.Restore <> 0 then Result := Result + ':r' + IntToStr(PP.Restore);
      Exit;
    end;

    { --- tta (C_TTA.cpp): defaults level3, s0. }
    if Name = 'tta' then
    begin
      Lvl := 3;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if Copy(L,1,1) = 'm' then Lvl := Num(Copy(L,2,MaxInt), 3);
      end;
      Result := 'tta';
      if Lvl <> 3 then Result := Result + (':m' + IntToStr(Lvl));
      Exit;
    end;

    { --- lz4 (parc_lz4enc). Defaults: c0, b1mb, 100%; "hc" es c2. El límite de memoria no lo toca. }
    if Name = 'lz4' then
    begin
      MC := 0; BS := MB; M := 100;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if L = '' then Continue;
        if L = 'hc' then MC := 2
        else if L[1] = 'c' then MC := Num(Copy(L,2,MaxInt), 0)
        else if L[1] = 'b' then BS := CMem(Copy(L,2,MaxInt), MB)
        else if L[Length(L)] = '%' then M := Num(Copy(L,1,Length(L)-1), 100);
      end;
      Result := 'lz4';
      if MC <> 0 then Result := Result + ':c' + IntToStr(MC);
      if BS <> MB then Result := Result + ':b' + CShowMem(BS);
      if M <> 100 then Result := Result + ':' + IntToStr(M) + '%';
      Exit;
    end;

    { --- 4x4 (C_4x4.cpp/.h): :b<mem> propio (no se limita ni purifica),
          el resto es el método interno, que hereda el límite y se canoniza.
          Igual que parse_4x4: un parámetro es propio si empieza con dígito o si el
          segundo carácter es dígito (t4, i2, r99, b7mb); el primero que no, arranca el
          método interno. Sin método interno, el default del constructor: tor:3:1mb. }
    if Name = '4x4' then
    begin
      BS := 0; StartI := 0;
      for J := 1 to High(Parts) do
      begin
        L := Parts[J];
        if (L <> '') and ((L[1] in ['0'..'9']) or
                          ((Length(L) > 1) and (L[2] in ['0'..'9']))) then
        begin
          // Parámetros propios de 4x4: :b<mem>, :t<n>, :i<n>, :r<porcentaje>, un número
          // suelto (hilos) o una memoria suelta (8mb). Sólo :b queda en el texto canónico
          // (purify no imprime los que sólo afectan a comprimir).
          if L[1] in ['0'..'9'] then
          begin
            if StrToInt64Def(L, -1) < 0 then BS := ParseMem(L, 0);   // "8mb" = BlockSize
          end
          else if (L[1] = 'b') or (L[1] = 'B') then BS := ParseMem(Copy(L, 2, MaxInt), 0);
        end
        else
        begin StartI := J; Break; end;
      end;
      if StartI = 0 then Interno := 'tor:3:1mb'
      else
      begin
        Interno := '';
        for J := StartI to High(Parts) do
        begin
          if Interno <> '' then Interno := Interno + (':');
          Interno := Interno + (Parts[J]);
        end;
      end;
      Result := '4x4';
      // ShowCompressionMethod con purify=True no imprime t/i/r (solo afectan a comprimir):
      // quedan el :b propio y el método interno.
      if BS <> 0 then Result := Result + (':b' + ShowMem(BS));
      if MemLim > 0 then
        Result := Result + (':' + CanonChain(Interno, Limit, Max(Int64(MB), MemLim div Max(1, BudgetThreads))))
      else
        Result := Result + (':' + CanonChain(Interno, Limit, 0));
      Exit;
    end;

    { --- etapas sin diccionario ni parámetros en el corpus }
    if (Name = 'exe') or (Name = 'mm') or (Name = 'delta') or (Name = 'storing')
       or (Name = 'crc') then Exit(Name);

    Result := S;   { desconocida: igual (criterio "lo que no se toca, igual") }
  end;

begin
  Stages := Method.Split(['+'], TStringSplitOptions.None);
  SetLength(Stages, Length(Stages));
  Result := '';
  for I := 0 to High(Stages) do
  begin
    if I > 0 then Result := Result + ('+');
    Result := Result + (CanonStage(Stages[I]));
    // compressionLimitDictionary (Compression.hs:199): después de un compresor externo ya no
    // se achican los diccionarios de las etapas siguientes.
    if StageNameOf(Stages[I]) = 'srep' then Limit := High(Int64);
  end;
end;

{ --- API pública ------------------------------------------------------------ }

function LimitAndCanonize(const Method: string; BlockSize: Int64): string;
begin
  Result := CanonChain(Method, RoundMemUp(BlockSize + BlockSize div 100 + 512), 0);
end;

function CanonStageMem(const Stage: string; MemLim: Int64): string;
begin
  Result := CanonChain(Stage, High(Int64), MemLim);
end;

function EffectiveCompressLimit: Int64;
var
  Ram, Va: Int64;
begin
  if CompressMemLimit >= 0 then Exit(CompressMemLimit);
  Ram := PhysicalMemory;
  if Ram > 0 then Result := Ram div 4 * 3 else Result := 0;
  {$IFNDEF CPU64}
  // Medido en win32 (Wine, 4 GB LAA) con TILIN -m9 y 8 hilos: 2304 MB llega a 2,4 GB de RSS
  // sin quedarse sin memoria; 2560 MB ya fallaba (antes del arreglo de la ventana de rep)
  if (Result = 0) or (Result > Int64(2304) shl 20) then Result := Int64(2304) shl 20;
  Va := AddressSpaceLimit;
  if (Va > 0) and (Va div 16 * 9 < Result) then Result := Va div 16 * 9;
  {$ELSE}
  Va := AddressSpaceLimit;   // ulimit -v
  if (Va > 0) and ((Result = 0) or (Va div 4 * 3 < Result)) then Result := Va div 4 * 3;
  {$ENDIF}
end;

end.
